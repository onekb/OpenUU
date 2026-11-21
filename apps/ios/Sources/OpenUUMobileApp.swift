import SwiftUI
import UIKit

final class OpenUUAppDelegate: NSObject, UIApplicationDelegate {
    @MainActor
    static var forcedOrientationMask: UIInterfaceOrientationMask?

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        if let forced = MainActor.assumeIsolated({ OpenUUAppDelegate.forcedOrientationMask }) {
            return forced
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }
        return .allButUpsideDown
    }
}

@main
struct OpenUUMobileApp: App {
    @UIApplicationDelegateAdaptor(OpenUUAppDelegate.self) private var appDelegate
    @StateObject private var viewModel = MobileSessionViewModel()

    var body: some Scene {
        WindowGroup {
            MobileMainView(viewModel: viewModel)
                .preferredColorScheme(.dark)
                .tint(OpenUUTheme.emerald)
        }
    }
}
