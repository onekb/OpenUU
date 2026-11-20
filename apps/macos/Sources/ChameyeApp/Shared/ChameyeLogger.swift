import AppKit
import CoreGraphics
import Foundation

/// Thread-safe diagnostic logger that keeps an in-memory ring buffer and appends to a rolling
/// log file at `~/Library/Logs/Chameye/chameye.log` (max 5 MiB) for one-click bug reporting.
final class ChameyeLogger: @unchecked Sendable {
    static let shared = ChameyeLogger()

    let logDirectoryURL: URL
    let logFileURL: URL

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.chameye.logger.io", qos: .utility)
    private var ringBuffer: [String] = []
    private let maxMemoryLines = 1500
    private let maxFileBytes: UInt64 = 5 * 1024 * 1024 // 5 MiB
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    var onLineAppended: ((String) -> Void)?

    private init() {
        let homeLogs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Chameye", isDirectory: true)
        self.logDirectoryURL = homeLogs
        self.logFileURL = homeLogs.appendingPathComponent("chameye.log")
        try? FileManager.default.createDirectory(at: homeLogs, withIntermediateDirectories: true)
    }

    func log(_ category: String, _ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        let ts = dateFormatter.string(from: Date())
        let line = "[\(ts)] [\(category)] \(trimmed)"
        ringBuffer.append(line)
        if ringBuffer.count > maxMemoryLines {
            ringBuffer.removeFirst(ringBuffer.count - maxMemoryLines)
        }
        let callback = onLineAppended
        lock.unlock()

        ioQueue.async { [logFileURL, maxFileBytes] in
            Self.appendLineToDisk(line, fileURL: logFileURL, maxBytes: maxFileBytes)
        }

        if let callback {
            DispatchQueue.main.async {
                callback(line)
            }
        }
    }

    func recentLines(limit: Int = 400) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        if ringBuffer.count <= limit {
            return ringBuffer
        }
        return Array(ringBuffer.suffix(limit))
    }

    func clear() {
        lock.lock()
        ringBuffer.removeAll()
        lock.unlock()

        ioQueue.async { [logFileURL] in
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Generates a self-contained diagnostic report (environment + active displays + recent log tail).
    @MainActor
    func buildDiagnosticReport(
        appVersion: String,
        roleSummary: String,
        schemeSummary: String,
        permissionsSummary: String,
        limit: Int = 400
    ) -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let displays = Self.describeActiveDisplays()
        let header = """
        === Chameye Diagnostic Report ===
        Version: \(appVersion)
        macOS: \(osVersion)
        Role: \(roleSummary)
        Scheme: \(schemeSummary)
        Permissions: \(permissionsSummary)
        Displays: \(displays)
        LogFile: \(logFileURL.path)
        =================================
        """
        let body = recentLines(limit: limit).joined(separator: "\n")
        return "\(header)\n\(body)\n"
    }

    private static func describeActiveDisplays() -> String {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return "none" }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        let mainID = CGMainDisplayID()
        return ids.prefix(Int(count)).map { id in
            let b = CGDisplayBounds(id)
            let tag = (id == mainID) ? "MAIN" : "EXT"
            return "id=\(id)(\(tag)) \(Int(b.origin.x)),\(Int(b.origin.y)) \(Int(b.width))x\(Int(b.height))"
        }.joined(separator: " | ")
    }

    private static func appendLineToDisk(_ line: String, fileURL: URL, maxBytes: UInt64) {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? UInt64,
           size >= maxBytes {
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("chameye.prev.log")
            try? fm.removeItem(at: backup)
            try? fm.moveItem(at: fileURL, to: backup)
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: data)
            return
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        }
    }
}
