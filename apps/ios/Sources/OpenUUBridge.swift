import COpenUUCore
import Foundation

enum OpenUUConstants {
    static let defaultPort: UInt16 = 39481
    static let fullDesktopBundleID = "__openuu_full_desktop__"
    static let fullDesktopWindowID: UInt32 = 0x7FFF_FF00
    static let defaultCoordURL = "https://openuu.1kb.ren"
    static let defaultRelayURL = "https://openuu-relay.1kb.ren"
}

enum MacModifiers {
    static let shift: UInt32 = 1
    static let control: UInt32 = 2
    static let option: UInt32 = 4
    static let command: UInt32 = 8
}

enum MacKeyCodes {
    static let a: UInt32 = 0
    static let s: UInt32 = 1
    static let d: UInt32 = 2
    static let f: UInt32 = 3
    static let h: UInt32 = 4
    static let g: UInt32 = 5
    static let z: UInt32 = 6
    static let x: UInt32 = 7
    static let c: UInt32 = 8
    static let v: UInt32 = 9
    static let b: UInt32 = 11
    static let q: UInt32 = 12
    static let w: UInt32 = 13
    static let e: UInt32 = 14
    static let r: UInt32 = 15
    static let y: UInt32 = 16
    static let t: UInt32 = 17
    static let num1: UInt32 = 18
    static let num2: UInt32 = 19
    static let num3: UInt32 = 20
    static let num4: UInt32 = 21
    static let num6: UInt32 = 22
    static let num5: UInt32 = 23
    static let equal: UInt32 = 24
    static let num9: UInt32 = 25
    static let num7: UInt32 = 26
    static let minus: UInt32 = 27
    static let num8: UInt32 = 28
    static let num0: UInt32 = 29
    static let rightBracket: UInt32 = 30
    static let o: UInt32 = 31
    static let u: UInt32 = 32
    static let leftBracket: UInt32 = 33
    static let i: UInt32 = 34
    static let p: UInt32 = 35
    static let returnKey: UInt32 = 36
    static let l: UInt32 = 37
    static let j: UInt32 = 38
    static let quote: UInt32 = 39
    static let k: UInt32 = 40
    static let semicolon: UInt32 = 41
    static let backslash: UInt32 = 42
    static let comma: UInt32 = 43
    static let slash: UInt32 = 44
    static let n: UInt32 = 45
    static let m: UInt32 = 46
    static let period: UInt32 = 47
    static let tab: UInt32 = 48
    static let space: UInt32 = 49
    static let grave: UInt32 = 50
    static let delete: UInt32 = 51
    static let escape: UInt32 = 53
    static let f5: UInt32 = 96
    static let f6: UInt32 = 97
    static let f7: UInt32 = 98
    static let f3: UInt32 = 99
    static let f8: UInt32 = 100
    static let f9: UInt32 = 101
    static let f11: UInt32 = 103
    static let f10: UInt32 = 109
    static let f12: UInt32 = 111
    static let home: UInt32 = 115
    static let pageUp: UInt32 = 116
    static let forwardDelete: UInt32 = 117
    static let f4: UInt32 = 118
    static let end: UInt32 = 119
    static let f2: UInt32 = 120
    static let pageDown: UInt32 = 121
    static let f1: UInt32 = 122
    static let left: UInt32 = 123
    static let right: UInt32 = 124
    static let down: UInt32 = 125
    static let up: UInt32 = 126

