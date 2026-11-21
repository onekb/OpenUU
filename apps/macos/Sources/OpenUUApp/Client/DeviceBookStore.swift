import Foundation

enum DeviceCodeFormatter {
    /// Returns true if the string only contains ASCII digits and whitespace (i.e. user is typing/pasting a device code).
    static func isDeviceCodeLike(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { ($0.isASCII && $0.isNumber) || $0.isWhitespace }
    }

    /// Formats pure-digit device code inputs by inserting a space every 3 digits (`"601550599"` -> `"601 550 599"`).
    /// Non-device-code inputs (IP, domain, `openuu://` ticket) strip any stray spaces so transitioning
    /// from digits to `10086.cn` or pasting URLs never leaves spaces inside addresses.
    static func formatInput(_ raw: String) -> String {
        guard !raw.isEmpty else { return "" }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        if trimmed.allSatisfy({ ($0.isASCII && $0.isNumber) || $0.isWhitespace }) {
            let digits = Array(trimmed.filter { $0.isASCII && $0.isNumber })
            guard !digits.isEmpty else { return "" }
            return stride(from: 0, to: digits.count, by: 3).map { idx in
                let end = min(idx + 3, digits.count)
                return String(digits[idx..<end])
            }.joined(separator: " ")
        }

        if raw.contains(where: \.isWhitespace) {
            return String(raw.filter { !$0.isWhitespace })
        }
        return raw
    }

    /// Formats `raw` while computing the exact UTF-16 cursor offset so typing or backspacing never jumps the cursor.
    static func formatInputWithCursor(
        _ raw: String,
        cursorUTF16Offset: Int,
        previousFormatted: String? = nil
    ) -> (text: String, cursorUTF16Offset: Int) {
        let nsRaw = raw as NSString
        let clampedCursor = min(max(0, cursorUTF16Offset), nsRaw.length)

        // If the user pressed Backspace right after an auto-inserted space (e.g. "601 |550" -> "601550"),
        // also delete the digit immediately preceding that space so middle-of-string backspace feels native.
        var workingRaw = raw
        var workingCursor = clampedCursor
        if let prev = previousFormatted,
           isDeviceCodeLike(prev),
           isDeviceCodeLike(raw) {
            let prevNS = prev as NSString
            if nsRaw.length == prevNS.length - 1,
               clampedCursor > 0,
               clampedCursor < prevNS.length,
               prevNS.substring(with: NSRange(location: clampedCursor, length: 1)) == " " {
                let prevDigits = prev.filter { $0.isASCII && $0.isNumber }
                let rawDigits = raw.filter { $0.isASCII && $0.isNumber }
                if prevDigits == rawDigits {
                    let mutable = NSMutableString(string: raw)
                    mutable.deleteCharacters(in: NSRange(location: clampedCursor - 1, length: 1))
                    workingRaw = mutable as String
                    workingCursor = clampedCursor - 1
                }
            }
        }

        let formatted = formatInput(workingRaw)
        if formatted.isEmpty {
            return ("", 0)
        }

        let workingNS = workingRaw as NSString
        let prefixStr = workingNS.substring(to: min(workingCursor, workingNS.length))

        if isDeviceCodeLike(formatted) {
            let digitsBefore = prefixStr.filter { $0.isASCII && $0.isNumber }.count
            if digitsBefore == 0 {
                return (formatted, 0)
            }
            var seenDigits = 0
            var utf16Pos = 0
            for ch in formatted {
                utf16Pos += ch.utf16.count
                if ch.isASCII && ch.isNumber {
                    seenDigits += 1
                    if seenDigits == digitsBefore {
                        return (formatted, utf16Pos)
                    }
                }
            }
            return (formatted, (formatted as NSString).length)
        } else {
            let nonSpaceBefore = prefixStr.filter { !$0.isWhitespace }.count
            if nonSpaceBefore == 0 {
                return (formatted, 0)
            }
            var seen = 0
            var utf16Pos = 0
            for ch in formatted {
                utf16Pos += ch.utf16.count
                if !ch.isWhitespace {
                    seen += 1
                    if seen == nonSpaceBefore {
                        return (formatted, utf16Pos)
                    }
                }
            }
            return (formatted, (formatted as NSString).length)
        }
    }

    /// Strips all spaces from device codes (and stray whitespace from any target) right before use/connection/storage.
    static func sanitizeForUse(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.allSatisfy({ ($0.isASCII && $0.isNumber) || $0.isWhitespace || $0 == "-" }) {
            return String(trimmed.filter { $0.isASCII && $0.isNumber })
        }
        return String(trimmed.filter { !$0.isWhitespace })
    }
}

enum DeviceOnlineState: String, Sendable {
    case lanOnline = "lan"
    case wanOnline = "wan"
    case offline = "offline"

    var label: String {
        switch self {
        case .lanOnline: return "局域网在线"
        case .wanOnline: return "远程在线"
        case .offline: return "离线/待机"
        }
    }

