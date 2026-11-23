using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;

namespace OpenUU.Views;

/// <summary>
/// Lightweight attached properties for modern placeholder watermarks and horizontal mouse-wheel scrolling.
/// </summary>
public static class UiAssist
{
    public static readonly DependencyProperty PlaceholderProperty =
        DependencyProperty.RegisterAttached(
            "Placeholder",
            typeof(string),
            typeof(UiAssist),
            new FrameworkPropertyMetadata(string.Empty)
        );

    public static string GetPlaceholder(DependencyObject obj) =>
        (string)obj.GetValue(PlaceholderProperty);

    public static void SetPlaceholder(DependencyObject obj, string value) =>
        obj.SetValue(PlaceholderProperty, value);

    public static readonly DependencyProperty HorizontalWheelScrollProperty =
        DependencyProperty.RegisterAttached(
            "HorizontalWheelScroll",
            typeof(bool),
            typeof(UiAssist),
            new PropertyMetadata(false, OnHorizontalWheelScrollChanged)
        );

    public static bool GetHorizontalWheelScroll(DependencyObject obj) =>
        (bool)obj.GetValue(HorizontalWheelScrollProperty);

    public static void SetHorizontalWheelScroll(DependencyObject obj, bool value) =>
        obj.SetValue(HorizontalWheelScrollProperty, value);

    private static void OnHorizontalWheelScrollChanged(DependencyObject d, DependencyPropertyChangedEventArgs e)
    {
        if (d is not ScrollViewer sv) return;
        sv.PreviewMouseWheel -= OnScrollViewerPreviewMouseWheel;
        if (e.NewValue is true)
        {
            sv.PreviewMouseWheel += OnScrollViewerPreviewMouseWheel;
        }
    }

    private static void OnScrollViewerPreviewMouseWheel(object sender, MouseWheelEventArgs e)
    {
        if (sender is not ScrollViewer sv) return;
        if (sv.ScrollableWidth <= 0) return;

        sv.ScrollToHorizontalOffset(sv.HorizontalOffset - e.Delta * 0.45);
        e.Handled = true;
    }
}
