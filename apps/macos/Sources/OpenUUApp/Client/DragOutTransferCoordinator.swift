import AppKit
import Foundation
import UniformTypeIdentifiers

struct DragOutItemDescriptor: Sendable, Equatable {
    let blobID: String
    let filename: String
    let totalBytes: UInt64
}

/// Thread-safe bridge object retained until Finder finishes fulfilling an `NSFilePromiseProvider` drop.
private final class DragOutPromiseDelegate: NSObject, NSFilePromiseProviderDelegate, @unchecked Sendable {
    private let lock = NSLock()
    let blobID: String
    let originalFilename: String
    private var completedInboxURL: URL?
    private var isCancelledOrFailed = false
    private let queue: OperationQueue = {
        let q = OperationQueue()
        q.name = "ren.onekb.openuu.filepromise"
        q.maxConcurrentOperationCount = 2
        q.qualityOfService = .userInitiated
        return q
    }()

    init(blobID: String, originalFilename: String, completedInboxURL: URL?) {
        self.blobID = blobID
        self.originalFilename = originalFilename
        self.completedInboxURL = completedInboxURL
        super.init()
    }

    func setCompleted(inboxURL: URL) {
        lock.lock()
        completedInboxURL = inboxURL
        lock.unlock()
    }

    func setCancelledOrFailed() {
        lock.lock()
        isCancelledOrFailed = true
        lock.unlock()
    }

    func snapshot() -> (completedURL: URL?, failed: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (completedInboxURL, isCancelledOrFailed)
    }

    func operationQueue(for filePromiseProvider: NSFilePromiseProvider) -> OperationQueue {
        queue
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        let snap = snapshot()
        if snap.completedURL != nil {
            return originalFilename
        }
        return "\(originalFilename).downloading"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let snap = snapshot()
        if snap.failed {
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
            return
        }

        let fm = FileManager.default
        let isPlaceholderTarget = url.lastPathComponent.hasSuffix(".downloading")

        // Fast path 1: Already finished before `fileNameForType` was queried (`url` has the final filename).
        if let inboxURL = snap.completedURL, !isPlaceholderTarget {
            do {
                if fm.fileExists(atPath: url.path) {
                    try? fm.removeItem(at: url)
                }
                try fm.moveItem(at: inboxURL, to: url)
                try? fm.removeItem(at: inboxURL.deletingLastPathComponent())
                completionHandler(nil)
                let bid = self.blobID
                Task { @MainActor in
                    DragOutTransferCoordinator.shared.didFulfillDirectPromise(blobID: bid)
                }
            } catch {
                completionHandler(error)
            }
            return
        }

        // Fast path 2: Finished in the tiny window between `fileNameForType` and `writePromiseTo`.
        if let inboxURL = snap.completedURL, isPlaceholderTarget {
            fm.createFile(atPath: url.path, contents: Data())
            completionHandler(nil)
            let bid = self.blobID
            let origName = self.originalFilename
            Task { @MainActor in
                DragOutTransferCoordinator.shared.replacePlaceholderImmediately(
                    blobID: bid,
                    placeholderURL: url,
                    inboxURL: inboxURL,
                    preferredFilename: origName
                )
            }
            return
        }

        // Streaming large-file path: create `.downloading` placeholder immediately (< 1ms) so Finder and user
        // are NEVER blocked waiting for the remaining network transfer, then swap atomically on completion!
        let created = fm.createFile(atPath: url.path, contents: Data())
        if !created {
            completionHandler(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError))
            return
        }
        let bookmark = try? url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        completionHandler(nil)

        let bid = self.blobID
        Task { @MainActor in
            DragOutTransferCoordinator.shared.attachPlaceholder(
                blobID: bid,
                placeholderURL: url,
                bookmark: bookmark
            )
        }
    }
}

/// Coordinates cross-machine drag-out transfers:
/// - Small/fast files: swapped directly as ready-to-use files with zero placeholder overhead.
/// - Large/slow files: immediately draggable at the window border, materialized as `<name>.downloading`
///   placeholders on drop while showing a non-activating live progress HUD, and atomically renamed on completion.
@MainActor
final class DragOutTransferCoordinator {
    static let shared = DragOutTransferCoordinator()

