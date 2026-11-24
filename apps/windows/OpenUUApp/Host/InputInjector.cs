using System.Collections.Concurrent;
using System.Runtime.InteropServices;

namespace OpenUU.Host;

using OpenUU.Shared;

/// <summary>
/// Delivers remote mouse, scroll, keyboard, window resize, and IME text events to the target Windows window
/// or full desktop using standard Win32 input APIs.
/// </summary>
public sealed class InputInjector : IDisposable
{
    private readonly BlockingCollection<Action> _queue = new(1024);
    private readonly Thread _workerThread;
    private volatile bool _disposed;

    private Win32Interop.POINT? _savedHostCursor;
    private CancellationTokenSource? _restoreCursorCts;
    private bool _isRemoteButtonDown;
    private long _lastHoverTickMs;
    private long _lastUipiWarnTickMs;
    private string _lastCursorKind = "";

    public bool IsCurrentProcessAdmin { get; set; }
    public bool SilentMode { get; set; } = true;
    public bool HoverCursorSync { get; set; } = true;

    public Action<string>? OnDebugLog { get; set; }
    public Action<string>? OnCursorKindChanged { get; set; }
    public Action<uint>? OnNormalWindowInteracted { get; set; }

    private static readonly Lazy<Dictionary<IntPtr, string>> SystemCursorHandles = new(BuildCursorMap);

    public InputInjector()
    {
        _workerThread = new Thread(WorkerLoop)
        {
            IsBackground = true,
            Name = "OpenUU-InputWorker"
        };
        _workerThread.Start();
    }

    public void HandleControlEvent(ControlEventMessage msg)
    {
        if (_disposed) return;
        _queue.TryAdd(() => ProcessControlEvent(msg));
    }

    public void PasteDroppedFiles(uint windowId, IReadOnlyList<string> filePaths)
    {
        if (_disposed || filePaths.Count == 0) return;
        _queue.TryAdd(() =>
        {
            IntPtr hwnd = ResolveHwnd(windowId);
            if (hwnd == IntPtr.Zero) return;
            ActivateWindowForInput(hwnd, isPopup: false);
            Thread.Sleep(55);
            SendKeyChord(0x56 /* V */, KeyCodeMapper.ModCtrl);
            var names = string.Join(", ", filePaths.Select(System.IO.Path.GetFileName));
            OnDebugLog?.Invoke($"已粘贴拖入文件: {names}");
        });
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _restoreCursorCts?.Cancel();
        _queue.CompleteAdding();
    }

    private void WorkerLoop()
    {
        foreach (var work in _queue.GetConsumingEnumerable())
        {
            if (_disposed) break;
            try { work(); }
            catch { }
        }
    }

    private static IntPtr ResolveHwnd(uint windowId)
    {
        if (windowId == 0 || windowId == MultiWindowCaptureManager.FullDesktopWindowId)
            return IntPtr.Zero;
        var hwnd = new IntPtr(unchecked((int)windowId));
        return Win32Interop.IsWindow(hwnd) ? hwnd : IntPtr.Zero;
    }

