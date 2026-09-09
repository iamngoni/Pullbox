import Foundation

// MARK: - Background Session Factory (extension-safe, App Group aware)

public struct DefaultBackgroundSessionFactory: Sendable {
    public init() {}

    public func makeSession(identifier: String, delegate: URLSessionDelegate? = nil) -> URLSession {
        let config = URLSessionConfiguration.background(withIdentifier: identifier)
        config.sharedContainerIdentifier = BackgroundDownloadHandoff.appGroupIdentifier
        config.sessionSendsLaunchEvents = true
        config.isDiscretionary = false
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 900
        // Use delegate queue nil (system creates serial queue)
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    public func makeBackgroundRequest(for sourceURL: URL, baseURL: URL) throws -> URLRequest {
        try APIRequestBuilder(baseURL: baseURL).download(sourceURL: sourceURL)
    }
}

// MARK: - Photo Library Saving (for testing and app integration)

public protocol PhotoLibrarySaving: Sendable {
    func save(at url: URL) async throws
}

// Default no-op for tests / fallback
public struct NoopPhotoSaver: PhotoLibrarySaving {
    public init() {}
    public func save(at url: URL) async throws {}
}

// MARK: - Background Download Enqueuer (system-owned transfer)

public protocol BackgroundTransferEnqueuer: Sendable {
    func enqueueBackgroundDownload(for item: QueuedDownload, request: URLRequest) throws
}

public struct SystemBackgroundTransferEnqueuer: BackgroundTransferEnqueuer {
    private let factory: DefaultBackgroundSessionFactory
    private let sessionIdentifier: String
    private let delegate: PullboxBackgroundSessionDelegate?

    public init(
        factory: DefaultBackgroundSessionFactory = DefaultBackgroundSessionFactory(),
        sessionIdentifier: String = BackgroundDownloadHandoff.backgroundSessionIdentifier,
        delegate: PullboxBackgroundSessionDelegate? = PullboxBackgroundSessionCoordinator.sharedDelegate
    ) {
        self.factory = factory
        self.sessionIdentifier = sessionIdentifier
        self.delegate = delegate
    }

    public func enqueueBackgroundDownload(for item: QueuedDownload, request: URLRequest) throws {
        let session = factory.makeSession(identifier: sessionIdentifier, delegate: delegate)
        // Retain session by not invalidating; system owns it after resume
        let task = session.downloadTask(with: request)
        task.taskDescription = item.id.uuidString
        // Earliest progress: mark as preparing before system takes over (app will observe via delegate)
        task.resume()
    }
}

// MARK: - Background Session Delegate (drives completion honestly)

public final class PullboxBackgroundSessionDelegate: NSObject, Sendable {
    private let store: FileQueueStore
    private let activityManager: LiveActivityControlling
    private let photoSaver: PhotoLibrarySaving

    public init(
        store: FileQueueStore = BackgroundDownloadHandoff.sharedStore,
        activityManager: LiveActivityControlling = PullboxLiveActivityManager.shared,
        photoSaver: PhotoLibrarySaving = NoopPhotoSaver()
    ) {
        self.store = store
        self.activityManager = activityManager
        self.photoSaver = photoSaver
        super.init()
    }

    // Exposed for testing: handle downloaded file location
    public func handleDownloadCompletion(taskDescription: String?, response: URLResponse?, location: URL?, error: Error?) async {
        guard let idStr = taskDescription, let uuid = UUID(uuidString: idStr) else { return }
        let items = (try? store.load()) ?? []
        guard let item = items.first(where: { $0.id == uuid }) else { return }

        if let error {
            let msg = error.localizedDescription
            try? store.update(id: uuid, status: .failed(msg))
            await activityManager.end(for: item, status: .failed(msg), errorMessage: msg)
            return
        }

        guard let http = response as? HTTPURLResponse else {
            let msg = "Invalid response"
            try? store.update(id: uuid, status: .failed(msg))
            await activityManager.end(for: item, status: .failed(msg), errorMessage: msg)
            return
        }

        guard 200..<300 ~= http.statusCode else {
            // Try to read error body from location if available
            var message = "Download failed with status \(http.statusCode)."
            if let location, let data = try? Data(contentsOf: location),
               let server = try? JSONDecoder().decode(ServerError.self, from: data) {
                message = server.error
            }
            try? store.update(id: uuid, status: .failed(message))
            await activityManager.end(for: item, status: .failed(message), errorMessage: message)
            return
        }

        guard let location else {
            let msg = "Missing downloaded file"
            try? store.update(id: uuid, status: .failed(msg))
            await activityManager.end(for: item, status: .failed(msg), errorMessage: msg)
            return
        }

        // Move to stable destination and save to Photos (honest success only after Photos)
        do {
            try? store.update(id: uuid, status: .saving)
            await activityManager.update(for: item, status: .saving, progress: nil, title: nil)

            // Determine destination with correct extension from content-type
            let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            let isImage = contentType.hasPrefix("image/")
            let ext = isImage ? (contentType.contains("png") ? "png" : "jpg") : "mp4"
            let destination = FileManager.default.temporaryDirectory
                .appending(path: "Pullbox-\(UUID().uuidString).\(ext)")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)

            // Save to Photos - only after this succeeds do we mark succeeded
            try await photoSaver.save(at: destination)
            try? FileManager.default.removeItem(at: destination)

            try? store.update(id: uuid, status: .succeeded)
            await activityManager.end(for: item, status: .succeeded, errorMessage: nil)
        } catch {
            let msg = error.localizedDescription
            try? store.update(id: uuid, status: .failed(msg))
            await activityManager.end(for: item, status: .failed(msg), errorMessage: msg)
        }
    }

