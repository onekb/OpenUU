using System.Collections.Specialized;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32.SafeHandles;
using Brushes = System.Windows.Media.Brushes;
using Button = System.Windows.Controls.Button;
using Color = System.Windows.Media.Color;
using DragDropEffects = System.Windows.DragDropEffects;
using FontFamily = System.Windows.Media.FontFamily;
using HorizontalAlignment = System.Windows.HorizontalAlignment;
using Orientation = System.Windows.Controls.Orientation;

namespace OpenUU.Client;

using OpenUU.Shared;

public sealed record DragOutItemDescriptor(string BlobId, string Filename, ulong TotalBytes);

public sealed class PreparedDragItem
{
    public required string BlobId { get; init; }
    public required string OriginalFilename { get; init; }
    public required string PlaceholderFilename { get; init; }
    public required string StagingPath { get; init; }
    public required bool IsPlaceholder { get; init; }
    public required DateTime CreatedAtUtc { get; init; }
    public SafeFileHandle? TrackingHandle { get; set; }
}

/// <summary>
/// Coordinates cross-machine drag-out transfers on Windows (1:1 counterpart to macOS <c>DragOutTransferCoordinator</c>):
/// <list type="bullet">
/// <item><description>Small/fast files: dragged directly as ready-to-use files (<c>DragDropEffects.Copy</c>) with zero placeholder overhead.</description></item>
/// <item><description>Large/streaming files: immediately draggable at the window border via a lightweight <c>.downloading</c> placeholder (<c>DragDropEffects.Move</c>), tracked across same-volume NTFS moves via <c>GetFinalPathNameByHandleW</c> (and cross-volume Explorer drops), accompanied by a non-activating live progress HUD, and atomically swapped to the final filename on completion.</description></item>
/// </list>
/// </summary>
public sealed class DragOutTransferCoordinator
{
    public static DragOutTransferCoordinator Shared { get; } = new();

    public enum TransferPhase
    {
        Transferring,
        Completed,
        Failed,
        Cancelled
    }

    internal sealed class TransferRecord
    {
        public required string BlobId { get; init; }
        public required string Filename { get; init; }
        public ulong ReceivedBytes { get; set; }
        public ulong TotalBytes { get; set; }
        public double SpeedBytesPerSec { get; set; }
        public long LastSampleTickMs { get; set; }
        public ulong LastSampleBytes { get; set; }
        public TransferPhase Phase { get; set; }
        public string? InboxCompletedPath { get; set; }
        public string? PlaceholderPath { get; set; }
        public bool IsClaimedByDragOut { get; set; }
        public bool IsDragSessionActive { get; set; }
        public bool ShowInHud { get; set; }
        public CancellationTokenSource? HudRevealCts { get; set; }
        public CancellationTokenSource? HudDismissCts { get; set; }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandleW(
        SafeFileHandle hFile,
        StringBuilder lpszFilePath,
        uint cchFilePath,
        uint dwFlags
    );

    private readonly Dictionary<string, TransferRecord> _records = new(StringComparer.Ordinal);
    private readonly List<string> _orderedHudIds = new();
    private DragTransferHudWindow? _hudWindow;

    private DragOutTransferCoordinator()
    {
    }

    public DragOutItemDescriptor RegisterTransferStarted(string blobId, string filename, ulong totalBytes)
    {
        string cleanName = SanitizeFileName(filename);
        long now = Environment.TickCount64;
        if (!_records.ContainsKey(blobId))
        {
            _records[blobId] = new TransferRecord
            {
                BlobId = blobId,
                Filename = cleanName,
                ReceivedBytes = 0,
                TotalBytes = totalBytes,
                SpeedBytesPerSec = 0,
                LastSampleTickMs = now,
                LastSampleBytes = 0,
                Phase = TransferPhase.Transferring
            };
        }
        return new DragOutItemDescriptor(blobId, cleanName, totalBytes);
    }

