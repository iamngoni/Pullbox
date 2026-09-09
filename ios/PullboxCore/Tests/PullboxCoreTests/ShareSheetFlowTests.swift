import Foundation
import Testing
@testable import PullboxCore

@Test func resolvingShareLinkAnalyzesWithoutQueuingDownload() async throws {
    let sourceURL = try #require(URL(string: "https://example.com/post"))
    let media = MediaInfo(
        title: "Resolved clip",
        thumbnail: URL(string: "https://example.com/thumb.jpg"),
        duration: 42,
        sourceURL: sourceURL
    )
    let analyzer = RecordingShareAnalyzer(result: media)
    let queue = RecordingShareDownloadQueue()
    let flow = ShareSheetDownloadFlow(analyzer: analyzer, queue: queue)

    let resolved = try await flow.resolve(sourceURL: sourceURL)

    #expect(resolved == media)
    #expect(await analyzer.requestedURLs == [sourceURL])
    #expect(await queue.requests.isEmpty)
}

@Test func downloadConfirmationQueuesResolvedMediaWithTitle() async throws {
    let sourceURL = try #require(URL(string: "https://example.com/post"))
    let media = MediaInfo(
        title: "Resolved clip",
        thumbnail: nil,
        duration: 42,
        sourceURL: sourceURL
    )
    let analyzer = RecordingShareAnalyzer(result: media)
    let queue = RecordingShareDownloadQueue()
    let flow = ShareSheetDownloadFlow(analyzer: analyzer, queue: queue)

    let requestID = UUID()
    let item = try await flow.confirmDownload(for: media, requestID: requestID)

    #expect(item.id == requestID)
    #expect(item.sourceURL == sourceURL)
    #expect(item.title == media.title)
    #expect(await analyzer.requestedURLs.isEmpty)
    #expect(await queue.requests == [
        .init(id: requestID, sourceURL: sourceURL, title: media.title)
    ])
}

@Test func systemShareQueueUsesTheInjectedBackgroundTransferOwner() async throws {
    let queueFile = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-share-runtime-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: queueFile) }
    let store = FileQueueStore(fileURL: queueFile)
    let manager = MockLiveActivityManager()
    let enqueuer = MockBackgroundEnqueuer()
    let baseURL = try #require(URL(string: "https://example.com"))
    let sourceURL = try #require(URL(string: "https://example.com/post"))
    let requestID = UUID()
    let queue = SystemShareDownloadQueue(
        baseURL: baseURL,
        store: store,
        activityManager: manager,
        backgroundEnqueuer: enqueuer
    )

    let item = try await queue.enqueue(
        id: requestID,
        sourceURL: sourceURL,
        title: "Resolved clip"
    )

    #expect(item.id == requestID)
    #expect(enqueuer.enqueuedIDs == [requestID.uuidString])
}

@Test func systemShareQueueCanUseRemotePushWithoutStartingLocalActivityKit() async throws {
    let queueFile = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-remote-status-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: queueFile) }

    let store = FileQueueStore(fileURL: queueFile)
    let enqueuer = MockBackgroundEnqueuer()
    let baseURL = try #require(URL(string: "https://example.com"))
    let sourceURL = try #require(URL(string: "https://example.com/post"))
    let queue = SystemShareDownloadQueue(
        baseURL: baseURL,
        store: store,
        activityManager: nil,
        backgroundEnqueuer: enqueuer
    )

    let item = try await queue.enqueue(
        id: UUID(),
        sourceURL: sourceURL,
        title: "Remote activity"
    )

    #expect(enqueuer.enqueuedIDs == [item.id.uuidString])
    #expect(try store.load().first?.status == .preparing)
}

private actor RecordingShareAnalyzer: ShareMediaAnalyzing {
    let result: MediaInfo
    private(set) var requestedURLs: [URL] = []

    init(result: MediaInfo) {
        self.result = result
    }

    func analyze(sourceURL: URL) async throws -> MediaInfo {
        requestedURLs.append(sourceURL)
        return result
    }
}

private actor RecordingShareDownloadQueue: ShareDownloadQueueing {
    struct Request: Equatable {
        let id: UUID
        let sourceURL: URL
        let title: String?
    }

    private(set) var requests: [Request] = []

    func enqueue(id: UUID, sourceURL: URL, title: String?) async throws -> QueuedDownload {
        requests.append(.init(id: id, sourceURL: sourceURL, title: title))
        return QueuedDownload(id: id, sourceURL: sourceURL, title: title)
    }
}
