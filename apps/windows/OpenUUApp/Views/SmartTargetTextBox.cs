using System.Windows;
using System.Windows.Input;

namespace OpenUU.Views;

using OpenUU.Client;

/// <summary>
/// Specialized <see cref="System.Windows.Controls.TextBox"/> that automatically spaces 9-digit device codes
/// every 3 digits (<c>601 550 599</c>) without jumping the caret, strips stray whitespace from IPs/tickets,
/// and invokes <see cref="SubmitRequested"/> on Enter (Windows counterpart to macOS <c>SmartTargetTextField</c>).
/// </summary>
public sealed class SmartTargetTextBox : System.Windows.Controls.TextBox
{
    public static readonly DependencyProperty PlaceholderProperty =
        DependencyProperty.Register(nameof(Placeholder), typeof(string), typeof(SmartTargetTextBox), new PropertyMetadata(""));

    public string Placeholder
    {
        get => (string)GetValue(PlaceholderProperty);
        set => SetValue(PlaceholderProperty, value);
    }

    public event Action? SubmitRequested;

    private string _lastFormatted = "";
    private bool _isFormatting;

    public SmartTargetTextBox()
    {
        FontFamily = new System.Windows.Media.FontFamily("Consolas, Microsoft YaHei UI");
        TextChanged += OnInternalTextChanged;
        PreviewKeyDown += OnInternalPreviewKeyDown;
    }

    private void OnInternalTextChanged(object sender, System.Windows.Controls.TextChangedEventArgs e)
    {
        if (_isFormatting) return;

        string raw = Text ?? "";
        int caret = CaretIndex;
        var (formatted, newCaret) = DeviceCodeFormatter.FormatInputWithCursor(raw, caret, _lastFormatted);
        _lastFormatted = formatted;

        if (formatted != raw)
        {
            _isFormatting = true;
            Text = formatted;
            CaretIndex = Math.Clamp(newCaret, 0, formatted.Length);
            _isFormatting = false;
        }
    }

    private void OnInternalPreviewKeyDown(object sender, System.Windows.Input.KeyEventArgs e)
    {
        if ((e.Key == Key.Return || e.Key == Key.Enter) && SubmitRequested != null)
        {
            SubmitRequested.Invoke();
            e.Handled = true;
        }
    }
}
