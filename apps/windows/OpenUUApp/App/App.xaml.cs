using System.Drawing;
using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace OpenUU.App;

using OpenUU.Client;
using OpenUU.Shared;
using OpenUU.Views;

public partial class OpenUUApplication : System.Windows.Application
{
    private AppState? _state;
    private MainWindow? _mainWindow;
    private System.Windows.Forms.NotifyIcon? _trayIcon;

    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        string[] args = e.Args;
        string? configDir = ParseFlag(args, "--config-dir");
        string? logDir = ParseFlag(args, "--log-dir");
        if (!string.IsNullOrWhiteSpace(logDir))
            Environment.SetEnvironmentVariable("OPENUU_LOG_DIR", logDir.Trim());

        if (!string.IsNullOrWhiteSpace(configDir))
        {
            string cacheDir = Path.Combine(configDir.Trim(), "cache");
            Directory.CreateDirectory(cacheDir);
            OpenUUBridge.SetGlobalAppDirs(configDir.Trim(), cacheDir);
        }

        Win32Interop.SetCurrentProcessExplicitAppUserModelID("ren.onekb.openuu.windows");

        DispatcherUnhandledException += (_, exArgs) =>
        {
            OpenUULogger.Shared.Error("CRASH", $"Unhandled UI exception: {exArgs.Exception}");
            exArgs.Handled = true;
        };

        _state = new AppState(configDir);
        _mainWindow = new MainWindow(_state);
        MainWindow = _mainWindow;

        SetupSystemTrayIcon();
        _mainWindow.Show();

