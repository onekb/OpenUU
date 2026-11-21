import AppKit
import CoreGraphics
import Foundation

enum OpenUULogLevel: Int, CaseIterable, Comparable, Sendable {
    case debug = 0
    case info = 1
    case warn = 2
    case error = 3

    var tag: String {
        switch self {
        case .debug: return "DEBUG"
        case .info: return "INFO "
        case .warn: return "WARN "
        case .error: return "ERROR"
        }
    }

    var label: String {
        switch self {
        case .debug: return "全部 (DEBUG+)"
        case .info: return "常规 (INFO+)"
        case .warn: return "警告 (WARN+)"
        case .error: return "仅错误 (ERROR)"
        }
    }

    static func < (lhs: OpenUULogLevel, rhs: OpenUULogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

struct OpenUULogEntry: Sendable, Identifiable {
    let id: UInt64
    let level: OpenUULogLevel
    let category: String
    let formatted: String
}

/// Thread-safe structured engineering logger with severity levels (`DEBUG`/`INFO`/`WARN`/`ERROR`),
/// an in-memory ring buffer (2000 entries), and rolling file persistence at `~/Library/Logs/OpenUU/openuu.log`.
final class OpenUULogger: @unchecked Sendable {
    static let shared = OpenUULogger()

    let logDirectoryURL: URL
    let logFileURL: URL

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "ren.onekb.openuu.logger.io", qos: .utility)
    private var ringBuffer: [OpenUULogEntry] = []
    private var nextID: UInt64 = 1
    private let maxMemoryEntries = 2000
    private let maxFileBytes: UInt64 = 8 * 1024 * 1024 // 8 MiB
    private let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        return df
    }()

    var onEntryAppended: ((OpenUULogEntry) -> Void)?

    private init() {
        let homeLogs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/OpenUU", isDirectory: true)
        self.logDirectoryURL = homeLogs
        self.logFileURL = homeLogs.appendingPathComponent("openuu.log")
        try? FileManager.default.createDirectory(at: homeLogs, withIntermediateDirectories: true)
    }

    func debug(_ category: String, _ message: String) {
        log(.debug, category, message)
    }

    func info(_ category: String, _ message: String) {
        log(.info, category, message)
    }

    func warn(_ category: String, _ message: String) {
        log(.warn, category, message)
    }

    func error(_ category: String, _ message: String) {
        log(.error, category, message)
    }

    func log(_ level: OpenUULogLevel = .info, _ category: String, _ message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        lock.lock()
        let ts = dateFormatter.string(from: Date())
        let id = nextID
        nextID += 1
        let line = "[\(ts)] [\(level.tag)] [\(category)] \(trimmed)"
        let entry = OpenUULogEntry(id: id, level: level, category: category, formatted: line)
        ringBuffer.append(entry)
        if ringBuffer.count > maxMemoryEntries {
            ringBuffer.removeFirst(ringBuffer.count - maxMemoryEntries)
        }
        let callback = onEntryAppended
        lock.unlock()

        ioQueue.async { [logFileURL, maxFileBytes] in
            Self.appendLineToDisk(line, fileURL: logFileURL, maxBytes: maxFileBytes)
        }

        if let callback {
            DispatchQueue.main.async {
                callback(entry)
            }
        }
    }

    func recentEntries(minLevel: OpenUULogLevel = .debug, limit: Int = 500) -> [OpenUULogEntry] {
        lock.lock()
        defer { lock.unlock() }
        let filtered = minLevel == .debug ? ringBuffer : ringBuffer.filter { $0.level >= minLevel }
        if filtered.count <= limit {
            return filtered
        }
        return Array(filtered.suffix(limit))
    }

    func clear() {
        lock.lock()
        ringBuffer.removeAll()
        lock.unlock()

        ioQueue.async { [logFileURL] in
            try? "".write(to: logFileURL, atomically: true, encoding: .utf8)
        }
    }

    @MainActor
    func buildDiagnosticReport(
        appVersion: String,
        roleSummary: String,
        schemeSummary: String,
        permissionsSummary: String,
        stateSnapshot: String,
        minLevel: OpenUULogLevel = .debug,
        limit: Int = 500
    ) -> String {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let displays = Self.describeActiveDisplays()
        let header = """
        === OpenUU Diagnostic Report ===
        Version: \(appVersion)
        macOS: \(osVersion)
        Role: \(roleSummary)
        Scheme: \(schemeSummary)
        Permissions: \(permissionsSummary)
        State: \(stateSnapshot)
        Displays: \(displays)
        LogFile: \(logFileURL.path)
        =================================
        """
        let body = recentEntries(minLevel: minLevel, limit: limit).map(\.formatted).joined(separator: "\n")
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
            let backup = fileURL.deletingLastPathComponent().appendingPathComponent("openuu.prev.log")
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