    private void ProcessControlEvent(ControlEventMessage msg)
    {
        uint winId = msg.WindowId ?? 0;
        if (winId == MultiWindowCaptureManager.FullDesktopWindowId)
        {
            ProcessFullDesktopEvent(msg);
            return;
        }

        IntPtr hwnd = ResolveHwnd(winId);
        if (hwnd == IntPtr.Zero)
        {
            OnDebugLog?.Invoke($"收到远程输入，但目标窗口不存在 (win={winId})");
            return;
        }

        bool isPopup = Win32Interop.IsFloatingMenuOrPopup(hwnd);

        if (!IsCurrentProcessAdmin &&
            ((msg.Type == "mouse" && msg.EventType == 1) || msg.Type is "key" or "text_commit" or "scroll"))
        {
            Win32Interop.GetWindowThreadProcessId(hwnd, out uint targetPid);
            if (targetPid != 0 && Win32Interop.IsProcessElevated(targetPid))
            {
                WarnUipiBlocked(hwnd, targetPid);
                return;
            }
        }

        if (!isPopup &&
            ((msg.Type == "mouse" && msg.EventType is 1 or 2 or 3) ||
             msg.Type is "scroll" or "key" or "text_commit"))
        {
            OnNormalWindowInteracted?.Invoke(winId);
        }

        var bounds = Win32Interop.GetVisibleWindowBounds(hwnd);
        double dpiScale = Win32Interop.GetDpiScale(hwnd);

        switch (msg.Type)
        {
            case "mouse":
            {
                int type = msg.EventType ?? 0;
                if (type == 4) // Cursor exited proxy window
                {
                    ScheduleHostCursorRestore(20);
                    return;
                }

                int px = bounds.Left + (int)Math.Round((msg.X ?? 0f) * dpiScale);
                int py = bounds.Top + (int)Math.Round((msg.Y ?? 0f) * dpiScale);
                px = Math.Clamp(px, bounds.Left + 1, Math.Max(bounds.Left + 1, bounds.Right - 2));
                py = Math.Clamp(py, bounds.Top + 1, Math.Max(bounds.Top + 1, bounds.Bottom - 2));

                if (type == 0) // Hover move
                {
                    long nowMs = Environment.TickCount64;
                    if (nowMs - _lastHoverTickMs < 30) return;
                    _lastHoverTickMs = nowMs;

                    if (!isPopup && (!HoverCursorSync || SilentMode))
                        return;

                    SendMouseAbsolute(px, py, Win32Interop.MOUSEEVENTF_MOVE, 0);
                    InspectAndEmitCursor();
                    return;
                }

                uint button = msg.Button ?? 0;
                if (type == 1) // Down
                {
                    _isRemoteButtonDown = true;
                    SaveHostCursorBeforeWarp();
                    ActivateWindowForInput(hwnd, isPopup);
                    SendMouseAbsolute(px, py, Win32Interop.MOUSEEVENTF_MOVE, 0);
                    Thread.Sleep(8);
                    uint downFlag = button == 1
                        ? Win32Interop.MOUSEEVENTF_RIGHTDOWN
                        : (button == 2 ? Win32Interop.MOUSEEVENTF_MIDDLEDOWN : Win32Interop.MOUSEEVENTF_LEFTDOWN);
                    SendMouseAbsolute(px, py, downFlag, 0);
                    InspectAndEmitCursor();
                }
                else if (type == 3) // Drag
                {
                    _restoreCursorCts?.Cancel();
                    SendMouseAbsolute(px, py, Win32Interop.MOUSEEVENTF_MOVE, 0);
                }
                else if (type == 2) // Up
                {
                    _isRemoteButtonDown = false;
                    uint upFlag = button == 1
                        ? Win32Interop.MOUSEEVENTF_RIGHTUP
                        : (button == 2 ? Win32Interop.MOUSEEVENTF_MIDDLEUP : Win32Interop.MOUSEEVENTF_LEFTUP);
                    SendMouseAbsolute(px, py, upFlag, 0);
                    InspectAndEmitCursor();
                    ScheduleHostCursorRestore(65);
                }
                break;
            }

            case "scroll":
            {
                int px = bounds.Left + (int)Math.Round((msg.X ?? 0f) * dpiScale);
                int py = bounds.Top + (int)Math.Round((msg.Y ?? 0f) * dpiScale);
                SaveHostCursorBeforeWarp();
                SendMouseAbsolute(px, py, Win32Interop.MOUSEEVENTF_MOVE, 0);
                EmitScroll(msg.DeltaX ?? 0f, msg.DeltaY ?? 0f, msg.IsContinuous ?? true);
                ScheduleHostCursorRestore(35);
                break;
            }

            case "key":
            {
                ActivateWindowForInput(hwnd, isPopup);
                HandleKeyEvent(hwnd, msg.KeyCode ?? 0, msg.IsDown ?? true, msg.Modifiers ?? 0);
                break;
            }

            case "text_commit":
            {
                string? text = msg.Text;
                if (string.IsNullOrEmpty(text)) return;
                ActivateWindowForInput(hwnd, isPopup);
                SendUnicodeString(text);
                OnDebugLog?.Invoke($"已输入文本: {text}");
                break;
            }

            case "resize_window":
            {
                float w = msg.Width ?? 0f;
                float h = msg.Height ?? 0f;
                if (w < 80f || h < 80f || isPopup || Win32Interop.IsZoomed(hwnd)) return;
                ResizeTargetWindow(hwnd, w, h, dpiScale);
                break;
            }
        }
    }

