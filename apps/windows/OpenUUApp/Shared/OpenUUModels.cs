using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json.Serialization;

namespace OpenUU.Shared;

public abstract class ObservableBase : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void OnPropertyChanged([CallerMemberName] string? propertyName = null)
        => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(propertyName));

    protected bool SetField<T>(ref T field, T value, [CallerMemberName] string? propertyName = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value))
            return false;
        field = value;
        OnPropertyChanged(propertyName);
        return true;
    }
}

public enum SidebarTab
{
    RemoteHome,
    DeviceList,
    SecurityQuality,
    NetworkLogs
}

public static class SidebarTabExtensions
{
    public static string GetTitle(this SidebarTab tab) => tab switch
    {
        SidebarTab.RemoteHome => "远程控制",
        SidebarTab.DeviceList => "设备列表",
        SidebarTab.SecurityQuality => "安全与画质",
        SidebarTab.NetworkLogs => "网络与日志",
        _ => "远程控制"
    };

    public static string GetSubtitle(this SidebarTab tab) => tab switch
    {
        SidebarTab.RemoteHome => "局域网与异地自动直连 · 支持单应用无缝窗口与整屏远程桌面",
        SidebarTab.DeviceList => "集中维护所有受控端设备与密码，支持同时连接并操控多台远端电脑",
        SidebarTab.SecurityQuality => "配置编码帧率、后台无感捕获、跨多机剪贴板同步及系统环境",
        SidebarTab.NetworkLogs => "配置跨网寻址与中继服务域名，查看实时分级诊断日志",
        _ => ""
    };
}

public enum StreamNetworkTier
{
    Lan,
    WanDirect,
    WanRelay
}

public static class StreamNetworkTierExtensions
{
    public static StreamNetworkTier Parse(string? raw) => raw switch
    {
        "wan_direct" => StreamNetworkTier.WanDirect,
        "wan_relay" => StreamNetworkTier.WanRelay,
        _ => StreamNetworkTier.Lan
    };

    public static string ToWireString(this StreamNetworkTier tier) => tier switch
    {
        StreamNetworkTier.WanDirect => "wan_direct",
        StreamNetworkTier.WanRelay => "wan_relay",
        _ => "lan"
    };

    public static string GetLabel(this StreamNetworkTier tier) => tier switch
    {
        StreamNetworkTier.WanDirect => "P2P 直连",
        StreamNetworkTier.WanRelay => "中继保底",
        _ => "局域网直连"
    };

    // Default to universal H.264 on Windows Host so all Windows/Mac/iOS/Android clients decode natively
    // without requiring the paid Microsoft Store HEVC Video Extension.
    public static bool PrefersHevc(this StreamNetworkTier _) => false;
}

public sealed class DiscoveredPeer
{
    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = "";

    [JsonPropertyName("device_name")]
    public string DeviceName { get; set; } = "";

    [JsonPropertyName("os")]
    public string Os { get; set; } = "";

    [JsonPropertyName("addresses")]
    public List<string> Addresses { get; set; } = new();

    [JsonPropertyName("port")]
    public ushort Port { get; set; } = 39481;

    [JsonPropertyName("protocol_version")]
    public uint ProtocolVersion { get; set; } = 1;

    [JsonPropertyName("device_code")]
    public string? DeviceCode { get; set; }

    [JsonPropertyName("endpoint_id")]
    public string? EndpointId { get; set; }

    [JsonIgnore]
    public string PreferredIp =>
        Addresses.FirstOrDefault(a => !a.Contains(':'))
        ?? Addresses.FirstOrDefault()
        ?? "127.0.0.1";
}

public sealed class WanConfigModel : IEquatable<WanConfigModel>
{
    [JsonPropertyName("coord_url")]
    public string CoordUrl { get; set; } = "https://openuu.1kb.ren";

    [JsonPropertyName("relay_url")]
    public string RelayUrl { get; set; } = "https://openuu-relay.1kb.ren";

    [JsonPropertyName("relay_auth_token")]
    public string? RelayAuthToken { get; set; } = "openuu-public-relay-fair-use";

    [JsonPropertyName("enable_public_fallback")]
    public bool EnablePublicFallback { get; set; } = true;

    [JsonPropertyName("allow_insecure_tls")]
    public bool AllowInsecureTls { get; set; } = false;

    public bool Equals(WanConfigModel? other)
    {
        if (other is null) return false;
        return CoordUrl == other.CoordUrl &&
               RelayUrl == other.RelayUrl &&
               (RelayAuthToken ?? "") == (other.RelayAuthToken ?? "") &&
               EnablePublicFallback == other.EnablePublicFallback &&
               AllowInsecureTls == other.AllowInsecureTls;
    }