    var isOnline: Bool {
        self != .offline
    }
}

struct ManagedRemoteDevice: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var alias: String
    var target: String
    var port: UInt16
    var savedPassword: String
    var groupTag: String
    var isFavorite: Bool
    var remoteDeviceID: String
    var deviceCode: String
    var notes: String
    var lastConnectedMs: UInt64

    var formattedTarget: String {
        let clean = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if !clean.isEmpty && clean.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == " " || $0 == "-" }) {
            let digits = String(clean.filter { $0.isASCII && $0.isNumber })
            if !digits.isEmpty {
                return DeviceCodeFormatter.formatInput(digits)
            }
        }
        if clean.hasPrefix("openuu://") {
            if !deviceCode.isEmpty, deviceCode.count == 9 {
                return "\(DeviceCodeFormatter.formatInput(deviceCode)) (直连串)"
            }
            return "跨网直连串 (openuu://…)"
        }
        return port == 39481 ? clean : "\(clean):\(port)"
    }
}

/// Persistent multi-host Device Book ("设备列表") supporting custom aliases, saved passwords, groups, favorites,
/// automatic history enrollment, and live LAN + WAN online presence polling.
@MainActor
final class DeviceBookStore: ObservableObject {
    static let defaultGroups = ["常用", "办公", "家里", "服务器"]

    @Published private(set) var devices: [ManagedRemoteDevice] = []
    @Published var presenceByID: [String: DeviceOnlineState] = [:]