    private void ProcessFullDesktopEvent(ControlEventMessage msg)
    {
        double dpi = Win32Interop.GetDpiScale(IntPtr.Zero);
        if (dpi <= 0.1) dpi = 1.0;

        switch (msg.Type)
        {
            case "mouse":
            {
                int type = msg.EventType ?? 0;
                if (type == 4) return;
                int px = (int)Math.Round((msg.X ?? 0f) * dpi);
                int py = (int)Math.Round((msg.Y ?? 0f) * dpi);
                uint button = msg.Button ?? 0;

                if (type == 0 || type == 3)
                {
                    SendMouseAbsolute(px, py, Win32Interop.MOUSEEVENTF_MOVE, 0);
                }
                else if (type == 1)
                {
                    SendMouseAbsolute(px, py, Win32Interop.MOUSEEVENTF_MOVE, 0);
                    uint downFlag = button == 1
                        ? Win32Interop.MOUSEEVENTF_RIGHTDOWN
                        : (button == 2 ? Win32Interop.MOUSEEVENTF_MIDDLEDOWN : Win32Interop.MOUSEEVENTF_LEFTDOWN);
                    if (SendMouseAbsolute(px, py, downFlag, 0) == 0 && !IsCurrentProcessAdmin)
                    {
                        WarnUipiBlocked(Win32Interop.GetForegroundWindow(), 0);
                    }
                }
                else if (type == 2)
                {
                    uint upFlag = button == 1
                        ? Win32Interop.MOUSEEVENTF_RIGHTUP
                        : (button == 2 ? Win32Interop.MOUSEEVENTF_MIDDLEUP : Win32Interop.MOUSEEVENTF_LEFTUP);
                    SendMouseAbsolute(px, py, upFlag, 0);
                }
                InspectAndEmitCursor();
                break;
            }
            case "scroll":
            {
                int px = (int)Math.Round((msg.X ?? 0f) * dpi);
                int py = (int)Math.Round((msg.Y ?? 0f) * dpi);
                SendMouseAbsolute(px, py, Win32Interop.MOUSEEVENTF_MOVE, 0);
                EmitScroll(msg.DeltaX ?? 0f, msg.DeltaY ?? 0f, msg.IsContinuous ?? true);
                break;
            }
            case "key":
            {
                HandleKeyEvent(IntPtr.Zero, msg.KeyCode ?? 0, msg.IsDown ?? true, msg.Modifiers ?? 0);
                break;
            }
            case "text_commit":
            {
                if (!string.IsNullOrEmpty(msg.Text))
                    SendUnicodeString(msg.Text);
                break;
            }
        }
    }

    private void WarnUipiBlocked(IntPtr hwnd, uint pid)
    {
        long now = Environment.TickCount64;
        if (now - _lastUipiWarnTickMs < 2500) return;
        _lastUipiWarnTickMs = now;

        string title = hwnd != IntPtr.Zero ? Win32Interop.GetWindowTitle(hwnd).Trim() : "";
        string label = !string.IsNullOrEmpty(title) ? title : (pid != 0 ? $"PID {pid}" : "管理员窗口");
        OpenUULogger.Shared.Warn("INPUT", $"UIPI blocked input to elevated window '{label}' (pid={pid}) while OpenUU admin=False");
        OnDebugLog?.Invoke($"权限受限：目标窗口「{label}」正以管理员权限运行，请在被控端点击「🛡 管理员提权」");
    }