    enum Phase: Equatable {
        case transferring
        case completed
        case failed
        case cancelled
    }

    struct TransferRecord {
        let blobID: String
        let filename: String
        var receivedBytes: UInt64
        var totalBytes: UInt64
        var speedBytesPerSec: Double
        var lastSampleTime: CFAbsoluteTime
        var lastSampleBytes: UInt64
        var phase: Phase
        var inboxCompletedURL: URL?
        var placeholderURL: URL?
        var placeholderBookmark: Data?
        var isClaimedByDragOut: Bool
        var showInHUD: Bool
        var hudRevealTask: Task<Void, Never>?
        var hudDismissTask: Task<Void, Never>?
    }

    private var records: [String: TransferRecord] = [:]
    private var orderedHUDIDs: [String] = []
    private var promiseDelegates: [String: DragOutPromiseDelegate] = [:]
    private lazy var hudController = DragTransferHUDController { [weak self] blobID in
        self?.cancelTransfer(blobID: blobID)
    }

    private init() {}

    // MARK: - Incoming Stream Lifecycle (called from RemotePeerSession)

    func registerTransferStarted(blobID: String, filename: String, totalBytes: UInt64) -> DragOutItemDescriptor {
        let cleanName = filename.isEmpty ? "file.bin" : filename
        let now = CFAbsoluteTimeGetCurrent()
        if records[blobID] == nil {
            records[blobID] = TransferRecord(
                blobID: blobID,
                filename: cleanName,
                receivedBytes: 0,
                totalBytes: totalBytes,
                speedBytesPerSec: 0,
                lastSampleTime: now,
                lastSampleBytes: 0,
                phase: .transferring,
                inboxCompletedURL: nil,
                placeholderURL: nil,
                placeholderBookmark: nil,
                isClaimedByDragOut: false,
                showInHUD: false,
                hudRevealTask: nil,
                hudDismissTask: nil
            )
        }
        return DragOutItemDescriptor(blobID: blobID, filename: cleanName, totalBytes: totalBytes)
    }

    func updateTransferProgress(blobID: String, filename: String, receivedBytes: UInt64, totalBytes: UInt64) {
        let now = CFAbsoluteTimeGetCurrent()
        if records[blobID] == nil {
            _ = registerTransferStarted(blobID: blobID, filename: filename, totalBytes: totalBytes)
        }
        guard var rec = records[blobID], rec.phase == .transferring else { return }

        let dt = now - rec.lastSampleTime
        if dt >= 0.08 && receivedBytes >= rec.lastSampleBytes {
            let instantSpeed = Double(receivedBytes - rec.lastSampleBytes) / dt
            rec.speedBytesPerSec = rec.speedBytesPerSec > 0
                ? (rec.speedBytesPerSec * 0.65 + instantSpeed * 0.35)
                : instantSpeed
            rec.lastSampleTime = now
            rec.lastSampleBytes = receivedBytes
        }
        rec.receivedBytes = receivedBytes
        if totalBytes > 0 {
            rec.totalBytes = totalBytes
        }
        records[blobID] = rec
        if rec.showInHUD {
            refreshHUD()
        }
    }

    func markTransferFailed(blobID: String) {
        guard var rec = records[blobID] else { return }
        rec.hudRevealTask?.cancel()
        rec.hudRevealTask = nil
        promiseDelegates[blobID]?.setCancelledOrFailed()
        cleanupPlaceholderIfPresent(for: &rec)

        if rec.phase == .cancelled {
            removeRecord(blobID: blobID)
            return
        }

        rec.phase = .failed
        records[blobID] = rec
        if rec.showInHUD || rec.isClaimedByDragOut {
            ensureShownInHUD(blobID: blobID)
            scheduleAutoDismiss(blobID: blobID, afterMs: 2600)
        } else {
            removeRecord(blobID: blobID)
        }
    }

