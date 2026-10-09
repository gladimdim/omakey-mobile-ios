import SwiftUI
import UIKit

@main
struct OmakeyApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var model: AppModel

    init() {
        #if DEBUG
        // UI tests start from a fresh install: no pairings, no settings. Once
        // per token, as opening a link relaunches the app with the same one.
        if let token = ProcessInfo.processInfo.environment["OMAKEY_RESET"], let id = Bundle.main.bundleIdentifier,
           let marks = UserDefaults(suiteName: "\(id).uitests"), marks.string(forKey: "reset") != token {
            UserDefaults.standard.removePersistentDomain(forName: id)
            marks.set(token, forKey: "reset")
        }
        #endif
        HostStore.wipeIfFreshInstall()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        WindowGroup {
            ConnectView(model: model)
                .onOpenURL { model.handleURL($0) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    if phase == .active { model.startBrowsing() } else if phase == .background { model.stopBrowsing() }
                }
        }
    }
}

/// Which way the screen may turn: the keyboard locks it to landscape (or
/// portrait, in portrait mode) while it shows.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor static var orientations: UIInterfaceOrientationMask = .allButUpsideDown

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Which way the phone is held, for facing that way when a keyboard lets go of the lock.
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        return true
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientations
    }
}
