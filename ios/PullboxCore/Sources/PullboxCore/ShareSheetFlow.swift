import Foundation

/// Resolves shared URLs without starting a download. The share sheet uses this
/// boundary to keep preview/analyze separate from the user's download confirmation.
public protocol ShareMediaAnalyzing: Sendable {
    func analyze(sourceURL: URL) async throws -> MediaInfo
}

extension APIClient: ShareMediaAnalyzing {}

/// Starts the durable background handoff only after the user confirms Download.
public protocol ShareDownloadQueueing: Sendable {
    func enqueue(id: UUID, sourceURL: URL, title: String?) async throws -> QueuedDownload
}

public struct SystemShareDownloadQueue: ShareDownloadQueueing {
    private let baseURL: URL
    private let store: FileQueueStore?
    private let activityManager: (any LiveActivityControlling)?
    private let backgroundEnqueuer: any BackgroundTransferEnqueuer

    public init(
        baseURL: URL,
        store: FileQueueStore? = nil,
        activityManager: (any LiveActivityControlling)? = nil,
        backgroundEnqueuer: any BackgroundTransferEnqueuer = SystemBackgroundTransferEnqueuer()
    ) {
        self.baseURL = baseURL
        self.store = store
        self.activityManager = activityManager
        self.backgroundEnqueuer = backgroundEnqueuer
    }

    public func enqueue(id: UUID, sourceURL: URL, title: String?) async throws -> QueuedDownload {
        try await BackgroundDownloadHandoff.enqueueAndNotify(
            id: id,
            sourceURL: sourceURL,
            title: title,
            store: store,
            activityManager: activityManager,
            baseURL: baseURL,
            backgroundEnqueuer: backgroundEnqueuer
        )
    }
}

public struct ShareSheetDownloadFlow: Sendable {
    private let analyzer: any ShareMediaAnalyzing
    private let queue: any ShareDownloadQueueing

    public init(analyzer: any ShareMediaAnalyzing, queue: any ShareDownloadQueueing) {
        self.analyzer = analyzer
        self.queue = queue
    }

    public func resolve(sourceURL: URL) async throws -> MediaInfo {
        try await analyzer.analyze(sourceURL: sourceURL)
    }

    public func confirmDownload(for media: MediaInfo, requestID: UUID) async throws -> QueuedDownload {
        try await queue.enqueue(
            id: requestID,
            sourceURL: media.sourceURL,
            title: media.title
        )
    }
}
