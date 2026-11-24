using System.Collections.Specialized;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Threading;

namespace OpenUU.Shared;

/// <summary>
/// Bidirectional Windows clipboard synchronizer (UTF-8 text + PNG/JPEG images + regular files &lt;= 512 MiB)
/// with <c>GetClipboardSequenceNumber</c> zero-lock polling, bounded ring-buffer SHA-256 + canonical pixel
/// fingerprint deduplication (defeating third-party clipboard history rewrites and cross-OS re-encoding loops),
/// and password-manager sensitive clipboard filtering.
/// </summary>
public sealed class ClipboardSyncManager
{
    public bool IsEnabled { get; set; } = true;
    public Action<string, string>? OnSendText { get; set; }
    public Action<string, string, byte[]>? OnSendImage { get; set; }
    public Action<IReadOnlyList<string>>? OnSendFiles { get; set; }
    public Action<string>? OnStatusLog { get; set; }

    private DispatcherTimer? _pollTimer;
    private bool _isRunning;
    private uint _lastSequenceNumber;
    private readonly Queue<string> _recentHashes = new();
    private readonly HashSet<string> _recentHashSet = new(StringComparer.Ordinal);
    private DateTime _postApplyCooldownUntilUtc = DateTime.MinValue;
    private bool _lastAppliedWasImage;

    private const int MaxRecentHashes = 64;
    private static readonly HashSet<string> ImageExtensions = new(StringComparer.OrdinalIgnoreCase)
    {
        ".png", ".jpg", ".jpeg", ".tiff", ".tif", ".webp", ".bmp", ".gif"
    };

    private const int MaxTextBytes = 2 * 1024 * 1024;
    private const int MaxImageBytes = 12 * 1024 * 1024;
    private const int PngToJpegThreshold = 5 * 1024 * 1024;
    private const long MaxFileBytes = 512L * 1024 * 1024;

    public void Start()
    {
        if (_isRunning) return;
        _isRunning = true;
        _lastSequenceNumber = Win32Interop.GetClipboardSequenceNumber();
        _pollTimer?.Stop();
        _pollTimer = new DispatcherTimer(DispatcherPriority.Background)
        {
            Interval = TimeSpan.FromMilliseconds(300)
        };
        _pollTimer.Tick += (_, _) => CheckLocalClipboardIfChanged();
        _pollTimer.Start();
    }

    public void Stop()
    {
        _isRunning = false;
        _pollTimer?.Stop();
        _pollTimer = null;
        _recentHashes.Clear();
        _recentHashSet.Clear();
        _postApplyCooldownUntilUtc = DateTime.MinValue;
        _lastAppliedWasImage = false;
    }

    public void SyncNowIfChanged()
    {
        if (!_isRunning || !IsEnabled) return;
        CheckLocalClipboardIfChanged();
    }

    public void IgnoreCurrentClipboardChange()
    {
        _lastSequenceNumber = Win32Interop.GetClipboardSequenceNumber();
    }

    public void ApplyRemoteClipboardFiles(IReadOnlyList<string> filePaths, bool forceWriteForDropPaste = false)
    {
        if ((!IsEnabled && !forceWriteForDropPaste) || filePaths.Count == 0) return;
        var existing = filePaths.Where(File.Exists).ToList();
        if (existing.Count == 0) return;

        var hashes = new List<string> { ComputeFileListContentHash(existing) };
        bool singleImage = existing.Count == 1 && IsImageFile(existing[0]);
        if (singleImage)
        {
            if (ComputeCanonicalImagePixelHashFromFile(existing[0]) is { } pxHash)
                hashes.Add(pxHash);
            try
            {
                var fi = new FileInfo(existing[0]);
                if (fi.Length > 0 && fi.Length <= MaxImageBytes)
                {
                    byte[] raw = File.ReadAllBytes(existing[0]);
                    hashes.Add(Sha256Hex("image:", raw));
                }
            }
            catch
            {
            }
        }

        if (!forceWriteForDropPaste && HasSeenAny(hashes))
        {
            CleanupTempInboxFilesIfNeeded(existing);
            return;
        }
        RecordSeen(hashes);

        RunOnStaClipboard(() =>
        {
            var sc = new StringCollection();
            foreach (var p in existing) sc.Add(p);
            System.Windows.Forms.Clipboard.SetFileDropList(sc);
            _lastSequenceNumber = Win32Interop.GetClipboardSequenceNumber();
        });
        _postApplyCooldownUntilUtc = DateTime.UtcNow.AddSeconds(1.0);
        _lastAppliedWasImage = singleImage;

        if (!forceWriteForDropPaste)
        {
            var names = string.Join(", ", existing.Select(Path.GetFileName));
            OnStatusLog?.Invoke($"已同步对端文件到剪贴板，可直接 Ctrl+V 粘贴: {names}");
        }
    }