    /// Returns `true` if this blob belonged to a drag-out flow (claimed or active), `false` if unhandled.
    func markTransferCompleted(blobID: String, inboxURL: URL, totalBytes: UInt64) -> Bool {
        let fallbackName = inboxURL.lastPathComponent
        let fileSize = totalBytes > 0
            ? totalBytes
            : ((try? FileManager.default.attributesOfItem(atPath: inboxURL.path)[.size] as? UInt64) ?? 0)

        if records[blobID] == nil {
            let now = CFAbsoluteTimeGetCurrent()
            records[blobID] = TransferRecord(
                blobID: blobID,
                filename: fallbackName,
                receivedBytes: fileSize,
                totalBytes: fileSize,
                speedBytesPerSec: 0,
                lastSampleTime: now,
                lastSampleBytes: fileSize,
                phase: .completed,
                inboxCompletedURL: inboxURL,
                placeholderURL: nil,
                placeholderBookmark: nil,
                isClaimedByDragOut: false,
                showInHUD: false,
                hudRevealTask: nil,
                hudDismissTask: nil
            )
        }

        guard var rec = records[blobID] else { return false }
        rec.hudRevealTask?.cancel()
        rec.hudRevealTask = nil
        if rec.phase == .cancelled {
            try? FileManager.default.removeItem(at: inboxURL.deletingLastPathComponent())
            removeRecord(blobID: blobID)
            return true
        }

        rec.phase = .completed
        rec.receivedBytes = max(rec.totalBytes, fileSize)
        rec.totalBytes = max(rec.totalBytes, fileSize)
        rec.inboxCompletedURL = inboxURL
        records[blobID] = rec

        promiseDelegates[blobID]?.setCompleted(inboxURL: inboxURL)

        // If user ALREADY dropped the `.downloading` placeholder onto Desktop/Finder, atomically swap it now!
        if rec.placeholderURL != nil || rec.placeholderBookmark != nil {
            finalizePlaceholderWithCompletedFile(blobID: blobID, inboxURL: inboxURL)
            return true
        }

        // If HUD was already visible while user is still dragging, update it to 100% and dismiss shortly.
        if rec.showInHUD {
            refreshHUD()
            scheduleAutoDismiss(blobID: blobID, afterMs: 1800)
        }
        return rec.isClaimedByDragOut
    }

    // MARK: - Drag-Out Session Construction (called from ProxyInteractiveView)