    private let fileURL: URL
    private let defaultsKey = "openuu.deviceBook.v1"

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("OpenUU", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("device_book.json")
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ManagedRemoteDevice].self, from: data) {
            self.devices = sortDevices(decoded)
            return
        }
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([ManagedRemoteDevice].self, from: data) {
            self.devices = sortDevices(decoded)
        }
    }

    private func persist() {
        devices = sortDevices(devices)
        guard let data = try? JSONEncoder().encode(devices) else { return }
        try? data.write(to: fileURL, options: .atomic)
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func sortDevices(_ list: [ManagedRemoteDevice]) -> [ManagedRemoteDevice] {
        list.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite {
                return lhs.isFavorite && !rhs.isFavorite
            }
            if lhs.lastConnectedMs != rhs.lastConnectedMs {
                return lhs.lastConnectedMs > rhs.lastConnectedMs
            }
            return lhs.alias.localizedCompare(rhs.alias) == .orderedAscending
        }
    }

    /// Merges any previously paired `TrustedPeerModel` entries from `identity.json` into the Device Book
    /// so upgrading users immediately see all their previously paired Macs without re-entering anything.
    func syncFromTrustedPeers(_ trusted: [TrustedPeerModel]) {
        var changed = false
        for tp in trusted {
            let normCode = tp.device_code.filter(\.isNumber)
            let existingIdx = devices.firstIndex { d in
                (!tp.device_id.isEmpty && d.remoteDeviceID == tp.device_id) ||
                (normCode.count == 9 && d.deviceCode == normCode) ||
                (!tp.last_ticket.isEmpty && d.target == tp.last_ticket)
            }
            if let idx = existingIdx {
                if devices[idx].remoteDeviceID.isEmpty {
                    devices[idx].remoteDeviceID = tp.device_id
                    changed = true
                }
                if devices[idx].deviceCode.isEmpty && normCode.count == 9 {
                    devices[idx].deviceCode = normCode
                    changed = true
                }
            } else {
                let target: String
                if normCode.count == 9 {
                    target = normCode
                } else if !tp.last_ticket.isEmpty {
                    target = tp.last_ticket
                } else {
                    continue
                }
                let imported = ManagedRemoteDevice(
                    id: UUID().uuidString,
                    alias: tp.device_name.isEmpty ? "远程 Mac" : tp.device_name,
                    target: target,
                    port: 39481,
                    savedPassword: "",
                    groupTag: "常用",
                    isFavorite: false,
                    remoteDeviceID: tp.device_id,
                    deviceCode: normCode,
                    notes: "",
                    lastConnectedMs: tp.last_connected_ms
                )
                devices.append(imported)
                changed = true
            }
        }
        if changed {
            persist()
        }
    }

    @discardableResult
    func addOrUpdateDevice(
        id: String? = nil,
        alias: String,
        target: String,
        port: UInt16 = 39481,
        savedPassword: String,
        groupTag: String = "常用",
        isFavorite: Bool = false,
        notes: String = ""
    ) -> ManagedRemoteDevice {
        let cleanTarget = DeviceCodeFormatter.sanitizeForUse(target)
        let normDigits = Self.extractNineDigitCode(cleanTarget)
        if let id, let idx = devices.firstIndex(where: { $0.id == id }) {
            devices[idx].alias = alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? devices[idx].alias : alias.trimmingCharacters(in: .whitespacesAndNewlines)
            devices[idx].target = cleanTarget
            devices[idx].port = port
            devices[idx].savedPassword = savedPassword
            devices[idx].groupTag = groupTag.isEmpty ? "常用" : groupTag
            devices[idx].isFavorite = isFavorite
            devices[idx].notes = notes
            if !normDigits.isEmpty {
                devices[idx].deviceCode = normDigits
            }
            let updated = devices[idx]
            persist()
            return updated
        }

        // Check if target already exists
        if let idx = devices.firstIndex(where: {
            DeviceCodeFormatter.sanitizeForUse($0.target) == cleanTarget || (!normDigits.isEmpty && $0.deviceCode == normDigits)
        }) {
            if !alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                devices[idx].alias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            devices[idx].target = cleanTarget
            devices[idx].port = port
            if !savedPassword.isEmpty {
                devices[idx].savedPassword = savedPassword
            }
            devices[idx].groupTag = groupTag.isEmpty ? devices[idx].groupTag : groupTag
            devices[idx].isFavorite = isFavorite
            devices[idx].notes = notes
            let updated = devices[idx]
            persist()
            return updated
        }

        let finalAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? (normDigits.isEmpty ? cleanTarget : "Mac (\(normDigits.suffix(4)))")
            : alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let created = ManagedRemoteDevice(
            id: UUID().uuidString,
            alias: finalAlias,
            target: cleanTarget,
            port: port,
            savedPassword: savedPassword,
            groupTag: groupTag.isEmpty ? "常用" : groupTag,
            isFavorite: isFavorite,
            remoteDeviceID: "",
            deviceCode: normDigits,
            notes: notes,
            lastConnectedMs: UInt64(Date().timeIntervalSince1970 * 1000)
        )
        devices.append(created)
        persist()
        return created
    }

    @discardableResult
    func recordConnectedHost(
        existingID: String?,
        remoteName: String,
        remoteDeviceID: String,
        target: String,
        port: UInt16,
        passwordUsed: String
    ) -> ManagedRemoteDevice {
        let nowMs = UInt64(Date().timeIntervalSince1970 * 1000)
        let cleanTarget = DeviceCodeFormatter.sanitizeForUse(target)
        let normCode = Self.extractNineDigitCode(cleanTarget)

        let idx = devices.firstIndex { d in
            (existingID != nil && d.id == existingID) ||
            (!remoteDeviceID.isEmpty && d.remoteDeviceID == remoteDeviceID) ||
            (!normCode.isEmpty && d.deviceCode == normCode) ||
            DeviceCodeFormatter.sanitizeForUse(d.target) == cleanTarget
        }

        if let idx {
            devices[idx].target = cleanTarget
            if !remoteDeviceID.isEmpty {
                devices[idx].remoteDeviceID = remoteDeviceID
            }
            if !normCode.isEmpty {
                devices[idx].deviceCode = normCode
            }
            if !passwordUsed.isEmpty {
                devices[idx].savedPassword = passwordUsed
            }
            // Update default placeholder alias to real remote Mac hostname if user hasn't customized it
            if devices[idx].alias == devices[idx].target || devices[idx].alias.hasPrefix("Mac (") || devices[idx].alias.hasPrefix("openuu://") {
                if !remoteName.isEmpty {
                    devices[idx].alias = remoteName
                }
            }
            devices[idx].lastConnectedMs = nowMs
            let saved = devices[idx]
            persist()
            return saved
        }

        let created = ManagedRemoteDevice(
            id: existingID ?? UUID().uuidString,
            alias: remoteName.isEmpty ? cleanTarget : remoteName,
            target: cleanTarget,
            port: port,
            savedPassword: passwordUsed,
            groupTag: "常用",
            isFavorite: false,
            remoteDeviceID: remoteDeviceID,
            deviceCode: normCode,
            notes: "",
            lastConnectedMs: nowMs
        )
        devices.append(created)
        persist()
        return created
    }

    func toggleFavorite(id: String) {
        guard let idx = devices.firstIndex(where: { $0.id == id }) else { return }
        devices[idx].isFavorite.toggle()
        persist()
    }

    func removeDevice(id: String) {
        devices.removeAll { $0.id == id }
        presenceByID.removeValue(forKey: id)
        persist()
    }

    func findMatchingDevice(forTarget rawTarget: String) -> ManagedRemoteDevice? {
        let clean = DeviceCodeFormatter.sanitizeForUse(rawTarget)
        guard !clean.isEmpty else { return nil }
        let norm = Self.extractNineDigitCode(clean)
        return devices.first { d in
            DeviceCodeFormatter.sanitizeForUse(d.target) == clean || (!norm.isEmpty && d.deviceCode == norm)
        }
    }

    func applyProbeResults(_ results: [DeviceProbeResultModel]) {
        for r in results {
            let state = DeviceOnlineState(rawValue: r.via) ?? (r.online ? .wanOnline : .offline)
            presenceByID[r.id] = state
        }
    }

    static func extractNineDigitCode(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) else {
            return ""
        }
        let digits = trimmed.filter(\.isNumber)
        return digits.count == 9 ? digits : ""
    }
}