    public override bool Equals(object? obj) => Equals(obj as WanConfigModel);
    public override int GetHashCode() => HashCode.Combine(CoordUrl, RelayUrl, RelayAuthToken, EnablePublicFallback, AllowInsecureTls);
}

public sealed class TrustedPeerModel
{
    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = "";

    [JsonPropertyName("device_name")]
    public string DeviceName { get; set; } = "";

    [JsonPropertyName("cert_fingerprint")]
    public string CertFingerprint { get; set; } = "";

    [JsonPropertyName("endpoint_id")]
    public string EndpointId { get; set; } = "";

    [JsonPropertyName("device_code")]
    public string DeviceCode { get; set; } = "";

    [JsonPropertyName("last_relay_url")]
    public string LastRelayUrl { get; set; } = "";

    [JsonPropertyName("last_ticket")]
    public string LastTicket { get; set; } = "";

    [JsonPropertyName("last_connected_ms")]
    public ulong LastConnectedMs { get; set; }

    [JsonIgnore]
    public string FormattedCode =>
        DeviceCode.Length == 9
            ? $"{DeviceCode[..3]} {DeviceCode[3..6]} {DeviceCode[6..]}"
            : DeviceCode;
}

public sealed class DeviceProbeQueryModel
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("target")]
    public string Target { get; set; } = "";

    [JsonPropertyName("pin")]
    public string Pin { get; set; } = "";

    [JsonPropertyName("endpoint_id")]
    public string EndpointId { get; set; } = "";
}

public sealed class DeviceProbeResultModel
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = "";

    [JsonPropertyName("online")]
    public bool Online { get; set; }

    [JsonPropertyName("via")]
    public string Via { get; set; } = "offline";

    [JsonPropertyName("remote_name")]
    public string RemoteName { get; set; } = "";
}

public sealed class IdentitySnapshotModel
{
    [JsonPropertyName("device_id")]
    public string DeviceId { get; set; } = "";

    [JsonPropertyName("device_name")]
    public string DeviceName { get; set; } = "";

    [JsonPropertyName("device_code")]
    public string DeviceCode { get; set; } = "";

    [JsonPropertyName("formatted_code")]
    public string FormattedCode { get; set; } = "--- --- ---";

    [JsonPropertyName("endpoint_id")]
    public string EndpointId { get; set; } = "";

    [JsonPropertyName("host_ticket")]
    public string HostTicket { get; set; } = "";

    [JsonPropertyName("coord_status")]
    public string CoordStatus { get; set; } = "";

    [JsonPropertyName("wan_config")]
    public WanConfigModel WanConfig { get; set; } = new();

    [JsonPropertyName("trusted_peers")]
    public List<TrustedPeerModel> TrustedPeers { get; set; } = new();
}

public sealed class RemoteAppSummary
{
    [JsonPropertyName("bundle_id")]
    public string BundleId { get; set; } = "";

    [JsonPropertyName("name")]
    public string Name { get; set; } = "";

    [JsonPropertyName("pid")]
    public uint Pid { get; set; }

    [JsonPropertyName("window_count")]
    public uint WindowCount { get; set; }

    [JsonPropertyName("icon_png_b64")]
    public string? IconPngB64 { get; set; }

    [JsonIgnore]
    public string UniqueId => $"{BundleId}-{Pid}";

    [JsonIgnore]
    public System.Windows.Media.ImageSource? DisplayIcon { get; set; }
}

public sealed class WindowTopologyItem : IEquatable<WindowTopologyItem>
{
    [JsonPropertyName("window_id")]
    public uint WindowId { get; set; }

    [JsonPropertyName("parent_window_id")]
    public uint ParentWindowId { get; set; }

    [JsonPropertyName("kind")]
    public int Kind { get; set; } // 0=MAIN, 1=POPUP/SECONDARY, 2=MENU/FLOATING_POPOVER

    [JsonPropertyName("rel_x")]
    public float RelX { get; set; }

    [JsonPropertyName("rel_y")]
    public float RelY { get; set; }

    [JsonPropertyName("width")]
    public float Width { get; set; }

    [JsonPropertyName("height")]
    public float Height { get; set; }

    [JsonPropertyName("title")]
    public string Title { get; set; } = "";

    [JsonPropertyName("icon_png_b64")]
    public string? IconPngB64 { get; set; }

    public bool Equals(WindowTopologyItem? other)
    {
        if (other is null) return false;
        return WindowId == other.WindowId &&
               ParentWindowId == other.ParentWindowId &&
               Kind == other.Kind &&
               MathF.Abs(RelX - other.RelX) < 0.5f &&
               MathF.Abs(RelY - other.RelY) < 0.5f &&
               MathF.Abs(Width - other.Width) < 0.5f &&
               MathF.Abs(Height - other.Height) < 0.5f &&
               Title == other.Title &&
               (IconPngB64 ?? "") == (other.IconPngB64 ?? "");
    }

