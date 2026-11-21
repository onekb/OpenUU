using System.Collections.ObjectModel;
using System.IO;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace OpenUU.Client;

using OpenUU.Shared;

public static class DeviceCodeFormatter
{
    public static bool IsDeviceCodeLike(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return false;
        string trimmed = raw.Trim();
        return trimmed.All(c => (c >= '0' && c <= '9') || char.IsWhiteSpace(c));
    }

    public static string FormatInput(string? raw)
    {
        if (string.IsNullOrEmpty(raw)) return "";
        string trimmed = raw.Trim();
        if (string.IsNullOrEmpty(trimmed)) return "";

        if (trimmed.All(c => (c >= '0' && c <= '9') || char.IsWhiteSpace(c)))
        {
            var digits = trimmed.Where(c => c >= '0' && c <= '9').ToArray();
            if (digits.Length == 0) return "";
            var sb = new StringBuilder(digits.Length + 4);
            for (int i = 0; i < digits.Length; i++)
            {
                if (i > 0 && i % 3 == 0) sb.Append(' ');
                sb.Append(digits[i]);
            }
            return sb.ToString();
        }

        if (raw.Any(char.IsWhiteSpace))
            return new string(raw.Where(c => !char.IsWhiteSpace(c)).ToArray());

        return raw;
    }

    public static (string Text, int CaretIndex) FormatInputWithCursor(
        string raw,
        int caretIndex,
        string? previousFormatted = null
    )
    {
        int clampedCaret = Math.Clamp(caretIndex, 0, raw.Length);
        string workingRaw = raw;
        int workingCaret = clampedCaret;

        if (!string.IsNullOrEmpty(previousFormatted) &&
            IsDeviceCodeLike(previousFormatted) &&
            IsDeviceCodeLike(raw) &&
            raw.Length == previousFormatted.Length - 1 &&
            clampedCaret > 0 &&
            clampedCaret < previousFormatted.Length &&
            previousFormatted[clampedCaret] == ' ')
        {
            string prevDigits = new string(previousFormatted.Where(c => c >= '0' && c <= '9').ToArray());
            string rawDigits = new string(raw.Where(c => c >= '0' && c <= '9').ToArray());
            if (prevDigits == rawDigits)
            {
                workingRaw = raw.Remove(clampedCaret - 1, 1);
                workingCaret = clampedCaret - 1;
            }
        }

        string formatted = FormatInput(workingRaw);
        if (string.IsNullOrEmpty(formatted))
            return ("", 0);

        string prefix = workingRaw[..Math.Min(workingCaret, workingRaw.Length)];
        if (IsDeviceCodeLike(formatted))
        {
            int digitsBefore = prefix.Count(c => c >= '0' && c <= '9');
            if (digitsBefore == 0) return (formatted, 0);
            int seen = 0;
            for (int i = 0; i < formatted.Length; i++)
            {
                if (formatted[i] >= '0' && formatted[i] <= '9')
                {
                    seen++;
                    if (seen == digitsBefore)
                        return (formatted, i + 1);
                }
            }
            return (formatted, formatted.Length);
        }
        else
        {
            int nonSpaceBefore = prefix.Count(c => !char.IsWhiteSpace(c));
            if (nonSpaceBefore == 0) return (formatted, 0);
            int seen = 0;
            for (int i = 0; i < formatted.Length; i++)
            {
                if (!char.IsWhiteSpace(formatted[i]))
                {
                    seen++;
                    if (seen == nonSpaceBefore)
                        return (formatted, i + 1);
                }
            }
            return (formatted, formatted.Length);
        }
    }

    public static string SanitizeForUse(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "";
        string trimmed = raw.Trim();
        if (trimmed.All(c => (c >= '0' && c <= '9') || char.IsWhiteSpace(c) || c == '-'))
            return new string(trimmed.Where(c => c >= '0' && c <= '9').ToArray());
        return new string(trimmed.Where(c => !char.IsWhiteSpace(c)).ToArray());
    }

    public static string ExtractNineDigitCode(string? raw)
    {
        if (string.IsNullOrWhiteSpace(raw)) return "";
        string trimmed = raw.Trim();
        if (!trimmed.All(c => char.IsDigit(c) || c == ' ' || c == '-'))
            return "";
        string digits = new string(trimmed.Where(char.IsDigit).ToArray());
        return digits.Length == 9 ? digits : "";
    }
}

