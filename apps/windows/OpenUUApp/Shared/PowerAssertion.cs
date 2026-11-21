namespace OpenUU.Shared;

/// <summary>
/// Prevents Windows display sleep and idle system sleep while OpenUU Host is sharing windows
/// (Windows counterpart to macOS IOKit <c>SleepPreventer</c>).
/// </summary>
public sealed class SleepPreventer : IDisposable
{
    private bool _isActive;

    public void SetEnabled(bool enabled)
    {
        if (enabled == _isActive) return;
        _isActive = enabled;
        if (enabled)
        {
            Win32Interop.SetThreadExecutionState(
                Win32Interop.ES_CONTINUOUS |
                Win32Interop.ES_DISPLAY_REQUIRED |
                Win32Interop.ES_SYSTEM_REQUIRED
            );
        }
        else
        {
            Win32Interop.SetThreadExecutionState(Win32Interop.ES_CONTINUOUS);
        }
    }

    public void Dispose()
    {
        if (_isActive)
        {
            _isActive = false;
            Win32Interop.SetThreadExecutionState(Win32Interop.ES_CONTINUOUS);
        }
    }
}