    static func asciiToKeyAndShift(_ ch: Character) -> (UInt32, UInt32)? {
        switch ch {
        case "a": return (a, 0); case "A": return (a, MacModifiers.shift)
        case "b": return (b, 0); case "B": return (b, MacModifiers.shift)
        case "c": return (c, 0); case "C": return (c, MacModifiers.shift)
        case "d": return (d, 0); case "D": return (d, MacModifiers.shift)
        case "e": return (e, 0); case "E": return (e, MacModifiers.shift)
        case "f": return (f, 0); case "F": return (f, MacModifiers.shift)
        case "g": return (g, 0); case "G": return (g, MacModifiers.shift)
        case "h": return (h, 0); case "H": return (h, MacModifiers.shift)
        case "i": return (i, 0); case "I": return (i, MacModifiers.shift)
        case "j": return (j, 0); case "J": return (j, MacModifiers.shift)
        case "k": return (k, 0); case "K": return (k, MacModifiers.shift)
        case "l": return (l, 0); case "L": return (l, MacModifiers.shift)
        case "m": return (m, 0); case "M": return (m, MacModifiers.shift)
        case "n": return (n, 0); case "N": return (n, MacModifiers.shift)
        case "o": return (o, 0); case "O": return (o, MacModifiers.shift)
        case "p": return (p, 0); case "P": return (p, MacModifiers.shift)
        case "q": return (q, 0); case "Q": return (q, MacModifiers.shift)
        case "r": return (r, 0); case "R": return (r, MacModifiers.shift)
        case "s": return (s, 0); case "S": return (s, MacModifiers.shift)
        case "t": return (t, 0); case "T": return (t, MacModifiers.shift)
        case "u": return (u, 0); case "U": return (u, MacModifiers.shift)
        case "v": return (v, 0); case "V": return (v, MacModifiers.shift)
        case "w": return (w, 0); case "W": return (w, MacModifiers.shift)
        case "x": return (x, 0); case "X": return (x, MacModifiers.shift)
        case "y": return (y, 0); case "Y": return (y, MacModifiers.shift)
        case "z": return (z, 0); case "Z": return (z, MacModifiers.shift)
        case "0": return (num0, 0); case ")": return (num0, MacModifiers.shift)
        case "1": return (num1, 0); case "!": return (num1, MacModifiers.shift)
        case "2": return (num2, 0); case "@": return (num2, MacModifiers.shift)
        case "3": return (num3, 0); case "#": return (num3, MacModifiers.shift)
        case "4": return (num4, 0); case "$": return (num4, MacModifiers.shift)
        case "5": return (num5, 0); case "%": return (num5, MacModifiers.shift)
        case "6": return (num6, 0); case "^": return (num6, MacModifiers.shift)
        case "7": return (num7, 0); case "&": return (num7, MacModifiers.shift)
        case "8": return (num8, 0); case "*": return (num8, MacModifiers.shift)
        case "9": return (num9, 0); case "(": return (num9, MacModifiers.shift)
        case "-": return (minus, 0); case "_": return (minus, MacModifiers.shift)
        case "=": return (equal, 0); case "+": return (equal, MacModifiers.shift)
        case "[": return (leftBracket, 0); case "{": return (leftBracket, MacModifiers.shift)
        case "]": return (rightBracket, 0); case "}": return (rightBracket, MacModifiers.shift)
        case "\\": return (backslash, 0); case "|": return (backslash, MacModifiers.shift)
        case ";": return (semicolon, 0); case ":": return (semicolon, MacModifiers.shift)
        case "'": return (quote, 0); case "\"": return (quote, MacModifiers.shift)
        case ",": return (comma, 0); case "<": return (comma, MacModifiers.shift)
        case ".": return (period, 0); case ">": return (period, MacModifiers.shift)
        case "/": return (slash, 0); case "?": return (slash, MacModifiers.shift)
        case "`": return (grave, 0); case "~": return (grave, MacModifiers.shift)
        case " ": return (space, 0)
        default: return nil
        }
    }
}

struct DiscoveredPeer: Codable, Identifiable, Hashable, Sendable {
    let device_id: String
    let device_name: String
    let os: String
    let addresses: [String]
    let port: UInt16
    let protocol_version: UInt32
    let device_code: String?
    let endpoint_id: String?

    var id: String { device_id }
    var preferredIP: String {
        addresses.first(where: { !$0.contains(":") }) ?? addresses.first ?? "127.0.0.1"
    }
}

struct WanConfigModel: Codable, Equatable, Sendable {
    var coord_url: String
    var relay_url: String
    var relay_auth_token: String?
    var enable_public_fallback: Bool
    var allow_insecure_tls: Bool