    public void ApplyRemoteClipboard(string hash, int clipKind, string? text, string? mimeType, string? imageBase64)
    {
        if (!IsEnabled || string.IsNullOrEmpty(hash)) return;
        if (HasSeenAny(new[] { hash })) return;

        switch (clipKind)
        {
            case 0: // TEXT
            {
                if (string.IsNullOrEmpty(text)) return;
                string localTextHash = Sha256Hex("text:", Encoding.UTF8.GetBytes(text));
                var textHashes = new[] { hash, localTextHash };
                if (HasSeenAny(textHashes)) return;
                RecordSeen(textHashes);

                RunOnStaClipboard(() =>
                {
                    System.Windows.Forms.Clipboard.SetText(text, System.Windows.Forms.TextDataFormat.UnicodeText);
                    _lastSequenceNumber = Win32Interop.GetClipboardSequenceNumber();
                });
                _postApplyCooldownUntilUtc = DateTime.UtcNow.AddMilliseconds(800);
                _lastAppliedWasImage = false;
                OnStatusLog?.Invoke($"已同步对端文本剪贴板 ({text.Length} 字)");
                break;
            }
            case 1: // IMAGE
            {
                if (string.IsNullOrEmpty(imageBase64)) return;
                byte[] bytes;
                try { bytes = Convert.FromBase64String(imageBase64); }
                catch { return; }
                if (bytes.Length == 0) return;

                var hashes = new List<string> { hash, Sha256Hex("image:", bytes) };
                if (ComputeCanonicalImagePixelHashFromBytes(bytes) is { } pxHash)
                    hashes.Add(pxHash);
                if (HasSeenAny(hashes)) return;
                RecordSeen(hashes);

                RunOnStaClipboard(() =>
                {
                    using var ms = new MemoryStream(bytes);
                    using var bmp = new Bitmap(ms);
                    var dataObj = new System.Windows.Forms.DataObject();
                    dataObj.SetImage(new Bitmap(bmp));
                    if ((mimeType ?? "image/png").Contains("png", StringComparison.OrdinalIgnoreCase))
                    {
                        dataObj.SetData("PNG", new MemoryStream(bytes));
                    }
                    System.Windows.Forms.Clipboard.SetDataObject(dataObj, true);
                    _lastSequenceNumber = Win32Interop.GetClipboardSequenceNumber();
                });
                _postApplyCooldownUntilUtc = DateTime.UtcNow.AddSeconds(1.0);
                _lastAppliedWasImage = true;
                int kb = Math.Max(1, bytes.Length / 1024);
                OnStatusLog?.Invoke($"已同步对端图片剪贴板 ({kb} KB)");
                break;
            }
        }
    }

