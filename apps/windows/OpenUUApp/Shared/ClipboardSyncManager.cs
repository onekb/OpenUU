using System.Collections.Specialized;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Windows.Threading;

namespace OpenUU.Shared;

/// <summary>
/// Bidirectional Windows clipboard synchronizer (UTF-8 text + PNG/JPEG images + regular files &lt;= 512 MiB)
/// with <c>GetClipboardSequenceNumber</c> zero-lock polling, SHA-256 echo loop prevention, and password-manager
/// sensitive clipboard filtering (matching macOS <c>ClipboardSyncManager</c>).
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
    private string? _lastSentHash;
    private string? _lastAppliedRemoteHash;

    private static readonly string[] ConcealedFormats =
    {
        "ExcludeClipboardContentFromMonitorProcessing",
        "Clipboard Viewer Ignore",
        "CanIncludeInClipboardHistory"
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
        _lastSentHash = null;
        _lastAppliedRemoteHash = null;
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

    public void ApplyRemoteClipboardFiles(IReadOnlyList<string> filePaths)
    {
        if (!IsEnabled || filePaths.Count == 0) return;
        var existing = filePaths.Where(File.Exists).ToList();
        if (existing.Count == 0) return;

        string hash = ComputeFileListHash(existing);
        _lastAppliedRemoteHash = hash;

        RunOnStaClipboard(() =>
        {
            var sc = new StringCollection();
            foreach (var p in existing) sc.Add(p);
            System.Windows.Forms.Clipboard.SetFileDropList(sc);
            _lastSequenceNumber = Win32Interop.GetClipboardSequenceNumber();
        });

        var names = string.Join(", ", existing.Select(Path.GetFileName));
        OnStatusLog?.Invoke($"已同步对端文件到剪贴板，可直接 Ctrl+V 粘贴: {names}");
    }

    public void ApplyRemoteClipboard(string hash, int clipKind, string? text, string? mimeType, string? imageBase64)
    {
        if (!IsEnabled || string.IsNullOrEmpty(hash)) return;
        if (hash == _lastSentHash || hash == _lastAppliedRemoteHash) return;

        switch (clipKind)
        {
            case 0: // TEXT
            {
                if (string.IsNullOrEmpty(text)) return;
                _lastAppliedRemoteHash = hash;
                RunOnStaClipboard(() =>
                {
                    System.Windows.Forms.Clipboard.SetText(text, System.Windows.Forms.TextDataFormat.UnicodeText);
                    _lastSequenceNumber = Win32Interop.GetClipboardSequenceNumber();
                });
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

                _lastAppliedRemoteHash = hash;
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

            // Priority 1: File drop list copied in Explorer / WeChat
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
                    string hash = ComputeFileListHash(regularFiles);
                    if (hash != _lastAppliedRemoteHash && hash != _lastSentHash)
                    {
                        _lastSentHash = hash;
                        OnSendFiles?.Invoke(regularFiles);
                    }
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
                    string hash = Sha256Hex("image:", imgBytes);
                    if (hash != _lastAppliedRemoteHash && hash != _lastSentHash)
                    {
                        _lastSentHash = hash;
                        OnSendImage?.Invoke(hash, mime, imgBytes);
                    }
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
                        if (hash != _lastAppliedRemoteHash && hash != _lastSentHash)
                        {
                            _lastSentHash = hash;
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

    private static string ComputeFileListHash(IEnumerable<string> paths)
    {
        var summary = string.Join("|", paths
            .Select(p =>
            {
                var fi = new FileInfo(p);
                return $"{fi.Name}:{(fi.Exists ? fi.Length : 0)}";
            })
            .OrderBy(s => s, StringComparer.Ordinal));
        return Sha256Hex("files:", Encoding.UTF8.GetBytes(summary));
    }
}
