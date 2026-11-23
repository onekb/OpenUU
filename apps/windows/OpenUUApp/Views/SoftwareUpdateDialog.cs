using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

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

    public SoftwareUpdateDialog(AppUpdater updater)
    {
        _updater = updater;
        Title = "OpenUU 版本更新";
        Width = 540;
        Height = 450;
        MinWidth = 480;
        MinHeight = 400;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        ResizeMode = ResizeMode.NoResize;
        Background = (SolidColorBrush)System.Windows.Application.Current.FindResource("CardBg");

        var root = new Grid { Margin = new Thickness(22) };
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        // 1. Header
        var headerRow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 14) };
        if (IconCompositor.BrandSquircleIcon != null)
        {
            headerRow.Children.Add(new System.Windows.Controls.Image
            {
                Source = IconCompositor.BrandSquircleIcon,
                Width = 42,
                Height = 42,
                Margin = new Thickness(0, 0, 12, 0)
            });
        }

        var titleCol = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
        _headingText = new TextBlock
        {
            FontSize = 16.5,
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
        Grid.SetRow(headerRow, 0);
        root.Children.Add(headerRow);

        // 2. Subtitle
        var subLabel = new TextBlock
        {
            Text = "更新内容说明",
            FontSize = 12.5,
            FontWeight = FontWeights.SemiBold,
            Foreground = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextSecondary"),
            Margin = new Thickness(0, 0, 0, 6)
        };
        Grid.SetRow(subLabel, 1);
        root.Children.Add(subLabel);

        // 3. Release Notes Scrollable Box
        _notesBox = new System.Windows.Controls.TextBox
        {
            IsReadOnly = true,
            AcceptsReturn = true,
            TextWrapping = TextWrapping.Wrap,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            FontSize = 12.5,
            Padding = new Thickness(12),
            Background = (SolidColorBrush)System.Windows.Application.Current.FindResource("SubtleSurfaceBg"),
            BorderBrush = (SolidColorBrush)System.Windows.Application.Current.FindResource("CardBorder"),
            BorderThickness = new Thickness(1),
            Foreground = (SolidColorBrush)System.Windows.Application.Current.FindResource("TextPrimary")
        };
        Grid.SetRow(_notesBox, 2);
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
        Grid.SetRow(statusHost, 3);
        root.Children.Add(statusHost);

        // 5. Action Buttons
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
        Grid.SetRow(footer, 4);
        root.Children.Add(footer);

        Content = root;

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
        _primaryActionBtn.IsEnabled = !busy;
        _primaryActionBtn.Content = hasUpdate
            ? (_updater.IsInstalling ? "正在更新..." : "⬇ 一键下载并重启更新")
            : (_updater.IsChecking ? "正在检查..." : "🔄 重新检查更新");
    }
}
