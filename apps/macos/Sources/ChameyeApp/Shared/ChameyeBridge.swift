import CChameyeCore
import Foundation

struct DiscoveredPeer: Codable, Identifiable, Hashable, Sendable {
    let device_id: String
    let device_name: String
    let os: String
    let addresses: [String]
    let port: UInt16
    let protocol_version: UInt32

    var id: String { device_id }
    var preferredIP: String {
        addresses.first(where: { !$0.contains(":") }) ?? addresses.first ?? "127.0.0.1"
    }
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

final class ChameyeBridge: @unchecked Sendable {
    private let runtime: OpaquePointer
    var onControlEvent: ((ControlEventMessage) -> Void)?
    var onVideoFrame: ((EncodedVideoPacket) -> Void)?
    var onStatus: ((String) -> Void)?

    init(deviceName: String = Host.current().localizedName ?? "Chameye-Mac") {
        guard let rt = deviceName.withCString({ chameye_runtime_create($0) }) else {
            fatalError("Failed to create ChameyeRuntime")
        }
        self.runtime = rt
    }

    deinit {
        chameye_disconnect(runtime)
        chameye_runtime_destroy(runtime)
    }

    func startHost(port: UInt16 = 39481, preferredPIN: String? = nil) -> (boundPort: UInt16, pin: String)? {
        var pinBuf = [CChar](repeating: 0, count: 16)
        if let preferredPIN, !preferredPIN.isEmpty {
            let utf8 = Array(preferredPIN.utf8.prefix(15))
            for (i, b) in utf8.enumerated() {
                pinBuf[i] = CChar(bitPattern: b)
            }
        }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let bound = chameye_start_host(
            runtime,
            port,
            &pinBuf,
            pinBuf.count,
            chameyeControlTrampoline,
            chameyeVideoTrampoline,
            chameyeStatusTrampoline,
            ctx
        )
        guard bound > 0 else { return nil }
        let bytes = pinBuf.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        let pin = String(decoding: bytes, as: UTF8.self)
        return (bound, pin)
    }

    func startDiscovery() {
        _ = chameye_start_discovery(runtime)
    }

    func listPeers() -> [DiscoveredPeer] {
        guard let cstr = chameye_list_peers_json(runtime) else { return [] }
        defer { chameye_free_string(cstr) }
        let json = String(cString: cstr)
        guard let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([DiscoveredPeer].self, from: data)) ?? []
    }

    func connectClient(hostIP: String, port: UInt16, pin: String) -> Bool {
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let rc = hostIP.withCString { ipPtr in
            pin.withCString { pinPtr in
                chameye_connect_client(
                    runtime,
                    ipPtr,
                    port,
                    pinPtr,
                    chameyeControlTrampoline,
                    chameyeVideoTrampoline,
                    chameyeStatusTrampoline,
                    ctx
                )
            }
        }
        return rc == 0
    }

    func disconnect() {
        chameye_disconnect(runtime)
    }

    func stopHost() {
        chameye_stop_host(runtime)
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
            _ = chameye_send_video_frame(
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
        _ = chameye_send_mouse_event(runtime, windowID, x, y, type, button, clickCount, modifiers)
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
        _ = chameye_send_scroll_event(runtime, windowID, x, y, deltaX, deltaY, isContinuous, modifiers)
    }

    func sendKey(
        windowID: UInt32,
        keyCode: UInt32,
        isDown: Bool,
        isRepeat: Bool,
        modifiers: UInt32
    ) {
        _ = chameye_send_key_event(runtime, windowID, keyCode, isDown, isRepeat, modifiers)
    }

    func sendTextCommit(windowID: UInt32, text: String) {
        text.withCString { ptr in
            _ = chameye_send_text_commit(runtime, windowID, ptr)
        }
    }

    func requestKeyframe(windowID: UInt32) {
        _ = chameye_request_keyframe(runtime, windowID)
    }

    func sendResizeWindow(windowID: UInt32, width: Float, height: Float) {
        _ = chameye_send_resize_window(runtime, windowID, width, height)
    }

    func sendClipboardText(hash: String, text: String) {
        hash.withCString { hashPtr in
            text.withCString { textPtr in
                _ = chameye_send_clipboard_text(runtime, hashPtr, textPtr)
            }
        }
    }

    func sendClipboardImage(hash: String, mimeType: String, data: Data) {
        hash.withCString { hashPtr in
            mimeType.withCString { mimePtr in
                data.withUnsafeBytes { rawBuf in
                    guard let ptr = rawBuf.bindMemory(to: UInt8.self).baseAddress else { return }
                    _ = chameye_send_clipboard_image(runtime, hashPtr, mimePtr, ptr, data.count)
                }
            }
        }
    }

    func sendNotification(bundleID: String, title: String, subtitle: String, body: String, timestampMS: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000)) {
        bundleID.withCString { bidPtr in
            title.withCString { titlePtr in
                subtitle.withCString { subPtr in
                    body.withCString { bodyPtr in
                        _ = chameye_send_notification(runtime, bidPtr, titlePtr, subPtr, bodyPtr, timestampMS)
                    }
                }
            }
        }
    }

    func sendBadgeUpdate(bundleID: String, badgeText: String) {
        bundleID.withCString { bidPtr in
            badgeText.withCString { badgePtr in
                _ = chameye_send_badge_update(runtime, bidPtr, badgePtr)
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
                    _ = chameye_send_file_blob(runtime, windowID, x, y, blobPtr, namePtr, pathPtr)
                }
            }
        }
    }

    func sendCursorUpdate(kind: String) {
        kind.withCString { ptr in
            _ = chameye_send_cursor_update(runtime, ptr, nil, 0, 0, 0)
        }
    }

    func sendWindowTopology(_ items: [WindowTopologyItem]) {
        guard let data = try? JSONEncoder().encode(items),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { ptr in
            _ = chameye_send_window_topology_json(runtime, ptr)
        }
    }

    func requestAppList() {
        _ = chameye_request_app_list(runtime)
    }

    func sendAppList(_ apps: [RemoteAppSummary]) {
        guard let data = try? JSONEncoder().encode(apps),
              let json = String(data: data, encoding: .utf8) else { return }
        json.withCString { ptr in
            _ = chameye_send_app_list_json(runtime, ptr)
        }
    }

    func startRemoteSession(bundleID: String, windowID: UInt32 = 0) {
        bundleID.withCString { ptr in
            _ = chameye_start_remote_session(runtime, ptr, windowID)
        }
    }

    func stopRemoteSession(windowID: UInt32) {
        _ = chameye_stop_remote_session(runtime, windowID)
    }
}

private func chameyeControlTrampoline(ctx: UnsafeMutableRawPointer?, jsonPtr: UnsafePointer<CChar>?) {
    guard let ctx, let jsonPtr else { return }
    let bridge = Unmanaged<ChameyeBridge>.fromOpaque(ctx).takeUnretainedValue()
    let str = String(cString: jsonPtr)
    if let data = str.data(using: .utf8),
       let msg = try? JSONDecoder().decode(ControlEventMessage.self, from: data) {
        bridge.onControlEvent?(msg)
    }
}

private func chameyeVideoTrampoline(
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
    let bridge = Unmanaged<ChameyeBridge>.fromOpaque(ctx).takeUnretainedValue()
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

private func chameyeStatusTrampoline(ctx: UnsafeMutableRawPointer?, statusPtr: UnsafePointer<CChar>?) {
    guard let ctx, let statusPtr else { return }
    let bridge = Unmanaged<ChameyeBridge>.fromOpaque(ctx).takeUnretainedValue()
    bridge.onStatus?(String(cString: statusPtr))
}
