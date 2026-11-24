using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenUU.Shared;

/// <summary>
/// Thread-safe managed wrapper around Rust <c>OpenUURuntime*</c>, keeping static unmanaged callback delegates
/// and a <see cref="GCHandle"/> alive for the entire lifetime of the runtime.
/// </summary>
public sealed unsafe class OpenUUBridge : IDisposable
{
    private static readonly JsonSerializerOptions WireJsonOptions = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };
    private static readonly OpenUUNativeMethods.ControlCallback StaticControlCb = OnControlTrampoline;
    private static readonly OpenUUNativeMethods.VideoCallback StaticVideoCb = OnVideoTrampoline;
    private static readonly OpenUUNativeMethods.AudioCallback StaticAudioCb = OnAudioTrampoline;
    private static readonly OpenUUNativeMethods.StatusCallback StaticStatusCb = OnStatusTrampoline;
    private static readonly OpenUUNativeMethods.StatusCallback StaticProbeCb = OnProbeTrampoline;

    private IntPtr _runtime;
    private GCHandle _selfHandle;
    private bool _disposed;

    public Action<ControlEventMessage>? OnControlEvent { get; set; }
    public Action<EncodedVideoPacket>? OnVideoFrame { get; set; }
    public Action<EncodedAudioPacket>? OnAudioFrame { get; set; }
    public Action<string>? OnStatus { get; set; }
    public Action<List<DeviceProbeResultModel>>? OnProbeResults { get; set; }

    public OpenUUBridge(string? deviceName = null, string? configDir = null)
    {
        var name = string.IsNullOrWhiteSpace(deviceName) ? Environment.MachineName : deviceName.Trim();
        if (string.IsNullOrWhiteSpace(name))
            name = "OpenUU-PC";

        _selfHandle = GCHandle.Alloc(this, GCHandleType.Normal);

        var nameBytes = ToNullTerminatedUtf8(name);
        fixed (byte* pName = nameBytes)
        {
            if (!string.IsNullOrWhiteSpace(configDir))
            {
                var dirBytes = ToNullTerminatedUtf8(configDir.Trim());
                fixed (byte* pDir = dirBytes)
                {
                    _runtime = OpenUUNativeMethods.openuu_runtime_create_with_dir(pName, pDir);
                }
            }
            else
            {
                _runtime = OpenUUNativeMethods.openuu_runtime_create(pName);
            }
        }

        if (_runtime == IntPtr.Zero)
        {
            if (_selfHandle.IsAllocated)
                _selfHandle.Free();
            throw new InvalidOperationException("Failed to create OpenUURuntime (openuu_core.dll).");
        }

        OpenUUNativeMethods.openuu_set_audio_callback(_runtime, StaticAudioCb, GCHandle.ToIntPtr(_selfHandle));
    }

    public static void SetGlobalAppDirs(string? configDir, string? cacheDir)
    {
        var cfgBytes = string.IsNullOrWhiteSpace(configDir) ? null : ToNullTerminatedUtf8(configDir.Trim());
        var cacheBytes = string.IsNullOrWhiteSpace(cacheDir) ? null : ToNullTerminatedUtf8(cacheDir.Trim());
        fixed (byte* pCfg = cfgBytes)
        fixed (byte* pCache = cacheBytes)
        {
            OpenUUNativeMethods.openuu_set_app_dirs(pCfg, pCache);
        }
    }

    public (ushort BoundPort, string Pin)? StartHost(ushort port = 39481, string? preferredPin = null)
    {
        if (_disposed || _runtime == IntPtr.Zero) return null;

        var pinBuf = new byte[48];
        if (!string.IsNullOrWhiteSpace(preferredPin))
        {
            var utf8 = Encoding.UTF8.GetBytes(preferredPin.Trim());
            var len = Math.Min(utf8.Length, pinBuf.Length - 1);
            Array.Copy(utf8, pinBuf, len);
        }

        ushort bound;
        fixed (byte* pPin = pinBuf)
        {
            bound = OpenUUNativeMethods.openuu_start_host(
                _runtime,
                port,
                pPin,
                (nuint)pinBuf.Length,
                StaticControlCb,
                StaticVideoCb,
                StaticStatusCb,
                GCHandle.ToIntPtr(_selfHandle)
            );
        }

        if (bound == 0) return null;
        int actualLen = Array.IndexOf(pinBuf, (byte)0);
        if (actualLen < 0) actualLen = pinBuf.Length;
        string pin = Encoding.UTF8.GetString(pinBuf, 0, actualLen);
        return (bound, pin);
    }

    public void StartDiscovery()
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        OpenUUNativeMethods.openuu_start_discovery(_runtime);
    }

    public List<DiscoveredPeer> ListPeers()
    {
        if (_disposed || _runtime == IntPtr.Zero) return new();
        IntPtr ptr = OpenUUNativeMethods.openuu_list_peers_json(_runtime);
        if (ptr == IntPtr.Zero) return new();
        try
        {
            string json = Marshal.PtrToStringUTF8(ptr) ?? "[]";
            return JsonSerializer.Deserialize<List<DiscoveredPeer>>(json) ?? new();
        }
        catch
        {
            return new();
        }
        finally
        {
            OpenUUNativeMethods.openuu_free_string(ptr);
        }
    }

    public bool ConnectClient(string hostIp, ushort port, string pin)
    {
        if (_disposed || _runtime == IntPtr.Zero) return false;
        var ipBytes = ToNullTerminatedUtf8(hostIp);
        var pinBytes = ToNullTerminatedUtf8(pin);
        fixed (byte* pIp = ipBytes)
        fixed (byte* pPin = pinBytes)
        {
            int rc = OpenUUNativeMethods.openuu_connect_client(
                _runtime,
                pIp,
                port,
                pPin,
                StaticControlCb,
                StaticVideoCb,
                StaticStatusCb,
                GCHandle.ToIntPtr(_selfHandle)
            );
            return rc == 0;
        }
    }

    public bool ConnectSmart(string target, ushort defaultPort, string pin)
    {
        if (_disposed || _runtime == IntPtr.Zero) return false;
        var targetBytes = ToNullTerminatedUtf8(target);
        var pinBytes = ToNullTerminatedUtf8(pin);
        fixed (byte* pTarget = targetBytes)
        fixed (byte* pPin = pinBytes)
        {
            int rc = OpenUUNativeMethods.openuu_connect_smart(
                _runtime,
                pTarget,
                defaultPort,
                pPin,
                StaticControlCb,
                StaticVideoCb,
                StaticStatusCb,
                GCHandle.ToIntPtr(_selfHandle)
            );
            return rc == 0;
        }
    }

    public IdentitySnapshotModel? GetIdentitySnapshot()
    {
        if (_disposed || _runtime == IntPtr.Zero) return null;
        IntPtr ptr = OpenUUNativeMethods.openuu_get_identity_json(_runtime);
        if (ptr == IntPtr.Zero) return null;
        try
        {
            string json = Marshal.PtrToStringUTF8(ptr) ?? "{}";
            return JsonSerializer.Deserialize<IdentitySnapshotModel>(json);
        }
        catch
        {
            return null;
        }
        finally
        {
            OpenUUNativeMethods.openuu_free_string(ptr);
        }
    }

    public bool SetWanConfig(WanConfigModel config)
    {
        if (_disposed || _runtime == IntPtr.Zero) return false;
        string json = JsonSerializer.Serialize(config, WireJsonOptions);
        var bytes = ToNullTerminatedUtf8(json);
        fixed (byte* p = bytes)
        {
            return OpenUUNativeMethods.openuu_set_wan_config_json(_runtime, p) == 0;
        }
    }

    public bool RemoveTrustedPeer(string deviceId)
    {
        if (_disposed || _runtime == IntPtr.Zero || string.IsNullOrEmpty(deviceId)) return false;
        var bytes = ToNullTerminatedUtf8(deviceId);
        fixed (byte* p = bytes)
        {
            return OpenUUNativeMethods.openuu_remove_trusted_peer(_runtime, p) == 0;
        }
    }

    public string GenerateAccessCode(bool strongAlphanumeric)
    {
        IntPtr ptr = OpenUUNativeMethods.openuu_generate_access_code(strongAlphanumeric);
        if (ptr == IntPtr.Zero)
            return Random.Shared.Next(0, 1_000_000).ToString("D6");
        try
        {
            return Marshal.PtrToStringUTF8(ptr) ?? Random.Shared.Next(0, 1_000_000).ToString("D6");
        }
        finally
        {
            OpenUUNativeMethods.openuu_free_string(ptr);
        }
    }

    public void ProbeDevicesOnline(IReadOnlyCollection<DeviceProbeQueryModel> queries)
    {
        if (_disposed || _runtime == IntPtr.Zero || queries.Count == 0) return;
        string json = JsonSerializer.Serialize(queries, WireJsonOptions);
        var bytes = ToNullTerminatedUtf8(json);
        fixed (byte* p = bytes)
        {
            OpenUUNativeMethods.openuu_probe_devices_online(
                _runtime,
                p,
                StaticProbeCb,
                GCHandle.ToIntPtr(_selfHandle)
            );
        }
    }

    public void Disconnect()
    {
        if (!_disposed && _runtime != IntPtr.Zero)
            OpenUUNativeMethods.openuu_disconnect(_runtime);
    }

    public void StopHost()
    {
        if (!_disposed && _runtime != IntPtr.Zero)
            OpenUUNativeMethods.openuu_stop_host(_runtime);
    }

    public void SendVideoFrame(
        byte codec,
        byte flags,
        uint windowId,
        ulong timestampUs,
        ushort width,
        ushort height,
        ReadOnlySpan<byte> data
    )
    {
        if (_disposed || _runtime == IntPtr.Zero || data.IsEmpty) return;
        fixed (byte* pData = data)
        {
            OpenUUNativeMethods.openuu_send_video_frame(
                _runtime,
                codec,
                flags,
                windowId,
                timestampUs,
                width,
                height,
                pData,
                (nuint)data.Length
            );
        }
    }

    public void SendAudioFrame(
        byte codec,
        byte flags,
        byte channels,
        uint sampleRate,
        ulong timestampUs,
        ReadOnlySpan<byte> data
    )
    {
        if (_disposed || _runtime == IntPtr.Zero || data.IsEmpty) return;
        fixed (byte* pData = data)
        {
            OpenUUNativeMethods.openuu_send_audio_frame(
                _runtime,
                codec,
                flags,
                channels,
                sampleRate,
                timestampUs,
                pData,
                (nuint)data.Length
            );
        }
    }

    public void SendAudioControl(bool enabled, bool muteHost)
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        OpenUUNativeMethods.openuu_send_audio_control(_runtime, enabled, muteHost);
    }

    public void SendMouse(
        uint windowId,
        float x,
        float y,
        byte type,
        uint button = 0,
        uint clickCount = 1,
        uint modifiers = 0
    )
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        OpenUUNativeMethods.openuu_send_mouse_event(_runtime, windowId, x, y, type, button, clickCount, modifiers);
    }

    public void SendScroll(
        uint windowId,
        float x,
        float y,
        float deltaX,
        float deltaY,
        bool isContinuous,
        uint modifiers
    )
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        OpenUUNativeMethods.openuu_send_scroll_event(_runtime, windowId, x, y, deltaX, deltaY, isContinuous, modifiers);
    }

    public void SendKey(uint windowId, uint keyCode, bool isDown, bool isRepeat, uint modifiers)
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        OpenUUNativeMethods.openuu_send_key_event(_runtime, windowId, keyCode, isDown, isRepeat, modifiers);
    }

    public void SendTextCommit(uint windowId, string text)
    {
        if (_disposed || _runtime == IntPtr.Zero || string.IsNullOrEmpty(text)) return;
        var bytes = ToNullTerminatedUtf8(text);
        fixed (byte* p = bytes)
        {
            OpenUUNativeMethods.openuu_send_text_commit(_runtime, windowId, p);
        }
    }

    public void RequestKeyframe(uint windowId)
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        OpenUUNativeMethods.openuu_request_keyframe(_runtime, windowId);
    }

    public void SendResizeWindow(uint windowId, float width, float height)
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        OpenUUNativeMethods.openuu_send_resize_window(_runtime, windowId, width, height);
    }

    public void SendClipboardText(string hash, string text)
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        var hBytes = ToNullTerminatedUtf8(hash);
        var tBytes = ToNullTerminatedUtf8(text);
        fixed (byte* pH = hBytes)
        fixed (byte* pT = tBytes)
        {
            OpenUUNativeMethods.openuu_send_clipboard_text(_runtime, pH, pT);
        }
    }

    public void SendClipboardImage(string hash, string mimeType, byte[] data)
    {
        if (_disposed || _runtime == IntPtr.Zero || data.Length == 0) return;
        var hBytes = ToNullTerminatedUtf8(hash);
        var mBytes = ToNullTerminatedUtf8(mimeType);
        fixed (byte* pH = hBytes)
        fixed (byte* pM = mBytes)
        fixed (byte* pD = data)
        {
            OpenUUNativeMethods.openuu_send_clipboard_image(_runtime, pH, pM, pD, (nuint)data.Length);
        }
    }

    public void SendNotification(string bundleId, string title, string subtitle, string body, ulong? timestampMs = null)
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        ulong ts = timestampMs ?? (ulong)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        var bBid = ToNullTerminatedUtf8(bundleId);
        var bTitle = ToNullTerminatedUtf8(title);
        var bSub = ToNullTerminatedUtf8(subtitle);
        var bBody = ToNullTerminatedUtf8(body);
        fixed (byte* pBid = bBid)
        fixed (byte* pTitle = bTitle)
        fixed (byte* pSub = bSub)
        fixed (byte* pBody = bBody)
        {
            OpenUUNativeMethods.openuu_send_notification(_runtime, pBid, pTitle, pSub, pBody, ts);
        }
    }

    public void SendBadgeUpdate(string bundleId, string badgeText)
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        var bBid = ToNullTerminatedUtf8(bundleId);
        var bBadge = ToNullTerminatedUtf8(badgeText);
        fixed (byte* pBid = bBid)
        fixed (byte* pBadge = bBadge)
        {
            OpenUUNativeMethods.openuu_send_badge_update(_runtime, pBid, pBadge);
        }
    }

    public void SendFileBlob(uint windowId, float x, float y, string localFilePath)
    {
        if (_disposed || _runtime == IntPtr.Zero || string.IsNullOrWhiteSpace(localFilePath)) return;
        var blobId = Guid.NewGuid().ToString("N");
        var fileName = System.IO.Path.GetFileName(localFilePath);
        var bBlob = ToNullTerminatedUtf8(blobId);
        var bName = ToNullTerminatedUtf8(fileName);
        var bPath = ToNullTerminatedUtf8(localFilePath);
        fixed (byte* pBlob = bBlob)
        fixed (byte* pName = bName)
        fixed (byte* pPath = bPath)
        {
            OpenUUNativeMethods.openuu_send_file_blob(_runtime, windowId, x, y, pBlob, pName, pPath);
        }
    }

    public void SendCursorUpdate(string kind)
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        var bKind = ToNullTerminatedUtf8(kind);
        fixed (byte* p = bKind)
        {
            OpenUUNativeMethods.openuu_send_cursor_update(_runtime, p, null, 0, 0, 0);
        }
    }

    public void SendWindowTopology(IReadOnlyList<WindowTopologyItem> items)
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        string json = JsonSerializer.Serialize(items, WireJsonOptions);
        var bytes = ToNullTerminatedUtf8(json);
        fixed (byte* p = bytes)
        {
            int rc = OpenUUNativeMethods.openuu_send_window_topology_json(_runtime, p);
            if (rc != 0)
            {
                OpenUULogger.Shared.Warn("TOPO", $"openuu_send_window_topology_json returned {rc} (count={items.Count})");
            }
        }
    }

    public void RequestAppList()
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        OpenUUNativeMethods.openuu_request_app_list(_runtime);
    }

    public void SendAppList(IReadOnlyList<RemoteAppSummary> apps)
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        string json = JsonSerializer.Serialize(apps, WireJsonOptions);
        var bytes = ToNullTerminatedUtf8(json);
        fixed (byte* p = bytes)
        {
            int rc = OpenUUNativeMethods.openuu_send_app_list_json(_runtime, p);
            if (rc != 0)
            {
                OpenUULogger.Shared.Warn("HOST", $"openuu_send_app_list_json returned {rc} (count={apps.Count})");
            }
        }
    }

    public void StartRemoteSession(string bundleId, uint windowId = 0)
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        var bytes = ToNullTerminatedUtf8(bundleId);
        fixed (byte* p = bytes)
        {
            OpenUUNativeMethods.openuu_start_remote_session(_runtime, p, windowId);
        }
    }

    public void StopRemoteSession(uint windowId)
    {
        if (_disposed || _runtime == IntPtr.Zero) return;
        OpenUUNativeMethods.openuu_stop_remote_session(_runtime, windowId);
    }

    public static void CancelIncomingBlob(string blobId)
    {
        if (string.IsNullOrWhiteSpace(blobId)) return;
        var bytes = ToNullTerminatedUtf8(blobId.Trim());
        fixed (byte* p = bytes)
        {
            OpenUUNativeMethods.openuu_cancel_file_blob(p);
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        var rt = Interlocked.Exchange(ref _runtime, IntPtr.Zero);
        if (rt != IntPtr.Zero)
        {
            OpenUUNativeMethods.openuu_set_audio_callback(rt, null, IntPtr.Zero);
            OpenUUNativeMethods.openuu_disconnect(rt);
            OpenUUNativeMethods.openuu_stop_host(rt);
            OpenUUNativeMethods.openuu_runtime_destroy(rt);
        }
        if (_selfHandle.IsAllocated)
        {
            _selfHandle.Free();
        }
    }

    private static byte[] ToNullTerminatedUtf8(string s)
    {
        int len = Encoding.UTF8.GetByteCount(s);
        var buf = new byte[len + 1];
        Encoding.UTF8.GetBytes(s, 0, s.Length, buf, 0);
        return buf;
    }

    private static OpenUUBridge? ResolveBridge(IntPtr ctx)
    {
        if (ctx == IntPtr.Zero) return null;
        try
        {
            var handle = GCHandle.FromIntPtr(ctx);
            return handle.Target as OpenUUBridge;
        }
        catch
        {
            return null;
        }
    }

    private static void OnControlTrampoline(IntPtr userCtx, IntPtr eventJsonUtf8)
    {
        var bridge = ResolveBridge(userCtx);
        if (bridge is null || bridge._disposed || eventJsonUtf8 == IntPtr.Zero) return;
        try
        {
            string? json = Marshal.PtrToStringUTF8(eventJsonUtf8);
            if (string.IsNullOrEmpty(json)) return;
            var msg = JsonSerializer.Deserialize<ControlEventMessage>(json);
            if (msg != null)
                bridge.OnControlEvent?.Invoke(msg);
        }
        catch
        {
            // Ignore malformed control frame
        }
    }

    private static void OnVideoTrampoline(
        IntPtr userCtx,
        byte codec,
        byte flags,
        uint windowId,
        ulong timestampUs,
        ushort width,
        ushort height,
        IntPtr dataPtr,
        nuint dataLen
    )
    {
        var bridge = ResolveBridge(userCtx);
        if (bridge is null || bridge._disposed || dataPtr == IntPtr.Zero || dataLen == 0) return;
        try
        {
            var buf = new byte[(int)dataLen];
            Marshal.Copy(dataPtr, buf, 0, (int)dataLen);
            var pkt = new EncodedVideoPacket
            {
                Codec = codec,
                Flags = flags,
                WindowId = windowId,
                TimestampUs = timestampUs,
                Width = width,
                Height = height,
                Data = buf
            };
            bridge.OnVideoFrame?.Invoke(pkt);
        }
        catch
        {
            // Ignore video callback error
        }
    }

    private static void OnAudioTrampoline(
        IntPtr userCtx,
        byte codec,
        byte flags,
        byte channels,
        uint sampleRate,
        ulong timestampUs,
        IntPtr dataPtr,
        nuint dataLen
    )
    {
        var bridge = ResolveBridge(userCtx);
        if (bridge is null || bridge._disposed || dataPtr == IntPtr.Zero || dataLen == 0) return;
        try
        {
            var buf = new byte[(int)dataLen];
            Marshal.Copy(dataPtr, buf, 0, (int)dataLen);
            var pkt = new EncodedAudioPacket
            {
                Codec = codec,
                Flags = flags,
                Channels = channels,
                SampleRate = sampleRate,
                TimestampUs = timestampUs,
                Data = buf
            };
            bridge.OnAudioFrame?.Invoke(pkt);
        }
        catch
        {
        }
    }

    private static void OnStatusTrampoline(IntPtr userCtx, IntPtr statusUtf8)
    {
        var bridge = ResolveBridge(userCtx);
        if (bridge is null || bridge._disposed || statusUtf8 == IntPtr.Zero) return;
        try
        {
            string? status = Marshal.PtrToStringUTF8(statusUtf8);
            if (!string.IsNullOrEmpty(status))
                bridge.OnStatus?.Invoke(status);
        }
        catch
        {
        }
    }

    private static void OnProbeTrampoline(IntPtr userCtx, IntPtr jsonUtf8)
    {
        var bridge = ResolveBridge(userCtx);
        if (bridge is null || bridge._disposed || jsonUtf8 == IntPtr.Zero) return;
        try
        {
            string? json = Marshal.PtrToStringUTF8(jsonUtf8);
            if (string.IsNullOrEmpty(json)) return;
            var items = JsonSerializer.Deserialize<List<DeviceProbeResultModel>>(json);
            if (items != null)
                bridge.OnProbeResults?.Invoke(items);
        }
        catch
        {
        }
    }
}