    private static void ActivateWindowForInput(IntPtr hwnd, bool isPopup)
    {
        if (hwnd == IntPtr.Zero || isPopup) return;
        if (Win32Interop.IsIconic(hwnd))
            Win32Interop.ShowWindow(hwnd, Win32Interop.SW_RESTORE);

        IntPtr fg = Win32Interop.GetForegroundWindow();
        if (fg == hwnd) return;

        // Avoid raising main window if foreground window is already an active floating menu/popover of the same process
        if (fg != IntPtr.Zero)
        {
            Win32Interop.GetWindowThreadProcessId(fg, out uint fgPid);
            Win32Interop.GetWindowThreadProcessId(hwnd, out uint targetPid);
            if (fgPid == targetPid && Win32Interop.IsFloatingMenuOrPopup(fg))
            {
                return;
            }
        }

        uint curThread = Win32Interop.GetCurrentThreadId();
        uint fgThread = fg != IntPtr.Zero ? Win32Interop.GetWindowThreadProcessId(fg, out _) : 0;
        bool attached = false;
        if (fgThread != 0 && fgThread != curThread)
            attached = Win32Interop.AttachThreadInput(curThread, fgThread, true);

        Win32Interop.BringWindowToTop(hwnd);
        Win32Interop.SetForegroundWindow(hwnd);

        if (attached)
            Win32Interop.AttachThreadInput(curThread, fgThread, false);

        // If Windows Foreground Lock prevented SetForegroundWindow from raising hwnd above covering windows,
        // lift hwnd to the top of the normal Z-order so SendInput clicks land directly on hwnd (not on an overlapping window).
        if (Win32Interop.GetForegroundWindow() != hwnd)
        {
            uint exStyle = Win32Interop.GetWindowLong(hwnd, Win32Interop.GWL_EXSTYLE);
            if ((exStyle & Win32Interop.WS_EX_TOPMOST) == 0)
            {
                const uint flags = Win32Interop.SWP_NOMOVE | Win32Interop.SWP_NOSIZE | Win32Interop.SWP_NOACTIVATE;
                Win32Interop.SetWindowPos(hwnd, Win32Interop.HWND_TOPMOST, 0, 0, 0, 0, flags);
                Win32Interop.SetWindowPos(hwnd, Win32Interop.HWND_NOTOPMOST, 0, 0, 0, 0, flags);
            }
            Win32Interop.SetForegroundWindow(hwnd);
        }
    }

    private static void ResizeTargetWindow(IntPtr hwnd, float logicalW, float logicalH, double dpiScale)
    {
        if (!Win32Interop.GetWindowRect(hwnd, out var rawRect)) return;
        var visRect = Win32Interop.GetVisibleWindowBounds(hwnd);

        // Preserve DWM invisible shadow frame margin when calling SetWindowPos
        int borderW = Math.Max(0, rawRect.Width - visRect.Width);
        int borderH = Math.Max(0, rawRect.Height - visRect.Height);

        int targetVisW = Math.Max(160, (int)Math.Round(logicalW * dpiScale));
        int targetVisH = Math.Max(120, (int)Math.Round(logicalH * dpiScale));
        if (Math.Abs(targetVisW - visRect.Width) < 4 && Math.Abs(targetVisH - visRect.Height) < 4)
            return;

        Win32Interop.SetWindowPos(
            hwnd,
            IntPtr.Zero,
            0,
            0,
            targetVisW + borderW,
            targetVisH + borderH,
            Win32Interop.SWP_NOMOVE | Win32Interop.SWP_NOZORDER | Win32Interop.SWP_NOACTIVATE | Win32Interop.SWP_ASYNCWINDOWPOS
        );
    }

    private void SaveHostCursorBeforeWarp()
    {
        if (!SilentMode) return;
        _restoreCursorCts?.Cancel();
        if (_savedHostCursor == null && Win32Interop.GetCursorPos(out var pt))
            _savedHostCursor = pt;
    }

    private void ScheduleHostCursorRestore(int delayMs)
    {
        if (!SilentMode)
        {
            _savedHostCursor = null;
            return;
        }
        _restoreCursorCts?.Cancel();
        var cts = new CancellationTokenSource();
        _restoreCursorCts = cts;
        var ct = cts.Token;
        _ = Task.Run(async () =>
        {
            try
            {
                await Task.Delay(delayMs, ct);
                if (!_isRemoteButtonDown && _savedHostCursor is { } saved)
                {
                    _savedHostCursor = null;
                    Win32Interop.SetCursorPos(saved.X, saved.Y);
                }
            }
            catch
            {
            }
        }, ct);
    }

    private static uint SendMouseAbsolute(int screenX, int screenY, uint mouseFlags, int wheelDelta)
    {
        int vx = Win32Interop.GetSystemMetrics(Win32Interop.SM_XVIRTUALSCREEN);
        int vy = Win32Interop.GetSystemMetrics(Win32Interop.SM_YVIRTUALSCREEN);
        int vw = Math.Max(1, Win32Interop.GetSystemMetrics(Win32Interop.SM_CXVIRTUALSCREEN));
        int vh = Math.Max(1, Win32Interop.GetSystemMetrics(Win32Interop.SM_CYVIRTUALSCREEN));

        int absX = (int)Math.Round(((screenX - vx) * 65535.0) / Math.Max(1, vw - 1));
        int absY = (int)Math.Round(((screenY - vy) * 65535.0) / Math.Max(1, vh - 1));

        var input = new Win32Interop.INPUT
        {
            type = Win32Interop.INPUT_MOUSE,
            U = new Win32Interop.InputUnion
            {
                mi = new Win32Interop.MOUSEINPUT
                {
                    dx = absX,
                    dy = absY,
                    mouseData = wheelDelta,
                    dwFlags = mouseFlags | Win32Interop.MOUSEEVENTF_ABSOLUTE | Win32Interop.MOUSEEVENTF_VIRTUALDESK
                }
            }
        };
        return Win32Interop.SendInput(1, new[] { input }, Marshal.SizeOf<Win32Interop.INPUT>());
    }

