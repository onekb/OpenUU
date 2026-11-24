using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Shell;
using System.Windows.Threading;

namespace OpenUU.Client;

using OpenUU.Host;
using OpenUU.Shared;

/// <summary>
/// Seamless Windows proxy window rendering a single remote application window, a floating popover (<c>kind=2</c>),
/// or a full remote desktop. Provides ungrouped per-app Taskbar icon + unread badge overlay, live resize sync,
/// local Windows Chinese IME composition, cursor shape sync, and bidirectional file drag-and-drop.
/// </summary>
public partial class ProxyWindow : Window
{
    public VideoDisplayRenderer Renderer { get; }
    private readonly OpenUUBridge _bridge;
    private readonly string _taskbarAppId;
    private readonly Action<string>? _onDebugLog;

    private IntPtr _hwnd;
    private uint _currentWindowId;
    private bool _hasAutoSized;
    private bool _isClosingProgrammatically;
    private bool _isApplyingProgrammaticSize;
    private bool _isDebugHudEnabled;
    private long _lastResizeSentMs;
    private long _lastUserResizeMs;
    private long _lastHoverSentMs;
    private CancellationTokenSource? _settleAspectCts;
    private DispatcherTimer? _hudIdleTimer;
    private VideoStreamTelemetry? _lastTelemetry;

    private bool _isLeftMouseDown;
    private bool _didStartLocalDragOut;
    private System.Windows.Point _lastMouseLocalPt;
    private readonly List<DragOutItemDescriptor> _pendingDragOutItems = new();
    private System.Windows.Input.Cursor _remoteCursor = System.Windows.Input.Cursors.Arrow;

    private (Rect ParentBounds, double RelX, double RelY, System.Windows.Size FallbackSize)? _popoverPlacement;

    public bool IsFloatingPopover { get; private set; }
    public bool IsOverlayPreview { get; private set; }
    public bool MapCtrlToMacCommand { get; set; } = true;
    public System.Windows.Size RemoteLogicalSize { get; private set; } = new(960, 640);

    public Action<uint>? OnWindowClosedByUser { get; set; }
    public Action? OnWindowMovedByUser { get; set; }
    public Action? OnBeforePasteShortcut { get; set; }
    public Action? OnToggleAudioMute { get; set; }

    public ProxyWindow(
        OpenUUBridge bridge,
        VideoDisplayRenderer renderer,
        string title,
        string taskbarAppId,
        System.Windows.Point initialOrigin,
        ImageSource? taskbarIcon = null,
        Action<string>? onDebugLog = null
    )
    {
        _bridge = bridge;
        Renderer = renderer;
        _taskbarAppId = taskbarAppId;
        _onDebugLog = onDebugLog;

        InitializeComponent();

        Left = initialOrigin.X;
        Top = initialOrigin.Y;
        UpdateWindowTitle(title);

        if (taskbarIcon != null)
            Icon = taskbarIcon;

        if (Renderer.CurrentBitmap != null)
        {
            VideoImage.Source = Renderer.CurrentBitmap;
            ConnectingPlaceholder.Visibility = Visibility.Collapsed;
        }

        Renderer.OnBitmapReplaced = bmp =>
        {
            VideoImage.Source = bmp;
            ConnectingPlaceholder.Visibility = Visibility.Collapsed;
        };
        Renderer.OnRequestKeyframe = wid => _bridge.RequestKeyframe(wid);
        Renderer.OnTelemetryUpdated = snap =>
        {
            Dispatcher.BeginInvoke(() =>
            {
                _lastTelemetry = snap;
                if (_isDebugHudEnabled && !IsFloatingPopover)
                    UpdateHudDisplay(snap, isIdle: false);
            });
        };

        SourceInitialized += OnSourceInitialized;
        Loaded += (_, _) => InteractiveSurface.Focus();
        LocationChanged += (_, _) =>
        {
            if (!IsFloatingPopover)
                OnWindowMovedByUser?.Invoke();
        };
        SizeChanged += OnWindowSizeChanged;
        Closing += (_, _) =>
        {
            _hudIdleTimer?.Stop();
            _settleAspectCts?.Cancel();
            if (!_isClosingProgrammatically && _currentWindowId != 0)
                OnWindowClosedByUser?.Invoke(_currentWindowId);
        };

        InteractiveSurface.MouseMove += OnSurfaceMouseMove;
        InteractiveSurface.MouseLeave += OnSurfaceMouseLeave;
        InteractiveSurface.MouseDown += OnSurfaceMouseDown;
        InteractiveSurface.MouseUp += OnSurfaceMouseUp;
        InteractiveSurface.MouseWheel += OnSurfaceMouseWheel;
        InteractiveSurface.PreviewKeyDown += OnSurfacePreviewKeyDown;
        InteractiveSurface.PreviewKeyUp += OnSurfacePreviewKeyUp;
        TextCompositionManager.AddTextInputHandler(InteractiveSurface, OnSurfaceTextInput);

        DragEnter += OnWindowDragEnter;
        DragOver += OnWindowDragOver;
        DragLeave += OnWindowDragLeave;
        Drop += OnWindowDrop;
    }