    func makeDraggingItem(
        for descriptor: DragOutItemDescriptor,
        localPoint: NSPoint,
        offsetIndex: Int
    ) -> NSDraggingItem? {
        let blobID = descriptor.blobID
        if records[blobID] == nil {
            _ = registerTransferStarted(
                blobID: blobID,
                filename: descriptor.filename,
                totalBytes: descriptor.totalBytes
            )
        }
        guard var rec = records[blobID], rec.phase != .cancelled, rec.phase != .failed else {
            return nil
        }

        rec.isClaimedByDragOut = true
        records[blobID] = rec

        let offset = CGFloat(offsetIndex * 6)
        let dragFrame = NSRect(x: localPoint.x - 24 + offset, y: localPoint.y - 24 - offset, width: 48, height: 48)

        // Fast Path: file already finished downloading before cursor reached the window border!
        if rec.phase == .completed, let readyURL = rec.inboxCompletedURL,
           FileManager.default.fileExists(atPath: readyURL.path) {
            let item = NSDraggingItem(pasteboardWriter: readyURL as NSURL)
            let icon = NSWorkspace.shared.icon(forFile: readyURL.path)
            icon.size = NSSize(width: 48, height: 48)
            item.setDraggingFrame(dragFrame, contents: icon)
            scheduleAutoCleanupUnplacedCompleted(blobID: blobID, afterSeconds: 60)
            return item
        }

        // Streaming / Large-File Path: wrap in `NSFilePromiseProvider` for 0ms instant drag-out + `.downloading` placeholder.
        let delegate = DragOutPromiseDelegate(
            blobID: blobID,
            originalFilename: rec.filename,
            completedInboxURL: rec.inboxCompletedURL
        )
        promiseDelegates[blobID] = delegate

        let ext = (rec.filename as NSString).pathExtension
        let utType = (!ext.isEmpty ? UTType(filenameExtension: ext) : nil)
            .flatMap { $0.conforms(to: .data) ? $0 : nil } ?? .data
        let provider = NSFilePromiseProvider(fileType: utType.identifier, delegate: delegate)

        let item = NSDraggingItem(pasteboardWriter: provider)
        let icon = Self.iconForFilename(rec.filename)
        icon.size = NSSize(width: 48, height: 48)
        item.setDraggingFrame(dragFrame, contents: icon)

        // Debounce HUD by 180ms so tiny files that finish almost immediately don't flash a banner,
        // while large transfers show real-time progress right away even while still dragging!
        rec.hudRevealTask?.cancel()
        rec.hudRevealTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled, let self else { return }
            guard let cur = self.records[blobID], cur.phase == .transferring else { return }
            self.ensureShownInHUD(blobID: blobID)
        }
        records[blobID] = rec
        return item
    }

    /// Called if the user released the mouse INSIDE the remote window without ever dragging out to the border.
    func abandonUnclaimedDragOut(blobID: String) {
        guard let rec = records[blobID], !rec.isClaimedByDragOut else { return }
        if rec.phase == .transferring {
            // Abort large in-flight stream so an internal click/drag never wastes bandwidth.
            OpenUUBridge.cancelIncomingBlob(blobID: blobID)
        } else if let url = rec.inboxCompletedURL {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        removeRecord(blobID: blobID)
    }

    /// Called when the local `NSDraggingSession` ends. If the user cancelled the drag (dropped nowhere / pressed Esc),
    /// clean up any background stream after a short grace window for Finder's `writePromiseTo` callback.
    func noteDraggingSessionEnded(blobIDs: [String], operation: NSDragOperation) {
        guard operation == [] else { return }
        Task { @MainActor [weak self] in
            // Give Finder 600ms in case a promise drop reports `operation == []` before `writePromiseTo` runs.
            try? await Task.sleep(for: .milliseconds(600))
            guard let self else { return }
            for bid in blobIDs {
                guard let rec = self.records[bid],
                      rec.placeholderURL == nil,
                      rec.placeholderBookmark == nil else {
                    continue
                }
                if rec.phase == .transferring {
                    self.cancelTransfer(blobID: bid)
                } else {
                    if let url = rec.inboxCompletedURL {
                        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
                    }
                    self.removeRecord(blobID: bid)
                }
            }
        }
    }

    // MARK: - Placeholder Attachment, Atomic Swap & User Cancellation

    fileprivate func didFulfillDirectPromise(blobID: String) {
        guard let rec = records[blobID] else { return }
        if rec.showInHUD {
            refreshHUD()
            scheduleAutoDismiss(blobID: blobID, afterMs: 1500)
        } else {
            removeRecord(blobID: blobID)
        }
    }

    fileprivate func attachPlaceholder(blobID: String, placeholderURL: URL, bookmark: Data?) {
        guard var rec = records[blobID] else {
            try? FileManager.default.removeItem(at: placeholderURL)
            return
        }
        if rec.phase == .cancelled || rec.phase == .failed {
            try? FileManager.default.removeItem(at: placeholderURL)
            return
        }
        rec.placeholderURL = placeholderURL
        rec.placeholderBookmark = bookmark
        records[blobID] = rec

        if rec.phase == .completed, let inboxURL = rec.inboxCompletedURL {
            finalizePlaceholderWithCompletedFile(blobID: blobID, inboxURL: inboxURL)
        } else {
            ensureShownInHUD(blobID: blobID)
        }
    }

    fileprivate func replacePlaceholderImmediately(
        blobID: String,
        placeholderURL: URL,
        inboxURL: URL,
        preferredFilename: String
    ) {
        swapPlaceholderToFinal(placeholderURL: placeholderURL, bookmark: nil, inboxURL: inboxURL, preferredFilename: preferredFilename)
        if let rec = records[blobID], rec.showInHUD {
            refreshHUD()
            scheduleAutoDismiss(blobID: blobID, afterMs: 1500)
        } else {
            removeRecord(blobID: blobID)
        }
    }

    func cancelTransfer(blobID: String) {
        OpenUUBridge.cancelIncomingBlob(blobID: blobID)
        promiseDelegates[blobID]?.setCancelledOrFailed()
        guard var rec = records[blobID] else { return }
        rec.hudRevealTask?.cancel()
        rec.hudRevealTask = nil
        rec.hudDismissTask?.cancel()
        rec.hudDismissTask = nil
        rec.phase = .cancelled
        cleanupPlaceholderIfPresent(for: &rec)
        if let inboxURL = rec.inboxCompletedURL {
            try? FileManager.default.removeItem(at: inboxURL.deletingLastPathComponent())
        }
        removeRecord(blobID: blobID)
    }

    private func finalizePlaceholderWithCompletedFile(blobID: String, inboxURL: URL) {
        guard var rec = records[blobID] else { return }
        let pURL = rec.placeholderURL
        let bmk = rec.placeholderBookmark
        rec.placeholderURL = nil
        rec.placeholderBookmark = nil
        records[blobID] = rec

        swapPlaceholderToFinal(
            placeholderURL: pURL,
            bookmark: bmk,
            inboxURL: inboxURL,
            preferredFilename: rec.filename
        )

        ensureShownInHUD(blobID: blobID)
        scheduleAutoDismiss(blobID: blobID, afterMs: 1800)
    }

    private func swapPlaceholderToFinal(
        placeholderURL: URL?,
        bookmark: Data?,
        inboxURL: URL,
        preferredFilename: String
    ) {
        let fm = FileManager.default
        var resolvedPlaceholder = placeholderURL
        if let bookmark {
            var isStale = false
            if let bmkURL = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ) {
                resolvedPlaceholder = bmkURL
            }
        }

        let targetDir: URL
        if let p = resolvedPlaceholder, fm.fileExists(atPath: p.deletingLastPathComponent().path) {
            targetDir = p.deletingLastPathComponent()
        } else {
            targetDir = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        }

        // Remove `.downloading` placeholder first, then move completed file into its final non-colliding name.
        if let p = resolvedPlaceholder {
            try? fm.removeItem(at: p)
        }
        let finalURL = Self.uniqueDestinationURL(in: targetDir, preferredName: preferredFilename)
        do {
            try fm.moveItem(at: inboxURL, to: finalURL)
        } catch {
            try? fm.copyItem(at: inboxURL, to: finalURL)
            try? fm.removeItem(at: inboxURL)
        }
        try? fm.removeItem(at: inboxURL.deletingLastPathComponent())
    }

    private func cleanupPlaceholderIfPresent(for rec: inout TransferRecord) {
        let fm = FileManager.default
        if let bookmark = rec.placeholderBookmark {
            var stale = false
            if let bmkURL = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                try? fm.removeItem(at: bmkURL)
            }
        }
        if let p = rec.placeholderURL {
            try? fm.removeItem(at: p)
        }
        rec.placeholderURL = nil
        rec.placeholderBookmark = nil
    }

    // MARK: - HUD Management & Cleanup

    private func ensureShownInHUD(blobID: String) {
        guard var rec = records[blobID] else { return }
        rec.showInHUD = true
        records[blobID] = rec
        if !orderedHUDIDs.contains(blobID) {
            orderedHUDIDs.append(blobID)
        }
        refreshHUD()
    }

    private func scheduleAutoDismiss(blobID: String, afterMs: Int) {
        records[blobID]?.hudDismissTask?.cancel()
        records[blobID]?.hudDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(afterMs))
            guard !Task.isCancelled, let self else { return }
            self.removeRecord(blobID: blobID)
        }
    }

    private func scheduleAutoCleanupUnplacedCompleted(blobID: String, afterSeconds: Int) {
        records[blobID]?.hudDismissTask?.cancel()
        records[blobID]?.hudDismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(afterSeconds))
            guard !Task.isCancelled, let self else { return }
            if let rec = self.records[blobID], rec.placeholderURL == nil, rec.placeholderBookmark == nil {
                if let inboxURL = rec.inboxCompletedURL {
                    try? FileManager.default.removeItem(at: inboxURL.deletingLastPathComponent())
                }
                self.removeRecord(blobID: blobID)
            }
        }
    }

    private func removeRecord(blobID: String) {
        if let rec = records.removeValue(forKey: blobID) {
            rec.hudRevealTask?.cancel()
            rec.hudDismissTask?.cancel()
        }
        orderedHUDIDs.removeAll { $0 == blobID }
        promiseDelegates.removeValue(forKey: blobID)
        refreshHUD()
    }

    private func refreshHUD() {
        let visibleRecords = orderedHUDIDs.compactMap { records[$0] }.filter(\.showInHUD)
        hudController.update(with: visibleRecords)
    }

    // MARK: - Helpers

    static func iconForFilename(_ filename: String) -> NSImage {
        let ext = (filename as NSString).pathExtension
        if !ext.isEmpty, let utType = UTType(filenameExtension: ext) {
            return NSWorkspace.shared.icon(for: utType)
        }
        return NSWorkspace.shared.icon(for: .data)
    }

    private static func uniqueDestinationURL(in directory: URL, preferredName: String) -> URL {
        let fm = FileManager.default
        let candidate = directory.appendingPathComponent(preferredName)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }
        let nsName = preferredName as NSString
        let ext = nsName.pathExtension
        let stem = nsName.deletingPathExtension
        for idx in 2...999 {
            let nextName = ext.isEmpty ? "\(stem) (\(idx))" : "\(stem) (\(idx)).\(ext)"
            let nextURL = directory.appendingPathComponent(nextName)
            if !fm.fileExists(atPath: nextURL.path) {
                return nextURL
            }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(preferredName)")
    }
}

