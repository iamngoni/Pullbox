import SwiftUI
import PullboxCore
import UserNotifications
import Photos

class AppDelegate: NSObject, UIApplicationDelegate {
    private let backgroundCompletionHandler = BackgroundEventsCompletionHandler()
    private var backgroundSession: URLSession?
    private var activityPushObserver: AnyObject?
    private lazy var backgroundDelegate = PullboxBackgroundSessionDelegate(
        photoSaver: SystemPhotoLibrarySaver(),
        onBackgroundEventsFinished: { [backgroundCompletionHandler] in
            backgroundCompletionHandler.complete()
        }
    )

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { _ in }

        if #available(iOS 17.2, *) {
            let observer = PullboxActivityPushObserver()
            activityPushObserver = observer
            let baseURL = BackgroundDownloadHandoff.resolveBaseURL()
            observer.start(baseURL: baseURL)
        }
        return true
    }

    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        guard identifier == BackgroundDownloadHandoff.backgroundSessionIdentifier else {
            completionHandler()
            return
        }

        backgroundCompletionHandler.install(completionHandler)
        backgroundSession = PullboxBackgroundSessionCoordinator.makeSession(delegate: backgroundDelegate)
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