    private void CheckLocalClipboardIfChanged()
    {
        if (!_isRunning || !IsEnabled) return;
        uint curSeq = Win32Interop.GetClipboardSequenceNumber();
        if (curSeq == _lastSequenceNumber) return;
        _lastSequenceNumber = curSeq;

        bool inPostApplyWindow = DateTime.UtcNow < _postApplyCooldownUntilUtc;

        try
        {
            var dataObj = System.Windows.Forms.Clipboard.GetDataObject();
            if (dataObj == null) return;

            // Respect Windows password manager concealed clipboard markers (1Password, Bitwarden, KeePass, Windows Cloud Clipboard)
            if (dataObj.GetDataPresent("ExcludeClipboardContentFromMonitorProcessing") ||
                dataObj.GetDataPresent("Clipboard Viewer Ignore"))
            {
                return;
            }

            // Priority 1: File drop list copied in Explorer / WeChat / clipboard manager
            if (System.Windows.Forms.Clipboard.ContainsFileDropList())
            {
                var dropList = System.Windows.Forms.Clipboard.GetFileDropList();
                var regularFiles = new List<string>();
                foreach (string? item in dropList)
                {
                    if (string.IsNullOrWhiteSpace(item)) continue;
                    var fi = new FileInfo(item);
                    if (fi.Exists && fi.Length > 0 && fi.Length <= MaxFileBytes)
                        regularFiles.Add(fi.FullName);
                }
                if (regularFiles.Count > 0)
                {
                    var candidateHashes = new List<string> { ComputeFileListContentHash(regularFiles) };
                    bool singleImage = regularFiles.Count == 1 && IsImageFile(regularFiles[0]);
                    if (singleImage)
                    {
                        if (ComputeCanonicalImagePixelHashFromFile(regularFiles[0]) is { } pxHash)
                            candidateHashes.Add(pxHash);
                        var fi = new FileInfo(regularFiles[0]);
                        if (fi.Length <= MaxImageBytes)
                        {
                            byte[] raw = File.ReadAllBytes(regularFiles[0]);
                            candidateHashes.Add(Sha256Hex("image:", raw));
                        }
                    }

                    if (HasSeenAny(candidateHashes))
                    {
                        RecordSeen(candidateHashes);
                        return;
                    }
                    if (inPostApplyWindow && _lastAppliedWasImage && singleImage)
                    {
                        RecordSeen(candidateHashes);
                        return;
                    }
                    RecordSeen(candidateHashes);
                    OnSendFiles?.Invoke(regularFiles);
                }
                return;
            }

            // Priority 2: Image on clipboard (Win+Shift+S Snipping Tool, browser Copy Image, WeChat Copy Image)
            var imgPayload = ExtractImageFromClipboard(dataObj);
            if (imgPayload != null)
            {
                var (mime, imgBytes) = imgPayload.Value;
                if (imgBytes.Length > 0 && imgBytes.Length <= MaxImageBytes)
                {
                    string dataHash = Sha256Hex("image:", imgBytes);
                    var hashes = new List<string> { dataHash };
                    if (ComputeCanonicalImagePixelHashFromBytes(imgBytes) is { } pxHash)
                        hashes.Add(pxHash);
                    if (HasSeenAny(hashes) || (inPostApplyWindow && _lastAppliedWasImage))
                    {
                        RecordSeen(hashes);
                        return;
                    }
                    RecordSeen(hashes);
                    OnSendImage?.Invoke(dataHash, mime, imgBytes);
                }
                return;
            }

            // Priority 3: UTF-8 text
            if (System.Windows.Forms.Clipboard.ContainsText())
            {
                string text = System.Windows.Forms.Clipboard.GetText();
                if (!string.IsNullOrEmpty(text))
                {
                    byte[] utf8 = Encoding.UTF8.GetBytes(text);
                    if (utf8.Length <= MaxTextBytes)
                    {
                        string hash = Sha256Hex("text:", utf8);
                        if (!HasSeenAny(new[] { hash }))
                        {
                            RecordSeen(new[] { hash });
                            OnSendText?.Invoke(hash, text);
                        }
                    }
                }
            }
        }
        catch
        {
            // Clipboard may be momentarily locked by another process; next tick or pre-paste will catch up
        }
    }

