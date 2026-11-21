using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Effects;
using System.Windows.Threading;

namespace OpenUU.Client;

/// <summary>
/// Presents forwarded remote app notifications on Windows using a sleek non-activating Windows 11-style
/// corner toast banner (plus optional System Tray balloon tip). Clicking the banner focuses or opens
/// the corresponding remote application window (matching macOS <c>ClientNotificationManager</c>).
/// </summary>
public sealed class ClientNotificationManager : IDisposable
{
    public bool IsEnabled { get; set; } = true;
    public Action<string>? OnNotificationClicked { get; set; }
    public System.Windows.Forms.NotifyIcon? TrayIcon { get; set; }

    private string _lastCompositeKey = "";
    private Window? _activeBanner;
    private DispatcherTimer? _dismissTimer;

    public void PresentRemoteNotification(
        string compositeKey,
        string appName,
        string title,
        string subtitle,
        string body,
        ImageSource? icon
    )
    {
        if (!IsEnabled) return;
        _lastCompositeKey = compositeKey;

        string finalTitle = string.IsNullOrWhiteSpace(title) ? appName : title;
        string finalSub = !string.IsNullOrWhiteSpace(subtitle)
            ? subtitle
            : (!string.IsNullOrWhiteSpace(appName) && finalTitle != appName ? appName : "");
        string finalBody = string.IsNullOrWhiteSpace(body) ? "收到新消息" : body;

        System.Windows.Application.Current?.Dispatcher.Invoke(() =>
        {
            ShowDesktopToastBanner(compositeKey, finalTitle, finalSub, finalBody, icon);
        });
    }

    public void NotifyTrayClicked()
    {
        if (!string.IsNullOrEmpty(_lastCompositeKey))
            OnNotificationClicked?.Invoke(_lastCompositeKey);
    }

    private void ShowDesktopToastBanner(
        string compositeKey,
        string title,
        string subtitle,
        string body,
        ImageSource? icon
    )
    {
        CloseBanner();

        var win = new Window
        {
            Width = 340,
            SizeToContent = SizeToContent.Height,
            WindowStyle = WindowStyle.None,
            AllowsTransparency = true,
            Background = System.Windows.Media.Brushes.Transparent,
            Topmost = true,
            ShowActivated = false,
            ShowInTaskbar = false,
            ResizeMode = ResizeMode.NoResize
        };

        var card = new Border
        {
            Margin = new Thickness(10),
            Padding = new Thickness(14, 12, 14, 12),
            CornerRadius = new CornerRadius(12),
            Background = new SolidColorBrush(System.Windows.Media.Color.FromArgb(245, 24, 24, 28)),
            BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromArgb(90, 255, 255, 255)),
            BorderThickness = new Thickness(1),
            Cursor = System.Windows.Input.Cursors.Hand,
            Effect = new DropShadowEffect
            {
                BlurRadius = 14,
                ShadowDepth = 4,
                Opacity = 0.45,
                Color = Colors.Black
            }
        };

        var row = new Grid();
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        if (icon != null)
        {
            var img = new System.Windows.Controls.Image
            {
                Source = icon,
                Width = 38,
                Height = 38,
                Margin = new Thickness(0, 0, 12, 0),
                VerticalAlignment = VerticalAlignment.Top
            };
            RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.HighQuality);
            Grid.SetColumn(img, 0);
            row.Children.Add(img);
        }

        var stack = new StackPanel();
        stack.Children.Add(new TextBlock
        {
            Text = title,
            Foreground = System.Windows.Media.Brushes.White,
            FontWeight = FontWeights.SemiBold,
            FontSize = 13,
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        if (!string.IsNullOrWhiteSpace(subtitle))
        {
            stack.Children.Add(new TextBlock
            {
                Text = subtitle,
                Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(161, 161, 170)),
                FontSize = 11,
                Margin = new Thickness(0, 1, 0, 0),
                TextTrimming = TextTrimming.CharacterEllipsis
            });
        }
        stack.Children.Add(new TextBlock
        {
            Text = body,
            Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(228, 228, 231)),
            FontSize = 12,
            Margin = new Thickness(0, 3, 0, 0),
            TextWrapping = TextWrapping.Wrap,
            MaxHeight = 40
        });
        Grid.SetColumn(stack, 1);
        row.Children.Add(stack);

        card.Child = row;
        card.MouseLeftButtonUp += (_, _) =>
        {
            CloseBanner();
            OnNotificationClicked?.Invoke(compositeKey);
        };

        win.Content = card;
        win.Loaded += (_, _) =>
        {
            var workArea = SystemParameters.WorkArea;
            win.Left = workArea.Right - win.ActualWidth - 8;
            win.Top = workArea.Bottom - win.ActualHeight - 8;
        };

        _activeBanner = win;
        win.Show();

        _dismissTimer = new DispatcherTimer { Interval = TimeSpan.FromSeconds(4.5) };
        _dismissTimer.Tick += (_, _) => CloseBanner();
        _dismissTimer.Start();
    }

    private void CloseBanner()
    {
        _dismissTimer?.Stop();
        _dismissTimer = null;
        if (_activeBanner != null)
        {
            try { _activeBanner.Close(); } catch { }
            _activeBanner = null;
        }
    }

    public void Dispose() => CloseBanner();
}
