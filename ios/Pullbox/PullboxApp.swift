import SwiftUI
import PullboxCore
import UserNotifications
import Photos

@MainActor
class AppDelegate: NSObject, UIApplicationDelegate {
    static weak var shared: AppDelegate?

    private let backgroundCompletionHandler = BackgroundEventsCompletionHandler()
    private let backgroundSessionOwnership = BackgroundSessionOwnership()
    private var activityPushObserver: AnyObject?
    private lazy var backgroundDelegate = PullboxBackgroundSessionDelegate(
        photoSaver: SystemPhotoLibrarySaver(),
        onBackgroundEventsFinished: {
            [
                backgroundCompletionHandler = backgroundCompletionHandler,
                backgroundSessionOwnership = backgroundSessionOwnership
            ] in
            backgroundSessionOwnership.finishAndRelease()
            backgroundCompletionHandler.complete()
        }
    )
    private lazy var backgroundTransferEnqueuer = SystemBackgroundTransferEnqueuer(
        delegate: backgroundDelegate
    )

    override init() {
        super.init()
        Self.shared = self
    }

    func enqueueDownload(
        sourceURL: URL,
        title: String?,
        baseURL: URL
    ) async throws -> QueuedDownload {
        try await BackgroundDownloadHandoff.enqueueAndNotify(
            sourceURL: sourceURL,
            title: title,
            activityManager: PullboxLiveActivityManager.shared,
            baseURL: baseURL,
            remoteActivityPush: false,
            backgroundEnqueuer: backgroundTransferEnqueuer
        )
    }

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
        let session = PullboxBackgroundSessionCoordinator.makeSession(delegate: backgroundDelegate)
        backgroundSessionOwnership.retain(session)
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
