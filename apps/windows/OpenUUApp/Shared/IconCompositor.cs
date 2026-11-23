using System.Collections.Concurrent;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace OpenUU.Shared;

public static class IconCompositor
{
    private static readonly ConcurrentDictionary<string, string> ExeHighResIconCache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<string, byte[]?> ExeThumb16Cache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly ConcurrentDictionary<string, string> CustomFileIconCache = new(StringComparer.OrdinalIgnoreCase);
    private static readonly Lazy<Bitmap?> RawBrandBitmap = new(LoadBrandBitmap);
    private static readonly Lazy<ImageSource?> CachedBrandImageSource = new(() =>
        RawBrandBitmap.Value != null ? BitmapToFrozenImageSource(RawBrandBitmap.Value) : null);

    public static ImageSource? BrandSquircleIcon => CachedBrandImageSource.Value;

    private static Bitmap? LoadBrandBitmap()
    {
        try
        {
            var uri = new Uri("pack://application:,,,/Resources/AppIcon.png", UriKind.Absolute);
            var streamInfo = System.Windows.Application.GetResourceStream(uri);
            if (streamInfo?.Stream != null)
            {
                using var s = streamInfo.Stream;
                return new Bitmap(s);
            }
        }
        catch
        {
        }

        string baseDir = AppContext.BaseDirectory;
        string[] candidates =
        {
            Path.Combine(baseDir, "Resources", "AppIcon.png"),
            Path.Combine(baseDir, "AppIcon.png"),
            Path.GetFullPath(Path.Combine(baseDir, "..", "..", "..", "Resources", "AppIcon.png")),
        };
        foreach (var path in candidates)
        {
            if (File.Exists(path))
            {
                try { return new Bitmap(path); }
                catch { }
            }
        }
        return null;
    }

    public static BitmapSource BitmapToFrozenImageSource(Bitmap bitmap)
    {
        using var ms = new MemoryStream();
        bitmap.Save(ms, ImageFormat.Png);
        ms.Position = 0;
        var bi = new BitmapImage();
        bi.BeginInit();
        bi.CacheOption = BitmapCacheOption.OnLoad;
        bi.StreamSource = ms;
        bi.EndInit();
        bi.Freeze();
        return bi;
    }

    public static Bitmap? DecodeBase64ToBitmap(string? base64Png)
    {
        if (string.IsNullOrWhiteSpace(base64Png)) return null;
        try
        {
            byte[] bytes = Convert.FromBase64String(base64Png);
            using var ms = new MemoryStream(bytes);
            using var tmp = new Bitmap(ms);
            return new Bitmap(tmp);
        }
        catch
        {
            return null;
        }
    }

