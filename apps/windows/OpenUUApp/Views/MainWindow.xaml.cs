using System.Collections.Specialized;
using System.Diagnostics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;

namespace OpenUU.Views;

using OpenUU.App;
using OpenUU.Client;
using OpenUU.Shared;

public partial class MainWindow : Window
{
    public const string GithubRepoUrl = "https://github.com/onekb/OpenUU";
    public const string SelfHostAiPrompt =
        """
        请帮我部署一套私有的 OpenUU 跨网寻址（Coord）与打洞中继（Relay）服务器。
        开源仓库地址：https://github.com/onekb/OpenUU （请先拉取或阅读仓库下的 deploy/ 目录与 README.md）。

        部署要求：
        1. 云服务器方案请参考 `deploy/docker-compose.yml`、`deploy/Dockerfile.coord` 与 `deploy/Caddyfile`；零暴露公网 IP 方案请参考 `deploy/cloudflare-worker` 与 `deploy/cloudflare-relay-worker`（Cloudflare Workers + D1 + Tunnel）。
        2. 先向我确认服务器 SSH 信息与解析好的 Coord / Relay 二级域名（或是否采用纯 IP 自签证书 / Cloudflare 方案）。
        3. 自动完成容器构建启动、HTTPS 证书签发、端口放行（TCP 80/443，UDP 443/3478/7842）及中继鉴权 Bearer Token 配置，并验证 `/health` 接口返回正常。
        4. 部署完成后，直接输出需要填入 OpenUU「网络与日志」页面的三项配置：设备码寻址 (Coord URL)、打洞与中继 (Relay URL)、中继鉴权 Token。
        """;

    private readonly AppState _state;
    private bool _syncingUi;
    private string _selectedGroupFilter = "全部";
    private bool _isDrawerCollapsed;
    private bool _isShowingAntiFraudDialog;
    public bool AllowTrueClose { get; set; }

    public MainWindow(AppState state)
    {
        _state = state;
        _syncingUi = true;
        InitializeComponent();
        _syncingUi = false;

        if (IconCompositor.BrandSquircleIcon != null)
        {
            BrandLogoImage.Source = IconCompositor.BrandSquircleIcon;
            Icon = IconCompositor.BrandSquircleIcon;
        }

        DeployPromptText.Text = SelfHostAiPrompt;

        _syncingUi = true;
        foreach (var level in Enum.GetValues<OpenUULogLevel>())
            LogLevelCombo.Items.Add(level.GetLabel());
        LogLevelCombo.SelectedIndex = (int)_state.SelectedLogLevel;
        _syncingUi = false;

        QuickTargetBox.SubmitRequested += () => _state.ConnectFromQuickInput(autoOpenDesktop: false);
        QuickTargetBox.TextChanged += (_, _) =>
        {
            if (!_syncingUi)
            {
                _state.QuickConnectTarget = QuickTargetBox.Text;
                if (QuickPasswordBox.Text != _state.QuickConnectPassword)
                    QuickPasswordBox.Text = _state.QuickConnectPassword;
            }
        };

        SourceInitialized += (_, _) =>
        {
            IntPtr hwnd = new WindowInteropHelper(this).Handle;
            int roundPref = Win32Interop.DWMWCP_ROUND;
            Win32Interop.DwmSetWindowAttribute(hwnd, Win32Interop.DWMWA_WINDOW_CORNER_PREFERENCE, ref roundPref, sizeof(int));
        };

        StateChanged += (_, _) => UpdateMaxRestoreIcon();

        Loaded += (_, _) =>
        {
            _state.StartDiscovery();
            SyncAllFromState();
            RefreshLogsBox();
        };

        Closing += OnMainWindowClosing;

        _state.PropertyChanged += (_, _) => Dispatcher.BeginInvoke(SyncAllFromState);
        _state.StateMutated += () => Dispatcher.BeginInvoke(SyncAllFromState);
        _state.DeviceBook.DevicesChanged += () => Dispatcher.BeginInvoke(SyncAllFromState);
        _state.LogEntries.CollectionChanged += OnLogEntriesChanged;
    }