    private void OnSourceInitialized(object? sender, EventArgs e)
    {
        _hwnd = new WindowInteropHelper(this).Handle;
        if (_hwnd == IntPtr.Zero) return;

        // Enable Windows 11 hardware rounded corners and dark frame
        int roundPref = Win32Interop.DWMWCP_ROUND;
        Win32Interop.DwmSetWindowAttribute(_hwnd, Win32Interop.DWMWA_WINDOW_CORNER_PREFERENCE, ref roundPref, sizeof(int));
        int darkVal = 1;
        Win32Interop.DwmSetWindowAttribute(_hwnd, Win32Interop.DWMWA_USE_IMMERSIVE_DARK_MODE, ref darkVal, sizeof(int));

        // Give each normal remote window its own independent ungrouped Taskbar icon (like macOS DockProxyManager!)
        if (!IsFloatingPopover && !string.IsNullOrWhiteSpace(_taskbarAppId))
        {
            Win32Interop.SetWindowAppUserModelId(_hwnd, _taskbarAppId);
        }

        ApplyExStylesForPopover();
    }

    public void UpdateWindowTitle(string title)
    {
        string clean = string.IsNullOrWhiteSpace(title) ? "远程窗口" : title.Trim();
        Title = clean;
        HoverTitleText.Text = clean;
    }

    public void UpdateTaskbarIcon(ImageSource? icon)
    {
        if (icon != null && !IsFloatingPopover)
            Icon = icon;
    }

    public void UpdateTaskbarBadge(string? badgeText)
    {
        if (IsFloatingPopover) return;
        WindowTaskbarInfo.Overlay = IconCompositor.CreateTaskbarBadgeOverlay(badgeText);
        WindowTaskbarInfo.Description = string.IsNullOrWhiteSpace(badgeText) ? Title : $"{Title} ({badgeText} 条未读)";
    }

    public void CloseProgrammatically()
    {
        _isClosingProgrammatically = true;
        try { Close(); } catch { }
    }

    public void ConfigureFloatingPopover(bool isFloating, bool isOverlayPreview)
    {
        IsFloatingPopover = isFloating;
        IsOverlayPreview = isOverlayPreview;

        if (isFloating)
        {
            ShowInTaskbar = false;
            ShowActivated = false;
            Topmost = true;
            ResizeMode = ResizeMode.NoResize;
            HoverTitlebarPill.Visibility = Visibility.Collapsed;
            DebugHudBox.Visibility = Visibility.Collapsed;
            WindowChrome.SetWindowChrome(this, new WindowChrome
            {
                CaptionHeight = 0,
                ResizeBorderThickness = new Thickness(0),
                GlassFrameThickness = new Thickness(1),
                CornerRadius = new CornerRadius(8)
            });
        }
        else
        {
            ShowInTaskbar = true;
            Topmost = false;
            ResizeMode = ResizeMode.CanResize;
            DebugHudBox.Visibility = _isDebugHudEnabled ? Visibility.Visible : Visibility.Collapsed;
        }

        ApplyExStylesForPopover();
    }

    private void ApplyExStylesForPopover()
    {
        if (_hwnd == IntPtr.Zero) return;
        uint ex = Win32Interop.GetWindowLong(_hwnd, Win32Interop.GWL_EXSTYLE);
        if (IsFloatingPopover)
        {
            ex |= Win32Interop.WS_EX_TOOLWINDOW | Win32Interop.WS_EX_NOACTIVATE;
            if (IsOverlayPreview)
                ex |= Win32Interop.WS_EX_TRANSPARENT | Win32Interop.WS_EX_LAYERED;
            else
                ex &= ~Win32Interop.WS_EX_TRANSPARENT;
        }
        else
        {
            ex &= ~(Win32Interop.WS_EX_TOOLWINDOW | Win32Interop.WS_EX_NOACTIVATE | Win32Interop.WS_EX_TRANSPARENT);
        }
        Win32Interop.SetWindowLong(_hwnd, Win32Interop.GWL_EXSTYLE, ex);
    }

