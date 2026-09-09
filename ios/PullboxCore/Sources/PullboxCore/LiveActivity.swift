import Foundation

#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: - Live Activity Attributes

public struct PullboxDownloadAttributes: Codable, Sendable, Equatable, Hashable {
    public let id: String
    public let sourceURL: String

    public init(id: String, sourceURL: String) {
        self.id = id
        self.sourceURL = sourceURL
    }

    public struct ContentState: Codable, Sendable, Equatable, Hashable {
        public var status: LiveActivityStatus
        public var progress: Double?
        public var title: String?
        public var errorMessage: String?

        public init(
            status: LiveActivityStatus,
            progress: Double? = nil,
            title: String? = nil,
            errorMessage: String? = nil
        ) {
            self.status = status
            self.progress = progress
            self.title = title
            self.errorMessage = errorMessage
        }

        public var description: String {
            switch status {
            case .queued: return "Queued"
            case .preparing: return "Preparing"
            case .downloading:
                if let p = progress {
                    return "Downloading \(Int((p * 100).rounded()))%"
                }
                return "Downloading"
            case .saving: return "Saving to Photos"
            case .succeeded: return "Saved to Photos"
            case .failed: return errorMessage ?? "Failed"
            }
        }
    }
}

#if canImport(ActivityKit) && os(iOS)
@available(iOS 16.1, *)
extension PullboxDownloadAttributes: ActivityAttributes {}
#endif

public enum LiveActivityPresentationPolicy {
    /// Leaves the final Saved/Failed state on screen long enough for the user to read it.
    public static let terminalVisibilityDuration: TimeInterval = 30
}

// MARK: - Live Activity Manager Protocol (for testability)

public protocol LiveActivityControlling: Sendable {
    func start(for item: QueuedDownload) async throws
    func update(for item: QueuedDownload, status: DownloadStatus, progress: Double?, title: String?) async
    func end(for item: QueuedDownload, status: DownloadStatus, errorMessage: String?) async
}

// MARK: - Default Live Activity Manager (extension-safe, degrades gracefully)

public actor PullboxLiveActivityManager: LiveActivityControlling {
    public static let shared = PullboxLiveActivityManager()

    // In-memory fallback for platforms without ActivityKit or for tests
    private var activeIDs: Set<String> = []

    public init() {}

    public func start(for item: QueuedDownload) async throws {
        let attributes = PullboxDownloadAttributes(id: item.id.uuidString, sourceURL: item.sourceURL.absoluteString)
        let state = PullboxDownloadAttributes.ContentState(status: .queued, progress: nil, title: item.title)

        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.1, *) {
            if let existing = Activity<PullboxDownloadAttributes>.activities.first(where: {
                $0.attributes.id == item.id.uuidString
            }) {
                activeIDs.insert(item.id.uuidString)
                await existing.update(ActivityContent(state: state, staleDate: nil))
                return
            }
            if ActivityAuthorizationInfo().areActivitiesEnabled {
                do {
                    _ = try Activity<PullboxDownloadAttributes>.request(
                        attributes: attributes,
                        content: ActivityContent(state: state, staleDate: nil)
                    )
                    activeIDs.insert(item.id.uuidString)
                    return
                } catch {
                    // Fall through to in-memory tracking; do not throw on Activity failure
                }
            }
        }
        #endif
        // Fallback: track in memory and post notification
        activeIDs.insert(item.id.uuidString)
        await postNotification(for: item, state: state)
    }

    public func update(for item: QueuedDownload, status: DownloadStatus, progress: Double?, title: String?) async {
        let liveStatus = status.liveActivityStatus
        let state = PullboxDownloadAttributes.ContentState(
            status: liveStatus,
            progress: progress,
            title: title ?? item.title,
            errorMessage: {
                if case .failed(let msg) = status { return msg }
                return nil
            }()
        )

        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.1, *) {
            for activity in Activity<PullboxDownloadAttributes>.activities where activity.attributes.id == item.id.uuidString {
                await activity.update(ActivityContent(state: state, staleDate: nil))
                await postNotification(for: item, state: state)
                return
            }
        }
        #endif
        await postNotification(for: item, state: state)
    }

    public func end(for item: QueuedDownload, status: DownloadStatus, errorMessage: String? = nil) async {
        let liveStatus = status.liveActivityStatus
        let state = PullboxDownloadAttributes.ContentState(
            status: liveStatus,
            progress: liveStatus == .succeeded ? 1.0 : nil,
            title: item.title,
            errorMessage: errorMessage ?? {
                if case .failed(let msg) = status { return msg }
                return nil
            }()
        )

        #if canImport(ActivityKit) && os(iOS)
        if #available(iOS 16.1, *) {
            for activity in Activity<PullboxDownloadAttributes>.activities where activity.attributes.id == item.id.uuidString {
                let dismissal: ActivityUIDismissalPolicy
                if liveStatus == .succeeded || liveStatus == .failed {
                    dismissal = .after(
                        Date().addingTimeInterval(LiveActivityPresentationPolicy.terminalVisibilityDuration)
                    )
                } else {
                    dismissal = .default
                }
                await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: dismissal)
                activeIDs.remove(item.id.uuidString)
                await postNotification(for: item, state: state)
                return
            }
        }
        #endif
        activeIDs.remove(item.id.uuidString)
        await postNotification(for: item, state: state)
    }

    private func postNotification(for item: QueuedDownload, state: PullboxDownloadAttributes.ContentState) async {
        // Post via NotificationCenter for in-app UI + schedule UNUserNotification for background
        NotificationCenter.default.post(name: .pullboxDownloadProgress, object: nil, userInfo: [
            "id": item.id.uuidString,
            "status": state.status.rawValue,
            "progress": state.progress as Any,
            "title": state.title as Any
        ])
        // Real local notification (extension-safe, best-effort)
        #if canImport(UserNotifications)
        let content = UNMutableNotificationContent()
        content.title = "Pullbox"
        content.body = state.description
        if state.status == .failed {
            content.sound = .default
        }
        // Use item id as identifier so progress updates replace previous notification
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
        #endif
    }

    public func isActive(id: String) -> Bool {
        activeIDs.contains(id)
    }
}