    public override bool Equals(object? obj) => Equals(obj as WindowTopologyItem);
    public override int GetHashCode() => HashCode.Combine(WindowId, ParentWindowId, Kind, Title);
}

public sealed class ControlEventMessage
{
    [JsonPropertyName("type")]
    public string Type { get; set; } = "";

    [JsonPropertyName("window_id")]
    public uint? WindowId { get; set; }

    [JsonPropertyName("bundle_id")]
    public string? BundleId { get; set; }

    [JsonPropertyName("x")]
    public float? X { get; set; }

    [JsonPropertyName("y")]
    public float? Y { get; set; }

    [JsonPropertyName("width")]
    public float? Width { get; set; }

    [JsonPropertyName("height")]
    public float? Height { get; set; }

    [JsonPropertyName("event_type")]
    public int? EventType { get; set; }

    [JsonPropertyName("button")]
    public uint? Button { get; set; }

    [JsonPropertyName("click_count")]
    public uint? ClickCount { get; set; }

    [JsonPropertyName("modifiers")]
    public uint? Modifiers { get; set; }

    [JsonPropertyName("delta_x")]
    public float? DeltaX { get; set; }

    [JsonPropertyName("delta_y")]
    public float? DeltaY { get; set; }

    [JsonPropertyName("is_continuous")]
    public bool? IsContinuous { get; set; }

    [JsonPropertyName("key_code")]
    public uint? KeyCode { get; set; }

    [JsonPropertyName("is_down")]
    public bool? IsDown { get; set; }

    [JsonPropertyName("is_repeat")]
    public bool? IsRepeat { get; set; }

    [JsonPropertyName("text")]
    public string? Text { get; set; }

    [JsonPropertyName("app_bundle_id")]
    public string? AppBundleId { get; set; }

    [JsonPropertyName("title")]
    public string? Title { get; set; }

    [JsonPropertyName("subtitle")]
    public string? Subtitle { get; set; }

    [JsonPropertyName("body")]
    public string? Body { get; set; }

    [JsonPropertyName("badge_text")]
    public string? BadgeText { get; set; }

    [JsonPropertyName("kind")]
    public string? Kind { get; set; }

    [JsonPropertyName("hotspot_x")]
    public float? HotspotX { get; set; }

    [JsonPropertyName("hotspot_y")]
    public float? HotspotY { get; set; }

    [JsonPropertyName("content_hash")]
    public string? ContentHash { get; set; }

    [JsonPropertyName("clip_kind")]
    public int? ClipKind { get; set; }

    [JsonPropertyName("mime_type")]
    public string? MimeType { get; set; }

    [JsonPropertyName("image_b64")]
    public string? ImageB64 { get; set; }

    [JsonPropertyName("blob_id")]
    public string? BlobId { get; set; }

    [JsonPropertyName("local_path")]
    public string? LocalPath { get; set; }

    [JsonPropertyName("link_mode")]
    public string? LinkMode { get; set; }

    [JsonPropertyName("rtt_ms")]
    public uint? RttMs { get; set; }

    [JsonPropertyName("remote_addr")]
    public string? RemoteAddr { get; set; }

    [JsonPropertyName("audio_enabled")]
    public bool? AudioEnabled { get; set; }

    [JsonPropertyName("mute_host")]
    public bool? MuteHost { get; set; }

    [JsonPropertyName("windows")]
    public List<WindowTopologyItem>? Windows { get; set; }

    [JsonPropertyName("apps")]
    public List<RemoteAppSummary>? Apps { get; set; }
}

public sealed class EncodedVideoPacket
{
    public byte Codec { get; init; }
    public byte Flags { get; init; }
    public uint WindowId { get; init; }
    public ulong TimestampUs { get; init; }
    public ushort Width { get; init; }
    public ushort Height { get; init; }
    public byte[] Data { get; init; } = Array.Empty<byte>();
}

public sealed class EncodedAudioPacket
{
    public byte Codec { get; init; }
    public byte Flags { get; init; }
    public byte Channels { get; init; }
    public uint SampleRate { get; init; }
    public ulong TimestampUs { get; init; }
    public byte[] Data { get; init; } = Array.Empty<byte>();
}

public sealed record VideoStreamTelemetry(
    string CodecName,
    int Fps,
    int HostFps,
    int MaxGapMs,
    double BitrateMbps,
    int EncodedWidth,
    int EncodedHeight,
    int LogicalWidth,
    int LogicalHeight,
    double ScaleRatio,
    double AvgDecodeMs,
    int LastFrameBytes,
    bool IsLastKeyframe,
    int SkippedBurstFrames,
    long UpdatedAtTicks
);