    public void UpdatePopoverPlacement(Rect parentBounds, double relX, double relY, System.Windows.Size fallbackSize)
    {
        _popoverPlacement = (parentBounds, relX, relY, fallbackSize);
        if (!IsFloatingPopover) return;

        double targetW = _hasAutoSized ? RemoteLogicalSize.Width : Math.Max(50, fallbackSize.Width);
        double targetH = _hasAutoSized ? RemoteLogicalSize.Height : Math.Max(36, fallbackSize.Height);
        double newX = parentBounds.Left + relX;
        double newY = parentBounds.Top + relY;

        _isApplyingProgrammaticSize = true;
        Left = newX;
        Top = newY;
        Width = targetW;
        Height = targetH;
        _isApplyingProgrammaticSize = false;
    }

    public void SyncRemoteFrameSize(uint windowId, ushort reportedWidth, ushort reportedHeight)
    {
        _currentWindowId = windowId;
        bool isDesktop = windowId == MultiWindowCaptureManager.FullDesktopWindowId;
        CloseRemoteBtn.Visibility = isDesktop ? Visibility.Collapsed : Visibility.Visible;
        CloseStreamBtn.Content = isDesktop ? "✕ 退出远程" : "✕ 关投屏";

        double logW = Math.Max(50.0, reportedWidth / 2.0);
        double logH = Math.Max(36.0, reportedHeight / 2.0);
        bool sizeChanged = Math.Abs(RemoteLogicalSize.Width - logW) > 2.0 ||
                           Math.Abs(RemoteLogicalSize.Height - logH) > 2.0;
        RemoteLogicalSize = new System.Windows.Size(logW, logH);

        bool recentlyResizedByUser = (Environment.TickCount64 - _lastUserResizeMs) < 750;
        if (!_hasAutoSized || (sizeChanged && !recentlyResizedByUser))
        {
            _hasAutoSized = true;
            _isApplyingProgrammaticSize = true;
            try
            {
                if (IsFloatingPopover && _popoverPlacement is { } pl)
                {
                    Left = pl.ParentBounds.Left + pl.RelX;
                    Top = pl.ParentBounds.Top + pl.RelY;
                    Width = logW;
                    Height = logH;
                }
                else
                {
                    var work = SystemParameters.WorkArea;
                    double maxW = Math.Max(320, work.Width - 40);
                    double maxH = Math.Max(240, work.Height - 40);
                    double targetW = logW;
                    double targetH = logH;
                    if (targetW > maxW || targetH > maxH)
                    {
                        double s = Math.Min(maxW / targetW, maxH / targetH);
                        targetW = Math.Floor(targetW * s);
                        targetH = Math.Floor(targetH * s);
                    }
                    Left = Math.Clamp(Left, work.Left + 12, Math.Max(work.Left + 12, work.Right - targetW - 12));
                    Top = Math.Clamp(Top, work.Top + 12, Math.Max(work.Top + 12, work.Bottom - targetH - 12));
                    Width = targetW;
                    Height = targetH;
                }
            }
            finally
            {
                _isApplyingProgrammaticSize = false;
            }

            if (!IsVisible)
            {
                Show();
                if (!IsFloatingPopover)
                    Activate();
            }
        }
    }