// MARK: - Non-Activating Floating Transfer Progress HUD

@MainActor
private final class DragTransferHUDController {
    private let onCancel: (String) -> Void
    private var panel: NSPanel?
    private let stackContainer = NSView()
    private let backgroundView = NSVisualEffectView()
    private var rowViews: [String: TransferRowView] = [:]

    init(onCancel: @escaping (String) -> Void) {
        self.onCancel = onCancel
    }

    func update(with records: [DragOutTransferCoordinator.TransferRecord]) {
        if records.isEmpty {
            panel?.orderOut(nil)
            for (_, v) in rowViews {
                v.removeFromSuperview()
            }
            rowViews.removeAll()
            return
        }

        let panel = ensurePanel()
        let shown = Array(records.suffix(3))
        let shownIDs = Set(shown.map(\.blobID))

        for (bid, view) in rowViews where !shownIDs.contains(bid) {
            view.removeFromSuperview()
            rowViews.removeValue(forKey: bid)
        }

        let width: CGFloat = 344
        let rowH: CGFloat = 64
        let pad: CGFloat = 8
        let totalH = CGFloat(shown.count) * rowH + pad * 2

        backgroundView.frame = NSRect(x: 0, y: 0, width: width, height: totalH)
        stackContainer.frame = backgroundView.bounds

        for (idx, rec) in shown.enumerated() {
            let y = totalH - pad - CGFloat(idx + 1) * rowH
            let rowFrame = NSRect(x: pad, y: y, width: width - pad * 2, height: rowH)
            let row: TransferRowView
            if let existing = rowViews[rec.blobID] {
                row = existing
                row.frame = rowFrame
            } else {
                let bid = rec.blobID
                row = TransferRowView(frame: rowFrame) { [weak self] in
                    self?.onCancel(bid)
                }
                rowViews[rec.blobID] = row
                stackContainer.addSubview(row)
            }
            row.configure(with: rec)
        }

        if let screen = NSScreen.main ?? NSScreen.screens.first {
            let vf = screen.visibleFrame
            let targetFrame = NSRect(
                x: vf.maxX - width - 18,
                y: vf.maxY - totalH - 14,
                width: width,
                height: totalH
            )
            panel.setFrame(targetFrame, display: true)
        }
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
    }

