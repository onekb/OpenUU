using System.IO;
using System.Text;

namespace OpenUU.Shared;

public enum OpenUULogLevel
{
    Debug = 0,
    Info = 1,
    Warn = 2,
    Error = 3
}

public static class OpenUULogLevelExtensions
{
    public static string GetTag(this OpenUULogLevel level) => level switch
    {
        OpenUULogLevel.Debug => "DEBUG",
        OpenUULogLevel.Info  => "INFO ",
        OpenUULogLevel.Warn  => "WARN ",
        OpenUULogLevel.Error => "ERROR",
        _ => "INFO "
    };

    public static string GetLabel(this OpenUULogLevel level) => level switch
    {
        OpenUULogLevel.Debug => "全部 (DEBUG+)",
        OpenUULogLevel.Info  => "常规 (INFO+)",
        OpenUULogLevel.Warn  => "警告 (WARN+)",
        OpenUULogLevel.Error => "仅错误 (ERROR)",
        _ => "全部 (DEBUG+)"
    };
}

public sealed record OpenUULogEntry(
    ulong Id,
    OpenUULogLevel Level,
    string Category,
    string Formatted
);

/// <summary>
/// Thread-safe structured engineering logger with severity levels, an in-memory 2000-entry ring buffer,
/// and rolling 8 MiB file persistence at <c>%LOCALAPPDATA%\OpenUU\Logs\openuu.log</c>.
/// </summary>
public sealed class OpenUULogger
{
    public static OpenUULogger Shared { get; } = new();

    public string LogDirectoryPath { get; }
    public string LogFilePath { get; }

    private readonly object _lock = new();
    private readonly List<OpenUULogEntry> _ringBuffer = new(2048);
    private ulong _nextId = 1;
    private const int MaxMemoryEntries = 2000;
    private const long MaxFileBytes = 8 * 1024 * 1024;

    public Action<OpenUULogEntry>? OnEntryAppended { get; set; }

    private OpenUULogger()
    {
        var customLogDir = Environment.GetEnvironmentVariable("OPENUU_LOG_DIR");
        var baseDir = !string.IsNullOrWhiteSpace(customLogDir)
            ? customLogDir.Trim()
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "OpenUU", "Logs");
        Directory.CreateDirectory(baseDir);
        LogDirectoryPath = baseDir;
        LogFilePath = Path.Combine(baseDir, "openuu.log");
    }

    public void Debug(string category, string message) => Log(OpenUULogLevel.Debug, category, message);
    public void Info(string category, string message) => Log(OpenUULogLevel.Info, category, message);
    public void Warn(string category, string message) => Log(OpenUULogLevel.Warn, category, message);
    public void Error(string category, string message) => Log(OpenUULogLevel.Error, category, message);

    public void Log(OpenUULogLevel level, string category, string message)
    {
        if (string.IsNullOrWhiteSpace(message)) return;
        var trimmed = message.Trim();

        OpenUULogEntry entry;
        Action<OpenUULogEntry>? cb;

        lock (_lock)
        {
            var ts = DateTime.Now.ToString("HH:mm:ss.fff");
            var id = _nextId++;
            var line = $"[{ts}] [{level.GetTag()}] [{category}] {trimmed}";
            entry = new OpenUULogEntry(id, level, category, line);
            _ringBuffer.Add(entry);
            if (_ringBuffer.Count > MaxMemoryEntries)
                _ringBuffer.RemoveRange(0, _ringBuffer.Count - MaxMemoryEntries);
            cb = OnEntryAppended;

            AppendLineToDiskNoThrow(line);
        }

        if (cb != null)
        {
            var app = System.Windows.Application.Current;
            if (app?.Dispatcher != null && !app.Dispatcher.CheckAccess())
            {
                app.Dispatcher.BeginInvoke(() => cb(entry));
            }
            else
            {
                cb(entry);
            }
        }
    }

    public List<OpenUULogEntry> RecentEntries(OpenUULogLevel minLevel = OpenUULogLevel.Debug, int limit = 500)
    {
        lock (_lock)
        {
            var filtered = minLevel == OpenUULogLevel.Debug
                ? _ringBuffer
                : _ringBuffer.Where(e => e.Level >= minLevel).ToList();
            if (filtered.Count <= limit)
                return new List<OpenUULogEntry>(filtered);
            return filtered.Skip(filtered.Count - limit).ToList();
        }
    }

    public void Clear()
    {
        lock (_lock)
        {
            _ringBuffer.Clear();
            try
            {
                File.WriteAllText(LogFilePath, "", Encoding.UTF8);
            }
            catch
            {
            }
        }
    }

    public string BuildDiagnosticReport(
        string appVersion,
        string roleSummary,
        string schemeSummary,
        string capabilitiesSummary,
        string stateSnapshot,
        OpenUULogLevel minLevel = OpenUULogLevel.Debug,
        int limit = 500
    )
    {
        var osDesc = System.Runtime.InteropServices.RuntimeInformation.OSDescription;
        var displays = DescribeActiveMonitors();
        var sb = new StringBuilder();
        sb.AppendLine("=== OpenUU Windows Diagnostic Report ===");
        sb.AppendLine($"Version: {appVersion}");
        sb.AppendLine($"Windows: {osDesc}");
        sb.AppendLine($"Role: {roleSummary}");
        sb.AppendLine($"Scheme: {schemeSummary}");
        sb.AppendLine($"Capabilities: {capabilitiesSummary}");
        sb.AppendLine($"State: {stateSnapshot}");
        sb.AppendLine($"Displays: {displays}");
        sb.AppendLine($"LogFile: {LogFilePath}");
        sb.AppendLine("========================================");
        foreach (var entry in RecentEntries(minLevel, limit))
        {
            sb.AppendLine(entry.Formatted);
        }
        return sb.ToString();
    }

    private static string DescribeActiveMonitors()
    {
        try
        {
            var screens = System.Windows.Forms.Screen.AllScreens;
            if (screens.Length == 0) return "none";
            return string.Join(" | ", screens.Select((s, i) =>
            {
                var tag = s.Primary ? "MAIN" : "EXT";
                var b = s.Bounds;
                return $"#{i}({tag}) {b.X},{b.Y} {b.Width}x{b.Height}";
            }));
        }
        catch
        {
            return "unknown";
        }
    }

    private void AppendLineToDiskNoThrow(string line)
    {
        try
        {
            var fi = new FileInfo(LogFilePath);
            if (fi.Exists && fi.Length >= MaxFileBytes)
            {
                var backup = Path.Combine(LogDirectoryPath, "openuu.prev.log");
                if (File.Exists(backup)) File.Delete(backup);
                File.Move(LogFilePath, backup);
            }
            File.AppendAllText(LogFilePath, line + Environment.NewLine, Encoding.UTF8);
        }
        catch
        {
        }
    }
}
