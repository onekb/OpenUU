import Foundation

enum DeviceCodeFormatter {
    static func isDeviceCodeLike(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { ($0.isASCII && $0.isNumber) || $0.isWhitespace }
    }

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
        let digits = target.filter(\.isNumber)
        let clean = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if digits.count == 9 && clean.allSatisfy({ $0.isNumber || $0 == " " || $0 == "-" }) {
            let i3 = digits.index(digits.startIndex, offsetBy: 3)
            let i6 = digits.index(digits.startIndex, offsetBy: 6)
            return "\(digits[..<i3]) \(digits[i3..<i6]) \(digits[i6...])"
        }
        if clean.hasPrefix("openuu://") {
            if deviceCode.count == 9 {
                let i3 = deviceCode.index(deviceCode.startIndex, offsetBy: 3)
                let i6 = deviceCode.index(deviceCode.startIndex, offsetBy: 6)
                return "\(deviceCode[..<i3]) \(deviceCode[i3..<i6]) \(deviceCode[i6...]) (直连串)"
            }
            return "跨网直连串 (openuu://…)"
        }
        return port == OpenUUConstants.defaultPort ? clean : "\(clean):\(port)"
    }
}

@MainActor
final class DeviceBookStore: ObservableObject {
    static let defaultGroups = ["常用", "办公", "家里", "服务器"]

    @Published private(set) var devices: [ManagedRemoteDevice] = []
    @Published var presenceByID: [String: DeviceOnlineState] = [:]

    private let fileURL: URL
    private let defaultsKey = "openuu.mobile.deviceBook.v1"

    init(appSupportDir: URL? = nil) {
        let baseDir: URL
        if let appSupportDir {
            baseDir = appSupportDir
        } else {
            let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
            baseDir = root.appendingPathComponent("OpenUU", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        self.fileURL = baseDir.appendingPathComponent("device_book.json")
        load()
    }

    func load() {
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([ManagedRemoteDevice].self, from: data) {
            devices = sortDevices(decoded)
            return
        }
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([ManagedRemoteDevice].self, from: data) {
            devices = sortDevices(decoded)
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
                    port: OpenUUConstants.defaultPort,
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
        port: UInt16 = OpenUUConstants.defaultPort,
        savedPassword: String,
        groupTag: String = "常用",
        isFavorite: Bool = false,
        notes: String = ""
    ) -> ManagedRemoteDevice {
        let cleanTarget = DeviceCodeFormatter.sanitizeForUse(target)
        let cleanAlias = alias.trimmingCharacters(in: .whitespacesAndNewlines)
        let normDigits = Self.extractNineDigitCode(cleanTarget)

        if let id, let idx = devices.firstIndex(where: { $0.id == id }) {
            if !cleanAlias.isEmpty {
                devices[idx].alias = cleanAlias
            }
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

        if let idx = devices.firstIndex(where: {
            DeviceCodeFormatter.sanitizeForUse($0.target) == cleanTarget || (!normDigits.isEmpty && $0.deviceCode == normDigits)
        }) {
            if !cleanAlias.isEmpty {
                devices[idx].alias = cleanAlias
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

        let finalAlias = cleanAlias.isEmpty
            ? (normDigits.isEmpty ? cleanTarget : "Mac (\(normDigits.suffix(4)))")
            : cleanAlias
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
            id: UUID().uuidString,
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

    func probeQueries() -> [DeviceProbeQueryModel] {
        devices.map { DeviceProbeQueryModel(id: $0.id, target: DeviceCodeFormatter.sanitizeForUse($0.target)) }
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