    private static void EmitScroll(float deltaX, float deltaY, bool isContinuous)
    {
        float scale = isContinuous ? 3.5f : 120f;
        int wheelY = (int)Math.Round(deltaY * scale);
        int wheelX = (int)Math.Round(-deltaX * scale);

        if (wheelY != 0)
        {
            var inY = new Win32Interop.INPUT
            {
                type = Win32Interop.INPUT_MOUSE,
                U = new Win32Interop.InputUnion
                {
                    mi = new Win32Interop.MOUSEINPUT
                    {
                        mouseData = wheelY,
                        dwFlags = Win32Interop.MOUSEEVENTF_WHEEL
                    }
                }
            };
            Win32Interop.SendInput(1, new[] { inY }, Marshal.SizeOf<Win32Interop.INPUT>());
        }

        if (wheelX != 0)
        {
            var inX = new Win32Interop.INPUT
            {
                type = Win32Interop.INPUT_MOUSE,
                U = new Win32Interop.InputUnion
                {
                    mi = new Win32Interop.MOUSEINPUT
                    {
                        mouseData = wheelX,
                        dwFlags = Win32Interop.MOUSEEVENTF_HWHEEL
                    }
                }
            };
            Win32Interop.SendInput(1, new[] { inX }, Marshal.SizeOf<Win32Interop.INPUT>());
        }
    }

    private static void HandleKeyEvent(IntPtr hwnd, uint cgKeyCode, bool isDown, uint modifiers)
    {
        // Close remote window request from macOS / iOS / Android client (Cmd+W: keyCode=13, modifiers=8)
        if (hwnd != IntPtr.Zero && cgKeyCode == 13 /* W */ && (modifiers & KeyCodeMapper.ModCmd) != 0)
        {
            if (isDown)
                Win32Interop.PostMessage(hwnd, Win32Interop.WM_CLOSE, IntPtr.Zero, IntPtr.Zero);
            return;
        }

        if (!KeyCodeMapper.TryMapCgKeyCodeToVk(cgKeyCode, out ushort vk))
            return;

        // Translate Mac/iOS/Android Command+<Key> shortcuts (Copy/Paste/Cut/Undo/SelectAll/Save/Find) into Windows Ctrl+<Key>
        bool cmdAsCtrl = (modifiers & KeyCodeMapper.ModCmd) != 0 && vk is >= 0x30 and <= 0x5A;
        bool wantCtrl = ((modifiers & KeyCodeMapper.ModCtrl) != 0) || cmdAsCtrl;
        bool wantShift = (modifiers & KeyCodeMapper.ModShift) != 0;
        bool wantAlt = (modifiers & KeyCodeMapper.ModAlt) != 0;

        if (isDown && vk == 0x56 /* V */ && wantCtrl)
        {
            Thread.Sleep(15); // Allow pre-paste ClipboardSync to settle on STA clipboard
        }

        var inputs = new List<Win32Interop.INPUT>(8);
        bool isModifierKey = vk is 0x10 or 0xA0 or 0xA1 or 0x11 or 0xA2 or 0xA3 or 0x12 or 0xA4 or 0xA5 or 0x5B or 0x5C;

        if (isDown && !isModifierKey)
        {
            if (wantCtrl) inputs.Add(MakeVkInput(0x11, true));
            if (wantShift) inputs.Add(MakeVkInput(0x10, true));
            if (wantAlt) inputs.Add(MakeVkInput(0x12, true));
        }

        inputs.Add(MakeVkInput(vk, isDown));

        if (!isDown && !isModifierKey)
        {
            if (wantAlt) inputs.Add(MakeVkInput(0x12, false));
            if (wantShift) inputs.Add(MakeVkInput(0x10, false));
            if (wantCtrl) inputs.Add(MakeVkInput(0x11, false));
        }

        Win32Interop.SendInput((uint)inputs.Count, inputs.ToArray(), Marshal.SizeOf<Win32Interop.INPUT>());
    }