    public void UpdateTransferProgress(string blobId, string filename, ulong receivedBytes, ulong totalBytes)
    {
        if (!_records.ContainsKey(blobId))
            RegisterTransferStarted(blobId, filename, totalBytes);

        if (!_records.TryGetValue(blobId, out var rec) || rec.Phase != TransferPhase.Transferring)
            return;

        long now = Environment.TickCount64;
        double dt = (now - rec.LastSampleTickMs) / 1000.0;
        if (dt >= 0.08 && receivedBytes >= rec.LastSampleBytes)
        {
            double instantSpeed = (receivedBytes - rec.LastSampleBytes) / dt;
            rec.SpeedBytesPerSec = rec.SpeedBytesPerSec > 0
                ? (rec.SpeedBytesPerSec * 0.65 + instantSpeed * 0.35)
                : instantSpeed;
            rec.LastSampleTickMs = now;
            rec.LastSampleBytes = receivedBytes;
        }

        rec.ReceivedBytes = receivedBytes;
        if (totalBytes > 0)
            rec.TotalBytes = totalBytes;

        if (rec.ShowInHud)
            RefreshHud();
    }

    public void MarkTransferFailed(string blobId)
    {
        if (!_records.TryGetValue(blobId, out var rec))
            return;

        rec.HudRevealCts?.Cancel();
        rec.HudRevealCts = null;
        CleanupPlaceholderIfPresent(rec);

        if (rec.Phase == TransferPhase.Cancelled)
        {
            RemoveRecord(blobId);
            return;
        }

        rec.Phase = TransferPhase.Failed;
        if (rec.ShowInHud || rec.IsClaimedByDragOut)
        {
            EnsureShownInHud(blobId);
            ScheduleAutoDismiss(blobId, afterMs: 2600);
        }
        else
        {
            RemoveRecord(blobId);
        }
    }

    public bool MarkTransferCompleted(string blobId, string inboxPath, ulong totalBytes)
    {
        string fallbackName = Path.GetFileName(inboxPath);
        ulong fileSize = totalBytes;
        if (fileSize == 0)
        {
            try
            {
                var fi = new FileInfo(inboxPath);
                if (fi.Exists && fi.Length > 0)
                    fileSize = (ulong)fi.Length;
            }
            catch
            {
            }
        }

        if (!_records.ContainsKey(blobId))
        {
            long now = Environment.TickCount64;
            _records[blobId] = new TransferRecord
            {
                BlobId = blobId,
                Filename = SanitizeFileName(fallbackName),
                ReceivedBytes = fileSize,
                TotalBytes = fileSize,
                LastSampleTickMs = now,
                LastSampleBytes = fileSize,
                Phase = TransferPhase.Completed,
                InboxCompletedPath = inboxPath
            };
        }

        if (!_records.TryGetValue(blobId, out var rec))
            return false;

        rec.HudRevealCts?.Cancel();
        rec.HudRevealCts = null;

        if (rec.Phase == TransferPhase.Cancelled)
        {
            TryDeleteInboxParent(inboxPath);
            RemoveRecord(blobId);
            return true;
        }

        rec.Phase = TransferPhase.Completed;
        rec.ReceivedBytes = Math.Max(rec.TotalBytes, fileSize);
        rec.TotalBytes = Math.Max(rec.TotalBytes, fileSize);
        rec.InboxCompletedPath = inboxPath;

        if (!string.IsNullOrEmpty(rec.PlaceholderPath) && !rec.IsDragSessionActive)
        {
            FinalizePlaceholderWithCompletedFile(blobId, inboxPath);
            return true;
        }

        if (rec.ShowInHud)
        {
            RefreshHud();
            if (!rec.IsDragSessionActive)
                ScheduleAutoDismiss(blobId, afterMs: 1800);
        }

        return rec.IsClaimedByDragOut;
    }

