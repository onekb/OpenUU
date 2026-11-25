using System.Windows.Input;

namespace OpenUU.Shared;

/// <summary>
/// Bidirectional translation between Windows <see cref="Key"/> / Win32 <c>VK_*</c> virtual-key codes and
/// OpenUU wire protocol <c>CGKeyCode</c> (macOS virtual keycodes in <c>openuu.proto</c>), plus smart
/// <c>Ctrl</c> &lt;-&gt; <c>Command</c> modifier adaptation across Windows and macOS peers.
/// </summary>
public static class KeyCodeMapper
{
    // Protocol modifier bitmask: 1=Shift, 2=Ctrl, 4=Opt/Alt, 8=Cmd/Meta
    public const uint ModShift = 1;
    public const uint ModCtrl  = 2;
    public const uint ModAlt   = 4;
    public const uint ModCmd   = 8;

    private static readonly Dictionary<int, uint> VkToCgKeyCode = new()
    {
        // Letters A-Z
        [0x41] = 0,   // A
        [0x53] = 1,   // S
        [0x44] = 2,   // D
        [0x46] = 3,   // F
        [0x48] = 4,   // H
        [0x47] = 5,   // G
        [0x5A] = 6,   // Z
        [0x58] = 7,   // X
        [0x43] = 8,   // C
        [0x56] = 9,   // V
        [0x42] = 11,  // B
        [0x51] = 12,  // Q
        [0x57] = 13,  // W
        [0x45] = 14,  // E
        [0x52] = 15,  // R
        [0x59] = 16,  // Y
        [0x54] = 17,  // T
        [0x31] = 18,  // 1
        [0x32] = 19,  // 2
        [0x33] = 20,  // 3
        [0x34] = 21,  // 4
        [0x36] = 22,  // 6
        [0x35] = 23,  // 5
        [0xBB] = 24,  // = / +
        [0x39] = 25,  // 9
        [0x37] = 26,  // 7
        [0xBD] = 27,  // - / _
        [0x38] = 28,  // 8
        [0x30] = 29,  // 0
        [0xDD] = 30,  // ]
        [0x4F] = 31,  // O
        [0x55] = 32,  // U
        [0xDB] = 33,  // [
        [0x49] = 34,  // I
        [0x50] = 35,  // P
        [0x0D] = 36,  // Enter / Return
        [0x4C] = 37,  // L
        [0x4A] = 38,  // J
        [0xDE] = 39,  // '
        [0x4B] = 40,  // K
        [0xBA] = 41,  // ;
        [0xDC] = 42,  // \
        [0xBC] = 43,  // ,
        [0xBF] = 44,  // /
        [0x4E] = 45,  // N
        [0x4D] = 46,  // M
        [0xBE] = 47,  // .
        [0x09] = 48,  // Tab
        [0x20] = 49,  // Space
        [0xC0] = 50,  // ` ~
        [0x08] = 51,  // Backspace
        [0x1B] = 53,  // Escape

        // Modifiers
        [0x5B] = 55,  // LWin -> Command
        [0x5C] = 54,  // RWin -> Right Command
        [0x10] = 56,  // Shift
        [0xA0] = 56,  // LShift
        [0xA1] = 60,  // RShift
        [0x14] = 57,  // CapsLock
        [0x12] = 58,  // Alt / Menu -> Option
        [0xA4] = 58,  // LMenu
        [0xA5] = 61,  // RMenu
        [0x11] = 59,  // Control
        [0xA2] = 59,  // LControl
        [0xA3] = 62,  // RControl

        // Navigation & Function keys
        [0x2E] = 117, // Forward Delete
        [0x24] = 115, // Home
        [0x23] = 119, // End
        [0x21] = 116, // PageUp
        [0x22] = 121, // PageDown
        [0x25] = 123, // Left
        [0x27] = 124, // Right
        [0x28] = 125, // Down
        [0x26] = 126, // Up

        [0x70] = 122, // F1
        [0x71] = 120, // F2
        [0x72] = 99,  // F3
        [0x73] = 118, // F4
        [0x74] = 96,  // F5
        [0x75] = 97,  // F6
        [0x76] = 98,  // F7
        [0x77] = 100, // F8
        [0x78] = 101, // F9
        [0x79] = 109, // F10
        [0x7A] = 103, // F11
        [0x7B] = 111, // F12
        [0x7C] = 105, // F13
        [0x7D] = 107, // F14
        [0x7E] = 113, // F15
        [0x7F] = 106, // F16
        [0x80] = 64,  // F17
        [0x81] = 79,  // F18
        [0x82] = 80,  // F19

        // Numeric Keypad (placed after main-row keys so reverse table preserves main-row VKs for 0..9)
        [0x0C] = 71,  // VK_CLEAR -> Keypad Clear
        [0x60] = 82,  // VK_NUMPAD0
        [0x61] = 83,  // VK_NUMPAD1
        [0x62] = 84,  // VK_NUMPAD2
        [0x63] = 85,  // VK_NUMPAD3
        [0x64] = 86,  // VK_NUMPAD4
        [0x65] = 87,  // VK_NUMPAD5
        [0x66] = 88,  // VK_NUMPAD6
        [0x67] = 89,  // VK_NUMPAD7
        [0x68] = 91,  // VK_NUMPAD8
        [0x69] = 92,  // VK_NUMPAD9
        [0x6A] = 67,  // VK_MULTIPLY -> Keypad *
        [0x6B] = 69,  // VK_ADD      -> Keypad +
        [0x6D] = 78,  // VK_SUBTRACT -> Keypad -
        [0x6E] = 65,  // VK_DECIMAL  -> Keypad .
        [0x6F] = 75,  // VK_DIVIDE   -> Keypad /
    };