    private void OnMainWindowClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        // When Host mode or remote proxy windows are active and user clicks X on MainWindow,
        // hide to System Tray so ongoing remote control streams never drop accidentally!
        if (!AllowTrueClose && _state.IsAnyActive)
        {
            e.Cancel = true;
            Hide();
            _state.StatusLog = "OpenUU 已最小化到系统托盘继续运行";
        }
    }

    private void SyncAllFromState()
    {
        if (_syncingUi) return;
        _syncingUi = true;
        try
        {
            // Navigation Tabs
            ApplyNavButtonStyle(NavRemoteBtn, _state.SelectedTab == SidebarTab.RemoteHome);
            ApplyNavButtonStyle(NavDevicesBtn, _state.SelectedTab == SidebarTab.DeviceList);
            ApplyNavButtonStyle(NavSecurityBtn, _state.SelectedTab == SidebarTab.SecurityQuality);
            ApplyNavButtonStyle(NavNetworkBtn, _state.SelectedTab == SidebarTab.NetworkLogs);

            PageRemoteHome.Visibility = _state.SelectedTab == SidebarTab.RemoteHome ? Visibility.Visible : Visibility.Collapsed;
            PageDeviceList.Visibility = _state.SelectedTab == SidebarTab.DeviceList ? Visibility.Visible : Visibility.Collapsed;
            PageSecurityQuality.Visibility = _state.SelectedTab == SidebarTab.SecurityQuality ? Visibility.Visible : Visibility.Collapsed;
            PageNetworkLogs.Visibility = _state.SelectedTab == SidebarTab.NetworkLogs ? Visibility.Visible : Visibility.Collapsed;

            PageHeaderTitle.Text = _state.HeaderTitle;
            PageHeaderSubtitle.Text = _state.HeaderSubtitle;
            TopAddDeviceBtn.Visibility = _state.ShowAddDeviceButton ? Visibility.Visible : Visibility.Collapsed;

            // Update Devices Count Badge in Sidebar
            if (NavDevicesBtn.Template.FindName("DevicesCountPill", NavDevicesBtn) is Border countPill &&
                NavDevicesBtn.Template.FindName("DevicesCountText", NavDevicesBtn) is TextBlock countTxt)
            {
                int total = _state.DeviceBook.Devices.Count;
                if (total > 0)
                {
                    countPill.Visibility = Visibility.Visible;
                    int conn = _state.ConnectedHostCount;
                    countTxt.Text = conn > 0 ? $"{conn}/{total}" : $"{total}";
                    countPill.Background = conn > 0
                        ? (SolidColorBrush)FindResource("OnlineGreenSoft")
                        : new SolidColorBrush(System.Windows.Media.Color.FromRgb(226, 232, 240));
                    countTxt.Foreground = conn > 0
                        ? (SolidColorBrush)FindResource("OnlineGreen")
                        : new SolidColorBrush(System.Windows.Media.Color.FromRgb(71, 85, 105));
                }
                else
                {
                    countPill.Visibility = Visibility.Collapsed;
                }
            }

            // Sidebar Status Card
            SidebarHostDot.Fill = _state.IsHostRunning
                ? (SolidColorBrush)FindResource("OnlineGreen")
                : new SolidColorBrush(System.Windows.Media.Color.FromRgb(245, 158, 11));
            SidebarHostLabel.Text = _state.IsHostRunning ? "本机被控：已开启" : "本机被控：未开启";
            SidebarHostToggleBtn.Content = _state.IsHostRunning ? "关闭" : "开启";
            SidebarHostToggleBtn.Style = (Style)FindResource(_state.IsHostRunning ? "SecondaryButtonStyle" : "PrimaryButtonStyle");

            SidebarClientDot.Fill = _state.ConnectedHostCount > 0
                ? (SolidColorBrush)FindResource("AccentBrush")
                : new SolidColorBrush(System.Windows.Media.Color.FromRgb(148, 163, 184));
            SidebarClientSummary.Text = _state.SidebarSummaryText;
            SidebarDisconnectAllBtn.Visibility = _state.ConnectedHostCount > 0 ? Visibility.Visible : Visibility.Collapsed;

            // Bottom Status Bar
            BottomStatusDot.Fill = _state.IsAnyActive
                ? (SolidColorBrush)FindResource("OnlineGreen")
                : new SolidColorBrush(System.Windows.Media.Color.FromRgb(148, 163, 184));
            BottomStatusText.Text = _state.StatusLog;

            // Hero Card: Host
            MyDeviceCodeText.Text = _state.MyFormattedDeviceCode;
            if (HostPinBox.Text != _state.HostPin)
                HostPinBox.Text = _state.HostPin;
            HostPinBox.IsEnabled = !_state.IsHostRunning;
            HostPinBox.Visibility = _state.IsHostPasswordRevealed ? Visibility.Visible : Visibility.Collapsed;
            HostPinMaskedText.Text = _state.MaskedHostPin;
            HostPinMaskedText.Visibility = _state.IsHostPasswordRevealed ? Visibility.Collapsed : Visibility.Visible;
            TogglePinEyeBtn.Content = _state.IsHostPasswordRevealed ? "隐藏" : "显示";
            RegenPinBtn.Visibility = _state.IsHostRunning ? Visibility.Collapsed : Visibility.Visible;

            HeroHostPillBtn.Content = _state.IsHostRunning ? "● 被控运行中 · 点击关闭" : "⚡ 点击开启被控";
            HeroHostPillBtn.Style = (Style)FindResource(_state.IsHostRunning ? "GreenButtonStyle" : "PrimaryButtonStyle");
            HostHeroCard.BorderBrush = _state.IsHostRunning
                ? (SolidColorBrush)FindResource("OnlineGreen")
                : (SolidColorBrush)FindResource("CardBorder");
            HostStoppedActionRow.Visibility = _state.IsHostRunning ? Visibility.Collapsed : Visibility.Visible;
            HostRunningActionRow.Visibility = _state.IsHostRunning ? Visibility.Visible : Visibility.Collapsed;

            string coordText = _state.IsHostRunning
                ? _state.CoordStatusText
                : "开启后支持异地与局域网设备连入（输错5次自动封禁防爆破）";
            if (!string.IsNullOrEmpty(_state.HostLinkBadge))
                coordText += $" · {_state.HostLinkBadge}";
            HostCoordStatusLabel.Text = coordText;

            // Hero Card: Quick Connect
            if (!QuickTargetBox.IsKeyboardFocused && QuickTargetBox.Text != _state.QuickConnectTarget)
                QuickTargetBox.Text = _state.QuickConnectTarget;
            if (!QuickPasswordBox.IsKeyboardFocused && QuickPasswordBox.Text != _state.QuickConnectPassword)
                QuickPasswordBox.Text = _state.QuickConnectPassword;
            if (!QuickPortBox.IsKeyboardFocused && QuickPortBox.Text != _state.QuickConnectPort)
                QuickPortBox.Text = _state.QuickConnectPort;
            QuickBookPickerBtn.Visibility = _state.DeviceBook.Devices.Count > 0 ? Visibility.Visible : Visibility.Collapsed;

            RebuildLanDiscoveryStrip();
            RebuildActiveSessionsDockAndRecent();

            if (_state.SelectedTab == SidebarTab.DeviceList)
            {
                RebuildDeviceBookPage();
            }

            // Security & Quality Page
            Fps30Btn.Style = (Style)FindResource(_state.TargetFps == 30 ? "PrimaryButtonStyle" : "SecondaryButtonStyle");
            Fps45Btn.Style = (Style)FindResource(_state.TargetFps == 45 ? "PrimaryButtonStyle" : "SecondaryButtonStyle");
            Fps60Btn.Style = (Style)FindResource(_state.TargetFps == 60 ? "PrimaryButtonStyle" : "SecondaryButtonStyle");

            DynResCheck.IsChecked = _state.DynamicResolutionBoost;
            DebugHudCheck.IsChecked = _state.ShowDebugHud;
            RemoteAudioCheck.IsChecked = _state.RemoteAudioEnabled;
            MuteHostAudioCheck.IsChecked = _state.MuteHostAudioDuringRemote;
            MuteHostAudioCheck.IsEnabled = _state.RemoteAudioEnabled;
            ClipboardSyncCheck.IsChecked = _state.ClipboardSyncEnabled;
            NotifSyncCheck.IsChecked = _state.NotificationSyncEnabled;
            MapCtrlToCmdCheck.IsChecked = _state.MapCtrlToMacCommand;
            SilentClickCheck.IsChecked = _state.SilentClickMode;
            HoverCursorCheck.IsChecked = _state.HoverCursorSync;
            PreventSleepCheck.IsChecked = _state.PreventDisplaySleep;

            if (_state.IsRunningAsAdministrator)
            {
                AdminStatusText.Text = "✅  管理员窗口控制权限 (UIPI)：已处于管理员权限（可操控本机所有管理员窗口与系统工具）";
                AdminStatusText.Foreground = (SolidColorBrush)FindResource("OnlineGreen");
                RelaunchAdminBtn.Visibility = Visibility.Collapsed;
                HomeAdminBadge.Visibility = Visibility.Visible;
                HomeElevateBtn.Visibility = Visibility.Collapsed;
            }
            else
            {
                RelaunchAdminBtn.Visibility = Visibility.Visible;
                HomeAdminBadge.Visibility = Visibility.Collapsed;
                HomeElevateBtn.Visibility = Visibility.Visible;
            }

            RebuildTrustedPeersCard();

            // Network Page (sync only if not actively editing)
            if (!WanCoordBox.IsKeyboardFocused) WanCoordBox.Text = _state.WanCoordUrl;
            if (!WanRelayBox.IsKeyboardFocused) WanRelayBox.Text = _state.WanRelayUrl;
            if (!WanTokenBox.IsKeyboardFocused) WanTokenBox.Text = _state.WanRelayAuthToken;
            WanFallbackCheck.IsChecked = _state.WanEnablePublicFallback;
            WanInsecureCheck.IsChecked = _state.WanAllowInsecureTls;
        }
        finally
        {
            _syncingUi = false;
        }
    }

    private void ApplyNavButtonStyle(System.Windows.Controls.Button btn, bool active)
    {
        btn.Background = active
            ? (SolidColorBrush)FindResource("AccentSoftBg")
            : System.Windows.Media.Brushes.Transparent;
        btn.Foreground = active
            ? (SolidColorBrush)FindResource("AccentBrush")
            : (SolidColorBrush)FindResource("TextPrimary");
        btn.FontWeight = active ? FontWeights.SemiBold : FontWeights.Normal;
    }

    private void RebuildLanDiscoveryStrip()
    {
        LanPeersHostPanel.Children.Clear();
        if (_state.DiscoveredPeers.Count == 0)
        {
            LanDiscoverySection.Visibility = Visibility.Collapsed;
            return;
        }
        LanDiscoverySection.Visibility = Visibility.Visible;

        foreach (var peer in _state.DiscoveredPeers)
        {
            var card = new Border
            {
                Background = (SolidColorBrush)FindResource("CardBg"),
                BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(134, 239, 172)),
                BorderThickness = new Thickness(1),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(12, 8, 12, 8),
                Margin = new Thickness(0, 0, 10, 0)
            };

            var row = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
            row.Children.Add(new System.Windows.Shapes.Ellipse
            {
                Width = 8,
                Height = 8,
                Fill = (SolidColorBrush)FindResource("OnlineGreen"),
                VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 8, 0)
            });
            var info = new StackPanel { Margin = new Thickness(0, 0, 12, 0), VerticalAlignment = VerticalAlignment.Center };
            info.Children.Add(new TextBlock
            {
                Text = peer.DeviceName,
                FontSize = 12.5,
                FontWeight = FontWeights.SemiBold,
                Foreground = (SolidColorBrush)FindResource("TextPrimary")
            });
            info.Children.Add(new TextBlock
            {
                Text = $"{peer.PreferredIp}:{peer.Port}",
                FontSize = 10.5,
                FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                Foreground = (SolidColorBrush)FindResource("TextSecondary")
            });
            row.Children.Add(info);

            var connBtn = new System.Windows.Controls.Button
            {
                Content = "连接",
                Padding = new Thickness(10, 4, 10, 4),
                FontSize = 11.5,
                Style = (Style)FindResource("PrimaryButtonStyle")
            };
            var captured = peer;
            connBtn.Click += (_, _) => _state.ConnectDiscoveredPeer(captured, autoOpenDesktop: false);
            row.Children.Add(connBtn);

            card.Child = row;
            LanPeersHostPanel.Children.Add(card);
        }
    }

    private void RebuildActiveSessionsDockAndRecent()
    {
        ActiveSessionsCardsPanel.Children.Clear();
        RecentDevicesStripPanel.Children.Clear();

        if (_state.ConnectedSessions.Count > 0)
        {
            ActiveSessionsHomeSection.Visibility = Visibility.Visible;
            RecentDevicesHomeSection.Visibility = Visibility.Collapsed;
            ActiveSessionsHomeHeading.Text = $"当前并行操控中的设备 ({_state.ConnectedSessions.Count})";

            foreach (var sess in _state.ConnectedSessions)
            {
                ActiveSessionsCardsPanel.Children.Add(BuildActiveSessionQuickPanel(sess));
            }
        }
        else
        {
            ActiveSessionsHomeSection.Visibility = Visibility.Collapsed;
            if (_state.DeviceBook.Devices.Count > 0)
            {
                RecentDevicesHomeSection.Visibility = Visibility.Visible;
                ManageAllDevicesLinkBtn.Content = $"管理全部 ({_state.DeviceBook.Devices.Count})";

                foreach (var dev in _state.DeviceBook.Devices.Take(6))
                {
                    var presence = _state.DeviceBook.GetPresence(dev.Id);
                    var card = new Border
                    {
                        Background = (SolidColorBrush)FindResource("CardBg"),
                        BorderBrush = (SolidColorBrush)FindResource("CardBorder"),
                        BorderThickness = new Thickness(1),
                        CornerRadius = new CornerRadius(10),
                        Padding = new Thickness(12, 8, 12, 8),
                        Margin = new Thickness(0, 0, 10, 0)
                    };
                    var row = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
                    row.Children.Add(new System.Windows.Shapes.Ellipse
                    {
                        Width = 8,
                        Height = 8,
                        Fill = presence.IsOnline()
                            ? (SolidColorBrush)FindResource("OnlineGreen")
                            : new SolidColorBrush(System.Windows.Media.Color.FromRgb(148, 163, 184)),
                        VerticalAlignment = VerticalAlignment.Center,
                        Margin = new Thickness(0, 0, 8, 0)
                    });

                    var txtCol = new StackPanel { Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center };
                    txtCol.Children.Add(new TextBlock { Text = dev.Alias, FontSize = 12.5, FontWeight = FontWeights.SemiBold });
                    txtCol.Children.Add(new TextBlock
                    {
                        Text = dev.FormattedTarget,
                        FontSize = 10.5,
                        FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                        Foreground = (SolidColorBrush)FindResource("TextSecondary")
                    });
                    row.Children.Add(txtCol);

                    var capturedDev = dev;
                    var btnApps = new System.Windows.Controls.Button
                    {
                        Content = "一键连",
                        Padding = new Thickness(10, 4, 10, 4),
                        FontSize = 11.5,
                        Margin = new Thickness(0, 0, 6, 0),
                        Style = (Style)FindResource("PrimaryButtonStyle")
                    };
                    btnApps.Click += (_, _) => _state.ConnectDevice(capturedDev, autoOpenDesktop: false);

                    var btnDesk = new System.Windows.Controls.Button
                    {
                        Content = "桌面",
                        Padding = new Thickness(8, 4, 8, 4),
                        FontSize = 11.5,
                        Style = (Style)FindResource("SecondaryButtonStyle")
                    };
                    btnDesk.Click += (_, _) => _state.ConnectDevice(capturedDev, autoOpenDesktop: true);

                    row.Children.Add(btnApps);
                    row.Children.Add(btnDesk);
                    card.Child = row;
                    RecentDevicesStripPanel.Children.Add(card);
                }
            }
            else
            {
                RecentDevicesHomeSection.Visibility = Visibility.Collapsed;
            }
        }
    }

    private UIElement BuildActiveSessionQuickPanel(RemotePeerSession sess)
    {
        var card = new Border
        {
            Background = (SolidColorBrush)FindResource("CardBg"),
            BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(134, 239, 172)),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(14),
            Margin = new Thickness(0, 0, 0, 10)
        };

        var col = new StackPanel();
        var topRow = new Grid();
        topRow.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        topRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        var leftStack = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        leftStack.Children.Add(new System.Windows.Shapes.Ellipse
        {
            Width = 9,
            Height = 9,
            Fill = sess.IsConnected ? (SolidColorBrush)FindResource("OnlineGreen") : (SolidColorBrush)FindResource("WarnAmber"),
            Margin = new Thickness(0, 0, 8, 0)
        });
        leftStack.Children.Add(new TextBlock
        {
            Text = sess.Alias,
            FontSize = 14,
            FontWeight = FontWeights.Bold,
            Margin = new Thickness(0, 0, 10, 0)
        });
        if (!string.IsNullOrEmpty(sess.LinkBadge))
        {
            var badge = new Border
            {
                Background = (SolidColorBrush)FindResource("OnlineGreenSoft"),
                CornerRadius = new CornerRadius(10),
                Padding = new Thickness(8, 2, 8, 2),
                Margin = new Thickness(0, 0, 10, 0),
                Child = new TextBlock
                {
                    Text = sess.LinkBadge,
                    FontSize = 11,
                    FontWeight = FontWeights.SemiBold,
                    Foreground = (SolidColorBrush)FindResource("OnlineGreen")
                }
            };
            leftStack.Children.Add(badge);
        }
        leftStack.Children.Add(new TextBlock
        {
            Text = $"已打开 {sess.OpenWindowCount} 个窗口",
            FontSize = 11.5,
            Foreground = (SolidColorBrush)FindResource("TextSecondary"),
            VerticalAlignment = VerticalAlignment.Center
        });
        Grid.SetColumn(leftStack, 0);
        topRow.Children.Add(leftStack);

        var rightStack = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, HorizontalAlignment = System.Windows.HorizontalAlignment.Right };
        var btnAudio = new System.Windows.Controls.Button
        {
            Content = sess.IsAudioMuted ? "🔇 已静音" : "🔊 远端声音",
            ToolTip = "开关本机接收远端电脑的声音",
            Padding = new Thickness(9, 4, 9, 4),
            FontSize = 11.5,
            Margin = new Thickness(0, 0, 8, 0),
            IsEnabled = sess.IsConnected,
            Style = (Style)FindResource("SecondaryButtonStyle")
        };
        btnAudio.Click += (_, _) => sess.IsAudioMuted = !sess.IsAudioMuted;

        var chkMuteHost = new System.Windows.Controls.CheckBox
        {
            Content = "被控端静音",
            ToolTip = "开启后远控播放声音时被控端电脑扬声器自动静音，断开后自动恢复",
            IsChecked = sess.MuteHostSpeakers,
            IsEnabled = sess.IsConnected && !sess.IsAudioMuted,
            VerticalAlignment = VerticalAlignment.Center,
            FontSize = 11.5,
            Margin = new Thickness(0, 0, 10, 0)
        };
        chkMuteHost.Checked += (_, _) => sess.MuteHostSpeakers = true;
        chkMuteHost.Unchecked += (_, _) => sess.MuteHostSpeakers = false;

        var btnRefresh = new System.Windows.Controls.Button
        {
            Content = "刷新应用",
            Padding = new Thickness(10, 4, 10, 4),
            FontSize = 11.5,
            Margin = new Thickness(0, 0, 6, 0),
            IsEnabled = sess.IsConnected,
            Style = (Style)FindResource("SecondaryButtonStyle")
        };
        btnRefresh.Click += (_, _) => sess.RefreshApps();

        var btnDesk = new System.Windows.Controls.Button
        {
            Content = "整屏桌面",
            Padding = new Thickness(10, 4, 10, 4),
            FontSize = 11.5,
            Margin = new Thickness(0, 0, 6, 0),
            IsEnabled = sess.IsConnected,
            Style = (Style)FindResource("SecondaryButtonStyle")
        };
        btnDesk.Click += (_, _) => sess.OpenFullDesktop();

        var btnDisc = new System.Windows.Controls.Button
        {
            Content = "断开",
            Padding = new Thickness(10, 4, 10, 4),
            FontSize = 11.5,
            Style = (Style)FindResource("DangerButtonStyle")
        };
        string sid = sess.Id;
        btnDisc.Click += (_, _) => _state.DisconnectSession(sid);

        rightStack.Children.Add(btnAudio);
        rightStack.Children.Add(chkMuteHost);
        rightStack.Children.Add(btnRefresh);
        rightStack.Children.Add(btnDesk);
        rightStack.Children.Add(btnDisc);
        Grid.SetColumn(rightStack, 1);
        topRow.Children.Add(rightStack);
        col.Children.Add(topRow);

        if (sess.IsConnecting)
        {
            col.Children.Add(new TextBlock
            {
                Text = $"⏳ {sess.StatusMessage}",
                FontSize = 12,
                Foreground = (SolidColorBrush)FindResource("TextSecondary"),
                Margin = new Thickness(0, 10, 0, 0)
            });
        }
        else if (sess.RemoteApps.Count > 0)
        {
            var scroller = new ScrollViewer
            {
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Margin = new Thickness(0, 10, 0, 0)
            };
            UiAssist.SetHorizontalWheelScroll(scroller, true);
            var appRow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
            foreach (var app in sess.RemoteApps)
            {
                var chip = new System.Windows.Controls.Button
                {
                    Margin = new Thickness(0, 0, 8, 2),
                    Padding = new Thickness(11, 5, 11, 5),
                    Style = (Style)FindResource("SecondaryButtonStyle"),
                    Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(240, 249, 255)),
                    BorderBrush = new SolidColorBrush(System.Windows.Media.Color.FromRgb(186, 230, 253)),
                    BorderThickness = new Thickness(1)
                };
                var chipContent = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
                if (app.DisplayIcon != null)
                {
                    var img = new System.Windows.Controls.Image
                    {
                        Source = app.DisplayIcon,
                        Width = 20,
                        Height = 20,
                        Margin = new Thickness(0, 0, 6, 0)
                    };
                    RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.HighQuality);
                    chipContent.Children.Add(img);
                }
                chipContent.Children.Add(new TextBlock
                {
                    Text = app.Name,
                    FontSize = 12,
                    FontWeight = FontWeights.Medium,
                    VerticalAlignment = VerticalAlignment.Center
                });
                chip.Content = chipContent;
                var capturedApp = app;
                chip.Click += (_, _) => sess.OpenApp(capturedApp);
                appRow.Children.Add(chip);
            }
            scroller.Content = appRow;
            col.Children.Add(scroller);
        }

        card.Child = col;
        return card;
    }

    private void RebuildDeviceBookPage()
    {
        // 1. Group Filter Pills
        GroupFilterPillsPanel.Children.Clear();
        var groups = new List<string> { "全部", "星标", "已连接" };
        var customGroups = _state.DeviceBook.Devices.Select(d => d.GroupTag)
            .Concat(DeviceBookStore.DefaultGroups)
            .Where(g => !string.IsNullOrWhiteSpace(g))
            .Distinct(StringComparer.Ordinal);
        foreach (var g in customGroups)
        {
            if (!groups.Contains(g)) groups.Add(g);
        }

        foreach (var grp in groups)
        {
            bool active = _selectedGroupFilter == grp;
            var pill = new System.Windows.Controls.Button
            {
                Content = grp,
                Margin = new Thickness(0, 0, 6, 0),
                Padding = new Thickness(12, 5, 12, 5),
                FontSize = 12,
                Style = (Style)FindResource(active ? "PrimaryButtonStyle" : "SecondaryButtonStyle")
            };
            string capturedGrp = grp;
            pill.Click += (_, _) =>
            {
                _selectedGroupFilter = capturedGrp;
                RebuildDeviceBookPage();
            };
            GroupFilterPillsPanel.Children.Add(pill);
        }

        // 2. Filtered Device Cards
        string q = (DeviceSearchBox.Text ?? "").Trim().ToLowerInvariant();
        string qNoSpace = new string(q.Where(c => !char.IsWhiteSpace(c)).ToArray());

        var filtered = _state.DeviceBook.Devices.Where(dev =>
        {
            bool matchesGroup = _selectedGroupFilter switch
            {
                "全部" => true,
                "星标" => dev.IsFavorite,
                "已连接" => _state.GetSession(dev.Id)?.IsConnected == true,
                _ => dev.GroupTag == _selectedGroupFilter
            };
            if (!matchesGroup) return false;
            if (string.IsNullOrEmpty(q)) return true;
            return dev.Alias.ToLowerInvariant().Contains(q) ||
                   dev.Target.ToLowerInvariant().Contains(q) ||
                   dev.Target.ToLowerInvariant().Contains(qNoSpace) ||
                   dev.FormattedTarget.ToLowerInvariant().Contains(q) ||
                   dev.Notes.ToLowerInvariant().Contains(q) ||
                   dev.GroupTag.ToLowerInvariant().Contains(q);
        }).ToList();

        DevicesWrapPanel.Children.Clear();
        if (filtered.Count == 0)
        {
            EmptyDevicesPlaceholder.Visibility = Visibility.Visible;
            DevicesGridScroller.Visibility = Visibility.Collapsed;
            EmptyDevicesTitle.Text = _state.DeviceBook.Devices.Count == 0 ? "尚未添加受控设备" : "没有匹配的设备";
        }
        else
        {
            EmptyDevicesPlaceholder.Visibility = Visibility.Collapsed;
            DevicesGridScroller.Visibility = Visibility.Visible;
            foreach (var dev in filtered)
            {
                DevicesWrapPanel.Children.Add(BuildManagedDeviceCard(dev));
            }
        }

        // 3. Bottom Multi-Host App Launcher Drawer
        if (_state.ConnectedSessions.Count == 0)
        {
            DrawerSplitterRow.Height = new GridLength(0);
            DrawerContentRow.Height = new GridLength(0);
        }
        else
        {
            DrawerSplitterRow.Height = new GridLength(8);
            DrawerContentRow.Height = _isDrawerCollapsed ? new GridLength(42) : new GridLength(Math.Max(140, _state.DrawerHeight));
            DrawerCollapseBtn.Content = _isDrawerCollapsed ? "▴" : "▾";
            RebuildDrawerContents();
        }
    }

    private UIElement BuildManagedDeviceCard(ManagedRemoteDevice dev)
    {
        var sess = _state.GetSession(dev.Id);
        bool isConn = sess?.IsConnected == true;
        bool isConnecting = sess?.IsConnecting == true;
        bool isSelected = _state.SelectedSessionId == dev.Id && isConn;
        var onlineState = _state.DeviceBook.GetPresence(dev.Id);

        var card = new Border
        {
            Width = 315,
            Margin = new Thickness(0, 0, 14, 14),
            Padding = new Thickness(14),
            CornerRadius = new CornerRadius(12),
            Background = (SolidColorBrush)FindResource("CardBg"),
            BorderThickness = new Thickness(isSelected ? 1.8 : 1.0),
            BorderBrush = isConn
                ? (SolidColorBrush)FindResource(isSelected ? "AccentBrush" : "OnlineGreen")
                : (SolidColorBrush)FindResource("CardBorder")
        };

        var col = new StackPanel();
        var top = new Grid();
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        top.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        var titleCol = new StackPanel();
        var aliasRow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal };
        aliasRow.Children.Add(new TextBlock
        {
            Text = dev.Alias,
            FontSize = 14.5,
            FontWeight = FontWeights.Bold,
            MaxWidth = 175,
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        aliasRow.Children.Add(new Border
        {
            Margin = new Thickness(6, 0, 0, 0),
            Padding = new Thickness(6, 1, 6, 1),
            CornerRadius = new CornerRadius(8),
            Background = new SolidColorBrush(System.Windows.Media.Color.FromRgb(226, 232, 240)),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock { Text = dev.GroupTag, FontSize = 10.5, Foreground = (SolidColorBrush)FindResource("TextSecondary") }
        });
        titleCol.Children.Add(aliasRow);
        titleCol.Children.Add(new TextBlock
        {
            Text = dev.FormattedTarget,
            FontSize = 11.5,
            FontFamily = new System.Windows.Media.FontFamily("Consolas"),
            Foreground = (SolidColorBrush)FindResource("TextSecondary"),
            Margin = new Thickness(0, 2, 0, 0),
            TextTrimming = TextTrimming.CharacterEllipsis
        });
        Grid.SetColumn(titleCol, 0);
        top.Children.Add(titleCol);

        var iconsRow = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Top };
        var starBtn = new System.Windows.Controls.Button
        {
            Content = dev.IsFavorite ? "★" : "☆",
            ToolTip = dev.IsFavorite ? "取消星标置顶" : "星标置顶",
            Foreground = dev.IsFavorite ? new SolidColorBrush(System.Windows.Media.Color.FromRgb(234, 179, 8)) : (SolidColorBrush)FindResource("TextSecondary"),
            Style = (Style)FindResource("IconActionButtonStyle"),
            FontSize = 14.5,
            Margin = new Thickness(0, -2, 2, 0)
        };
        starBtn.Click += (_, _) => _state.DeviceBook.ToggleFavorite(dev.Id);

        var delBtn = new System.Windows.Controls.Button
        {
            Content = "✕",
            ToolTip = "从设备列表移除",
            Style = (Style)FindResource("IconActionButtonStyle"),
            FontSize = 11.5,
            Foreground = (SolidColorBrush)FindResource("TextSecondary"),
            Margin = new Thickness(0, -1, 0, 0)
        };
        delBtn.Click += (_, _) => _state.DeleteManagedDevice(dev);

        iconsRow.Children.Add(starBtn);
        iconsRow.Children.Add(delBtn);
        Grid.SetColumn(iconsRow, 1);
        top.Children.Add(iconsRow);
        col.Children.Add(top);

        // Status row
        string statusStr = isConn
            ? $"● 操控中 · {(string.IsNullOrEmpty(sess?.LinkBadge) ? "已连接" : sess!.LinkBadge)}"
            : (isConnecting
                ? "● 正在连接穿透中..."
                : $"● {onlineState.GetLabel()}");
        if (!string.IsNullOrEmpty(dev.SavedPassword) && !isConn)
            statusStr += " · 已记住密码";

        col.Children.Add(new TextBlock
        {
            Text = statusStr,
            FontSize = 11.5,
            Foreground = isConn || onlineState.IsOnline()
                ? (SolidColorBrush)FindResource("OnlineGreen")
                : (SolidColorBrush)FindResource("TextSecondary"),
            Margin = new Thickness(0, 10, 0, 10),
            TextTrimming = TextTrimming.CharacterEllipsis
        });

        // Action Buttons
        var actions = new Grid();
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(6) });
        actions.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

        if (isConn)
        {
            var btnPick = new System.Windows.Controls.Button
            {
                Content = $"挑应用 ({sess?.RemoteApps.Count ?? 0})",
                Padding = new Thickness(8, 6, 8, 6),
                FontSize = 12,
                Style = (Style)FindResource("PrimaryButtonStyle")
            };
            btnPick.Click += (_, _) =>
            {
                _state.SelectedSessionId = dev.Id;
                _isDrawerCollapsed = false;
                RebuildDeviceBookPage();
            };

            var btnDesk = new System.Windows.Controls.Button
            {
                Content = "远程桌面",
                Padding = new Thickness(10, 6, 10, 6),
                FontSize = 12,
                Style = (Style)FindResource("SecondaryButtonStyle")
            };
            btnDesk.Click += (_, _) => sess?.OpenFullDesktop();

            var btnDisc = new System.Windows.Controls.Button
            {
                Content = "断开",
                Padding = new Thickness(10, 6, 10, 6),
                FontSize = 12,
                Style = (Style)FindResource("DangerButtonStyle")
            };
            btnDisc.Click += (_, _) => _state.DisconnectSession(dev.Id);

            Grid.SetColumn(btnPick, 0);
            Grid.SetColumn(btnDesk, 2);
            Grid.SetColumn(btnDisc, 4);
            actions.Children.Add(btnPick);
            actions.Children.Add(btnDesk);
            actions.Children.Add(btnDisc);
        }
        else
        {
            var btnConn = new System.Windows.Controls.Button
            {
                Content = isConnecting ? "重连" : "⚡ 一键连接",
                Padding = new Thickness(8, 6, 8, 6),
                FontSize = 12,
                Style = (Style)FindResource("PrimaryButtonStyle")
            };
            btnConn.Click += (_, _) => _state.ConnectDevice(dev, autoOpenDesktop: false);

            var btnDesk = new System.Windows.Controls.Button
            {
                Content = "远程桌面",
                Padding = new Thickness(10, 6, 10, 6),
                FontSize = 12,
                Style = (Style)FindResource("SecondaryButtonStyle")
            };
            btnDesk.Click += (_, _) => _state.ConnectDevice(dev, autoOpenDesktop: true);

            var btnEdit = new System.Windows.Controls.Button
            {
                Content = "编辑",
                Padding = new Thickness(10, 6, 10, 6),
                FontSize = 12,
                Style = (Style)FindResource("SecondaryButtonStyle")
            };
            btnEdit.Click += (_, _) => OpenEditDeviceDialog(dev);

            Grid.SetColumn(btnConn, 0);
            Grid.SetColumn(btnDesk, 2);
            Grid.SetColumn(btnEdit, 4);
            actions.Children.Add(btnConn);
            actions.Children.Add(btnDesk);
            actions.Children.Add(btnEdit);
        }

        col.Children.Add(actions);
        card.Child = col;
        return card;
    }

    private void RebuildDrawerContents()
    {
        DrawerSessionTabsPanel.Children.Clear();
        DrawerAppsWrapPanel.Children.Clear();

        var activeSess = _state.ConnectedSessions.FirstOrDefault(s => s.Id == _state.SelectedSessionId)
                         ?? _state.ConnectedSessions.FirstOrDefault();

        foreach (var sess in _state.ConnectedSessions)
        {
            bool selected = activeSess?.Id == sess.Id;
            var tab = new System.Windows.Controls.Button
            {
                Content = string.IsNullOrEmpty(sess.LinkBadge) ? sess.Alias : $"{sess.Alias} · {sess.LinkBadge}",
                Margin = new Thickness(0, 0, 6, 0),
                Padding = new Thickness(11, 4, 11, 4),
                FontSize = 11.5,
                Style = (Style)FindResource(selected ? "PrimaryButtonStyle" : "SecondaryButtonStyle")
            };
            string sid = sess.Id;
            tab.Click += (_, _) => _state.SelectedSessionId = sid;
            DrawerSessionTabsPanel.Children.Add(tab);
        }

        if (_isDrawerCollapsed || activeSess == null)
            return;

        if (activeSess.IsConnecting)
        {
            DrawerAppsWrapPanel.Children.Add(new TextBlock
            {
                Text = $"正在连接 {activeSess.Alias}：{activeSess.StatusMessage}",
                FontSize = 12.5,
                Foreground = (SolidColorBrush)FindResource("TextSecondary"),
                Margin = new Thickness(8)
            });
            return;
        }

        foreach (var app in activeSess.RemoteApps)
        {
            var appCard = new Border
            {
                Width = 240,
                Margin = new Thickness(0, 0, 10, 10),
                Padding = new Thickness(10, 7, 10, 7),
                CornerRadius = new CornerRadius(8),
                Background = (SolidColorBrush)FindResource("SubtleSurfaceBg"),
                BorderBrush = (SolidColorBrush)FindResource("CardBorder"),
                BorderThickness = new Thickness(1)
            };
            var row = new Grid();
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });

            if (app.DisplayIcon != null)
            {
                var img = new System.Windows.Controls.Image
                {
                    Source = app.DisplayIcon,
                    Width = 28,
                    Height = 28,
                    Margin = new Thickness(0, 0, 8, 0)
                };
                RenderOptions.SetBitmapScalingMode(img, BitmapScalingMode.HighQuality);
                Grid.SetColumn(img, 0);
                row.Children.Add(img);
            }

            var txt = new StackPanel { VerticalAlignment = VerticalAlignment.Center };
            txt.Children.Add(new TextBlock { Text = app.Name, FontSize = 12.5, FontWeight = FontWeights.SemiBold, TextTrimming = TextTrimming.CharacterEllipsis });
            txt.Children.Add(new TextBlock { Text = $"{app.WindowCount} 个窗口", FontSize = 10.5, Foreground = (SolidColorBrush)FindResource("TextSecondary") });
            Grid.SetColumn(txt, 1);
            row.Children.Add(txt);

            var openBtn = new System.Windows.Controls.Button
            {
                Content = "打开",
                Padding = new Thickness(10, 4, 10, 4),
                FontSize = 11.5,
                VerticalAlignment = VerticalAlignment.Center,
                Style = (Style)FindResource("PrimaryButtonStyle")
            };
            var capturedApp = app;
            openBtn.Click += (_, _) => activeSess.OpenApp(capturedApp);
            Grid.SetColumn(openBtn, 2);
            row.Children.Add(openBtn);

            appCard.Child = row;
            DrawerAppsWrapPanel.Children.Add(appCard);
        }
    }

    private void RebuildTrustedPeersCard()
    {
        TrustedPeersListPanel.Children.Clear();
        if (_state.TrustedPeers.Count == 0)
        {
            TrustedPeersCard.Visibility = Visibility.Collapsed;
            return;
        }
        TrustedPeersCard.Visibility = Visibility.Visible;
        TrustedPeersHeading.Text = $"已信任免密证书设备白名单 ({_state.TrustedPeers.Count})";

        foreach (var tp in _state.TrustedPeers)
        {
            var row = new Grid { Margin = new Thickness(0, 4, 0, 4) };
            var left = new StackPanel { Orientation = System.Windows.Controls.Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            left.Children.Add(new TextBlock { Text = $"✅  {tp.DeviceName}", FontSize = 12.5, FontWeight = FontWeights.SemiBold });
            if (!string.IsNullOrEmpty(tp.DeviceCode))
            {
                left.Children.Add(new TextBlock
                {
                    Text = $"  ({tp.FormattedCode})",
                    FontSize = 11.5,
                    FontFamily = new System.Windows.Media.FontFamily("Consolas"),
                    Foreground = (SolidColorBrush)FindResource("TextSecondary")
                });
            }
            row.Children.Add(left);

            var revokeBtn = new System.Windows.Controls.Button
            {
                Content = "撤销免密授权",
                HorizontalAlignment = System.Windows.HorizontalAlignment.Right,
                Padding = new Thickness(10, 3, 10, 3),
                FontSize = 11,
                Style = (Style)FindResource("SecondaryButtonStyle")
            };
            var capturedTp = tp;
            revokeBtn.Click += (_, _) => _state.RevokeTrustedPeer(capturedTp);
            row.Children.Add(revokeBtn);

            TrustedPeersListPanel.Children.Add(row);
        }
    }

    // ========================================================================
    // Logs Live Updating
    // ========================================================================

    private void OnLogEntriesChanged(object? sender, NotifyCollectionChangedEventArgs e)
    {
        if (e.Action == NotifyCollectionChangedAction.Reset)
        {
            LogsListBox.Items.Clear();
            return;
        }
        if (e.NewItems != null)
        {
            foreach (OpenUULogEntry entry in e.NewItems)
            {
                if (entry.Level >= _state.SelectedLogLevel)
                {
                    LogsListBox.Items.Add(CreateLogItem(entry));
                    while (LogsListBox.Items.Count > 350)
                        LogsListBox.Items.RemoveAt(0);
                }
            }
            if (LogsListBox.Items.Count > 0)
                LogsListBox.ScrollIntoView(LogsListBox.Items[^1]);
        }
    }

    private void RefreshLogsBox()
    {
        LogsListBox.Items.Clear();
        foreach (var entry in _state.LogEntries.Where(e => e.Level >= _state.SelectedLogLevel))
        {
            LogsListBox.Items.Add(CreateLogItem(entry));
        }
        if (LogsListBox.Items.Count > 0)
            LogsListBox.ScrollIntoView(LogsListBox.Items[^1]);
    }

    private static ListBoxItem CreateLogItem(OpenUULogEntry entry)
    {
        var color = entry.Level switch
        {
            OpenUULogLevel.Error => System.Windows.Media.Color.FromRgb(248, 113, 113),
            OpenUULogLevel.Warn  => System.Windows.Media.Color.FromRgb(251, 191, 36),
            OpenUULogLevel.Debug => System.Windows.Media.Color.FromRgb(148, 163, 184),
            _                    => System.Windows.Media.Color.FromRgb(226, 232, 240)
        };
        return new ListBoxItem
        {
            Content = entry.Formatted,
            Foreground = new SolidColorBrush(color),
            Padding = new Thickness(2, 1, 2, 1)
        };
    }

    // ========================================================================
    // UI Event Handlers
    // ========================================================================

    private void DraggableTopRegion_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2)
        {
            MaxRestoreWindow_Click(sender, e);
            return;
        }
        if (e.ButtonState == MouseButtonState.Pressed)
        {
            try { DragMove(); } catch { }
        }
    }

    private void MinimizeWindow_Click(object sender, RoutedEventArgs e) => WindowState = WindowState.Minimized;

    private void MaxRestoreWindow_Click(object sender, RoutedEventArgs e)
    {
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;
        UpdateMaxRestoreIcon();
    }

    private void UpdateMaxRestoreIcon()
    {
        MaxRestoreIconPath.Data = Geometry.Parse(
            WindowState == WindowState.Maximized
                ? "M 2.5,0.5 H 9.5 V 7.5 M 0.5,2.5 H 7.5 V 9.5 H 0.5 Z"
                : "M 0.5,0.5 H 9.5 V 9.5 H 0.5 Z"
        );
    }

    private void CloseWindow_Click(object sender, RoutedEventArgs e) => Close();

    private void NavRemoteBtn_Click(object sender, RoutedEventArgs e) => _state.SelectedTab = SidebarTab.RemoteHome;
    private void NavDevicesBtn_Click(object sender, RoutedEventArgs e) => _state.SelectedTab = SidebarTab.DeviceList;
    private void NavSecurityBtn_Click(object sender, RoutedEventArgs e) => _state.SelectedTab = SidebarTab.SecurityQuality;
    private void NavNetworkBtn_Click(object sender, RoutedEventArgs e) => _state.SelectedTab = SidebarTab.NetworkLogs;

    private void ToggleHostBtn_Click(object sender, RoutedEventArgs e) => ToggleHostWithAntiFraudCheck();
    private void StartHostBtn_Click(object sender, RoutedEventArgs e) => StartHostWithAntiFraudCheck();
    private void DisconnectAllBtn_Click(object sender, RoutedEventArgs e) => _state.DisconnectAllClientSessions();

    public void ToggleHostWithAntiFraudCheck()
    {
        if (_state.IsHostRunning)
            _state.StopHostService();
        else
            StartHostWithAntiFraudCheck();
    }

    public void StartHostWithAntiFraudCheck()
    {
        if (_state.IsHostRunning || _isShowingAntiFraudDialog)
            return;

        if (!_state.SuppressAntiFraudWarning)
        {
            _isShowingAntiFraudDialog = true;
            try
            {
                var dlg = new AntiFraudWarningDialog();
                if (IsVisible && WindowState != WindowState.Minimized)
                {
                    dlg.Owner = this;
                    dlg.WindowStartupLocation = WindowStartupLocation.CenterOwner;
                }
                else
                {
                    dlg.WindowStartupLocation = WindowStartupLocation.CenterScreen;
                    dlg.Topmost = true;
                }

                if (dlg.ShowDialog() != true)
                {
                    _state.StatusLog = "已取消开启本机被控";
                    return;
                }

                if (dlg.DontShowAgain)
                {
                    _state.SuppressAntiFraudWarning = true;
                }
            }
            finally
            {
                _isShowingAntiFraudDialog = false;
            }
        }

        _state.StartHost();
    }

    private void CopyMyCodeBtn_Click(object sender, RoutedEventArgs e) => _state.CopyMyDeviceCode();
    private void CopyInviteBtn_Click(object sender, RoutedEventArgs e) => _state.CopyInvitationBundle();
    private void CopyTicketBtn_Click(object sender, RoutedEventArgs e) => _state.CopyMyHostTicket();

    private void HostPinBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_syncingUi) _state.HostPin = HostPinBox.Text;
    }

    private void TogglePinEyeBtn_Click(object sender, RoutedEventArgs e)
        => _state.IsHostPasswordRevealed = !_state.IsHostPasswordRevealed;

    private void RegenPinBtn_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        var item6 = new MenuItem { Header = "刷新 6 位数字验证码" };
        item6.Click += (_, _) => _state.RegenerateHostPin(strong: false);
        var item8 = new MenuItem { Header = "生成 8 位高强度密码（跨网推荐）" };
        item8.Click += (_, _) => _state.RegenerateHostPin(strong: true);
        menu.Items.Add(item6);
        menu.Items.Add(item8);
        menu.PlacementTarget = RegenPinBtn;
        menu.IsOpen = true;
    }

    private void QuickBookPickerBtn_Click(object sender, RoutedEventArgs e)
    {
        var menu = new ContextMenu();
        foreach (var dev in _state.DeviceBook.Devices)
        {
            var mi = new MenuItem { Header = $"{dev.Alias} ({dev.FormattedTarget})" };
            var captured = dev;
            mi.Click += (_, _) =>
            {
                _state.QuickConnectTarget = DeviceCodeFormatter.FormatInput(captured.Target);
                _state.QuickConnectPort = captured.Port.ToString();
                _state.QuickConnectPassword = captured.SavedPassword;
                SyncAllFromState();
            };
            menu.Items.Add(mi);
        }
        menu.PlacementTarget = QuickBookPickerBtn;
        menu.IsOpen = true;
    }

    private void QuickPasswordBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_syncingUi) _state.QuickConnectPassword = QuickPasswordBox.Text;
    }

    private void QuickPortBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (!_syncingUi) _state.QuickConnectPort = QuickPortBox.Text;
    }

    private void QuickConnectAppsBtn_Click(object sender, RoutedEventArgs e)
    {
        _state.QuickConnectTarget = QuickTargetBox.Text;
        _state.QuickConnectPassword = QuickPasswordBox.Text;
        _state.QuickConnectPort = QuickPortBox.Text;
        _state.ConnectFromQuickInput(autoOpenDesktop: false);
    }

    private void QuickConnectDesktopBtn_Click(object sender, RoutedEventArgs e)
    {
        _state.QuickConnectTarget = QuickTargetBox.Text;
        _state.QuickConnectPassword = QuickPasswordBox.Text;
        _state.QuickConnectPort = QuickPortBox.Text;
        _state.ConnectFromQuickInput(autoOpenDesktop: true);
    }

    private void AddDeviceBtn_Click(object sender, RoutedEventArgs e)
    {
        var dlg = new DeviceEditorDialog(null) { Owner = this };
        if (dlg.ShowDialog() == true)
        {
            _state.DeviceBook.AddOrUpdateDevice(
                alias: dlg.ResultAlias,
                target: dlg.ResultTarget,
                port: dlg.ResultPort,
                savedPassword: dlg.ResultPassword,
                groupTag: dlg.ResultGroup,
                isFavorite: dlg.ResultFavorite,
                notes: dlg.ResultNotes
            );
            _state.ProbeAllSavedDevicesNow();
        }
    }

    private void OpenEditDeviceDialog(ManagedRemoteDevice dev)
    {
        var dlg = new DeviceEditorDialog(dev) { Owner = this };
        if (dlg.ShowDialog() == true)
        {
            var saved = _state.DeviceBook.AddOrUpdateDevice(
                id: dev.Id,
                alias: dlg.ResultAlias,
                target: dlg.ResultTarget,
                port: dlg.ResultPort,
                savedPassword: dlg.ResultPassword,
                groupTag: dlg.ResultGroup,
                isFavorite: dlg.ResultFavorite,
                notes: dlg.ResultNotes
            );
            if (_state.GetSession(dev.Id) is { } s)
            {
                s.Alias = saved.Alias;
                s.Target = saved.Target;
                s.Port = saved.Port;
            }
            _state.ProbeAllSavedDevicesNow();
        }
    }

    private void DeviceSearchBox_TextChanged(object sender, TextChangedEventArgs e)
    {
        if (_syncingUi || !IsInitialized) return;
        RebuildDeviceBookPage();
    }
    private void RefreshOnlineBtn_Click(object sender, RoutedEventArgs e) => _state.ProbeAllSavedDevicesNow();

    private void DrawerRefreshAppsBtn_Click(object sender, RoutedEventArgs e)
    {
        var active = _state.ConnectedSessions.FirstOrDefault(s => s.Id == _state.SelectedSessionId)
                     ?? _state.ConnectedSessions.FirstOrDefault();
        active?.RefreshApps();
    }

    private void DrawerCollapseBtn_Click(object sender, RoutedEventArgs e)
    {
        _isDrawerCollapsed = !_isDrawerCollapsed;
        RebuildDeviceBookPage();
    }

    private void Fps30Btn_Click(object sender, RoutedEventArgs e) => _state.TargetFps = 30;
    private void Fps45Btn_Click(object sender, RoutedEventArgs e) => _state.TargetFps = 45;
    private void Fps60Btn_Click(object sender, RoutedEventArgs e) => _state.TargetFps = 60;

    private void QualityCheck_Changed(object sender, RoutedEventArgs e)
    {
        if (_syncingUi || !IsInitialized) return;
        _state.DynamicResolutionBoost = DynResCheck.IsChecked == true;
        _state.ShowDebugHud = DebugHudCheck.IsChecked == true;
        _state.RemoteAudioEnabled = RemoteAudioCheck.IsChecked == true;
        _state.MuteHostAudioDuringRemote = MuteHostAudioCheck.IsChecked == true;
        MuteHostAudioCheck.IsEnabled = _state.RemoteAudioEnabled;
        _state.ClipboardSyncEnabled = ClipboardSyncCheck.IsChecked == true;
        _state.NotificationSyncEnabled = NotifSyncCheck.IsChecked == true;
        _state.MapCtrlToMacCommand = MapCtrlToCmdCheck.IsChecked == true;
        _state.SilentClickMode = SilentClickCheck.IsChecked == true;
        _state.HoverCursorSync = HoverCursorCheck.IsChecked == true;
        _state.PreventDisplaySleep = PreventSleepCheck.IsChecked == true;
    }

    private void RelaunchAdminBtn_Click(object sender, RoutedEventArgs e) => _state.RelaunchAsAdministrator();

    private void ResetPublicWanBtn_Click(object sender, RoutedEventArgs e)
    {
        _state.WanCoordUrl = "https://openuu.1kb.ren";
        _state.WanRelayUrl = "https://openuu-relay.1kb.ren";
        _state.WanRelayAuthToken = AppState.DefaultRelayToken;
        _state.WanEnablePublicFallback = true;
        _state.WanAllowInsecureTls = false;
        _state.SaveWanSettings();
        SyncAllFromState();
    }

    private void SaveWanBtn_Click(object sender, RoutedEventArgs e)
    {
        _state.WanCoordUrl = WanCoordBox.Text.Trim();
        _state.WanRelayUrl = WanRelayBox.Text.Trim();
        _state.WanRelayAuthToken = WanTokenBox.Text.Trim();
        _state.WanEnablePublicFallback = WanFallbackCheck.IsChecked == true;
        _state.WanAllowInsecureTls = WanInsecureCheck.IsChecked == true;
        _state.SaveWanSettings();
    }

    private void CopyDeployPromptOnlyBtn_Click(object sender, RoutedEventArgs e) => CopyDeployPrompt(openGithub: false);
    private void CopyDeployPromptOpenGithubBtn_Click(object sender, RoutedEventArgs e) => CopyDeployPrompt(openGithub: true);

    private void CopyDeployPrompt(bool openGithub)
    {
        _state.CopyTextWithoutSyncEcho(
            SelfHostAiPrompt,
            openGithub ? "[自建机房] 已复制 AI 部署提示词并打开 GitHub 仓库页面" : "[自建机房] 已复制 AI 部署提示词，可直接发送给 AI 助手自动部署"
        );
        CopiedPromptBadge.Visibility = Visibility.Visible;
        if (openGithub)
        {
            try { Process.Start(new ProcessStartInfo(GithubRepoUrl) { UseShellExecute = true }); } catch { }
        }
        var timer = new System.Windows.Threading.DispatcherTimer { Interval = TimeSpan.FromSeconds(2.5) };
        timer.Tick += (_, _) =>
        {
            timer.Stop();
            CopiedPromptBadge.Visibility = Visibility.Collapsed;
        };
        timer.Start();
    }

    private void LogLevelCombo_SelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        if (_syncingUi || !IsInitialized) return;
        if (LogLevelCombo.SelectedIndex >= 0)
        {
            _state.SelectedLogLevel = (OpenUULogLevel)LogLevelCombo.SelectedIndex;
            RefreshLogsBox();
        }
    }

    private void CopyDiagLogsBtn_Click(object sender, RoutedEventArgs e) => _state.CopyDiagnosticLogs();
    private void OpenLogDirBtn_Click(object sender, RoutedEventArgs e) => _state.RevealLogDirectoryInExplorer();
    private void ClearLogsBtn_Click(object sender, RoutedEventArgs e) => _state.ClearDiagnosticLogs();
}