    public (string[] FilePaths, DragDropEffects AllowedEffects, List<PreparedDragItem> Items) PrepareDragSession(
        IReadOnlyList<DragOutItemDescriptor> descriptors
    )
    {
        var paths = new List<string>(descriptors.Count);
        var prepared = new List<PreparedDragItem>(descriptors.Count);
        bool anyPlaceholder = false;

        foreach (var desc in descriptors)
        {
            if (!_records.ContainsKey(desc.BlobId))
                RegisterTransferStarted(desc.BlobId, desc.Filename, desc.TotalBytes);

            if (!_records.TryGetValue(desc.BlobId, out var rec) ||
                rec.Phase is TransferPhase.Cancelled or TransferPhase.Failed)
            {
                continue;
            }

            rec.IsClaimedByDragOut = true;
            rec.IsDragSessionActive = true;

            // Fast Path: already completed before cursor reached window edge!
            if (rec.Phase == TransferPhase.Completed &&
                !string.IsNullOrEmpty(rec.InboxCompletedPath) &&
                File.Exists(rec.InboxCompletedPath))
            {
                paths.Add(rec.InboxCompletedPath);
                prepared.Add(new PreparedDragItem
                {
                    BlobId = desc.BlobId,
                    OriginalFilename = rec.Filename,
                    PlaceholderFilename = rec.Filename,
                    StagingPath = rec.InboxCompletedPath,
                    IsPlaceholder = false,
                    CreatedAtUtc = DateTime.UtcNow
                });
                ScheduleAutoCleanupUnplacedCompleted(desc.BlobId, afterSeconds: 60);
                continue;
            }

            // Streaming Path: materialize a 0-byte `<filename>.downloading` placeholder for 0ms instant OLE drag-out!
            string stageDir = Path.Combine(Path.GetTempPath(), "openuu-dragstage", desc.BlobId);
            Directory.CreateDirectory(stageDir);
            string phName = $"{rec.Filename}.downloading";
            string stagePath = Path.Combine(stageDir, phName);
            DateTime createdUtc = DateTime.UtcNow;

            try
            {
                File.WriteAllBytes(stagePath, Array.Empty<byte>());
            }
            catch
            {
                continue;
            }

            SafeFileHandle? trackHandle = null;
            try
            {
                trackHandle = File.OpenHandle(
                    stagePath,
                    FileMode.Open,
                    FileAccess.Read,
                    FileShare.ReadWrite | FileShare.Delete
                );
            }
            catch
            {
            }

            anyPlaceholder = true;
            paths.Add(stagePath);
            prepared.Add(new PreparedDragItem
            {
                BlobId = desc.BlobId,
                OriginalFilename = rec.Filename,
                PlaceholderFilename = phName,
                StagingPath = stagePath,
                IsPlaceholder = true,
                CreatedAtUtc = createdUtc,
                TrackingHandle = trackHandle
            });

            // Debounce HUD by 180ms so tiny files don't flash a banner, while large transfers show progress right away
            rec.HudRevealCts?.Cancel();
            var cts = new CancellationTokenSource();
            rec.HudRevealCts = cts;
            var ct = cts.Token;
            string bid = desc.BlobId;
            _ = Task.Run(async () =>
            {
                try
                {
                    await Task.Delay(180, ct);
                    System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                    {
                        if (!ct.IsCancellationRequested &&
                            _records.TryGetValue(bid, out var cur) &&
                            cur.Phase == TransferPhase.Transferring)
                        {
                            EnsureShownInHud(bid);
                        }
                    });
                }
                catch
                {
                }
            }, ct);
        }

        var effects = anyPlaceholder ? DragDropEffects.Move : DragDropEffects.Copy;
        return (paths.ToArray(), effects, prepared);
    }

