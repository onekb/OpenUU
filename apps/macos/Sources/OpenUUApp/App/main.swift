import AppKit

// Entry point: if launched as a lightweight `--dock-proxy` helper, run pure AppKit Dock icon mode;
// otherwise launch the full SwiftUI OpenUU application.
if !DockProxyRunner.runIfRequested() {
    OpenUUApp.main()
}