    static let `default` = WanConfigModel(
        coord_url: OpenUUConstants.defaultCoordURL,
        relay_url: OpenUUConstants.defaultRelayURL,
        relay_auth_token: "",
        enable_public_fallback: true,
        allow_insecure_tls: false
    )
}

struct TrustedPeerModel: Codable, Identifiable, Hashable, Sendable {
    let device_id: String
    let device_name: String
    let cert_fingerprint: String
    let endpoint_id: String
    let device_code: String
    let last_relay_url: String
    let last_ticket: String
    let last_connected_ms: UInt64

    var id: String { device_id }

    var formattedCode: String {
        guard device_code.count == 9 else { return device_code }
        let s = device_code
        let i3 = s.index(s.startIndex, offsetBy: 3)
        let i6 = s.index(s.startIndex, offsetBy: 6)
        return "\(s[..<i3]) \(s[i3..<i6]) \(s[i6...])"
    }

    var preferredTarget: String {
        if device_code.count == 9 { return device_code }
        if !last_ticket.isEmpty { return last_ticket }
        if !device_id.isEmpty { return device_id }
        return endpoint_id
    }
}

struct DeviceProbeQueryModel: Codable, Sendable {
    let id: String
    let target: String
}

struct DeviceProbeResultModel: Codable, Sendable {
    let id: String
    let online: Bool
    let via: String // "lan", "wan", or "offline"
    let remote_name: String
}

struct IdentitySnapshotModel: Codable, Sendable {
    let device_id: String
    let device_name: String
    let device_code: String
    let formatted_code: String
    let endpoint_id: String
    let host_ticket: String
    let coord_status: String
    let wan_config: WanConfigModel
    let trusted_peers: [TrustedPeerModel]
}

struct RemoteAppSummary: Codable, Identifiable, Hashable, Sendable {
    let bundle_id: String
    let name: String
    let pid: UInt32
    let window_count: UInt32
    let icon_png_b64: String?

    var id: String { "\(bundle_id)-\(pid)" }
}

struct WindowTopologyItem: Codable, Identifiable, Equatable, Hashable, Sendable {
    let window_id: UInt32
    let parent_window_id: UInt32
    let kind: Int32
    let rel_x: Float
    let rel_y: Float
    let width: Float
    let height: Float
    let title: String
    let icon_png_b64: String?

    var id: UInt32 { window_id }

    var displayTitle: String {
        if window_id == OpenUUConstants.fullDesktopWindowID {
            return "Mac 整屏桌面"
        }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "窗口 #\(window_id)" : trimmed
    }

    enum CodingKeys: String, CodingKey {
        case window_id
        case parent_window_id
        case kind
        case rel_x
        case rel_y
        case width
        case height
        case title
        case icon_png_b64
    }

    init(
        window_id: UInt32,
        parent_window_id: UInt32 = 0,
        kind: Int32 = 0,
        rel_x: Float = 0,
        rel_y: Float = 0,
        width: Float = 0,
        height: Float = 0,
        title: String = "",
        icon_png_b64: String? = nil
    ) {
        self.window_id = window_id
        self.parent_window_id = parent_window_id
        self.kind = kind
        self.rel_x = rel_x
        self.rel_y = rel_y
        self.width = width
        self.height = height
        self.title = title
        self.icon_png_b64 = icon_png_b64
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        window_id = try c.decode(UInt32.self, forKey: .window_id)
        parent_window_id = try c.decodeIfPresent(UInt32.self, forKey: .parent_window_id) ?? 0
        kind = try c.decodeIfPresent(Int32.self, forKey: .kind) ?? 0
        rel_x = try c.decodeIfPresent(Float.self, forKey: .rel_x) ?? 0
        rel_y = try c.decodeIfPresent(Float.self, forKey: .rel_y) ?? 0
        width = try c.decodeIfPresent(Float.self, forKey: .width) ?? 0
        height = try c.decodeIfPresent(Float.self, forKey: .height) ?? 0
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        icon_png_b64 = try c.decodeIfPresent(String.self, forKey: .icon_png_b64)
    }
}

