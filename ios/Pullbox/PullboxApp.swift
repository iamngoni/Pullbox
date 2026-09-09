import SwiftUI
import PullboxCore
import UserNotifications

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Request notification permission for Live Activity updates
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        // Ensure background session is configured
        _ = PullboxBackgroundSessionCoordinator.makeSession()
        return true
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        // System woke app to handle background download completions
        if identifier == BackgroundDownloadHandoff.backgroundSessionIdentifier {
            let session = PullboxBackgroundSessionCoordinator.makeSession()
            // Store completion handler to call after delegate finishes
            BackgroundCompletionHandler.completion = completionHandler
            // Session delegate will handle completions
            _ = session
        } else {
            completionHandler()
        }
    }
}

enum BackgroundCompletionHandler {
    nonisolated(unsafe) static var completion: (() -> Void)?
    static func complete() {
        completion?()
        completion = nil
    }
}

@main
struct PullboxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.light)
                .task {
                    // Sync serverURL to App Group on launch
                    if let suite = UserDefaults(suiteName: BackgroundDownloadHandoff.appGroupIdentifier),
                       let standard = UserDefaults.standard.string(forKey: "serverURL.v2") {
                        suite.set(standard, forKey: "serverURL.v2")
                    }
                }
        }
    }
}
