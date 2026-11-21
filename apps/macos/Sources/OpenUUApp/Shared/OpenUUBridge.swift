import COpenUUCore
import Foundation

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
}

struct DeviceProbeQueryModel: Codable, Sendable {
    let id: String
    let target: String
    let pin: String
    let endpoint_id: String
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

final class OpenUUBridge: @unchecked Sendable {
    private let runtime: OpaquePointer
    var onControlEvent: ((ControlEventMessage) -> Void)?
    var onVideoFrame: ((EncodedVideoPacket) -> Void)?
    var onStatus: ((String) -> Void)?
    var onProbeResults: (([DeviceProbeResultModel]) -> Void)?

    init(deviceName: String = Host.current().localizedName ?? "OpenUU-Mac") {
        guard let rt = deviceName.withCString({ openuu_runtime_create($0) }) else {
            fatalError("Failed to create OpenUURuntime")
        }
        self.runtime = rt
    }

    deinit {
        openuu_disconnect(runtime)
        openuu_runtime_destroy(runtime)
    }

    func startHost(port: UInt16 = 39481, preferredPIN: String? = nil) -> (boundPort: UInt16, pin: String)? {
        var pinBuf = [CChar](repeating: 0, count: 32)
        if let preferredPIN, !preferredPIN.isEmpty {
            let utf8 = Array(preferredPIN.utf8.prefix(31))
            for (i, b) in utf8.enumerated() {
                pinBuf[i] = CChar(bitPattern: b)
            }
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let bound = openuu_start_host(
            runtime,
            port,
            &pinBuf,
            pinBuf.count,
            openuuControlTrampoline,
            openuuVideoTrampoline,
            openuuStatusTrampoline,
            ctx
        )
        guard bound > 0 else { return nil }
        let bytes = pinBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let pin = String(decoding: bytes, as: UTF8.self)
        return (bound, pin)
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

    func connectSmart(target: String, defaultPort: UInt16 = 39481, pin: String) -> Bool {
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

    func generateAccessCode(strongAlphanumeric: Bool) -> String {
        guard let cstr = openuu_generate_access_code(strongAlphanumeric) else {
            return String(format: "%06d", Int.random(in: 0...999999))
        }
        defer { openuu_free_string(cstr) }
        return String(cString: cstr)
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

    func disconnect() {
        openuu_disconnect(runtime)
    }

    func stopHost() {
        openuu_stop_host(runtime)
    }

    func sendVideoFrame(
        codec: UInt8,
        flags: UInt8,
        windowID: UInt32,
        timestampUS: UInt64,
        width: UInt16,
        height: UInt16,
        data: Data
    ) {
        data.withUnsafeBytes { rawBuf in
            guard let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
            _ = openuu_send_video_frame(
                runtime,
                codec,
                flags,
                windowID,
                timestampUS,
                width,
                height,
                ptr,
                data.count
            )
        }
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
        isContinuous: Bool,
        modifiers: UInt32
    ) {
        _ = openuu_send_scroll_event(runtime, windowID, x, y, deltaX, deltaY, isContinuous, modifiers)
    }

    func sendKey(
        windowID: UInt32,
        keyCode: UInt32,
        isDown: Bool,
        isRepeat: Bool,
        modifiers: UInt32
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

    func sendNotification(bundleID: String, title: String, subtitle: String, body: String, timestampMS: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) {
        bundleID.withCString { bidPtr in
            title.withCString { titlePtr in
                subtitle.withCString { subPtr in
                    body.withCString { bodyPtr in
                        _ = openuu_send_notification(runtime, bidPtr, titlePtr, subPtr, bodyPtr, timestampMS)
                    }
                }
            }
        }
    }

    func sendBadgeUpdate(bundleID: String, badgeText: String) {
        bundleID.withCString { bidPtr in
            badgeText.withCString { badgePtr in
                _ = openuu_send_badge_update(runtime, bidPtr, badgePtr)
            }
        }
    }

    func sendFileBlob(windowID: UInt32, x: Float, y: Float, fileURL: URL) {
        let blobID = UUID().uuidString
        let filename = fileURL.lastPathComponent
        let localPath = fileURL.path
        blobID.withCString { blobPtr in
            filename.withCString { namePtr in
                localPath.withCString { pathPtr in
                    _ = openuu_send_file_blob(runtime, windowID, x, y, blobPtr, namePtr, pathPtr)
                }
            }
        }
    }

    func sendCursorUpdate(kind: String) {
        kind.withCString { ptr in
            _ = openuu_send_cursor_update(runtime, ptr, nil, 0, 0, 0)
        }
    }

    func sendWindowTopology(_ items: [WindowTopologyItem]) {
        guard let data = try? JSONEncoder().encode(items),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { ptr in
            _ = openuu_send_window_topology_json(runtime, ptr)
        }
    }

    func requestAppList() {
        _ = openuu_request_app_list(runtime)
    }

    func sendAppList(_ apps: [RemoteAppSummary]) {
        guard let data = try? JSONEncoder().encode(apps),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { ptr in
            _ = openuu_send_app_list_json(runtime, ptr)
        }
    }

    func startRemoteSession(bundleID: String, windowID: UInt32 = 0) {
        bundleID.withCString { ptr in
            _ = openuu_start_remote_session(runtime, ptr, windowID)
        }
    }

    func stopRemoteSession(windowID: UInt32) {
        _ = openuu_stop_remote_session(runtime, windowID)
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