    public void CompleteDragSession(IReadOnlyList<PreparedDragItem> items, DragDropEffects resultEffects)
    {
        foreach (var item in items)
        {
            if (_records.TryGetValue(item.BlobId, out var rec))
                rec.IsDragSessionActive = false;

            if (!item.IsPlaceholder)
            {
                item.TrackingHandle?.Dispose();
                if (_records.TryGetValue(item.BlobId, out var fastRec) && fastRec.ShowInHud)
                {
                    RefreshHud();
                    ScheduleAutoDismiss(item.BlobId, afterMs: 1500);
                }
                continue;
            }

            string? movedPath = TryResolveMovedPathFromHandle(item.TrackingHandle, item.StagingPath);
            item.TrackingHandle?.Dispose();
            item.TrackingHandle = null;

            bool stagingStillPresent = File.Exists(item.StagingPath);
            if (movedPath == null && (!stagingStillPresent || resultEffects != DragDropEffects.None))
            {
                movedPath = TryLocateCrossVolumePlaceholder(item.PlaceholderFilename, item.CreatedAtUtc);
            }

            TryDeleteStagingDir(item.StagingPath);

            if (movedPath == null && resultEffects == DragDropEffects.None && stagingStillPresent)
            {
                // User pressed Esc or released over a non-drop area: abort background stream cleanly
                CancelTransfer(item.BlobId);
                continue;
            }

            if (movedPath == null)
            {
                // Fallback to user's Downloads folder if drop target consumed/deleted placeholder across volumes
                string downloads = Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
                    "Downloads"
                );
                Directory.CreateDirectory(downloads);
                movedPath = Path.Combine(downloads, item.PlaceholderFilename);
                try
                {
                    if (!File.Exists(movedPath))
                        File.WriteAllBytes(movedPath, Array.Empty<byte>());
                }
                catch
                {
                }
            }

            AttachPlaceholder(item.BlobId, movedPath);
        }
    }

    public void AbandonUnclaimedDragOut(string blobId)
    {
        if (!_records.TryGetValue(blobId, out var rec) || rec.IsClaimedByDragOut)
            return;

        if (rec.Phase == TransferPhase.Transferring)
        {
            OpenUUBridge.CancelIncomingBlob(blobId);
        }
        else if (!string.IsNullOrEmpty(rec.InboxCompletedPath))
        {
            TryDeleteInboxParent(rec.InboxCompletedPath);
        }

        RemoveRecord(blobId);
    }

    public void CancelTransfer(string blobId)
    {
        OpenUUBridge.CancelIncomingBlob(blobId);
        if (!_records.TryGetValue(blobId, out var rec))
            return;

        rec.HudRevealCts?.Cancel();
        rec.HudRevealCts = null;
        rec.HudDismissCts?.Cancel();
        rec.HudDismissCts = null;
        rec.Phase = TransferPhase.Cancelled;
        CleanupPlaceholderIfPresent(rec);
        if (!string.IsNullOrEmpty(rec.InboxCompletedPath))
            TryDeleteInboxParent(rec.InboxCompletedPath);

        RemoveRecord(blobId);
    }

    private void AttachPlaceholder(string blobId, string placeholderPath)
    {
        if (!_records.TryGetValue(blobId, out var rec))
        {
            TryDeleteFile(placeholderPath);
            return;
        }

        if (rec.Phase is TransferPhase.Cancelled or TransferPhase.Failed)
        {
            TryDeleteFile(placeholderPath);
            return;
        }

        rec.PlaceholderPath = placeholderPath;
        if (rec.Phase == TransferPhase.Completed && !string.IsNullOrEmpty(rec.InboxCompletedPath))
        {
            FinalizePlaceholderWithCompletedFile(blobId, rec.InboxCompletedPath);
        }
        else
        {
            EnsureShownInHud(blobId);
        }
    }

    private void FinalizePlaceholderWithCompletedFile(string blobId, string inboxPath)
    {
        if (!_records.TryGetValue(blobId, out var rec))
            return;

        string? placeholder = rec.PlaceholderPath;
        rec.PlaceholderPath = null;

        SwapPlaceholderToFinal(placeholder, inboxPath, rec.Filename);
        EnsureShownInHud(blobId);
        ScheduleAutoDismiss(blobId, afterMs: 1800);
    }

    private static void SwapPlaceholderToFinal(string? placeholderPath, string inboxPath, string preferredFilename)
    {
        string targetDir;
        if (!string.IsNullOrEmpty(placeholderPath))
        {
            string? dir = Path.GetDirectoryName(placeholderPath);
            targetDir = !string.IsNullOrEmpty(dir) && Directory.Exists(dir)
                ? dir
                : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
            TryDeleteFile(placeholderPath);
        }
        else
        {
            targetDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        }

        Directory.CreateDirectory(targetDir);
        string finalPath = UniqueDestinationPath(targetDir, preferredFilename);
        try
        {
            if (File.Exists(inboxPath))
                File.Move(inboxPath, finalPath);
        }
        catch
        {
            try
            {
                if (File.Exists(inboxPath))
                {
                    File.Copy(inboxPath, finalPath, overwrite: true);
                    File.Delete(inboxPath);
                }
            }
            catch
            {
            }
        }

        TryDeleteInboxParent(inboxPath);
    }

    private static void CleanupPlaceholderIfPresent(TransferRecord rec)
    {
        if (!string.IsNullOrEmpty(rec.PlaceholderPath))
        {
            TryDeleteFile(rec.PlaceholderPath);
            rec.PlaceholderPath = null;
        }
    }

    private void EnsureShownInHud(string blobId)
    {
        if (!_records.TryGetValue(blobId, out var rec))
            return;

        rec.ShowInHud = true;
        if (!_orderedHudIds.Contains(blobId))
            _orderedHudIds.Add(blobId);
        RefreshHud();
    }

    private void ScheduleAutoDismiss(string blobId, int afterMs)
    {
        if (!_records.TryGetValue(blobId, out var rec))
            return;

        rec.HudDismissCts?.Cancel();
        var cts = new CancellationTokenSource();
        rec.HudDismissCts = cts;
        var ct = cts.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(afterMs, ct);
                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                {
                    if (!ct.IsCancellationRequested)
                        RemoveRecord(blobId);
                });
            }
            catch
            {
            }
        }, ct);
    }

    private void ScheduleAutoCleanupUnplacedCompleted(string blobId, int afterSeconds)
    {
        if (!_records.TryGetValue(blobId, out var rec))
            return;

        rec.HudDismissCts?.Cancel();
        var cts = new CancellationTokenSource();
        rec.HudDismissCts = cts;
        var ct = cts.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(TimeSpan.FromSeconds(afterSeconds), ct);
                System.Windows.Application.Current?.Dispatcher.BeginInvoke(() =>
                {
                    if (!ct.IsCancellationRequested &&
                        _records.TryGetValue(blobId, out var cur) &&
                        string.IsNullOrEmpty(cur.PlaceholderPath))
                    {
                        if (!string.IsNullOrEmpty(cur.InboxCompletedPath))
                            TryDeleteInboxParent(cur.InboxCompletedPath);
                        RemoveRecord(blobId);
                    }
                });
            }
            catch
            {
            }
        }, ct);
    }

    private void RemoveRecord(string blobId)
    {
        if (_records.Remove(blobId, out var rec))
        {
            rec.HudRevealCts?.Cancel();
            rec.HudDismissCts?.Cancel();
        }
        _orderedHudIds.Remove(blobId);
        RefreshHud();
    }

    private void RefreshHud()
    {
        var visible = _orderedHudIds
            .Where(id => _records.TryGetValue(id, out var r) && r.ShowInHud)
            .Select(id => _records[id])
            .ToList();

        if (visible.Count == 0)
        {
            _hudWindow?.Hide();
            return;
        }

        _hudWindow ??= new DragTransferHudWindow(CancelTransfer);
        _hudWindow.UpdateRecords(visible);
    }

    private static string? TryResolveMovedPathFromHandle(SafeFileHandle? handle, string originalStagePath)
    {
        if (handle == null || handle.IsInvalid || handle.IsClosed)
            return null;

        try
        {
            var sb = new StringBuilder(1024);
            uint len = GetFinalPathNameByHandleW(handle, sb, (uint)sb.Capacity, 0);
            if (len == 0 || len >= sb.Capacity)
                return null;

            string path = sb.ToString();
            if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
                path = @"\\" + path[8..];
            else if (path.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
                path = path[4..];

            if (string.Equals(Path.GetFullPath(path), Path.GetFullPath(originalStagePath), StringComparison.OrdinalIgnoreCase))
                return null;
            if (path.Contains("$Recycle.Bin", StringComparison.OrdinalIgnoreCase) ||
                path.Contains("openuu-dragstage", StringComparison.OrdinalIgnoreCase))
            {
                return null;
            }
            return File.Exists(path) ? path : null;
        }
        catch
        {
            return null;
        }
    }

    private static string? TryLocateCrossVolumePlaceholder(string placeholderName, DateTime minCreatedUtc)
    {
        var candidateDirs = new List<string>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        void AddDir(string? d)
        {
            if (!string.IsNullOrWhiteSpace(d) && Directory.Exists(d) && seen.Add(d))
                candidateDirs.Add(d);
        }

        AddDir(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory));
        AddDir(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads"));

        try
        {
            var shellType = Type.GetTypeFromProgID("Shell.Application");
            if (shellType != null)
            {
                dynamic? shell = Activator.CreateInstance(shellType);
                dynamic? windows = shell?.Windows();
                int count = (int)(windows?.Count ?? 0);
                for (int i = 0; i < count; i++)
                {
                    try
                    {
                        dynamic? win = windows?.Item(i);
                        string? folderPath = win?.Document?.Folder?.Self?.Path as string;
                        AddDir(folderPath);
                    }
                    catch
                    {
                    }
                }
            }
        }
        catch
        {
        }

        DateTime threshold = minCreatedUtc.AddSeconds(-2);
        foreach (var dir in candidateDirs)
        {
            try
            {
                string candidate = Path.Combine(dir, placeholderName);
                var fi = new FileInfo(candidate);
                if (fi.Exists && fi.LastWriteTimeUtc >= threshold)
                    return fi.FullName;
            }
            catch
            {
            }
        }
        return null;
    }

    private static string SanitizeFileName(string raw)
    {
        if (string.IsNullOrWhiteSpace(raw))
            return "file.bin";
        string baseName = Path.GetFileName(raw.Trim());
        foreach (char invalid in Path.GetInvalidFileNameChars())
            baseName = baseName.Replace(invalid, '_');
        return string.IsNullOrWhiteSpace(baseName) ? "file.bin" : baseName;
    }

    private static string UniqueDestinationPath(string directory, string preferredName)
    {
        string candidate = Path.Combine(directory, preferredName);
        if (!File.Exists(candidate))
            return candidate;

        string stem = Path.GetFileNameWithoutExtension(preferredName);
        string ext = Path.GetExtension(preferredName);
        for (int idx = 2; idx <= 999; idx++)
        {
            string next = Path.Combine(directory, $"{stem} ({idx}){ext}");
            if (!File.Exists(next))
                return next;
        }
        return Path.Combine(directory, $"{Guid.NewGuid():N}-{preferredName}");
    }

    private static void TryDeleteFile(string path)
    {
        try
        {
            if (File.Exists(path))
                File.Delete(path);
        }
        catch
        {
        }
    }

    private static void TryDeleteStagingDir(string stageFilePath)
    {
        try
        {
            string? dir = Path.GetDirectoryName(stageFilePath);
            if (!string.IsNullOrEmpty(dir) &&
                dir.Contains("openuu-dragstage", StringComparison.OrdinalIgnoreCase) &&
                Directory.Exists(dir))
            {
                Directory.Delete(dir, recursive: true);
            }
        }
        catch
        {
        }
    }

    private static void TryDeleteInboxParent(string inboxFilePath)
    {
        try
        {
            string? dir = Path.GetDirectoryName(inboxFilePath);
            if (!string.IsNullOrEmpty(dir) &&
                dir.Contains("openuu-inbox", StringComparison.OrdinalIgnoreCase) &&
                Directory.Exists(dir))
            {
                Directory.Delete(dir, recursive: true);
            }
        }
        catch
        {
        }
    }

    internal static string FormatBytes(ulong bytes)
    {
        double kb = bytes / 1024.0;
        if (kb < 1024.0)
            return $"{Math.Max(1.0, kb):F0} KB";
        double mb = kb / 1024.0;
        if (mb < 1024.0)
            return $"{mb:F1} MB";
        return $"{mb / 1024.0:F2} GB";
    }
}

