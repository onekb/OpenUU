import AppKit

// Entry point: if launched as a lightweight `--dock-proxy` helper, run pure AppKit Dock icon mode;
// otherwise launch the full SwiftUI Chameye application.
if !DockProxyRunner.runIfRequested() {
    ChameyeApp.main()
}