    private bool HasSeenAny(IEnumerable<string> hashes)
    {
        foreach (var h in hashes)
        {
            if (!string.IsNullOrEmpty(h) && _recentHashSet.Contains(h))
                return true;
        }
        return false;
    }

    private void RecordSeen(IEnumerable<string> hashes)
    {
        foreach (var h in hashes)
        {
            if (string.IsNullOrEmpty(h)) continue;
            if (_recentHashSet.Add(h))
            {
                _recentHashes.Enqueue(h);
                if (_recentHashes.Count > MaxRecentHashes)
                {
                    string evicted = _recentHashes.Dequeue();
                    _recentHashSet.Remove(evicted);
                }
            }
        }
    }

    private static bool IsImageFile(string path)
        => ImageExtensions.Contains(Path.GetExtension(path));

    private static void CleanupTempInboxFilesIfNeeded(IEnumerable<string> paths)
    {
        foreach (var p in paths)
        {
            if (p.Contains("openuu-inbox", StringComparison.OrdinalIgnoreCase))
            {
                try
                {
                    string? dir = Path.GetDirectoryName(p);
                    if (!string.IsNullOrEmpty(dir) && Directory.Exists(dir))
                        Directory.Delete(dir, true);
                }
                catch
                {
                }
            }
        }
    }

    private static string? ComputeCanonicalImagePixelHashFromFile(string path)
    {
        try
        {
            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            using var img = Image.FromStream(fs, useEmbeddedColorManagement: false, validateImageData: false);
            return ComputeCanonicalImagePixelHash(img);
        }
        catch
        {
            return null;
        }
    }

    private static string? ComputeCanonicalImagePixelHashFromBytes(byte[] bytes)
    {
        try
        {
            using var ms = new MemoryStream(bytes);
            using var img = Image.FromStream(ms, useEmbeddedColorManagement: false, validateImageData: false);
            return ComputeCanonicalImagePixelHash(img);
        }
        catch
        {
            return null;
        }
    }

    private static string? ComputeCanonicalImagePixelHash(Image img)
    {
        int origW = img.Width;
        int origH = img.Height;
        if (origW <= 0 || origH <= 0) return null;

        const int side = 64;
        using var resized = new Bitmap(side, side, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(resized))
        {
            g.InterpolationMode = InterpolationMode.Bilinear;
            g.PixelOffsetMode = PixelOffsetMode.Half;
            g.DrawImage(img, new Rectangle(0, 0, side, side));
        }

        var rect = new Rectangle(0, 0, side, side);
        var bmpData = resized.LockBits(rect, ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        byte[] bgra = new byte[side * side * 4];
        try
        {
            Marshal.Copy(bmpData.Scan0, bgra, 0, bgra.Length);
        }
        finally
        {
            resized.UnlockBits(bmpData);
        }

        // Convert BGRA -> premultiplied RGBA masked with 0xF8 (matching macOS `computeCanonicalImagePixelHash`).
        byte[] rgba = new byte[bgra.Length];
        for (int i = 0; i < bgra.Length; i += 4)
        {
            byte b = bgra[i];
            byte g = bgra[i + 1];
            byte r = bgra[i + 2];
            byte a = bgra[i + 3];
            byte pr = (byte)((r * a + 127) / 255);
            byte pg = (byte)((g * a + 127) / 255);
            byte pb = (byte)((b * a + 127) / 255);
            rgba[i] = (byte)(pr & 0xF8);
            rgba[i + 1] = (byte)(pg & 0xF8);
            rgba[i + 2] = (byte)(pb & 0xF8);
            rgba[i + 3] = (byte)(a & 0xF8);
        }

        return Sha256Hex($"img-px:{origW}x{origH}:", rgba);
    }

    private static (string MimeType, byte[] Data)? ExtractImageFromClipboard(System.Windows.Forms.IDataObject dataObj)
    {
        if (dataObj.GetDataPresent("PNG") && dataObj.GetData("PNG") is MemoryStream pngStream)
        {
            byte[] pngBytes = pngStream.ToArray();
            if (pngBytes.Length > 0)
                return CompressPngIfNeeded(pngBytes);
        }

        if (System.Windows.Forms.Clipboard.ContainsImage())
        {
            using var img = System.Windows.Forms.Clipboard.GetImage();
            if (img != null)
            {
                using var ms = new MemoryStream();
                img.Save(ms, ImageFormat.Png);
                return CompressPngIfNeeded(ms.ToArray(), img);
            }
        }
        return null;
    }

    private static (string MimeType, byte[] Data)? CompressPngIfNeeded(byte[] pngBytes, Image? existingImg = null)
    {
        if (pngBytes.Length <= PngToJpegThreshold)
            return ("image/png", pngBytes);

        try
        {
            Image? owned = null;
            var src = existingImg;
            if (src == null)
            {
                owned = Image.FromStream(new MemoryStream(pngBytes));
                src = owned;
            }
            try
            {
                var jpegCodec = ImageCodecInfo.GetImageEncoders().FirstOrDefault(c => c.FormatID == ImageFormat.Jpeg.Guid);
                if (jpegCodec != null)
                {
                    using var encParams = new EncoderParameters(1);
                    encParams.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 88L);
                    using var jpgStream = new MemoryStream();
                    src.Save(jpgStream, jpegCodec, encParams);
                    byte[] jpgBytes = jpgStream.ToArray();
                    if (jpgBytes.Length <= MaxImageBytes)
                        return ("image/jpeg", jpgBytes);
                }
            }
            finally
            {
                owned?.Dispose();
            }
        }
        catch
        {
        }

        return pngBytes.Length <= MaxImageBytes ? ("image/png", pngBytes) : null;
    }