    private static void SendKeyChord(ushort vk, uint modifiers)
    {
        var list = new List<Win32Interop.INPUT>(4);
        if ((modifiers & KeyCodeMapper.ModCtrl) != 0) list.Add(MakeVkInput(0x11, true));
        list.Add(MakeVkInput(vk, true));
        list.Add(MakeVkInput(vk, false));
        if ((modifiers & KeyCodeMapper.ModCtrl) != 0) list.Add(MakeVkInput(0x11, false));
        Win32Interop.SendInput((uint)list.Count, list.ToArray(), Marshal.SizeOf<Win32Interop.INPUT>());
    }

    private static Win32Interop.INPUT MakeVkInput(ushort vk, bool isDown)
    {
        ushort scan = (ushort)Win32Interop.MapVirtualKey(vk, 0);
        uint flags = isDown ? 0u : Win32Interop.KEYEVENTF_KEYUP;
        if (vk is >= 0x21 and <= 0x2E or 0x5B or 0x5C)
            flags |= Win32Interop.KEYEVENTF_EXTENDEDKEY;

        return new Win32Interop.INPUT
        {
            type = Win32Interop.INPUT_KEYBOARD,
            U = new Win32Interop.InputUnion
            {
                ki = new Win32Interop.KEYBDINPUT
                {
                    wVk = vk,
                    wScan = scan,
                    dwFlags = flags
                }
            }
        };
    }

    private static void SendUnicodeString(string text)
    {
        var inputs = new Win32Interop.INPUT[text.Length * 2];
        for (int i = 0; i < text.Length; i++)
        {
            ushort ch = text[i];
            inputs[i * 2] = new Win32Interop.INPUT
            {
                type = Win32Interop.INPUT_KEYBOARD,
                U = new Win32Interop.InputUnion
                {
                    ki = new Win32Interop.KEYBDINPUT
                    {
                        wVk = 0,
                        wScan = ch,
                        dwFlags = Win32Interop.KEYEVENTF_UNICODE
                    }
                }
            };
            inputs[i * 2 + 1] = new Win32Interop.INPUT
            {
                type = Win32Interop.INPUT_KEYBOARD,
                U = new Win32Interop.InputUnion
                {
                    ki = new Win32Interop.KEYBDINPUT
                    {
                        wVk = 0,
                        wScan = ch,
                        dwFlags = Win32Interop.KEYEVENTF_UNICODE | Win32Interop.KEYEVENTF_KEYUP
                    }
                }
            };
        }
        Win32Interop.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Win32Interop.INPUT>());
    }

    private void InspectAndEmitCursor()
    {
        var ci = new Win32Interop.CURSORINFO { cbSize = Marshal.SizeOf<Win32Interop.CURSORINFO>() };
        if (!Win32Interop.GetCursorInfo(ref ci) || ci.hCursor == IntPtr.Zero)
            return;

        string kind = SystemCursorHandles.Value.TryGetValue(ci.hCursor, out var mapped) ? mapped : "arrow";
        if (kind != _lastCursorKind)
        {
            _lastCursorKind = kind;
            OnCursorKindChanged?.Invoke(kind);
        }
    }

    private static Dictionary<IntPtr, string> BuildCursorMap()
    {
        var map = new Dictionary<IntPtr, string>();
        void Add(int id, string name)
        {
            IntPtr h = Win32Interop.LoadCursor(IntPtr.Zero, id);
            if (h != IntPtr.Zero) map[h] = name;
        }
        Add(Win32Interop.IDC_ARROW, "arrow");
        Add(Win32Interop.IDC_IBEAM, "ibeam");
        Add(Win32Interop.IDC_HAND, "pointing_hand");
        Add(Win32Interop.IDC_SIZEWE, "resize_lr");
        Add(Win32Interop.IDC_SIZENS, "resize_ud");
        Add(Win32Interop.IDC_SIZENWSE, "resize_lr");
        Add(Win32Interop.IDC_SIZENESW, "resize_lr");
        Add(Win32Interop.IDC_SIZEALL, "open_hand");
        Add(Win32Interop.IDC_CROSS, "crosshair");
        return map;
    }
}
