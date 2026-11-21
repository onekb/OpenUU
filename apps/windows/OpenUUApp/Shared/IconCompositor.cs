using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace OpenUU.Shared;

public static class IconCompositor
{
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

    public static string ExtractWindowOrExeIconBase64(IntPtr hwnd, string? exePath)
    {
        try
        {
            IntPtr hIcon = IntPtr.Zero;
            if (hwnd != IntPtr.Zero)
            {
                Win32Interop.SendMessageTimeout(hwnd, Win32Interop.WM_GETICON, (IntPtr)Win32Interop.ICON_BIG, IntPtr.Zero, 0x0002, 80, out hIcon);
                if (hIcon == IntPtr.Zero)
                    hIcon = Win32Interop.GetClassLongPtr(hwnd, Win32Interop.GCL_HICON);
                if (hIcon == IntPtr.Zero)
                    Win32Interop.SendMessageTimeout(hwnd, Win32Interop.WM_GETICON, (IntPtr)Win32Interop.ICON_SMALL2, IntPtr.Zero, 0x0002, 80, out hIcon);
            }

            if (hIcon != IntPtr.Zero)
            {
                using var ico = Icon.FromHandle(hIcon);
                using var bmp = ico.ToBitmap();
                return EncodeBitmapToBase64Png(bmp, 128);
            }

            if (!string.IsNullOrWhiteSpace(exePath) && File.Exists(exePath))
            {
                using var assoc = Icon.ExtractAssociatedIcon(exePath);
                if (assoc != null)
                {
                    using var bmp = assoc.ToBitmap();
                    return EncodeBitmapToBase64Png(bmp, 128);
                }
            }
        }
        catch
        {
        }
        return "";
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