struct ControlEventMessage: Codable, Sendable {
    let type: String
    let window_id: UInt32?
    let bundle_id: String?
    let x: Float?
    let y: Float?
    let width: Float?
    let height: Float?
    let event_type: Int32?
    let button: UInt32?
    let click_count: UInt32?
    let modifiers: UInt32?
    let delta_x: Float?
    let delta_y: Float?
    let is_continuous: Bool?
    let key_code: UInt32?
    let is_down: Bool?
    let is_repeat: Bool?
    let text: String?
    let app_bundle_id: String?
    let title: String?
    let subtitle: String?
    let body: String?
    let badge_text: String?
    let kind: String?
    let hotspot_x: Float?
    let hotspot_y: Float?
    let content_hash: String?
    let clip_kind: Int32?
    let mime_type: String?
    let image_b64: String?
    let blob_id: String?
    let local_path: String?
    let link_mode: String?
    let rtt_ms: UInt32?
    let remote_addr: String?
    let audio_enabled: Bool?
    let mute_host: Bool?
    let windows: [WindowTopologyItem]?
    let apps: [RemoteAppSummary]?
}

struct EncodedVideoPacket: Sendable {
    let codec: UInt8
    let flags: UInt8
    let windowID: UInt32
    let timestampUS: UInt64
    let width: UInt16
    let height: UInt16
    let data: Data
}

struct EncodedAudioPacket: Sendable {
    let codec: UInt8
    let flags: UInt8
    let channels: UInt8
    let sampleRate: UInt32
    let timestampUS: UInt64
    let data: Data
}

final class OpenUUBridge: @unchecked Sendable {
    private let runtime: OpaquePointer
    let appSupportDir: URL
    let cachesDir: URL

    var onControlEvent: (@Sendable (ControlEventMessage) -> Void)?
    var onVideoFrame: (@Sendable (EncodedVideoPacket) -> Void)?
    var onAudioFrame: (@Sendable (EncodedAudioPacket) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?
    var onProbeResults: (@Sendable ([DeviceProbeResultModel]) -> Void)?

    init(deviceName: String, appSupportDir: URL, cachesDir: URL) {
        self.appSupportDir = appSupportDir
        self.cachesDir = cachesDir

        try? FileManager.default.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: cachesDir, withIntermediateDirectories: true)

        let appSupportPath = appSupportDir.path
        let cachesPath = cachesDir.path

        appSupportPath.withCString { cfgPtr in
            cachesPath.withCString { cachePtr in
                _ = openuu_set_app_dirs(cfgPtr, cachePtr)
            }
        }

        let created: OpaquePointer? = deviceName.withCString { namePtr in
            appSupportPath.withCString { dirPtr in
                openuu_runtime_create_with_dir(namePtr, dirPtr)
            }
        }
        guard let rt = created else {
            fatalError("Failed to create OpenUURuntime")
        }
        self.runtime = rt
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        _ = openuu_set_audio_callback(rt, openuuAudioTrampoline, ctx)
    }

    deinit {
        _ = openuu_set_audio_callback(runtime, nil, nil)
        openuu_disconnect(runtime)
        openuu_runtime_destroy(runtime)
    }

    func startDiscovery() {
        _ = openuu_start_discovery(runtime)
    }