    public static string EncodeBitmapToBase64Png(Bitmap? bitmap, int targetSize = 128)
    {
        if (bitmap == null) return "";
        try
        {
            using var resized = new Bitmap(targetSize, targetSize, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
            using (var g = Graphics.FromImage(resized))
            {
                g.Clear(System.Drawing.Color.Transparent);
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.SmoothingMode = SmoothingMode.AntiAlias;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.DrawImage(bitmap, new Rectangle(0, 0, targetSize, targetSize));
            }
            using var ms = new MemoryStream();
            resized.Save(ms, ImageFormat.Png);
            return Convert.ToBase64String(ms.ToArray());
        }
        catch
        {
            return "";
        }
    }

    public static string ExtractWindowOrExeIconBase64(
        IntPtr hwnd,
        string? exePath,
        string? explicitIconPath = null,
        string? discoveredProjectIconPath = null,
        bool isGenericRuntime = false,
        string? fallbackAppName = null
    )
    {
        try
        {
            if (!isGenericRuntime)
            {
                if (!string.IsNullOrWhiteSpace(explicitIconPath))
                {
                    string expB64 = ExtractFileImageOrIconBase64(explicitIconPath);
                    if (!string.IsNullOrEmpty(expB64)) return expB64;
                }

                // Prefer high-res 256x256 embedded EXE icon over 32x32 GCL_HICON when available,
                // unless the window explicitly set a custom per-HWND WM_GETICON.
                IntPtr wmIcon = QueryWindowSpecificHIcon(hwnd);
                if (wmIcon != IntPtr.Zero)
                {
                    using var ico = Icon.FromHandle(wmIcon);
                    using var bmp = ico.ToBitmap();
                    if (bmp.Width >= 48 && bmp.Height >= 48)
                        return EncodeBitmapToBase64Png(bmp, 128);
                }

                if (!string.IsNullOrWhiteSpace(exePath) && File.Exists(exePath))
                {
                    string exeB64 = ExtractHighResExeIconBase64(exePath);
                    if (!string.IsNullOrEmpty(exeB64)) return exeB64;
                }

                IntPtr anyHIcon = wmIcon != IntPtr.Zero ? wmIcon : QueryClassHIcon(hwnd);
                if (anyHIcon != IntPtr.Zero)
                {
                    using var ico = Icon.FromHandle(anyHIcon);
                    using var bmp = ico.ToBitmap();
                    return EncodeBitmapToBase64Png(bmp, 128);
                }
                return "";
            }

            // Generic host runtime (e.g. electron.exe, javaw.exe, pythonw.exe):
            // 1. Explicit RelaunchIconResource or package.json build.icon
            if (!string.IsNullOrWhiteSpace(explicitIconPath))
            {
                string expB64 = ExtractFileImageOrIconBase64(explicitIconPath);
                if (!string.IsNullOrEmpty(expB64)) return expB64;
            }

            // 2. Per-window custom HICON (e.g. Electron `new BrowserWindow({ icon })`) if different from electron.exe's atom icon
            IntPtr customWmIcon = QueryWindowSpecificHIcon(hwnd);
            IntPtr classIcon = QueryClassHIcon(hwnd);
            if (customWmIcon != IntPtr.Zero && customWmIcon != classIcon)
            {
                using var ico = Icon.FromHandle(customWmIcon);
                using var bmp = ico.ToBitmap();
                if (!IsSameVisualIconAsExeDefault(bmp, exePath))
                {
                    string winB64 = EncodeBitmapToBase64Png(bmp, 128);
                    if (!string.IsNullOrEmpty(winB64)) return winB64;
                }
            }

            // 3. Discovered square icon/logo file inside the Electron/script app's project directory
            if (!string.IsNullOrWhiteSpace(discoveredProjectIconPath))
            {
                string projB64 = ExtractFileImageOrIconBase64(discoveredProjectIconPath);
                if (!string.IsNullOrEmpty(projB64)) return projB64;
            }

            // 4. Clean monogram squircle icon using the app's real name (instead of generic Electron framework icon)
            if (!string.IsNullOrWhiteSpace(fallbackAppName) &&
                !fallbackAppName.Equals("Electron", StringComparison.OrdinalIgnoreCase))
            {
                string mono = GenerateMonogramIconBase64(fallbackAppName);
                if (!string.IsNullOrEmpty(mono)) return mono;
            }

            if (!string.IsNullOrWhiteSpace(exePath) && File.Exists(exePath))
            {
                return ExtractHighResExeIconBase64(exePath);
            }
        }
        catch
        {
        }
        return "";
    }

    private static IntPtr QueryWindowSpecificHIcon(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return IntPtr.Zero;
        Win32Interop.SendMessageTimeout(hwnd, Win32Interop.WM_GETICON, (IntPtr)Win32Interop.ICON_BIG, IntPtr.Zero, 0x0002, 80, out IntPtr hIcon);
        if (hIcon == IntPtr.Zero)
            Win32Interop.SendMessageTimeout(hwnd, Win32Interop.WM_GETICON, (IntPtr)Win32Interop.ICON_SMALL2, IntPtr.Zero, 0x0002, 80, out hIcon);
        if (hIcon == IntPtr.Zero)
            Win32Interop.SendMessageTimeout(hwnd, Win32Interop.WM_GETICON, (IntPtr)Win32Interop.ICON_SMALL, IntPtr.Zero, 0x0002, 80, out hIcon);
        return hIcon;
    }

    private static IntPtr QueryClassHIcon(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return IntPtr.Zero;
        IntPtr hIcon = Win32Interop.GetClassLongPtr(hwnd, Win32Interop.GCL_HICON);
        if (hIcon == IntPtr.Zero)
            hIcon = Win32Interop.GetClassLongPtr(hwnd, Win32Interop.GCL_HICONSM);
        return hIcon;
    }

    private static string ExtractHighResExeIconBase64(string exePath)
    {
        if (ExeHighResIconCache.TryGetValue(exePath, out var cached))
            return cached;

        string result = "";
        try
        {
            using var bmp = ExtractHighResExeBitmap(exePath);
            if (bmp != null)
                result = EncodeBitmapToBase64Png(bmp, 128);
        }
        catch
        {
        }

        if (!string.IsNullOrEmpty(result))
            ExeHighResIconCache[exePath] = result;
        return result;
    }

    private static Bitmap? ExtractHighResExeBitmap(string exePath, int desiredSize = 256)
    {
        if (string.IsNullOrWhiteSpace(exePath) || !File.Exists(exePath))
            return null;

        var hIcons = new IntPtr[1];
        var ids = new uint[1];
        uint extracted = Win32Interop.PrivateExtractIconsW(exePath, 0, desiredSize, desiredSize, hIcons, ids, 1, 0);
        if (extracted != uint.MaxValue && extracted > 0 && hIcons[0] != IntPtr.Zero)
        {
            try
            {
                using var ico = Icon.FromHandle(hIcons[0]);
                return ico.ToBitmap();
            }
            finally
            {
                Win32Interop.DestroyIcon(hIcons[0]);
            }
        }

        using var assoc = Icon.ExtractAssociatedIcon(exePath);
        return assoc?.ToBitmap();
    }

    private static bool IsSameVisualIconAsExeDefault(Bitmap candidate, string? exePath)
    {
        if (string.IsNullOrWhiteSpace(exePath) || !File.Exists(exePath))
            return false;

        var exeThumb = ExeThumb16Cache.GetOrAdd(exePath, p =>
        {
            try
            {
                using var exeBmp = ExtractHighResExeBitmap(p, 64);
                return exeBmp != null ? ComputeThumb16Rgba(exeBmp) : null;
            }
            catch
            {
                return null;
            }
        });
        if (exeThumb == null) return false;

        var candThumb = ComputeThumb16Rgba(candidate);
        long totalDiff = 0;
        for (int i = 0; i < exeThumb.Length; i++)
            totalDiff += Math.Abs(exeThumb[i] - candThumb[i]);

        double meanDiff = totalDiff / (double)exeThumb.Length;
        return meanDiff < 12.0;
    }

    private static byte[] ComputeThumb16Rgba(Bitmap src)
    {
        const int sz = 16;
        using var small = new Bitmap(sz, sz, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(small))
        {
            g.Clear(System.Drawing.Color.Transparent);
            g.InterpolationMode = InterpolationMode.HighQualityBilinear;
            g.DrawImage(src, new Rectangle(0, 0, sz, sz));
        }
        var outBytes = new byte[sz * sz * 4];
        int idx = 0;
        for (int y = 0; y < sz; y++)
        {
            for (int x = 0; x < sz; x++)
            {
                var c = small.GetPixel(x, y);
                outBytes[idx++] = c.R;
                outBytes[idx++] = c.G;
                outBytes[idx++] = c.B;
                outBytes[idx++] = c.A;
            }
        }
        return outBytes;
    }

    public static string ExtractFileImageOrIconBase64(string rawResourcePath)
    {
        if (string.IsNullOrWhiteSpace(rawResourcePath)) return "";
        if (CustomFileIconCache.TryGetValue(rawResourcePath, out var cached))
            return cached;

        string cleanPath = rawResourcePath.Trim().Trim('"');
        int iconIndex = 0;
        int commaIdx = cleanPath.LastIndexOf(',');
        if (commaIdx > 2 && int.TryParse(cleanPath[(commaIdx + 1)..].Trim(), out int parsedIdx))
        {
            iconIndex = Math.Max(0, parsedIdx);
            cleanPath = cleanPath[..commaIdx].Trim().Trim('"');
        }

        if (!File.Exists(cleanPath)) return "";

        string ext = Path.GetExtension(cleanPath).ToLowerInvariant();
        string b64 = "";
        try
        {
            if (ext is ".ico" or ".exe" or ".dll")
            {
                var hIcons = new IntPtr[1];
                var ids = new uint[1];
                uint count = Win32Interop.PrivateExtractIconsW(cleanPath, iconIndex, 256, 256, hIcons, ids, 1, 0);
                if (count != uint.MaxValue && count > 0 && hIcons[0] != IntPtr.Zero)
                {
                    try
                    {
                        using var ico = Icon.FromHandle(hIcons[0]);
                        using var bmp = ico.ToBitmap();
                        b64 = EncodeBitmapToBase64Png(bmp, 128);
                    }
                    finally
                    {
                        Win32Interop.DestroyIcon(hIcons[0]);
                    }
                }
                else if (ext == ".ico")
                {
                    byte[] bytes = File.ReadAllBytes(cleanPath);
                    using var ms = new MemoryStream(bytes);
                    using var ico = new Icon(ms, new Size(256, 256));
                    using var bmp = ico.ToBitmap();
                    b64 = EncodeBitmapToBase64Png(bmp, 128);
                }
            }
            else
            {
                byte[] bytes = File.ReadAllBytes(cleanPath);
                using var ms = new MemoryStream(bytes);
                using var raw = new Bitmap(ms);
                b64 = EncodeProportionalBitmapToBase64Png(raw, 128);
            }
        }
        catch
        {
        }

        if (!string.IsNullOrEmpty(b64))
            CustomFileIconCache[rawResourcePath] = b64;
        return b64;
    }

    private static string EncodeProportionalBitmapToBase64Png(Bitmap bitmap, int targetSize)
    {
        using var canvas = new Bitmap(targetSize, targetSize, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(canvas))
        {
            g.Clear(System.Drawing.Color.Transparent);
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;

            float scale = Math.Min((float)targetSize / Math.Max(1, bitmap.Width), (float)targetSize / Math.Max(1, bitmap.Height));
            int drawW = Math.Max(1, (int)Math.Round(bitmap.Width * scale));
            int drawH = Math.Max(1, (int)Math.Round(bitmap.Height * scale));
            int drawX = (targetSize - drawW) / 2;
            int drawY = (targetSize - drawH) / 2;
            g.DrawImage(bitmap, new Rectangle(drawX, drawY, drawW, drawH));
        }
        using var outMs = new MemoryStream();
        canvas.Save(outMs, ImageFormat.Png);
        return Convert.ToBase64String(outMs.ToArray());
    }

    public static string GenerateMonogramIconBase64(string appName)
    {
        string clean = (appName ?? "").Trim();
        string glyph = "A";
        foreach (var ch in clean)
        {
            if (char.IsLetterOrDigit(ch))
            {
                glyph = char.ToUpperInvariant(ch).ToString();
                break;
            }
        }

        (System.Drawing.Color C1, System.Drawing.Color C2)[] palettes =
        {
            (System.Drawing.Color.FromArgb(255, 99, 102, 241), System.Drawing.Color.FromArgb(255, 79, 70, 229)),
            (System.Drawing.Color.FromArgb(255, 14, 165, 233), System.Drawing.Color.FromArgb(255, 37, 99, 235)),
            (System.Drawing.Color.FromArgb(255, 16, 185, 129), System.Drawing.Color.FromArgb(255, 5, 150, 105)),
            (System.Drawing.Color.FromArgb(255, 245, 158, 11), System.Drawing.Color.FromArgb(255, 217, 119, 6)),
            (System.Drawing.Color.FromArgb(255, 236, 72, 153), System.Drawing.Color.FromArgb(255, 219, 39, 119)),
            (System.Drawing.Color.FromArgb(255, 139, 92, 246), System.Drawing.Color.FromArgb(255, 109, 40, 217)),
        };
        int idx = Math.Abs(StringComparer.OrdinalIgnoreCase.GetHashCode(clean)) % palettes.Length;
        var (c1, c2) = palettes[idx];

        using var bmp = new Bitmap(128, 128, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            g.Clear(System.Drawing.Color.Transparent);

            var rect = new RectangleF(8, 8, 112, 112);
            using var path = CreateRoundedRect(rect, 26f);
            using var grad = new System.Drawing.Drawing2D.LinearGradientBrush(rect, c1, c2, 45f);
            g.FillPath(grad, path);

            using var font = new Font("Microsoft YaHei UI", 60f, System.Drawing.FontStyle.Bold, GraphicsUnit.Pixel);
            using var brush = new SolidBrush(System.Drawing.Color.White);
            var sf = new StringFormat
            {
                Alignment = StringAlignment.Center,
                LineAlignment = StringAlignment.Center
            };
            g.DrawString(glyph, font, brush, new RectangleF(8, 10, 112, 112), sf);
        }
        return EncodeBitmapToBase64Png(bmp, 128);
    }

    public static string GenerateDesktopIconBase64()
    {
        using var bmp = new Bitmap(128, 128, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.Clear(System.Drawing.Color.Transparent);

            using var bgPath = CreateRoundedRect(new RectangleF(10, 16, 108, 76), 14f);
            using var grad = new System.Drawing.Drawing2D.LinearGradientBrush(
                new RectangleF(10, 16, 108, 76),
                System.Drawing.Color.FromArgb(255, 14, 165, 233),
                System.Drawing.Color.FromArgb(255, 37, 99, 235),
                45f);
            g.FillPath(grad, bgPath);

            using var borderPen = new System.Drawing.Pen(System.Drawing.Color.FromArgb(220, 255, 255, 255), 3.5f);
            g.DrawPath(borderPen, bgPath);

            using var standBrush = new SolidBrush(System.Drawing.Color.FromArgb(220, 148, 163, 184));
            g.FillRectangle(standBrush, 54, 94, 20, 12);
            using var basePath = CreateRoundedRect(new RectangleF(38, 104, 52, 8), 4f);
            g.FillPath(standBrush, basePath);
        }
        return EncodeBitmapToBase64Png(bmp, 128);
    }

    /// <summary>
    /// Composites a remote app icon at 256x256 with the official OpenUU squircle badge in the bottom-right corner
    /// (with soft drop shadow + crisp white border rim, identical to macOS <c>IconCompositor.compositeWithOpenUUBadge</c>).
    /// </summary>
    public static Bitmap CompositeWithOpenUUBadgeBitmap(Bitmap? baseIcon)
    {
        const int canvasSize = 256;
        var outBmp = new Bitmap(canvasSize, canvasSize, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using var g = Graphics.FromImage(outBmp);
        g.Clear(System.Drawing.Color.Transparent);
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;

        if (baseIcon != null)
        {
            g.DrawImage(baseIcon, new Rectangle(8, 8, canvasSize - 16, canvasSize - 16));
        }
        else
        {
            using var fallbackPath = CreateRoundedRect(new RectangleF(20, 20, canvasSize - 40, canvasSize - 40), 46f);
            using var fallbackBrush = new System.Drawing.Drawing2D.LinearGradientBrush(
                new RectangleF(20, 20, canvasSize - 40, canvasSize - 40),
                System.Drawing.Color.FromArgb(255, 14, 165, 233),
                System.Drawing.Color.FromArgb(255, 59, 130, 246),
                45f);
            g.FillPath(fallbackBrush, fallbackPath);
        }

        int badgeSize = (int)(canvasSize * 0.38f);
        int margin = 8;
        var badgeRect = new RectangleF(
            canvasSize - badgeSize - margin,
            canvasSize - badgeSize - margin,
            badgeSize,
            badgeSize
        );

        // Soft shadow + white rim behind the bottom-right OpenUU badge
        using (var shadowPath = CreateRoundedRect(RectangleF.Inflate(badgeRect, 5f, 5f), badgeSize * 0.26f))
        using (var shadowBrush = new SolidBrush(System.Drawing.Color.FromArgb(95, 0, 0, 0)))
        {
            g.TranslateTransform(0, 2.5f);
            g.FillPath(shadowBrush, shadowPath);
            g.ResetTransform();
        }

        using (var rimPath = CreateRoundedRect(RectangleF.Inflate(badgeRect, 3f, 3f), badgeSize * 0.25f))
        using (var rimBrush = new SolidBrush(System.Drawing.Color.FromArgb(245, 255, 255, 255)))
        {
            g.FillPath(rimBrush, rimPath);
        }

        var brand = RawBrandBitmap.Value;
        if (brand != null)
        {
            g.DrawImage(brand, badgeRect);
        }
        else
        {
            using var ringPath = CreateRoundedRect(badgeRect, badgeSize * 0.24f);
            using var cyanBrush = new SolidBrush(System.Drawing.Color.FromArgb(255, 6, 182, 212));
            g.FillPath(cyanBrush, ringPath);
        }

        return outBmp;
    }

    public static ImageSource CompositeWithOpenUUBadge(string? base64Png)
    {
        using var raw = DecodeBase64ToBitmap(base64Png);
        using var comp = CompositeWithOpenUUBadgeBitmap(raw);
        return BitmapToFrozenImageSource(comp);
    }

    /// <summary>
    /// Creates a crisp red unread badge overlay (<see cref="ImageSource"/>) for <c>Window.TaskbarItemInfo.Overlay</c>.
    /// </summary>
    public static ImageSource? CreateTaskbarBadgeOverlay(string? badgeText)
    {
        if (string.IsNullOrWhiteSpace(badgeText)) return null;
        string clean = badgeText.Trim();
        if (clean == "0") return null;
        if (clean.Length > 3) clean = "99+";

        using var bmp = new Bitmap(64, 64, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            g.Clear(System.Drawing.Color.Transparent);

            using var redBrush = new SolidBrush(System.Drawing.Color.FromArgb(255, 239, 68, 68));
            using var whitePen = new System.Drawing.Pen(System.Drawing.Color.White, 3.5f);
            var rect = new RectangleF(4, 4, 56, 56);
            g.FillEllipse(redBrush, rect);
            g.DrawEllipse(whitePen, rect);

            float fontSize = clean.Length >= 3 ? 20f : (clean.Length == 2 ? 25f : 30f);
            using var font = new Font("Segoe UI", fontSize, System.Drawing.FontStyle.Bold, GraphicsUnit.Pixel);
            using var textBrush = new SolidBrush(System.Drawing.Color.White);
            var sf = new StringFormat
            {
                Alignment = StringAlignment.Center,
                LineAlignment = StringAlignment.Center
            };
            g.DrawString(clean, font, textBrush, rect, sf);
        }
        return BitmapToFrozenImageSource(bmp);
    }

    private static GraphicsPath CreateRoundedRect(RectangleF bounds, float radius)
    {
        float d = radius * 2f;
        var path = new GraphicsPath();
        path.AddArc(bounds.X, bounds.Y, d, d, 180, 90);
        path.AddArc(bounds.Right - d, bounds.Y, d, d, 270, 90);
        path.AddArc(bounds.Right - d, bounds.Bottom - d, d, d, 0, 90);
        path.AddArc(bounds.X, bounds.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}
