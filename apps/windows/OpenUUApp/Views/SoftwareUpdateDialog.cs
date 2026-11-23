using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Shell;

namespace OpenUU.Views;

using OpenUU.Shared;

public sealed class SoftwareUpdateDialog : Window
{
    private readonly AppUpdater _updater;
    private readonly TextBlock _headingText;
    private readonly TextBlock _metaText;
    private readonly System.Windows.Controls.TextBox _notesBox;
    private readonly Border _progressCard;
    private readonly TextBlock _progressLabel;
    private readonly System.Windows.Controls.ProgressBar _progressBar;
    private readonly Border _errorCard;
    private readonly TextBlock _errorLabel;
    private readonly System.Windows.Controls.Button _skipBtn;
    private readonly System.Windows.Controls.Button _browserBtn;
    private readonly System.Windows.Controls.Button _primaryActionBtn;
    private readonly System.Windows.Controls.Button _closeBtn;
    private readonly System.Windows.Controls.Button _topCloseBtn;

    public SoftwareUpdateDialog(AppUpdater updater)
    {
        _updater = updater;
        Title = "OpenUU 版本更新";
        Width = 556;
        Height = 468;
        MinWidth = 496;
        MinHeight = 410;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        UseLayoutRounding = true;
        SnapsToDevicePixels = true;
        Background = (SolidColorBrush)System.Windows.Application.Current.FindResource("CardBg");

        WindowChrome.SetWindowChrome(this, new WindowChrome
        {
            CaptionHeight = 0,
            ResizeBorderThickness = new Thickness(0),
            GlassFrameThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            UseAeroCaptionButtons = false
        });

        SourceInitialized += (_, _) =>
        {
            IntPtr hwnd = new WindowInteropHelper(this).Handle;
            int roundPref = Win32Interop.DWMWCP_ROUND;
            Win32Interop.DwmSetWindowAttribute(hwnd, Win32Interop.DWMWA_WINDOW_CORNER_PREFERENCE, ref roundPref, sizeof(int));
        };

        var outerGrid = new Grid();
        outerGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        outerGrid.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        outerGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // Top Draggable Header
        var topHeader = new Grid
        {
            Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(248, 250, 252))
        };
        topHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topHeader.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        topHeader.MouseLeftButtonDown += (_, e) =>
        {
            if (e.ButtonState == MouseButtonState.Pressed && !_updater.IsInstalling)
            {
                try { DragMove(); } catch { }
            }
        };