/// <summary>
/// Non-activating top-right floating dark-glass transfer progress HUD window.
/// </summary>
internal sealed class DragTransferHudWindow : Window
{
    private readonly Action<string> _onCancel;
    private readonly StackPanel _rowsPanel;

    public DragTransferHudWindow(Action<string> onCancel)
    {
        _onCancel = onCancel;
        Width = 352;
        SizeToContent = SizeToContent.Height;
        WindowStyle = WindowStyle.None;
        AllowsTransparency = true;
        Background = Brushes.Transparent;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        ShowActivated = false;
        Topmost = true;
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;

        _rowsPanel = new StackPanel
        {
            Orientation = Orientation.Vertical
        };

        var card = new Border
        {
            CornerRadius = new CornerRadius(13),
            Background = new SolidColorBrush(Color.FromArgb(236, 20, 22, 29)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(56, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            Padding = new Thickness(10, 8, 10, 8),
            Margin = new Thickness(6),
            Child = _rowsPanel
        };

        Content = card;
        SourceInitialized += OnHudSourceInitialized;
    }

    private void OnHudSourceInitialized(object? sender, EventArgs e)
    {
        IntPtr hwnd = new WindowInteropHelper(this).Handle;
        if (hwnd == IntPtr.Zero) return;
        uint ex = Win32Interop.GetWindowLong(hwnd, Win32Interop.GWL_EXSTYLE);
        ex |= Win32Interop.WS_EX_TOOLWINDOW | Win32Interop.WS_EX_NOACTIVATE;
        Win32Interop.SetWindowLong(hwnd, Win32Interop.GWL_EXSTYLE, ex);
    }

    public void UpdateRecords(IReadOnlyList<DragOutTransferCoordinator.TransferRecord> records)
    {
        var shown = records.TakeLast(3).ToList();
        _rowsPanel.Children.Clear();

        for (int i = 0; i < shown.Count; i++)
        {
            var rec = shown[i];
            _rowsPanel.Children.Add(BuildRow(rec, isLast: i == shown.Count - 1));
        }

        UpdateLayout();
        var work = SystemParameters.WorkArea;
        Left = work.Right - Width - 14;
        Top = work.Top + 14;

        if (!IsVisible)
            Show();
    }

    private UIElement BuildRow(DragOutTransferCoordinator.TransferRecord rec, bool isLast)
    {
        var grid = new Grid
        {
            Margin = new Thickness(0, 3, 0, isLast ? 3 : 8)
        };
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(36) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        string ext = Path.GetExtension(rec.Filename).TrimStart('.').ToUpperInvariant();
        if (string.IsNullOrEmpty(ext)) ext = "FILE";
        if (ext.Length > 4) ext = ext[..4];

        var iconBadge = new Border
        {
            Width = 30,
            Height = 30,
            CornerRadius = new CornerRadius(7),
            Background = new SolidColorBrush(Color.FromArgb(46, 59, 130, 246)),
            BorderBrush = new SolidColorBrush(Color.FromArgb(90, 96, 165, 250)),
            BorderThickness = new Thickness(1),
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = new TextBlock
            {
                Text = ext,
                FontSize = 8.5,
                FontWeight = FontWeights.Bold,
                Foreground = new SolidColorBrush(Color.FromRgb(147, 197, 253)),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center
            }
        };
        Grid.SetColumn(iconBadge, 0);
        grid.Children.Add(iconBadge);

        double fraction = rec.TotalBytes > 0
            ? Math.Clamp((double)rec.ReceivedBytes / rec.TotalBytes, 0.0, 1.0)
            : (rec.Phase == DragOutTransferCoordinator.TransferPhase.Completed ? 1.0 : 0.15);
        if (rec.Phase == DragOutTransferCoordinator.TransferPhase.Completed)
            fraction = 1.0;

        Color barColor;
        string detailText;
        bool showCancel = false;

        switch (rec.Phase)
        {
            case DragOutTransferCoordinator.TransferPhase.Transferring:
            {
                barColor = Color.FromRgb(59, 130, 246);
                showCancel = true;
                int pct = (int)Math.Round(fraction * 100.0);
                string curStr = DragOutTransferCoordinator.FormatBytes(rec.ReceivedBytes);
                string totStr = DragOutTransferCoordinator.FormatBytes(rec.TotalBytes);
                string spdStr = rec.SpeedBytesPerSec > 1024
                    ? $" · {DragOutTransferCoordinator.FormatBytes((ulong)rec.SpeedBytesPerSec)}/s"
                    : "";
                string prefix = !string.IsNullOrEmpty(rec.PlaceholderPath) ? "占位接收中" : "正在传出";
                detailText = $"{prefix} {pct}% ({curStr}/{totStr}){spdStr}";
                break;
            }
            case DragOutTransferCoordinator.TransferPhase.Completed:
            {
                barColor = Color.FromRgb(34, 197, 94);
                detailText = $"✓ 传输完成，已就绪 ({DragOutTransferCoordinator.FormatBytes(rec.TotalBytes)})";
                break;
            }
            case DragOutTransferCoordinator.TransferPhase.Failed:
            {
                barColor = Color.FromRgb(239, 68, 68);
                detailText = "✕ 文件传输中断，已清理临时占位文件";
                break;
            }
            default:
            {
                barColor = Color.FromRgb(148, 163, 184);
                detailText = "已取消传输";
                break;
            }
        }

        var centerStack = new StackPanel
        {
            Orientation = Orientation.Vertical,
            Margin = new Thickness(4, 0, showCancel ? 8 : 2, 0),
            VerticalAlignment = VerticalAlignment.Center
        };

        centerStack.Children.Add(new TextBlock
        {
            Text = rec.Filename,
            Foreground = Brushes.White,
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            TextTrimming = TextTrimming.CharacterEllipsis
        });

        const double trackWidth = 246.0;
        var trackGrid = new Grid
        {
            Height = 5,
            Margin = new Thickness(0, 5, 0, 4),
            HorizontalAlignment = HorizontalAlignment.Stretch
        };
        trackGrid.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(2.5),
            Background = new SolidColorBrush(Color.FromArgb(46, 255, 255, 255))
        });
        trackGrid.Children.Add(new Border
        {
            CornerRadius = new CornerRadius(2.5),
            Background = new SolidColorBrush(barColor),
            HorizontalAlignment = HorizontalAlignment.Left,
            Width = Math.Max(4.0, trackWidth * fraction)
        });
        centerStack.Children.Add(trackGrid);

        centerStack.Children.Add(new TextBlock
        {
            Text = detailText,
            Foreground = new SolidColorBrush(Color.FromArgb(204, 241, 245, 249)),
            FontFamily = new FontFamily("Consolas, Microsoft YaHei UI"),
            FontSize = 10.5,
            TextTrimming = TextTrimming.CharacterEllipsis
        });

        Grid.SetColumn(centerStack, 1);
        grid.Children.Add(centerStack);

        if (showCancel)
        {
            string bid = rec.BlobId;
            var cancelBtn = new Button
            {
                Content = "✕",
                Width = 22,
                Height = 22,
                FontSize = 10.5,
                Foreground = new SolidColorBrush(Color.FromArgb(190, 255, 255, 255)),
                Background = new SolidColorBrush(Color.FromArgb(28, 255, 255, 255)),
                BorderThickness = new Thickness(0),
                Cursor = System.Windows.Input.Cursors.Hand,
                ToolTip = "取消传输",
                VerticalAlignment = VerticalAlignment.Center
            };
            cancelBtn.Click += (_, _) => _onCancel(bid);
            Grid.SetColumn(cancelBtn, 2);
            grid.Children.Add(cancelBtn);
        }

        return grid;
    }
}