    private void OnWindowSizeChanged(object sender, SizeChangedEventArgs e)
    {
        if (IsFloatingPopover || _isApplyingProgrammaticSize || !_hasAutoSized || _currentWindowId == 0)
            return;

        long now = Environment.TickCount64;
        _lastUserResizeMs = now;

        if (_currentWindowId != MultiWindowCaptureManager.FullDesktopWindowId && now - _lastResizeSentMs >= 75)
        {
            _lastResizeSentMs = now;
            _bridge.SendResizeWindow(_currentWindowId, (float)e.NewSize.Width, (float)e.NewSize.Height);
        }

        // Aspect-ratio settle fallback if Host window hit max/min size or is non-resizable
        _settleAspectCts?.Cancel();
        var cts = new CancellationTokenSource();
        _settleAspectCts = cts;
        var ct = cts.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(320, ct);
                Dispatcher.Invoke(() =>
                {
                    if (ct.IsCancellationRequested || RemoteLogicalSize.Width <= 10 || RemoteLogicalSize.Height <= 10)
                        return;
                    if (Math.Abs(ActualWidth - RemoteLogicalSize.Width) <= 8 &&
                        Math.Abs(ActualHeight - RemoteLogicalSize.Height) <= 8)
                    {
                        return;
                    }
                    double remoteAspect = RemoteLogicalSize.Width / RemoteLogicalSize.Height;
                    double localAspect = ActualWidth / Math.Max(1.0, ActualHeight);
                    if (Math.Abs(localAspect - remoteAspect) <= 0.02)
                        return;

                    var work = SystemParameters.WorkArea;
                    double fittedW = ActualWidth;
                    double fittedH = Math.Round(fittedW / remoteAspect);
                    if (fittedH > work.Height - 24)
                    {
                        fittedH = work.Height - 24;
                        fittedW = Math.Round(fittedH * remoteAspect);
                    }
                    _isApplyingProgrammaticSize = true;
                    Width = fittedW;
                    Height = fittedH;
                    _isApplyingProgrammaticSize = false;
                });
            }
            catch
            {
            }
        }, ct);
    }

    public void ApplyRemoteCursor(string kind)
    {
        _remoteCursor = kind switch
        {
            "ibeam" => System.Windows.Input.Cursors.IBeam,
            "pointing_hand" => System.Windows.Input.Cursors.Hand,
            "resize_lr" or "resize_left" or "resize_right" => System.Windows.Input.Cursors.SizeWE,
            "resize_ud" or "resize_up" or "resize_down" => System.Windows.Input.Cursors.SizeNS,
            "open_hand" or "closed_hand" => System.Windows.Input.Cursors.SizeAll,
            "crosshair" => System.Windows.Input.Cursors.Cross,
            _ => System.Windows.Input.Cursors.Arrow
        };
        InteractiveSurface.Cursor = _remoteCursor;
    }

    public void SetDebugHudVisible(bool visible)
    {
        _isDebugHudEnabled = visible;
        bool shouldShow = visible && !IsFloatingPopover;
        DebugHudBox.Visibility = shouldShow ? Visibility.Visible : Visibility.Collapsed;
        _hudIdleTimer?.Stop();
        _hudIdleTimer = null;

        if (shouldShow)
        {
            if (_lastTelemetry != null)
                UpdateHudDisplay(_lastTelemetry, IsTelemetryIdle(_lastTelemetry));

            _hudIdleTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(500) };
            _hudIdleTimer.Tick += (_, _) =>
            {
                if (_isDebugHudEnabled && !IsFloatingPopover && _lastTelemetry != null && IsTelemetryIdle(_lastTelemetry))
                    UpdateHudDisplay(_lastTelemetry, isIdle: true);
            };
            _hudIdleTimer.Start();
        }
    }

    private static bool IsTelemetryIdle(VideoStreamTelemetry s)
        => Stopwatch.GetElapsedTime(s.UpdatedAtTicks).TotalSeconds >= 0.65;

    private void UpdateHudDisplay(VideoStreamTelemetry s, bool isIdle)
    {
        string fpsText = isIdle ? "0 FPS (静止省流)" : $"收{s.Fps}/采{s.HostFps} FPS";
        string brText = isIdle ? "0.00 Mbps" : $"{s.BitrateMbps:F2} Mbps";
        string gapText = isIdle ? "间隔 -" : $"最大间隔 {s.MaxGapMs}ms";
        string scaleMode = s.ScaleRatio < 1.65 ? "动态加速" : "Retina超清";
        int kb = Math.Max(1, s.LastFrameBytes / 1024);
        string kind = s.IsLastKeyframe ? "IDR" : "P";

        DebugHudText.Text =
            $"● {fpsText} | {brText} | {gapText}\n" +
            $"{s.CodecName}: {s.EncodedWidth}×{s.EncodedHeight} ({s.ScaleRatio:F2}x {scaleMode}) | 解码 {s.AvgDecodeMs:F2}ms\n" +
            $"逻辑: {s.LogicalWidth}×{s.LogicalHeight} pt | 帧: {kb}KB({kind})";
    }

    // ========================================================================
    // Mouse, Wheel, Keyboard & Local Windows Chinese IME Forwarding
    // ========================================================================

    private (float X, float Y) MapRemotePoint(System.Windows.Point localPt)
    {
        double w = Math.Max(1.0, InteractiveSurface.ActualWidth);
        double h = Math.Max(1.0, InteractiveSurface.ActualHeight);
        double normX = Math.Clamp(localPt.X / w, 0.0, 1.0);
        double normY = Math.Clamp(localPt.Y / h, 0.0, 1.0);
        return ((float)(normX * RemoteLogicalSize.Width), (float)(normY * RemoteLogicalSize.Height));
    }

    private void UpdateImeCandidatePosition(System.Windows.Point localPt)
    {
        if (_hwnd == IntPtr.Zero) return;
        IntPtr hImc = Win32Interop.ImmGetContext(_hwnd);
        if (hImc == IntPtr.Zero) return;
        try
        {
            double dpi = Win32Interop.GetDpiScale(_hwnd);
            var cf = new Win32Interop.COMPOSITIONFORM
            {
                dwStyle = Win32Interop.CFS_POINT,
                ptCurrentPos = new Win32Interop.POINT
                {
                    X = (int)Math.Round(localPt.X * dpi),
                    Y = (int)Math.Round((localPt.Y + 16) * dpi)
                }
            };
            Win32Interop.ImmSetCompositionWindow(hImc, ref cf);
        }
        finally
        {
            Win32Interop.ImmReleaseContext(_hwnd, hImc);
        }
    }

    private void OnSurfaceMouseMove(object sender, System.Windows.Input.MouseEventArgs e)
    {
        var local = e.GetPosition(InteractiveSurface);
        _lastMouseLocalPt = local;

        if (!IsFloatingPopover)
        {
            bool nearTop = local.Y <= 34.0 && !_isLeftMouseDown;
            HoverTitlebarPill.Visibility = nearTop ? Visibility.Visible : Visibility.Collapsed;
        }

        if (_currentWindowId == 0) return;

        if (_isLeftMouseDown || e.RightButton == MouseButtonState.Pressed || e.MiddleButton == MouseButtonState.Pressed)
        {
            if (_didStartLocalDragOut) return;

            // Hand off to local Windows Explorer Drag-Out as soon as Host notifies drag-out metadata and cursor nears border
            if (_pendingDragOutItems.Count > 0 && IsNearEdge(local))
            {
                BeginNativeWindowsDragOut();
                return;
            }

            uint btn = e.RightButton == MouseButtonState.Pressed ? 1u : (e.MiddleButton == MouseButtonState.Pressed ? 2u : 0u);
            var (rx, ry) = MapRemotePoint(local);
            uint mods = KeyCodeMapper.BuildClientModifiers(Keyboard.Modifiers, MapCtrlToMacCommand);
            _bridge.SendMouse(_currentWindowId, rx, ry, type: 3, button: btn, clickCount: 1, modifiers: mods);
            return;
        }

        long now = Environment.TickCount64;
        if (now - _lastHoverSentMs < 32) return;
        _lastHoverSentMs = now;

        var (hx, hy) = MapRemotePoint(local);
        uint hMods = KeyCodeMapper.BuildClientModifiers(Keyboard.Modifiers, MapCtrlToMacCommand);
        _bridge.SendMouse(_currentWindowId, hx, hy, type: 0, button: 0, clickCount: 0, modifiers: hMods);
    }

    private void OnSurfaceMouseLeave(object sender, System.Windows.Input.MouseEventArgs e)
    {
        HoverTitlebarPill.Visibility = Visibility.Collapsed;
        if (_currentWindowId != 0 && !_isLeftMouseDown)
        {
            _bridge.SendMouse(_currentWindowId, 0, 0, type: 4, modifiers: 0);
        }
    }

    private void OnSurfaceMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (HoverTitlebarPill.IsMouseOver) return;

        InteractiveSurface.Focus();
        var local = e.GetPosition(InteractiveSurface);
        _lastMouseLocalPt = local;
        UpdateImeCandidatePosition(local);

        if (_currentWindowId == 0) return;

        uint btn = e.ChangedButton switch
        {
            MouseButton.Right => 1u,
            MouseButton.Middle => 2u,
            _ => 0u
        };

        if (btn == 0)
        {
            _isLeftMouseDown = true;
            _didStartLocalDragOut = false;
            _pendingDragOutItems.Clear();
            InteractiveSurface.CaptureMouse();
        }

        var (rx, ry) = MapRemotePoint(local);
        uint mods = KeyCodeMapper.BuildClientModifiers(Keyboard.Modifiers, MapCtrlToMacCommand);
        _onDebugLog?.Invoke($"发送点击 ({rx:F0}, {ry:F0}) win={_currentWindowId}");
        _bridge.SendMouse(_currentWindowId, rx, ry, type: 1, button: btn, clickCount: (uint)Math.Max(1, e.ClickCount), modifiers: mods);
        e.Handled = true;
    }

    private void OnSurfaceMouseUp(object sender, MouseButtonEventArgs e)
    {
        uint btn = e.ChangedButton switch
        {
            MouseButton.Right => 1u,
            MouseButton.Middle => 2u,
            _ => 0u
        };

        if (btn == 0)
        {
            _isLeftMouseDown = false;
            if (InteractiveSurface.IsMouseCaptured)
                InteractiveSurface.ReleaseMouseCapture();

            if (_didStartLocalDragOut)
            {
                _didStartLocalDragOut = false;
                _pendingDragOutItems.Clear();
                e.Handled = true;
                return;
            }

            if (_pendingDragOutItems.Count > 0)
            {
                var unclaimed = _pendingDragOutItems.ToArray();
                _pendingDragOutItems.Clear();
                foreach (var item in unclaimed)
                    DragOutTransferCoordinator.Shared.AbandonUnclaimedDragOut(item.BlobId);
            }
        }

        if (_currentWindowId == 0) return;
        var local = e.GetPosition(InteractiveSurface);
        var (rx, ry) = MapRemotePoint(local);
        uint mods = KeyCodeMapper.BuildClientModifiers(Keyboard.Modifiers, MapCtrlToMacCommand);
        _bridge.SendMouse(_currentWindowId, rx, ry, type: 2, button: btn, clickCount: (uint)Math.Max(1, e.ClickCount), modifiers: mods);
        e.Handled = true;
    }

    private void OnSurfaceMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (_currentWindowId == 0) return;
        var local = e.GetPosition(InteractiveSurface);
        var (rx, ry) = MapRemotePoint(local);
        uint mods = KeyCodeMapper.BuildClientModifiers(Keyboard.Modifiers, MapCtrlToMacCommand);
        float dy = e.Delta / 120.0f * 3.0f;
        _bridge.SendScroll(_currentWindowId, rx, ry, deltaX: 0f, deltaY: dy, isContinuous: false, modifiers: mods);
        e.Handled = true;
    }

    private void OnSurfacePreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (_currentWindowId == 0) return;
        Key actualKey = e.Key == Key.System ? e.SystemKey : e.Key;

        // Let Windows Chinese/Japanese/Korean IME process composition keys unimpeded!
        if (actualKey == Key.ImeProcessed)
            return;

        if (!KeyCodeMapper.TryMapWpfKeyToCgKeyCode(actualKey, out uint cgKey, out int vk))
            return;

        uint mods = KeyCodeMapper.BuildClientModifiers(Keyboard.Modifiers, MapCtrlToMacCommand);
        bool hasShortcutMod = (mods & (KeyCodeMapper.ModCmd | KeyCodeMapper.ModCtrl | KeyCodeMapper.ModAlt)) != 0;
        bool isControlKey = KeyCodeMapper.IsNonTextControlVk(vk);

        if (hasShortcutMod || isControlKey)
        {
            if (KeyCodeMapper.IsPasteShortcut(vk, mods))
                OnBeforePasteShortcut?.Invoke();

            _bridge.SendKey(_currentWindowId, cgKey, isDown: true, isRepeat: e.IsRepeat, modifiers: mods);
            e.Handled = true;
        }
    }

    private void OnSurfacePreviewKeyUp(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if (_currentWindowId == 0) return;
        Key actualKey = e.Key == Key.System ? e.SystemKey : e.Key;
        if (actualKey == Key.ImeProcessed) return;

        if (!KeyCodeMapper.TryMapWpfKeyToCgKeyCode(actualKey, out uint cgKey, out int vk))
            return;

        uint mods = KeyCodeMapper.BuildClientModifiers(Keyboard.Modifiers, MapCtrlToMacCommand);
        bool hasShortcutMod = (mods & (KeyCodeMapper.ModCmd | KeyCodeMapper.ModCtrl | KeyCodeMapper.ModAlt)) != 0;
        if (hasShortcutMod || KeyCodeMapper.IsNonTextControlVk(vk))
        {
            _bridge.SendKey(_currentWindowId, cgKey, isDown: false, isRepeat: false, modifiers: mods);
            e.Handled = true;
        }
    }

    private void OnSurfaceTextInput(object sender, TextCompositionEventArgs e)
    {
        if (_currentWindowId == 0 || string.IsNullOrEmpty(e.Text))
            return;

        // Filter raw control characters (< 0x20) already sent via PreviewKeyDown (Enter, Backspace, Tab, Esc)
        string printable = new string(e.Text.Where(ch => ch >= ' ').ToArray());
        if (!string.IsNullOrEmpty(printable))
        {
            _bridge.SendTextCommit(_currentWindowId, printable);
            e.Handled = true;
        }
    }

    // ========================================================================
    // Drag-In (Explorer -> Remote Window) & Drag-Out (Remote Window -> Explorer)
    // ========================================================================

    private void OnWindowDragEnter(object sender, System.Windows.DragEventArgs e)
    {
        // Never allow a drag-out initiated from this same proxy window to loop back into itself!
        if (_didStartLocalDragOut || IsFloatingPopover || _currentWindowId == 0 || !e.Data.GetDataPresent(System.Windows.DataFormats.FileDrop))
        {
            e.Effects = System.Windows.DragDropEffects.None;
            return;
        }
        var files = ExtractDroppedRegularFiles(e.Data);
        if (files.Count == 0)
        {
            e.Effects = System.Windows.DragDropEffects.None;
            return;
        }
        string trimmedTitle = (Title ?? "").Trim();
        string targetDesc = string.IsNullOrEmpty(trimmedTitle) ? "远端窗口" : $"「{trimmedTitle}」";
        FileDropLabel.Text = files.Count > 1 ? $"松手发送 {files.Count} 个文件到{targetDesc}" : $"松手发送文件到{targetDesc}";
        FileDropOverlay.Visibility = Visibility.Visible;
        e.Effects = System.Windows.DragDropEffects.Copy;
        e.Handled = true;
    }

    private void OnWindowDragOver(object sender, System.Windows.DragEventArgs e)
    {
        if (_didStartLocalDragOut)
        {
            e.Effects = System.Windows.DragDropEffects.None;
            e.Handled = true;
            return;
        }
        if (FileDropOverlay.Visibility == Visibility.Visible)
        {
            e.Effects = System.Windows.DragDropEffects.Copy;
            e.Handled = true;
        }
    }

    private void OnWindowDragLeave(object sender, System.Windows.DragEventArgs e)
    {
        FileDropOverlay.Visibility = Visibility.Collapsed;
    }

    private void OnWindowDrop(object sender, System.Windows.DragEventArgs e)
    {
        FileDropOverlay.Visibility = Visibility.Collapsed;
        if (_didStartLocalDragOut || IsFloatingPopover || _currentWindowId == 0) return;

        var files = ExtractDroppedRegularFiles(e.Data);
        if (files.Count == 0) return;

        var local = e.GetPosition(InteractiveSurface);
        var (rx, ry) = MapRemotePoint(local);

        const long maxBytes = 512L * 1024 * 1024;
        int sent = 0;
        foreach (var path in files)
        {
            var fi = new FileInfo(path);
            if (!fi.Exists || fi.Length <= 0 || fi.Length > maxBytes)
            {
                _onDebugLog?.Invoke($"跳过超大或无效文件: {fi.Name}");
                continue;
            }
            _bridge.SendFileBlob(_currentWindowId, rx, ry, fi.FullName);
            sent++;
        }
        if (sent > 0)
            _onDebugLog?.Invoke($"正在发送 {sent} 个文件到远端窗口...");
    }

    private static List<string> ExtractDroppedRegularFiles(System.Windows.IDataObject data)
    {
        if (data.GetData(System.Windows.DataFormats.FileDrop) is not string[] raw)
            return new();
        return raw.Where(p => File.Exists(p) && !p.EndsWith(".downloading", StringComparison.OrdinalIgnoreCase)).ToList();
    }

    private bool IsNearEdge(System.Windows.Point pt)
    {
        double w = InteractiveSurface.ActualWidth;
        double h = InteractiveSurface.ActualHeight;
        return pt.X <= 6 || pt.Y <= 6 || pt.X >= w - 6 || pt.Y >= h - 6;
    }

    public bool DeliverDragOutItems(IReadOnlyList<DragOutItemDescriptor> items)
    {
        if (items.Count == 0 || !_isLeftMouseDown || _didStartLocalDragOut)
            return false;

        foreach (var item in items)
        {
            if (_pendingDragOutItems.All(x => x.BlobId != item.BlobId))
                _pendingDragOutItems.Add(item);
        }
        if (_pendingDragOutItems.Count > 0 && IsNearEdge(_lastMouseLocalPt))
        {
            BeginNativeWindowsDragOut();
        }
        return _pendingDragOutItems.Count > 0;
    }

    private void BeginNativeWindowsDragOut()
    {
        if (_didStartLocalDragOut || _pendingDragOutItems.Count == 0) return;

        var descriptors = _pendingDragOutItems.ToArray();
        var (dropPaths, allowedEffects, preparedItems) = DragOutTransferCoordinator.Shared.PrepareDragSession(descriptors);
        if (dropPaths.Length == 0) return;

        _didStartLocalDragOut = true;
        _pendingDragOutItems.Clear();

        if (InteractiveSurface.IsMouseCaptured)
            InteractiveSurface.ReleaseMouseCapture();

        // Cancel remote Host-side drag safely: move remote drag cursor to the non-drop-target top-left corner (12, 12)
        // and send Esc BEFORE releasing leftMouseUp 45ms later so WeChat never drops the file back into the chat or opens a preview!
        if (_currentWindowId != 0)
        {
            uint winId = _currentWindowId;
            var b = _bridge;
            b.SendMouse(winId, 12f, 12f, type: 3, button: 0, clickCount: 0, modifiers: 0);
            b.SendKey(winId, 53 /* Esc */, isDown: true, isRepeat: false, modifiers: 0);
            b.SendKey(winId, 53 /* Esc */, isDown: false, isRepeat: false, modifiers: 0);
            _ = Task.Run(async () =>
            {
                await Task.Delay(45);
                b.SendKey(winId, 53 /* Esc */, isDown: true, isRepeat: false, modifiers: 0);
                b.SendKey(winId, 53 /* Esc */, isDown: false, isRepeat: false, modifiers: 0);
                b.SendMouse(winId, 12f, 12f, type: 2, button: 0, clickCount: 0, modifiers: 0);
            });
        }

        _onDebugLog?.Invoke($"已接管拖出 {dropPaths.Length} 个文件，可松手放到本机桌面/资源管理器");
        var dataObj = new System.Windows.DataObject(System.Windows.DataFormats.FileDrop, dropPaths);
        System.Windows.DragDropEffects finalEffect = System.Windows.DragDropEffects.None;
        try
        {
            finalEffect = DragDrop.DoDragDrop(InteractiveSurface, dataObj, allowedEffects);
        }
        finally
        {
            _isLeftMouseDown = false;
            _didStartLocalDragOut = false;
            DragOutTransferCoordinator.Shared.CompleteDragSession(preparedItems, finalEffect);
        }
    }

    // ========================================================================
    // Hover Titlebar Capsule Actions
    // ========================================================================

    private void HoverTitlebarPill_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ChangedButton == MouseButton.Left)
        {
            try { DragMove(); } catch { }
        }
    }

    private void CloseRemoteBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_currentWindowId == 0 || _currentWindowId == MultiWindowCaptureManager.FullDesktopWindowId)
            return;
        _bridge.SendKey(_currentWindowId, 13 /* W */, isDown: true, isRepeat: false, modifiers: KeyCodeMapper.ModCmd);
        _bridge.SendKey(_currentWindowId, 13 /* W */, isDown: false, isRepeat: false, modifiers: KeyCodeMapper.ModCmd);
    }

    public void SetAudioMuted(bool muted)
    {
        MuteAudioBtn.Content = muted ? "🔇" : "🔊";
        MuteAudioBtn.Foreground = muted
            ? new SolidColorBrush(System.Windows.Media.Color.FromRgb(148, 163, 184))
            : new SolidColorBrush(System.Windows.Media.Color.FromRgb(74, 222, 128));
        MuteAudioBtn.ToolTip = muted ? "远端声音已静音（点击开启声音）" : "远端声音已开启（点击静音）";
    }

    private void MuteAudioBtn_Click(object sender, RoutedEventArgs e)
    {
        OnToggleAudioMute?.Invoke();
    }

    private void CloseStreamBtn_Click(object sender, RoutedEventArgs e)
    {
        Close();
    }
}