    private static void RunOnStaClipboard(Action action)
    {
        var app = System.Windows.Application.Current;
        if (app?.Dispatcher != null && !app.Dispatcher.CheckAccess())
        {
            app.Dispatcher.Invoke(action);
            return;
        }
        try
        {
            action();
        }
        catch
        {
        }
    }

    private static string Sha256Hex(string prefix, ReadOnlySpan<byte> payload)
    {
        byte[] prefixBytes = Encoding.UTF8.GetBytes(prefix);
        using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        sha.AppendData(prefixBytes);
        sha.AppendData(payload);
        return Convert.ToHexString(sha.GetHashAndReset()).ToLowerInvariant();
    }

    private static string ComputeFileListContentHash(IEnumerable<string> paths)
    {
        var summary = string.Join("|", paths
            .Select(ComputeSingleFileContentHash)
            .OrderBy(s => s, StringComparer.Ordinal));
        return Sha256Hex("files-content:", Encoding.UTF8.GetBytes(summary));
    }

    private static string ComputeSingleFileContentHash(string path)
    {
        try
        {
            var fi = new FileInfo(path);
            if (!fi.Exists || fi.Length <= 0)
                return $"{fi.Name}:0";

            const int sampleChunk = 1024 * 1024; // 1 MiB
            using var sha = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            sha.AppendData(Encoding.UTF8.GetBytes($"sz={fi.Length}:"));

            using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
            byte[] buf = new byte[Math.Min(sampleChunk, (int)Math.Min(fi.Length, sampleChunk))];
            int headRead = fs.Read(buf, 0, buf.Length);
            if (headRead > 0)
                sha.AppendData(buf.AsSpan(0, headRead));

            if (fi.Length > sampleChunk)
            {
                long tailOffset = fi.Length > sampleChunk * 2L ? (fi.Length - sampleChunk) : sampleChunk;
                fs.Seek(tailOffset, SeekOrigin.Begin);
                int tailRead = fs.Read(buf, 0, buf.Length);
                if (tailRead > 0)
                    sha.AppendData(buf.AsSpan(0, tailRead));
            }
            return Convert.ToHexString(sha.GetHashAndReset()).ToLowerInvariant();
        }
        catch
        {
            return Path.GetFileName(path);
        }
    }
}