        var headerRow = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            Margin = new Thickness(22, 15, 12, 14)
        };
        if (IconCompositor.BrandSquircleIcon != null)
        {
            headerRow.Children.Add(new System.Windows.Controls.Image
            {
                Source = IconCompositor.BrandSquircleIcon,
                Width = 40,
                Height = 40,
                Margin = new Thickness(0, 0, 12, 0)
            });
        }

        var titleCol = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        _headingText = new TextBlock
        {
            FontSize = 16,
            FontWeight = FontWeights.Bold,
            Foreground = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextPrimary")
        };
        _metaText = new TextBlock
        {
            FontSize = 11.5,
            Foreground = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextSecondary"),
            Margin = new Thickness(0, 3, 0, 0)
        };
        titleCol.Children.Add(_headingText);
        titleCol.Children.Add(_metaText);
        headerRow.Children.Add(titleCol);
        Grid.SetColumn(headerRow, 0);
        topHeader.Children.Add(headerRow);

        _topCloseBtn = new System.Windows.Controls.Button
        {
            VerticalAlignment = VerticalAlignment.Top,
            ToolTip = "关闭",
            Style = (Style)System.Windows.Application.Current.FindResource("WindowCloseBtnStyle")
        };
        var closeCanvas = new Canvas { Width = 10, Height = 10 };
        var closePath = new Path
        {
            Data = Geometry.Parse("M 0.5,0.5 L 9.5,9.5 M 9.5,0.5 L 0.5,9.5"),
            StrokeThickness = 1.3
        };
        closePath.SetBinding(Shape.StrokeProperty, new System.Windows.Data.Binding("Foreground")
        {
            RelativeSource = new System.Windows.Data.RelativeSource(System.Windows.Data.RelativeSourceMode.FindAncestor, typeof(System.Windows.Controls.Button), 1)
        });
        closeCanvas.Children.Add(closePath);
        _topCloseBtn.Content = closeCanvas;
        _topCloseBtn.Click += (_, _) => { if (!_updater.IsInstalling) Close(); };
        Grid.SetColumn(_topCloseBtn, 1);
        topHeader.Children.Add(_topCloseBtn);

        Grid.SetRow(topHeader, 0);
        outerGrid.Children.Add(topHeader);

        var divider = new Border
        {
            Height = 1,
            Background = (SolidColorBrush)System.Windows.Application.Current.FindResource("DividerBrush")
        };
        Grid.SetRow(divider, 1);
        outerGrid.Children.Add(divider);

        var root = new Grid { Margin = new Thickness(22, 16, 22, 20) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // 1. Subtitle
        var subLabel = new TextBlock
        {
            Text = "更新内容说明",
            FontSize = 12,
            FontWeight = FontWeights.SemiBold,
            Foreground = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextSecondary"),
            Margin = new Thickness(0, 0, 0, 6)
        };
        Grid.SetRow(subLabel, 0);
        root.Children.Add(subLabel);

        // 2. Release Notes Scrollable Box
        _notesBox = new System.Windows.Controls.TextBox
        {
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Style = (Style)System.Windows.Application.Current.FindResource("RoundedTextBoxStyle"),
            FontSize = 12.5,
            Padding = new Thickness(12, 10, 12, 10),
            Background = (SolidColorBrush)System.Windows.Application.Current.FindResource("SubtleSurfaceBg"),
            BorderBrush = (SolidColorBrush)System.Windows.Application.Current.FindResource("CardBorder"),
            Foreground = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextPrimary")
        };
        Grid.SetRow(_notesBox, 1);
        root.Children.Add(_notesBox);

        // 4. Live Progress / Error Banner
        var statusHost = new StackPanel { Margin = new Thickness(0, 10, 0, 0) };

        _progressCard = new Border
        {
            Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(239, 246, 255)),
            BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(147, 197, 253)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 8, 10, 8),
            Visibility = Visibility.Collapsed
        };
        var progStack = new StackPanel();
        var progTop = new Grid();
        _progressLabel = new TextBlock
        {
            FontSize = 12,
            FontFamily = new System.Windows.Media.FontFamily("Consolas"),
            Foreground = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextPrimary"),
            VerticalAlignment = VerticalAlignment.Center
        };
        var cancelDlBtn = new System.Windows.Controls.Button
        {
            Content = "取消下载",
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
            Padding = new Thickness(8, 2, 8, 2),
            FontSize = 11,
            Style = (Style)System.Windows.Application.Current.FindResource("SecondaryButtonStyle")
        };
        cancelDlBtn.Click += (_, _) => _updater.CancelDownload();
        progTop.Children.Add(_progressLabel);
        progTop.Children.Add(cancelDlBtn);
        _progressBar = new System.Windows.Controls.ProgressBar
        {
            Minimum = 0,
            Maximum = 100,
            Height = 6,
            Margin = new Thickness(0, 6, 0, 0)
        };
        progStack.Children.Add(progTop);
        progStack.Children.Add(_progressBar);
        _progressCard.Child = progStack;

        _errorCard = new Border
        {
            Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(254, 242, 242)),
            BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(252, 165, 165)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(8),
            Padding = new Thickness(10, 8, 10, 8),
            Visibility = Visibility.Collapsed
        };
        _errorLabel = new TextBlock
        {
            FontSize = 11.5,
            Foreground = new SolidColorBrush(System.Windows.Media.Color.FromRgb(185, 28, 28)),
            TextWrapping = TextWrapping.Wrap
        };
        _errorCard.Child = _errorLabel;

        statusHost.Children.Add(_progressCard);
        statusHost.Children.Add(_errorCard);
        Grid.SetRow(statusHost, 2);
        root.Children.Add(statusHost);

        // 4. Action Buttons
        var footer = new Grid { Margin = new Thickness(0, 14, 0, 0) };
        var leftBtns = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        _skipBtn = new System.Windows.Controls.Button
        {
            Content = "忽略此版本",
            Padding = new Thickness(10, 6, 10, 6),
            FontSize = 12,
            Margin = new Thickness(0, 0, 8, 0),
            Style = (Style)System.Windows.Application.Current.FindResource("SecondaryButtonStyle")
        };
        _skipBtn.Click += (_, _) =>
        {
            _updater.SkipCurrentAvailableVersion();
            Close();
        };

        var ghBtn = new System.Windows.Controls.Button
        {
            Content = "GitHub Releases",
            Padding = new Thickness(10, 6, 10, 6),
            FontSize = 12,
            Style = (Style)System.Windows.Application.Current.FindResource("SecondaryButtonStyle")
        };
        ghBtn.Click += (_, _) =>
        {
            string url = _updater.ReleaseInfo?.HtmlUrl ?? AppUpdater.GithubReleasesPage;
            try { Process.Start(new ProcessStartInfo(url) { UseShellExecute = true }); } catch { }
        };
        leftBtns.Children.Add(_skipBtn);
        leftBtns.Children.Add(ghBtn);

        var rightBtns = new StackPanel
        {
            Orientation = System.Windows.Controls.Orientation.Horizontal,
            HorizontalAlignment = System.Windows.HorizontalAlignment.Right
        };
        _closeBtn = new System.Windows.Controls.Button
        {
            Content = "稍后",
            Padding = new Thickness(12, 6, 12, 6),
            FontSize = 12,
            Margin = new Thickness(0, 0, 8, 0),
            Style = (Style)System.Windows.Application.Current.FindResource("SecondaryButtonStyle")
        };
        _closeBtn.Click += (_, _) => Close();

        _browserBtn = new System.Windows.Controls.Button
        {
            Content = "浏览器下载",
            Padding = new Thickness(12, 6, 12, 6),
            FontSize = 12,
            Margin = new Thickness(0, 0, 8, 0),
            Style = (Style)System.Windows.Application.Current.FindResource("SecondaryButtonStyle")
        };
        _browserBtn.Click += (_, _) => _updater.OpenReleaseInBrowser();

        _primaryActionBtn = new System.Windows.Controls.Button
        {
            Content = "⬇ 一键下载并重启更新",
            Padding = new Thickness(14, 6, 14, 6),
            FontSize = 12.5,
            Style = (Style)System.Windows.Application.Current.FindResource("PrimaryButtonStyle")
        };
        _primaryActionBtn.Click += async (_, _) =>
        {
            if (_updater.HasAvailableUpdate)
                await _updater.PerformOneClickUpdateAsync();
            else
                await _updater.CheckForUpdatesAsync(manual: true);
        };

        rightBtns.Children.Add(_closeBtn);
        rightBtns.Children.Add(_browserBtn);
        rightBtns.Children.Add(_primaryActionBtn);

        footer.Children.Add(leftBtns);
        footer.Children.Add(rightBtns);
        Grid.SetRow(footer, 3);
        root.Children.Add(footer);

        Grid.SetRow(root, 2);
        outerGrid.Children.Add(root);

        Content = new Border
        {
            BorderBrush = (SolidColorBrush)System.Windows.Application.Current.FindResource("ControlBorder"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Background = (SolidColorBrush)System.Windows.Application.Current.FindResource("CardBg"),
            ClipToBounds = true,
            Child = outerGrid
        };

        _updater.PropertyChanged += OnUpdaterPropertyChanged;
        Closed += (_, _) => _updater.PropertyChanged -= OnUpdaterPropertyChanged;
        SyncUi();
    }

    private void OnUpdaterPropertyChanged(object? sender, System.ComponentModel.PropertyChangedEventArgs e)
    {
        Dispatcher.BeginInvoke(SyncUi);
    }

    private void SyncUi()
    {
        var info = _updater.ReleaseInfo;
        bool hasUpdate = info?.HasUpdate == true;

        _headingText.Text = hasUpdate
            ? $"发现新版本 {info!.TagName}"
            : $"当前已是最新版本 ({AppVersion.Display})";

        var metaParts = new List<string> { $"当前版本：{AppVersion.Display}" };
        if (info != null)
        {
            if (!string.IsNullOrEmpty(info.FormattedDate))
                metaParts.Add($"发布日期：{info.FormattedDate}");
            if (!string.IsNullOrEmpty(info.FormattedSize))
                metaParts.Add($"安装包：{info.FormattedSize}");
        }
        _metaText.Text = string.Join("  ·  ", metaParts);

        _notesBox.Text = !string.IsNullOrWhiteSpace(info?.ReleaseNotes)
            ? info!.ReleaseNotes
            : "暂无详细更新说明，可点击左下角前往 GitHub Releases 查看完整变更记录。";

        _progressCard.Visibility = _updater.IsInstalling ? Visibility.Visible : Visibility.Collapsed;
        _progressLabel.Text = _updater.InstallStatusText;
        _progressBar.Value = _updater.DownloadProgressPct;

        bool hasErr = !string.IsNullOrEmpty(_updater.InstallErrorText);
        _errorCard.Visibility = hasErr ? Visibility.Visible : Visibility.Collapsed;
        _errorLabel.Text = _updater.InstallErrorText;

        _skipBtn.Visibility = hasUpdate ? Visibility.Visible : Visibility.Collapsed;
        _browserBtn.Visibility = hasUpdate ? Visibility.Visible : Visibility.Collapsed;
        _closeBtn.Content = hasUpdate ? "稍后" : "关闭";

        bool busy = _updater.IsInstalling || _updater.IsChecking;
        _skipBtn.IsEnabled = !busy;
        _browserBtn.IsEnabled = !busy;
        _closeBtn.IsEnabled = !_updater.IsInstalling;
        _topCloseBtn.IsEnabled = !_updater.IsInstalling;
        _primaryActionBtn.IsEnabled = !busy;
        _primaryActionBtn.Content = hasUpdate
            ? (_updater.IsInstalling ? "正在更新..." : "⬇ 一键下载并重启更新")
            : (_updater.IsChecking ? "正在检查..." : "🔄 重新检查更新");
    }
}