        ConfigureCliAutomationIfPresent(args);
    }

    private void SetupSystemTrayIcon()
    {
        try
        {
            Icon? winIcon = null;
            var uri = new Uri("pack://application:,,,/Resources/AppIcon.ico", UriKind.Absolute);
            var streamInfo = GetResourceStream(uri);
            if (streamInfo?.Stream != null)
            {
                using var s = streamInfo.Stream;
                winIcon = new Icon(s);
            }

            var menu = new System.Windows.Forms.ContextMenuStrip();
            menu.Items.Add("打开 OpenUU 主面板", null, (_, _) => Dispatcher.Invoke(ShowMainWindow));
            menu.Items.Add("开启 / 关闭本机被控", null, (_, _) => Dispatcher.Invoke(() => _mainWindow?.ToggleHostWithAntiFraudCheck()));
            menu.Items.Add("断开所有远控连接", null, (_, _) => Dispatcher.Invoke(() => _state?.DisconnectAllClientSessions()));
            menu.Items.Add(new System.Windows.Forms.ToolStripSeparator());
            menu.Items.Add("退出 OpenUU", null, (_, _) => Dispatcher.Invoke(ShutdownCleanly));

            _trayIcon = new System.Windows.Forms.NotifyIcon
            {
                Icon = winIcon ?? SystemIcons.Application,
                Text = "OpenUU - 免费开源远程控制",
                Visible = true,
                ContextMenuStrip = menu
            };
            _trayIcon.DoubleClick += (_, _) => Dispatcher.Invoke(ShowMainWindow);
            if (_state != null)
                _state.ClientNotificationManager.TrayIcon = _trayIcon;
        }
        catch
        {
        }
    }

    private void ShowMainWindow()
    {
        if (_mainWindow == null) return;
        if (!_mainWindow.IsVisible)
            _mainWindow.Show();
        if (_mainWindow.WindowState == WindowState.Minimized)
            _mainWindow.WindowState = WindowState.Normal;
        _mainWindow.Activate();
    }

    public void ShutdownCleanly()
    {
        if (_trayIcon != null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _trayIcon = null;
        }
        if (_mainWindow != null)
        {
            _mainWindow.AllowTrueClose = true;
            try { _mainWindow.Close(); } catch { }
            _mainWindow = null;
        }
        _state?.Dispose();
        _state = null;
        Shutdown(0);
    }

    protected override void OnExit(ExitEventArgs e)
    {
        if (_trayIcon != null)
        {
            _trayIcon.Visible = false;
            _trayIcon.Dispose();
            _trayIcon = null;
        }
        _state?.Dispose();
        base.OnExit(e);
    }

    // ========================================================================
    // Optional CLI / E2E Automation Support (--e2e-target / --e2e-host-port)
    // ========================================================================

    private static string? ParseFlag(string[] args, string flag)
    {
        for (int i = 0; i + 1 < args.Length; i++)
        {
            if (string.Equals(args[i], flag, StringComparison.OrdinalIgnoreCase))
                return args[i + 1];
        }
        return null;
    }

    private static bool HasFlag(string[] args, string flag)
        => args.Any(a => string.Equals(a, flag, StringComparison.OrdinalIgnoreCase));

    private void ConfigureCliAutomationIfPresent(string[] args)
    {
        if (_state == null) return;

        string? hostPortStr = ParseFlag(args, "--e2e-host-port");
        string? hostPin = ParseFlag(args, "--e2e-host-pin");
        string? readyFile = ParseFlag(args, "--e2e-ready-file");
        string? screenshotDir = ParseFlag(args, "--e2e-screenshot-dir");

        if (!string.IsNullOrWhiteSpace(hostPortStr) && ushort.TryParse(hostPortStr, out ushort hPort))
        {
            _state.HostPort = hPort;
            if (!string.IsNullOrWhiteSpace(hostPin))
                _state.HostPin = hostPin;

            Dispatcher.BeginInvoke(async () =>
            {
                await Task.Delay(350);
                bool started = _state.StartHost();
                OpenUULogger.Shared.Info("OpenUUE2E", $"HOST_MODE started={started} port={_state.HostPort} pin={_state.HostPin} code={_state.MyRawDeviceCode}");
                if (started)
                {
                    // Emit a gentle 440Hz AAC-LC test tone periodically in E2E Host mode so headless E2E verifies
                    // live QUIC Audio Stream (0x02) + Media Foundation AAC-LC encode & decode end-to-end!
                    _ = RunE2EHostToneEmitterAsync(_state);
                }
                if (started && !string.IsNullOrWhiteSpace(readyFile))
                {
                    await Task.Delay(800);
                    _state.RefreshIdentitySnapshot();
                    File.WriteAllText(readyFile, $"port={_state.HostPort}\npin={_state.HostPin}\ncode={_state.MyRawDeviceCode}\nticket={_state.MyHostTicket}\n");
                }
            });
        }

        string? e2eTarget = ParseFlag(args, "--e2e-target");
        if (!string.IsNullOrWhiteSpace(e2eTarget))
        {
            string pin = ParseFlag(args, "--e2e-pin") ?? "";
            string appBid = ParseFlag(args, "--e2e-app") ?? "com.tencent.xinWeChat";
            bool autoTest = HasFlag(args, "--e2e-autotest");

            _ = RunClientE2EFlowAsync(e2eTarget, pin, appBid, autoTest, screenshotDir);
        }
    }

    private async Task RunClientE2EFlowAsync(
        string target,
        string pin,
        string appBid,
        bool autoTest,
        string? screenshotDir
    )
    {
        if (_state == null) return;

        await Task.Delay(500);
        if (!string.IsNullOrWhiteSpace(screenshotDir) && _mainWindow != null)
        {
            Directory.CreateDirectory(screenshotDir);
            SaveWindowScreenshot(_mainWindow, Path.Combine(screenshotDir, "windows_01_home.png"));
        }

        _state.ShowDebugHud = true;
        _state.QuickConnectTarget = target;
        _state.QuickConnectPassword = pin;

        var sess = _state.ConnectFromQuickInput(autoOpenDesktop: false);
        if (sess == null) return;

        // Wait up to 15s for connection & app list
        for (int i = 0; i < 60; i++)
        {
            if (sess.IsConnected && sess.RemoteApps.Count > 0)
                break;
            await Task.Delay(250);
        }

        if (!sess.IsConnected)
        {
            OpenUULogger.Shared.Error("OpenUUE2E", $"CONNECT_FAILED status={sess.StatusMessage}");
            return;
        }
        OpenUULogger.Shared.Info("OpenUUE2E", $"CONNECTED host={sess.RemoteHostName} apps={sess.RemoteApps.Count}");

        if (!autoTest)
            return;

        var chosenApp = sess.RemoteApps.FirstOrDefault(a => string.Equals(a.BundleId, appBid, StringComparison.OrdinalIgnoreCase))
                        ?? sess.RemoteApps.FirstOrDefault(a => a.BundleId != Host.MultiWindowCaptureManager.FullDesktopBundleId)
                        ?? sess.RemoteApps.FirstOrDefault();

        if (chosenApp != null)
        {
            sess.OpenApp(chosenApp);
        }

        // Wait up to 10s for video frames to decode
        for (int i = 0; i < 40; i++)
        {
            if (sess.TotalDecodedFramesAcrossWindows() >= 5)
                break;
            await Task.Delay(250);
        }

        var topo = sess.SnapshotKnownWindows();
        uint activeWinId = topo.Keys.FirstOrDefault(k => topo[k].Kind == 0);
        if (activeWinId == 0)
            activeWinId = topo.Keys.FirstOrDefault();
        if (activeWinId == 0)
            activeWinId = chosenApp?.BundleId == Host.MultiWindowCaptureManager.FullDesktopBundleId
                ? Host.MultiWindowCaptureManager.FullDesktopWindowId
                : 101u;

        // Exercise full input & clipboard pipeline (mouse click, drag, right-click popover, scroll, IME text_commit, key, clipboard_sync)
        sess.Bridge.SendMouse(activeWinId, 180f, 140f, type: 1, button: 0, clickCount: 1, modifiers: 0);
        sess.Bridge.SendMouse(activeWinId, 240f, 180f, type: 3, button: 0, clickCount: 1, modifiers: 0);
        sess.Bridge.SendMouse(activeWinId, 240f, 180f, type: 2, button: 0, clickCount: 1, modifiers: 0);

        sess.Bridge.SendMouse(activeWinId, 240f, 160f, type: 1, button: 1, clickCount: 1, modifiers: 0);
        sess.Bridge.SendMouse(activeWinId, 240f, 160f, type: 2, button: 1, clickCount: 1, modifiers: 0);

        sess.Bridge.SendScroll(activeWinId, 200f, 200f, 0f, -3f, isContinuous: false, modifiers: 0);
        sess.Bridge.SendTextCommit(activeWinId, "你好，OpenUU Windows 端！");
        sess.Bridge.SendKey(activeWinId, 8 /* C */, isDown: true, isRepeat: false, modifiers: KeyCodeMapper.ModCmd);
        sess.Bridge.SendKey(activeWinId, 8 /* C */, isDown: false, isRepeat: false, modifiers: KeyCodeMapper.ModCmd);
        sess.Bridge.SendClipboardText("win-e2e-clip-hash-1", "Hello from Windows E2E");

        OpenUULogger.Shared.Info("OpenUUE2E", $"E2E_ALL_SENT decoded_frames={sess.TotalDecodedFramesAcrossWindows()}");

        await Task.Delay(1200);
        OpenUULogger.Shared.Info("OpenUUE2E", $"FINAL_STATS decoded_frames={sess.TotalDecodedFramesAcrossWindows()} audio_frames={sess.AudioPlayer.TotalDecodedAudioFrames} open_windows={sess.OpenWindowCount}");

        if (!string.IsNullOrWhiteSpace(screenshotDir))
        {
            if (_mainWindow != null)
                SaveWindowScreenshot(_mainWindow, Path.Combine(screenshotDir, "windows_02_connected_workspace.png"));

            var firstProxy = Windows.OfType<ProxyWindow>().FirstOrDefault(w => !w.IsFloatingPopover && w.Renderer.CurrentBitmap != null)
                             ?? Windows.OfType<ProxyWindow>().FirstOrDefault(w => !w.IsFloatingPopover);
            if (firstProxy != null)
                SaveWindowScreenshot(firstProxy, Path.Combine(screenshotDir, "windows_03_proxy_window.png"));
        }
    }

    private static void SaveWindowScreenshot(Window window, string filePath)
    {
        try
        {
            window.UpdateLayout();
            int w = Math.Max(1, (int)Math.Round(window.ActualWidth));
            int h = Math.Max(1, (int)Math.Round(window.ActualHeight));
            var rtb = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
            rtb.Render(window);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(rtb));
            using var fs = File.Create(filePath);
            encoder.Save(fs);
        }
        catch
        {
        }
    }

    private static async Task RunE2EHostToneEmitterAsync(AppState state)
    {
        await Task.Yield();
        OpenUUNativeMethods.openuu_media_startup();
        IntPtr enc = OpenUUNativeMethods.openuu_aac_encoder_create(48_000, 2, 128_000);
        if (enc == IntPtr.Zero) return;

        var pcm = new short[1024 * 2];
        for (int i = 0; i < 1024; i++)
        {
            short v = (short)(Math.Sin(2.0 * Math.PI * 440.0 * i / 48_000.0) * 4000.0);
            pcm[i * 2] = v;
            pcm[i * 2 + 1] = v;
        }
        var aacBuf = new byte[2048];
        ulong pts = 0;

        try
        {
            while (state.IsHostRunning)
            {
                if (state.ActiveStreamCount > 0)
                {
                    int encoded = EncodeSingleAacTestFrame(enc, pcm, pts, aacBuf);
                    pts += 21_333;
                    if (encoded > 0)
                    {
                        state.HostBridge.SendAudioFrame(3, 0, 2, 48_000, pts, aacBuf.AsSpan(0, encoded));
                    }
                    await Task.Delay(35);
                }
                else
                {
                    await Task.Delay(150);
                }
            }
        }
        finally
        {
            OpenUUNativeMethods.openuu_aac_encoder_destroy(enc);
        }
    }

    private static unsafe int EncodeSingleAacTestFrame(IntPtr enc, short[] pcm, ulong pts, byte[] aacOut)
    {
        fixed (short* pIn = pcm)
        fixed (byte* pOut = aacOut)
        {
            return OpenUUNativeMethods.openuu_aac_encoder_encode_pcm16(enc, pIn, 1024, pts, pOut, aacOut.Length);
        }
    }
}