public extension Notification.Name {
    static let pullboxDownloadProgress = Notification.Name("pullboxDownloadProgress")
    static let pullboxQueueUpdated = Notification.Name("pullboxQueueUpdated")
}

// MARK: - Background Download Handoff

public enum BackgroundDownloadHandoff {
    public static let appGroupIdentifier = "group.dev.iamngoni.pullbox"
    public static let backgroundSessionIdentifier = "group.dev.iamngoni.pullbox.download"
    public static let queueFilename = "pullbox-queue.json"

    public static var sharedStore: FileQueueStore {
        FileQueueStore(appGroupIdentifier: appGroupIdentifier, filename: queueFilename)
    }

    public static var stagingDirectory: URL {
        sharedStore.fileURL.deletingLastPathComponent()
            .appending(path: "background-downloads", directoryHint: .isDirectory)
    }

    public static func resolveBaseURL() -> URL {
        // Prefer App Group shared defaults (written by main app), then standard, then fallback
        if let suite = UserDefaults(suiteName: appGroupIdentifier),
           let raw = suite.string(forKey: "serverURL.v2"),
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return url
        }
        if let raw = UserDefaults.standard.string(forKey: "serverURL.v2"),
           let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
           let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
            return url
        }
        return URL(string: "https://pullbox.antonlabs.cc")!
    }

    /// Async handoff for the share extension: durably enqueue, create/resume the
    /// system-owned background transfer, persist preparing, and return. A local
    /// ActivityKit surface is opt-in; the normal share path uses APNs push-to-start.
    /// Throws without persisting on invalid URL or persistence failure.
    @discardableResult
    public static func enqueueAndNotify(
        id: UUID = UUID(),
        sourceURL: URL,
        title: String? = nil,
        store: FileQueueStore? = nil,
        activityManager: LiveActivityControlling? = nil,
        baseURL: URL? = nil,
        clientID: String? = nil,
        backgroundEnqueuer: BackgroundTransferEnqueuer? = nil
    ) async throws -> QueuedDownload {
        let targetStore = store ?? sharedStore
        let item = try targetStore.enqueue(sourceURL: sourceURL, id: id, title: title)

        // System-owned background transfer: synchronously create and resume task before returning.
        // If this handoff fails, remove the queue record so the extension never reports a
        // download as queued when no process owns the transfer.
        let resolvedBase = baseURL ?? resolveBaseURL()
        let resolvedClientID = clientID ?? PullboxClientIdentityStore().clientID()
        do {
            let request = try APIRequestBuilder(baseURL: resolvedBase).download(
                sourceURL: sourceURL,
                requestID: item.id,
                title: item.title,
                clientID: resolvedClientID
            )
            let enqueuer: BackgroundTransferEnqueuer = backgroundEnqueuer ?? SystemBackgroundTransferEnqueuer()
            try enqueuer.enqueueBackgroundDownload(for: item, request: request)
        } catch {
            try? targetStore.remove(id: item.id)
            throw error
        }

        // Persist the accepted transfer state before any optional presentation work.
        try? targetStore.update(id: item.id, status: .preparing)
        if let manager = activityManager {
            try? await manager.start(for: item)
            await manager.update(for: item, status: .preparing, progress: nil, title: item.title)
        }

        NotificationCenter.default.post(name: .pullboxQueueUpdated, object: nil)
        return item
    }

    /// Legacy sync handoff (kept for compatibility). Performs durable enqueue synchronously
    /// and enqueues system-owned background transfer synchronously, but fires Live Activity
    /// asynchronously. Prefer the async version in the share extension so the activity is
    /// guaranteed before completeRequest.
    @discardableResult
    public static func enqueueAndNotify(sourceURL: URL, title: String? = nil, store: FileQueueStore? = nil, activityManager: LiveActivityControlling? = nil) throws -> QueuedDownload {
        let targetStore = store ?? sharedStore
        let item = try targetStore.enqueue(sourceURL: sourceURL, title: title)
        // System-owned background transfer synchronously (best effort)
        let base = resolveBaseURL()
        if let request = try? APIRequestBuilder(baseURL: base).download(sourceURL: sourceURL) {
            let enqueuer = SystemBackgroundTransferEnqueuer()
            try? enqueuer.enqueueBackgroundDownload(for: item, request: request)
        }
        // Fire Live Activity asynchronously (legacy behavior)
        if let manager = activityManager {
            let captured = item
            Task { [captured] in try? await manager.start(for: captured) }
        } else {
            let captured = item
            Task { [captured] in try? await PullboxLiveActivityManager.shared.start(for: captured) }
        }
        NotificationCenter.default.post(name: .pullboxQueueUpdated, object: nil)
        return item
    }
}