    private func ensurePanel() -> NSPanel {
        if let existing = panel {
            return existing
        }
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 344, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true

        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 14
        backgroundView.layer?.masksToBounds = true
        backgroundView.layer?.borderWidth = 0.8
        backgroundView.layer?.borderColor = NSColor.white.withAlphaComponent(0.18).cgColor

        backgroundView.addSubview(stackContainer)
        p.contentView = backgroundView
        self.panel = p
        return p
    }
}

@MainActor
private final class TransferRowView: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let trackLayer = CALayer()
    private let fillLayer = CALayer()
    private let cancelButton = NSButton()
    private let onCancelClicked: () -> Void
    private var currentFraction: CGFloat = 0

    init(frame frameRect: NSRect, onCancelClicked: @escaping () -> Void) {
        self.onCancelClicked = onCancelClicked
        super.init(frame: frameRect)
        wantsLayer = true

        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingMiddle
        addSubview(titleLabel)

        detailLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = NSColor.white.withAlphaComponent(0.78)
        detailLabel.lineBreakMode = .byTruncatingTail
        addSubview(detailLabel)

        trackLayer.backgroundColor = NSColor.white.withAlphaComponent(0.18).cgColor
        trackLayer.cornerRadius = 2.5
        layer?.addSublayer(trackLayer)

        fillLayer.backgroundColor = NSColor.systemBlue.cgColor
        fillLayer.cornerRadius = 2.5
        trackLayer.addSublayer(fillLayer)

        cancelButton.bezelStyle = .inline
        cancelButton.isBordered = false
        cancelButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "取消传输")
        cancelButton.contentTintColor = NSColor.white.withAlphaComponent(0.7)
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        addSubview(cancelButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func handleCancel() {
        onCancelClicked()
    }

    override func layout() {
        super.layout()
        iconView.frame = NSRect(x: 8, y: (bounds.height - 34) / 2, width: 34, height: 34)
        let rightSpace: CGFloat = cancelButton.isHidden ? 10 : 34
        let textX: CGFloat = 50
        let textW = max(80, bounds.width - textX - rightSpace)
        titleLabel.frame = NSRect(x: textX, y: bounds.height - 23, width: textW, height: 17)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = NSRect(x: textX, y: 24, width: textW, height: 5)
        fillLayer.frame = CGRect(x: 0, y: 0, width: max(0, textW * currentFraction), height: 5)
        CATransaction.commit()
        detailLabel.frame = NSRect(x: textX, y: 6, width: textW, height: 15)
        cancelButton.frame = NSRect(x: bounds.width - 28, y: (bounds.height - 22) / 2, width: 22, height: 22)
    }

    func configure(with rec: DragOutTransferCoordinator.TransferRecord) {
        iconView.image = DragOutTransferCoordinator.iconForFilename(rec.filename)
        titleLabel.stringValue = rec.filename

        let fraction: CGFloat
        if rec.totalBytes > 0 {
            fraction = CGFloat(min(1.0, Double(rec.receivedBytes) / Double(rec.totalBytes)))
        } else {
            fraction = rec.phase == .completed ? 1.0 : 0.15
        }
        currentFraction = rec.phase == .completed ? 1.0 : fraction

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let barW = max(0, trackLayer.bounds.width * currentFraction)
        fillLayer.frame = CGRect(x: 0, y: 0, width: barW, height: 5)

        switch rec.phase {
        case .transferring:
            fillLayer.backgroundColor = NSColor.systemBlue.cgColor
            cancelButton.isHidden = false
            let pct = Int((fraction * 100).rounded())
            let curStr = Self.formatBytes(rec.receivedBytes)
            let totStr = Self.formatBytes(rec.totalBytes)
            let spdStr = rec.speedBytesPerSec > 1024 ? " · \(Self.formatBytes(UInt64(rec.speedBytesPerSec)))/s" : ""
            let suffix = rec.placeholderURL != nil ? "占位接收中" : "正在传出"
            detailLabel.stringValue = "\(suffix) \(pct)% (\(curStr)/\(totStr))\(spdStr)"
        case .completed:
            fillLayer.backgroundColor = NSColor.systemGreen.cgColor
            cancelButton.isHidden = true
            detailLabel.stringValue = "✓ 传输完成，已就绪 (\(Self.formatBytes(rec.totalBytes)))"
        case .failed:
            fillLayer.backgroundColor = NSColor.systemRed.cgColor
            cancelButton.isHidden = true
            detailLabel.stringValue = "✕ 文件传输中断，已清理临时占位文件"
        case .cancelled:
            fillLayer.backgroundColor = NSColor.systemGray.cgColor
            cancelButton.isHidden = true
            detailLabel.stringValue = "已取消传输"
        }
        CATransaction.commit()
        needsLayout = true
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024.0
        if kb < 1024.0 {
            return String(format: "%.0f KB", max(1, kb))
        }
        let mb = kb / 1024.0
        if mb < 1024.0 {
            return String(format: "%.1f MB", mb)
        }
        return String(format: "%.2f GB", mb / 1024.0)
    }
}