    public func handleProgress(taskDescription: String?, progress: Double) async {
        guard let idStr = taskDescription, let uuid = UUID(uuidString: idStr) else { return }
        let items = (try? store.load()) ?? []
        guard let item = items.first(where: { $0.id == uuid }) else { return }
        let status = DownloadStatus.downloading(progress: progress)
        try? store.update(id: uuid, status: status)
        await activityManager.update(for: item, status: status, progress: progress, title: nil)
    }
}

extension PullboxBackgroundSessionDelegate: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let response = downloadTask.response
        let desc = downloadTask.taskDescription
        Task { await self.handleDownloadCompletion(taskDescription: desc, response: response, location: location, error: nil) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let desc = downloadTask.taskDescription
        Task { await self.handleProgress(taskDescription: desc, progress: progress) }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let desc = task.taskDescription
            Task { await self.handleDownloadCompletion(taskDescription: desc, response: task.response, location: nil, error: error) }
        }
    }
}

private struct ServerError: Decodable { let error: String }

// Shared delegate retained for lifetime of process
public enum PullboxBackgroundSessionCoordinator {
    public static let sharedDelegate = PullboxBackgroundSessionDelegate()
    public static func makeSession() -> URLSession {
        DefaultBackgroundSessionFactory().makeSession(identifier: BackgroundDownloadHandoff.backgroundSessionIdentifier, delegate: sharedDelegate)
    }
}

// MARK: - Download Queue Processor (foreground fallback, now honest)

public actor DownloadQueueProcessor {
    private let store: FileQueueStore
    private let activityManager: LiveActivityControlling
    private let photoSaver: PhotoLibrarySaving
    private var isProcessing = false

    public init(
        store: FileQueueStore? = nil,
        activityManager: LiveActivityControlling = PullboxLiveActivityManager.shared,
        photoSaver: PhotoLibrarySaving = NoopPhotoSaver()
    ) {
        self.store = store ?? BackgroundDownloadHandoff.sharedStore
        self.activityManager = activityManager
        self.photoSaver = photoSaver
    }

    /// Foreground fallback processor: downloads via APIClient, saves to Photos, then marks succeeded.
    /// Honest: only marks succeeded after Photos save succeeds; failures preserve error state.
    public func processNextIfNeeded(baseURL: URL, apiSession: URLSession = .shared) async {
        guard !isProcessing else { return }
        isProcessing = true
        defer { isProcessing = false }

        guard let items = try? store.load() else { return }
        guard let next = items.first(where: { $0.status == .queued }) else { return }

        var preparingItem = next
        preparingItem.status = .preparing
        try? store.update(id: next.id, status: .preparing)
        await activityManager.update(for: preparingItem, status: .preparing, progress: nil, title: next.title)

        do {
            let client = APIClient(baseURL: baseURL, session: apiSession)
            await activityManager.update(for: preparingItem, status: .downloading(progress: 0.0), progress: 0.0, title: nil)
            let localURL = try await client.download(sourceURL: next.sourceURL)

            // Transition to saving and attempt Photos save before declaring success
            try? store.update(id: next.id, status: .saving)
            await activityManager.update(for: preparingItem, status: .saving, progress: nil, title: nil)

            do {
                try await photoSaver.save(at: localURL)
                try? FileManager.default.removeItem(at: localURL)
                try? store.update(id: next.id, status: .succeeded)
                await activityManager.end(for: preparingItem, status: .succeeded, errorMessage: nil)
            } catch {
                try? FileManager.default.removeItem(at: localURL)
                let msg = error.localizedDescription
                try? store.update(id: next.id, status: .failed(msg))
                await activityManager.end(for: preparingItem, status: .failed(msg), errorMessage: msg)
            }
        } catch {
            let message = error.localizedDescription
            try? store.update(id: next.id, status: .failed(message))
            await activityManager.end(for: preparingItem, status: .failed(message), errorMessage: message)
        }
    }
}