    func listPeers() -> [DiscoveredPeer] {
        guard let cstr = openuu_list_peers_json(runtime) else { return [] }
        defer { openuu_free_string(cstr) }
        let json = String(cString: cstr)
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([DiscoveredPeer].self, from: data)) ?? []
    }

    @discardableResult
    func connectSmart(target: String, defaultPort: UInt16 = OpenUUConstants.defaultPort, pin: String) -> Bool {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let rc = target.withCString { targetPtr in
            pin.withCString { pinPtr in
                openuu_connect_smart(
                    runtime,
                    targetPtr,
                    defaultPort,
                    pinPtr,
                    openuuControlTrampoline,
                    openuuVideoTrampoline,
                    openuuStatusTrampoline,
                    ctx
                )
            }
        }
        return rc == 0
    }

    @discardableResult
    func connectClient(hostIP: String, port: UInt16, pin: String) -> Bool {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let rc = hostIP.withCString { ipPtr in
            pin.withCString { pinPtr in
                openuu_connect_client(
                    runtime,
                    ipPtr,
                    port,
                    pinPtr,
                    openuuControlTrampoline,
                    openuuVideoTrampoline,
                    openuuStatusTrampoline,
                    ctx
                )
            }
        }
        return rc == 0
    }

    func disconnect() {
        openuu_disconnect(runtime)
    }

    func getIdentitySnapshot() -> IdentitySnapshotModel? {
        guard let cstr = openuu_get_identity_json(runtime) else { return nil }
        defer { openuu_free_string(cstr) }
        let json = String(cString: cstr)
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(IdentitySnapshotModel.self, from: data)
    }

    @discardableResult
    func setWanConfig(_ config: WanConfigModel) -> Bool {
        guard let data = try? JSONEncoder().encode(config),
              let json = String(data: data, encoding: .utf8) else { return false }
        return json.withCString { ptr in
            openuu_set_wan_config_json(runtime, ptr) == 0
        }
    }

    @discardableResult
    func removeTrustedPeer(deviceID: String) -> Bool {
        deviceID.withCString { ptr in
            openuu_remove_trusted_peer(runtime, ptr) == 0
        }
    }

    func probeDevicesOnline(_ queries: [DeviceProbeQueryModel]) {
        guard !queries.isEmpty,
              let data = try? JSONEncoder().encode(queries),
              let json = String(data: data, encoding: .utf8) else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        json.withCString { ptr in
            _ = openuu_probe_devices_online(runtime, ptr, openuuProbeTrampoline, ctx)
        }
    }

    func requestAppList() {
        _ = openuu_request_app_list(runtime)
    }

    func startRemoteSession(bundleID: String, windowID: UInt32 = 0) {
        bundleID.withCString { ptr in
            _ = openuu_start_remote_session(runtime, ptr, windowID)
        }
    }

    func stopRemoteSession(windowID: UInt32) {
        _ = openuu_stop_remote_session(runtime, windowID)
    }

    func sendMouse(
        windowID: UInt32,
        x: Float,
        y: Float,
        type: UInt8,
        button: UInt32 = 0,
        clickCount: UInt32 = 1,
        modifiers: UInt32 = 0
    ) {
        _ = openuu_send_mouse_event(runtime, windowID, x, y, type, button, clickCount, modifiers)
    }

    func sendScroll(
        windowID: UInt32,
        x: Float,
        y: Float,
        deltaX: Float,
        deltaY: Float,
        isContinuous: Bool = true,
        modifiers: UInt32 = 0
    ) {
        _ = openuu_send_scroll_event(runtime, windowID, x, y, deltaX, deltaY, isContinuous, modifiers)
    }

    func sendKey(
        windowID: UInt32,
        keyCode: UInt32,
        isDown: Bool,
        isRepeat: Bool = false,
        modifiers: UInt32 = 0
    ) {
        _ = openuu_send_key_event(runtime, windowID, keyCode, isDown, isRepeat, modifiers)
    }

    func sendTextCommit(windowID: UInt32, text: String) {
        text.withCString { ptr in
            _ = openuu_send_text_commit(runtime, windowID, ptr)
        }
    }

    func requestKeyframe(windowID: UInt32) {
        _ = openuu_request_keyframe(runtime, windowID)
    }

    func sendAudioControl(enabled: Bool, muteHost: Bool) {
        _ = openuu_send_audio_control(runtime, enabled, muteHost)
    }

    func sendResizeWindow(windowID: UInt32, width: Float, height: Float) {
        _ = openuu_send_resize_window(runtime, windowID, width, height)
    }

    func sendClipboardText(hash: String, text: String) {
        hash.withCString { hashPtr in
            text.withCString { textPtr in
                _ = openuu_send_clipboard_text(runtime, hashPtr, textPtr)
            }
        }
    }

    func sendClipboardImage(hash: String, mimeType: String, data: Data) {
        hash.withCString { hashPtr in
            mimeType.withCString { mimePtr in
                data.withUnsafeBytes { rawBuf in
                    guard let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
                    _ = openuu_send_clipboard_image(runtime, hashPtr, mimePtr, ptr, data.count)
                }
            }
        }
    }

    @discardableResult
    func sendFileBlob(windowID: UInt32, x: Float, y: Float, fileURL: URL) -> Bool {
        let blobID = UUID().uuidString
        let filename = fileURL.lastPathComponent
        let localPath = fileURL.path
        let rc = blobID.withCString { blobPtr in
            filename.withCString { namePtr in
                localPath.withCString { pathPtr in
                    openuu_send_file_blob(runtime, windowID, x, y, blobPtr, namePtr, pathPtr)
                }
            }
        }
        return rc == 0
    }
}