public enum DeviceOnlineState
{
    LanOnline,
    WanOnline,
    Offline
}

public static class DeviceOnlineStateExtensions
{
    public static DeviceOnlineState Parse(string? via, bool online) => via switch
    {
        "lan" => DeviceOnlineState.LanOnline,
        "wan" => DeviceOnlineState.WanOnline,
        _ => online ? DeviceOnlineState.WanOnline : DeviceOnlineState.Offline
    };

    public static string GetLabel(this DeviceOnlineState state) => state switch
    {
        DeviceOnlineState.LanOnline => "局域网在线",
        DeviceOnlineState.WanOnline => "远程在线",
        _ => "离线/待机"
    };

    public static bool IsOnline(this DeviceOnlineState state) => state != DeviceOnlineState.Offline;
}

public sealed class ManagedRemoteDevice : ObservableBase
{
    [JsonPropertyName("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString();

    [JsonPropertyName("alias")]
    public string Alias { get; set; } = "";

    [JsonPropertyName("target")]
    public string Target { get; set; } = "";

    [JsonPropertyName("port")]
    public ushort Port { get; set; } = 39481;

    [JsonPropertyName("savedPassword")]
    public string SavedPassword { get; set; } = "";

    [JsonPropertyName("groupTag")]
    public string GroupTag { get; set; } = "常用";

    [JsonPropertyName("isFavorite")]
    public bool IsFavorite { get; set; }

    [JsonPropertyName("remoteDeviceID")]
    public string RemoteDeviceId { get; set; } = "";

    [JsonPropertyName("deviceCode")]
    public string DeviceCode { get; set; } = "";

    [JsonPropertyName("notes")]
    public string Notes { get; set; } = "";

    [JsonPropertyName("lastConnectedMs")]
    public ulong LastConnectedMs { get; set; }

    [JsonIgnore]
    public string FormattedTarget
    {
        get
        {
            string clean = Target.Trim();
            if (!string.IsNullOrEmpty(clean) && clean.All(c => (c >= '0' && c <= '9') || c == ' ' || c == '-'))
            {
                string digits = new string(clean.Where(c => c >= '0' && c <= '9').ToArray());
                if (!string.IsNullOrEmpty(digits))
                    return DeviceCodeFormatter.FormatInput(digits);
            }
            if (clean.StartsWith("openuu://", StringComparison.OrdinalIgnoreCase))
            {
                if (DeviceCode.Length == 9)
                    return $"{DeviceCodeFormatter.FormatInput(DeviceCode)} (直连串)";
                return "跨网直连串 (openuu://…)";
            }
            return Port == 39481 ? clean : $"{clean}:{Port}";
        }
    }
}

public sealed class DeviceBookStore : ObservableBase
{
    public static readonly string[] DefaultGroups = { "常用", "办公", "家里", "服务器" };

    public ObservableCollection<ManagedRemoteDevice> Devices { get; } = new();
    private readonly Dictionary<string, DeviceOnlineState> _presenceById = new();

    private readonly string _filePath;

    public event Action? DevicesChanged;

    public DeviceBookStore(string? customDir = null)
    {
        string dir = !string.IsNullOrWhiteSpace(customDir)
            ? customDir.Trim()
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "OpenUU");
        Directory.CreateDirectory(dir);
        _filePath = Path.Combine(dir, "device_book.json");
        Load();
    }

    public DeviceOnlineState GetPresence(string deviceId)
        => _presenceById.TryGetValue(deviceId, out var st) ? st : DeviceOnlineState.Offline;

    public void Load()
    {
        if (!File.Exists(_filePath)) return;
        try
        {
            string raw = File.ReadAllText(_filePath);
            var list = JsonSerializer.Deserialize<List<ManagedRemoteDevice>>(raw);
            if (list != null)
            {
                ReplaceSorted(list);
            }
        }
        catch
        {
        }
    }

    private void Persist()
    {
        var sorted = SortDevices(Devices.ToList());
        ReplaceSorted(sorted);
        try
        {
            string json = JsonSerializer.Serialize(sorted, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(_filePath, json);
        }
        catch
        {
        }
        DevicesChanged?.Invoke();
    }

    private void ReplaceSorted(List<ManagedRemoteDevice> sorted)
    {
        Devices.Clear();
        foreach (var d in sorted)
            Devices.Add(d);
    }

    private static List<ManagedRemoteDevice> SortDevices(List<ManagedRemoteDevice> list)
    {
        return list
            .OrderByDescending(d => d.IsFavorite)
            .ThenByDescending(d => d.LastConnectedMs)
            .ThenBy(d => d.Alias, StringComparer.CurrentCultureIgnoreCase)
            .ToList();
    }

    public void SyncFromTrustedPeers(IReadOnlyList<TrustedPeerModel> trusted)
    {
        bool changed = false;
        var list = Devices.ToList();

        foreach (var tp in trusted)
        {
            string normCode = new string(tp.DeviceCode.Where(char.IsDigit).ToArray());
            var existing = list.FirstOrDefault(d =>
                (!string.IsNullOrEmpty(tp.DeviceId) && d.RemoteDeviceId == tp.DeviceId) ||
                (normCode.Length == 9 && d.DeviceCode == normCode) ||
                (!string.IsNullOrEmpty(tp.LastTicket) && d.Target == tp.LastTicket));

            if (existing != null)
            {
                if (string.IsNullOrEmpty(existing.RemoteDeviceId) && !string.IsNullOrEmpty(tp.DeviceId))
                {
                    existing.RemoteDeviceId = tp.DeviceId;
                    changed = true;
                }
                if (string.IsNullOrEmpty(existing.DeviceCode) && normCode.Length == 9)
                {
                    existing.DeviceCode = normCode;
                    changed = true;
                }
            }
            else
            {
                string target = normCode.Length == 9 ? normCode : tp.LastTicket;
                if (string.IsNullOrEmpty(target)) continue;

                list.Add(new ManagedRemoteDevice
                {
                    Id = Guid.NewGuid().ToString(),
                    Alias = string.IsNullOrWhiteSpace(tp.DeviceName) ? "远程电脑" : tp.DeviceName,
                    Target = target,
                    Port = 39481,
                    SavedPassword = "",
                    GroupTag = "常用",
                    IsFavorite = false,
                    RemoteDeviceId = tp.DeviceId,
                    DeviceCode = normCode,
                    Notes = "",
                    LastConnectedMs = tp.LastConnectedMs
                });
                changed = true;
            }
        }

        if (changed)
        {
            ReplaceSorted(list);
            Persist();
        }
    }

    public ManagedRemoteDevice AddOrUpdateDevice(
        string? id = null,
        string alias = "",
        string target = "",
        ushort port = 39481,
        string savedPassword = "",
        string groupTag = "常用",
        bool isFavorite = false,
        string notes = ""
    )
    {
        string cleanTarget = DeviceCodeFormatter.SanitizeForUse(target);
        string normDigits = DeviceCodeFormatter.ExtractNineDigitCode(cleanTarget);
        var list = Devices.ToList();

        if (!string.IsNullOrEmpty(id))
        {
            var byId = list.FirstOrDefault(d => d.Id == id);
            if (byId != null)
            {
                if (!string.IsNullOrWhiteSpace(alias))
                    byId.Alias = alias.Trim();
                byId.Target = cleanTarget;
                byId.Port = port;
                byId.SavedPassword = savedPassword;
                byId.GroupTag = string.IsNullOrWhiteSpace(groupTag) ? "常用" : groupTag.Trim();
                byId.IsFavorite = isFavorite;
                byId.Notes = notes;
                if (!string.IsNullOrEmpty(normDigits))
                    byId.DeviceCode = normDigits;
                ReplaceSorted(list);
                Persist();
                return byId;
            }
        }

        var byTarget = list.FirstOrDefault(d =>
            DeviceCodeFormatter.SanitizeForUse(d.Target) == cleanTarget ||
            (!string.IsNullOrEmpty(normDigits) && d.DeviceCode == normDigits));

        if (byTarget != null)
        {
            if (!string.IsNullOrWhiteSpace(alias))
                byTarget.Alias = alias.Trim();
            byTarget.Target = cleanTarget;
            byTarget.Port = port;
            if (!string.IsNullOrEmpty(savedPassword))
                byTarget.SavedPassword = savedPassword;
            if (!string.IsNullOrWhiteSpace(groupTag))
                byTarget.GroupTag = groupTag.Trim();
            byTarget.IsFavorite = isFavorite;
            byTarget.Notes = notes;
            ReplaceSorted(list);
            Persist();
            return byTarget;
        }

        string finalAlias = string.IsNullOrWhiteSpace(alias)
            ? (string.IsNullOrEmpty(normDigits) ? cleanTarget : $"远程设备 ({normDigits[^4..]})")
            : alias.Trim();

        var created = new ManagedRemoteDevice
        {
            Id = Guid.NewGuid().ToString(),
            Alias = finalAlias,
            Target = cleanTarget,
            Port = port,
            SavedPassword = savedPassword,
            GroupTag = string.IsNullOrWhiteSpace(groupTag) ? "常用" : groupTag.Trim(),
            IsFavorite = isFavorite,
            RemoteDeviceId = "",
            DeviceCode = normDigits,
            Notes = notes,
            LastConnectedMs = (ulong)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds()
        };
        list.Add(created);
        ReplaceSorted(list);
        Persist();
        return created;
    }

    public ManagedRemoteDevice RecordConnectedHost(
        string? existingId,
        string remoteName,
        string remoteDeviceId,
        string target,
        ushort port,
        string passwordUsed
    )
    {
        ulong nowMs = (ulong)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        string cleanTarget = DeviceCodeFormatter.SanitizeForUse(target);
        string normCode = DeviceCodeFormatter.ExtractNineDigitCode(cleanTarget);
        var list = Devices.ToList();

        var match = list.FirstOrDefault(d =>
            (!string.IsNullOrEmpty(existingId) && d.Id == existingId) ||
            (!string.IsNullOrEmpty(remoteDeviceId) && d.RemoteDeviceId == remoteDeviceId) ||
            (!string.IsNullOrEmpty(normCode) && d.DeviceCode == normCode) ||
            DeviceCodeFormatter.SanitizeForUse(d.Target) == cleanTarget);

        if (match != null)
        {
            match.Target = cleanTarget;
            if (!string.IsNullOrEmpty(remoteDeviceId))
                match.RemoteDeviceId = remoteDeviceId;
            if (!string.IsNullOrEmpty(normCode))
                match.DeviceCode = normCode;
            if (!string.IsNullOrEmpty(passwordUsed))
                match.SavedPassword = passwordUsed;
            if ((match.Alias == match.Target ||
                 match.Alias.StartsWith("远程设备 (", StringComparison.Ordinal) ||
                 match.Alias.StartsWith("Mac (", StringComparison.Ordinal) ||
                 match.Alias.StartsWith("openuu://", StringComparison.OrdinalIgnoreCase)) &&
                !string.IsNullOrWhiteSpace(remoteName))
            {
                match.Alias = remoteName;
            }
            match.LastConnectedMs = nowMs;
            ReplaceSorted(list);
            Persist();
            return match;
        }

        var created = new ManagedRemoteDevice
        {
            Id = existingId ?? Guid.NewGuid().ToString(),
            Alias = string.IsNullOrWhiteSpace(remoteName) ? cleanTarget : remoteName,
            Target = cleanTarget,
            Port = port,
            SavedPassword = passwordUsed,
            GroupTag = "常用",
            IsFavorite = false,
            RemoteDeviceId = remoteDeviceId,
            DeviceCode = normCode,
            Notes = "",
            LastConnectedMs = nowMs
        };
        list.Add(created);
        ReplaceSorted(list);
        Persist();
        return created;
    }

    public void ToggleFavorite(string id)
    {
        var list = Devices.ToList();
        var item = list.FirstOrDefault(d => d.Id == id);
        if (item == null) return;
        item.IsFavorite = !item.IsFavorite;
        ReplaceSorted(list);
        Persist();
    }

    public void RemoveDevice(string id)
    {
        var list = Devices.Where(d => d.Id != id).ToList();
        _presenceById.Remove(id);
        ReplaceSorted(list);
        Persist();
    }

    public ManagedRemoteDevice? FindMatchingDevice(string? rawTarget)
    {
        string clean = DeviceCodeFormatter.SanitizeForUse(rawTarget);
        if (string.IsNullOrEmpty(clean)) return null;
        string norm = DeviceCodeFormatter.ExtractNineDigitCode(clean);
        return Devices.FirstOrDefault(d =>
            DeviceCodeFormatter.SanitizeForUse(d.Target) == clean ||
            (!string.IsNullOrEmpty(norm) && d.DeviceCode == norm));
    }

    public void ApplyProbeResults(IReadOnlyList<DeviceProbeResultModel> results)
    {
        foreach (var r in results)
        {
            _presenceById[r.Id] = DeviceOnlineStateExtensions.Parse(r.Via, r.Online);
        }
        DevicesChanged?.Invoke();
    }
}
