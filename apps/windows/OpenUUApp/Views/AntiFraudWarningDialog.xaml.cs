using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;

namespace OpenUU.Views;

using OpenUU.Shared;

public partial class AntiFraudWarningDialog : Window
{
    private const int RequiredCountdownSeconds = 3;

    private readonly Stopwatch _stopwatch = new();
    private readonly DispatcherTimer _countdownTimer;
    private bool _explicitCloseAllowed;

    public bool DontShowAgain { get; private set; }

    public AntiFraudWarningDialog()
    {
        InitializeComponent();

        _countdownTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(100)
        };
        _countdownTimer.Tick += OnCountdownTick;

        SourceInitialized += (_, _) =>
        {
            IntPtr hwnd = new WindowInteropHelper(this).Handle;
            int roundPref = Win32Interop.DWMWCP_ROUND;
            Win32Interop.DwmSetWindowAttribute(hwnd, Win32Interop.DWMWA_WINDOW_CORNER_PREFERENCE, ref roundPref, sizeof(int));
        };

        Loaded += (_, _) =>
        {
            ConfirmBtn.IsEnabled = false;
            ConfirmBtn.Content = $"我知道了 ({RequiredCountdownSeconds}s)";
            _stopwatch.Restart();
            _countdownTimer.Start();
        };

        PreviewKeyDown += OnPreviewKeyDown;
    }

    private void OnCountdownTick(object? sender, EventArgs e)
    {
        double elapsedSec = _stopwatch.Elapsed.TotalSeconds;
        if (elapsedSec >= RequiredCountdownSeconds)
        {
            _countdownTimer.Stop();
            ConfirmBtn.Content = "我知道了";
            ConfirmBtn.IsEnabled = true;
            return;
        }

        int remaining = Math.Max(1, (int)Math.Ceiling(RequiredCountdownSeconds - elapsedSec));
        string label = $"我知道了 ({remaining}s)";
        if (!Equals(ConfirmBtn.Content, label))
        {
            ConfirmBtn.Content = label;
        }
    }

    private void OnPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        // Prevent Esc / Alt+F4 / Space / Enter from accidentally dismissing the anti-fraud warning
        if (e.Key == Key.Escape || (e.Key == Key.System && e.SystemKey == Key.F4))
        {
            e.Handled = true;
        }
    }

    protected override void OnClosing(CancelEventArgs e)
    {
        if (!_explicitCloseAllowed)
        {
            e.Cancel = true;
            return;
        }
        _countdownTimer.Stop();
        base.OnClosing(e);
    }

    private void Header_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed)
        {
            try { DragMove(); } catch { }
        }
    }

    private void CancelBtn_Click(object sender, RoutedEventArgs e)
    {
        DontShowAgain = false;
        _explicitCloseAllowed = true;
        DialogResult = false;
        Close();
    }

    private void ConfirmBtn_Click(object sender, RoutedEventArgs e)
    {
        if (_stopwatch.Elapsed.TotalSeconds < RequiredCountdownSeconds)
            return;

        DontShowAgain = DontShowAgainCheck.IsChecked == true;
        _explicitCloseAllowed = true;
        DialogResult = true;
        Close();
    }
}