private func openuuControlTrampoline(ctx: UnsafeMutableRawPointer?, jsonPtr: UnsafePointer<CChar>?) {
    guard let ctx, let jsonPtr else { return }
    let bridge = Unmanaged<OpenUUBridge>.fromOpaque(ctx).takeUnretainedValue()
    let str = String(cString: jsonPtr)
    if let data = str.data(using: .utf8),
       let msg = try? JSONDecoder().decode(ControlEventMessage.self, from: data) {
        bridge.onControlEvent?(msg)
    }
}

private func openuuVideoTrampoline(
    ctx: UnsafeMutableRawPointer?,
    codec: UInt8,
    flags: UInt8,
    windowID: UInt32,
    timestampUS: UInt64,
    width: UInt16,
    height: UInt16,
    dataPtr: UnsafePointer<UInt8>?,
    dataLen: Int
) {
    guard let ctx, let dataPtr, dataLen > 0 else { return }
    let bridge = Unmanaged<OpenUUBridge>.fromOpaque(ctx).takeUnretainedValue()
    let payload = Data(bytes: dataPtr, count: dataLen)
    let packet = EncodedVideoPacket(
        codec: codec,
        flags: flags,
        windowID: windowID,
        timestampUS: timestampUS,
        width: width,
        height: height,
        data: payload
    )
    bridge.onVideoFrame?(packet)
}

private func openuuAudioTrampoline(
    ctx: UnsafeMutableRawPointer?,
    codec: UInt8,
    flags: UInt8,
    channels: UInt8,
    sampleRate: UInt32,
    timestampUS: UInt64,
    dataPtr: UnsafePointer<UInt8>?,
    dataLen: Int
) {
    guard let ctx, let dataPtr, dataLen > 0 else { return }
    let bridge = Unmanaged<OpenUUBridge>.fromOpaque(ctx).takeUnretainedValue()
    let payload = Data(bytes: dataPtr, count: dataLen)
    let packet = EncodedAudioPacket(
        codec: codec,
        flags: flags,
        channels: channels,
        sampleRate: sampleRate,
        timestampUS: timestampUS,
        data: payload
    )
    bridge.onAudioFrame?(packet)
}

private func openuuStatusTrampoline(ctx: UnsafeMutableRawPointer?, statusPtr: UnsafePointer<CChar>?) {
    guard let ctx, let statusPtr else { return }
    let bridge = Unmanaged<OpenUUBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.onStatus?(String(cString: statusPtr))
}

private func openuuProbeTrampoline(ctx: UnsafeMutableRawPointer?, jsonPtr: UnsafePointer<CChar>?) {
    guard let ctx, let jsonPtr else { return }
    let bridge = Unmanaged<OpenUUBridge>.fromOpaque(ctx).takeUnretainedValue()
    let str = String(cString: jsonPtr)
    if let data = str.data(using: .utf8),
       let items = try? JSONDecoder().decode([DeviceProbeResultModel].self, from: data) {
        bridge.onProbeResults?(items)
    }
}
