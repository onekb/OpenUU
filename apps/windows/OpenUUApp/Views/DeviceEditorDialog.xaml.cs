using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;

namespace OpenUU.Views;

using OpenUU.Client;
using OpenUU.Shared;

public partial class DeviceEditorDialog : Window
{
    public string ResultAlias { get; private set; } = "";
    public string ResultTarget { get; private set; } = "";
    public ushort ResultPort { get; private set; } = 39481;
    public string ResultPassword { get; private set; } = "";
    public string ResultGroup { get; private set; } = "常用";
    public bool ResultFavorite { get; private set; }
    public string ResultNotes { get; private set; } = "";

    public DeviceEditorDialog(ManagedRemoteDevice? existing = null)
    {
        InitializeComponent();

        SourceInitialized += (_, _) =>
        {
            IntPtr hwnd = new WindowInteropHelper(this).Handle;
            int roundPref = Win32Interop.DWMWCP_ROUND;
            Win32Interop.DwmSetWindowAttribute(hwnd, Win32Interop.DWMWA_WINDOW_CORNER_PREFERENCE, ref roundPref, sizeof(int));
        };

        foreach (var g in DeviceBookStore.DefaultGroups)
            GroupCombo.Items.Add(g);

        if (existing != null)
        {
            DialogHeading.Text = "编辑受控端设备";
            Title = "编辑受控端设备";
            AliasBox.Text = existing.Alias;
            TargetBox.Text = DeviceCodeFormatter.FormatInput(existing.Target);
            PortBox.Text = existing.Port.ToString();
            PasswordBox.Text = existing.SavedPassword;
            GroupCombo.Text = string.IsNullOrWhiteSpace(existing.GroupTag) ? "常用" : existing.GroupTag;
            NotesBox.Text = existing.Notes;
            FavoriteCheck.IsChecked = existing.IsFavorite;
        }
        else
        {
            GroupCombo.SelectedIndex = 0;
        }

        TargetBox.TextChanged += (_, _) => UpdateSaveEnabled();
        UpdateSaveEnabled();
    }

    private void Header_MouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ButtonState == MouseButtonState.Pressed)
        {
            try { DragMove(); } catch { }
        }
    }

    private void UpdateSaveEnabled()
    {
        SaveBtn.IsEnabled = !string.IsNullOrEmpty(DeviceCodeFormatter.SanitizeForUse(TargetBox.Text));
    }

    private void CancelBtn_Click(object sender, RoutedEventArgs e)
    {
        DialogResult = false;
        Close();
    }

    private void SaveBtn_Click(object sender, RoutedEventArgs e)
    {
        string cleanTarget = DeviceCodeFormatter.SanitizeForUse(TargetBox.Text);
        if (string.IsNullOrEmpty(cleanTarget)) return;

        ResultAlias = AliasBox.Text.Trim();
        ResultTarget = cleanTarget;
        ResultPort = ushort.TryParse(PortBox.Text.Trim(), out ushort p) && p > 0 ? p : (ushort)39481;
        ResultPassword = PasswordBox.Text.Trim();
        ResultGroup = string.IsNullOrWhiteSpace(GroupCombo.Text) ? "常用" : GroupCombo.Text.Trim();
        ResultFavorite = FavoriteCheck.IsChecked == true;
        ResultNotes = NotesBox.Text.Trim();

        DialogResult = true;
        Close();
    }
}