    private static readonly Dictionary<uint, ushort> CgKeyCodeToVk = BuildReverseTable();

    private static Dictionary<uint, ushort> BuildReverseTable()
    {
        var rev = new Dictionary<uint, ushort>();
        foreach (var kv in VkToCgKeyCode)
        {
            if (!rev.ContainsKey(kv.Value))
                rev[kv.Value] = (ushort)kv.Key;
        }
        // macOS Numeric Keypad virtual keycodes -> Win32 VK_* equivalents
        rev[76] = 0x0D; // kVK_ANSI_KeypadEnter -> VK_RETURN
        rev[65] = 0x6E; // kVK_ANSI_KeypadDecimal -> VK_DECIMAL
        rev[67] = 0x6A; // kVK_ANSI_KeypadMultiply -> VK_MULTIPLY
        rev[69] = 0x6B; // kVK_ANSI_KeypadPlus -> VK_ADD
        rev[75] = 0x6F; // kVK_ANSI_KeypadDivide -> VK_DIVIDE
        rev[78] = 0x6D; // kVK_ANSI_KeypadMinus -> VK_SUBTRACT
        rev[81] = 0xBB; // kVK_ANSI_KeypadEquals -> VK_OEM_PLUS
        rev[82] = 0x60; // Keypad 0
        rev[83] = 0x61; // Keypad 1
        rev[84] = 0x62; // Keypad 2
        rev[85] = 0x63; // Keypad 3
        rev[86] = 0x64; // Keypad 4
        rev[87] = 0x65; // Keypad 5
        rev[88] = 0x66; // Keypad 6
        rev[89] = 0x67; // Keypad 7
        rev[91] = 0x68; // Keypad 8
        rev[92] = 0x69; // Keypad 9
        return rev;
    }

    public static bool TryMapWpfKeyToCgKeyCode(Key key, out uint cgKeyCode, out int vk)
    {
        vk = KeyInterop.VirtualKeyFromKey(key);
        if (VkToCgKeyCode.TryGetValue(vk, out cgKeyCode))
            return true;
        cgKeyCode = 0;
        return false;
    }

    public static bool TryMapCgKeyCodeToVk(uint cgKeyCode, out ushort vk)
        => CgKeyCodeToVk.TryGetValue(cgKeyCode, out vk);

    public static bool IsNonTextControlVk(int vk) => vk switch
    {
        0x08 or 0x09 or 0x0C or 0x0D or 0x1B or 0x21 or 0x22 or 0x23 or 0x24 or
        0x25 or 0x26 or 0x27 or 0x28 or 0x2D or 0x2E => true,
        >= 0x70 and <= 0x82 => true, // F1..F19
        _ => false
    };

    /// <summary>
    /// Computes the OpenUU modifier bitmask from current WPF <see cref="ModifierKeys"/>.
    /// When <paramref name="mapCtrlToMacCommand"/> is enabled (controlling a macOS Host from a Windows keyboard),
    /// <c>Ctrl + Key</c> shortcuts (Copy, Paste, Undo, Save, Close Tab, etc.) map cleanly to macOS <c>Command (⌘)</c>.
    /// </summary>
    public static uint BuildClientModifiers(ModifierKeys mods, bool mapCtrlToMacCommand)
    {
        uint mask = 0;
        if (mods.HasFlag(ModifierKeys.Shift)) mask |= ModShift;
        if (mods.HasFlag(ModifierKeys.Alt)) mask |= ModAlt;

        bool hasCtrl = mods.HasFlag(ModifierKeys.Control);
        bool hasWin = (Keyboard.IsKeyDown(Key.LWin) || Keyboard.IsKeyDown(Key.RWin));

        if (mapCtrlToMacCommand)
        {
            if (hasCtrl) mask |= ModCmd;
            if (hasWin) mask |= ModCtrl;
        }
        else
        {
            if (hasCtrl) mask |= ModCtrl;
            if (hasWin) mask |= ModCmd;
        }
        return mask;
    }

    public static bool IsPasteShortcut(int vk, uint protocolModifiers)
        => vk == 0x56 /* V */ && ((protocolModifiers & (ModCmd | ModCtrl)) != 0);
}
