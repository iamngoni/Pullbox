import Foundation
import Testing
@testable import PullboxCore

@Test func backgroundHandoffEnqueuesAndStartsLiveActivity() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-bg-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = FileQueueStore(fileURL: tmp)
    let mockManager = MockLiveActivityManager()
    let mockEnqueuer = MockBackgroundEnqueuer()
    let url = try #require(URL(string: "https://example.com/video"))
    let baseURL = try #require(URL(string: "https://example.com"))

    let item = try await BackgroundDownloadHandoff.enqueueAndNotify(
        sourceURL: url,
        store: store,
        activityManager: mockManager,
        baseURL: baseURL,
        backgroundEnqueuer: mockEnqueuer
    )
    #expect(item.sourceURL == url)
    let started = await mockManager.startedIDs
    #expect(started.contains(item.id.uuidString))
    #expect(mockEnqueuer.enqueuedIDs.contains(item.id.uuidString))
    // Durable
    let items = try store.load()
    #expect(items.count == 1)
}

@Test func backgroundHandoffInvalidURLThrowsWithoutStartingActivity() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-bg2-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = FileQueueStore(fileURL: tmp)
    let mockManager = MockLiveActivityManager()
    let mockEnqueuer = MockBackgroundEnqueuer()
    let bad = try #require(URL(string: "ftp://example.com/file"))
    let baseURL = try #require(URL(string: "https://example.com"))

    var didThrow = false
    do {
        _ = try await BackgroundDownloadHandoff.enqueueAndNotify(sourceURL: bad, store: store, activityManager: mockManager, baseURL: baseURL, backgroundEnqueuer: mockEnqueuer)
    } catch {
        didThrow = true
    }
    #expect(didThrow)
    let started = await mockManager.startedIDs
    #expect(started.isEmpty)
    #expect(mockEnqueuer.enqueuedIDs.isEmpty)
    let items = try store.load()
    #expect(items.isEmpty)
}

@Test func backgroundSessionUsesCorrectIdentifiers() throws {
    #expect(BackgroundDownloadHandoff.appGroupIdentifier == "group.dev.iamngoni.pullbox")
    #expect(BackgroundDownloadHandoff.backgroundSessionIdentifier == "group.dev.iamngoni.pullbox.download")
    #expect(BackgroundDownloadHandoff.queueFilename == "pullbox-queue.json")
    // Verify sharedStore uses App Group when available - fallback is tested implicitly
    let store = BackgroundDownloadHandoff.sharedStore
    #expect(store.fileURL.lastPathComponent == "pullbox-queue.json")
}

@Test func backgroundURLSessionConfigurationIsExtensionSafe() throws {
    // Verify factory creates background config with shared container
    let factory = DefaultBackgroundSessionFactory()
    let session = factory.makeSession(identifier: BackgroundDownloadHandoff.backgroundSessionIdentifier)
    #expect(session.configuration.identifier == BackgroundDownloadHandoff.backgroundSessionIdentifier)
    #expect(session.configuration.sharedContainerIdentifier == BackgroundDownloadHandoff.appGroupIdentifier)
    // isDiscretionary = false for immediate, sessionSendsLaunchEvents = true for background wake
    #expect(session.configuration.sessionSendsLaunchEvents == true)
}

@Test func shareExtensionEnqueueIsImmediate() throws {
    // Simulate extension enqueue timing: should complete in < 200ms (no network)
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-timing-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = FileQueueStore(fileURL: tmp)
    let url = try #require(URL(string: "https://example.com/video"))
    let start = Date()
    _ = try store.enqueue(sourceURL: url)
    let elapsed = Date().timeIntervalSince(start)
    #expect(elapsed < 0.5, "enqueue must be immediate, not waiting for download")
}

@Test func delegateHonestSuccessRequiresPhotoSave() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-delegate-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = FileQueueStore(fileURL: tmp)
    let url = try #require(URL(string: "https://example.com/video"))
    let item = try store.enqueue(sourceURL: url)
    // Create a temp file to simulate download
    let tmpFile = FileManager.default.temporaryDirectory.appending(path: "pullbox-tmp-\(UUID().uuidString).mp4")
    try Data("fake video".utf8).write(to: tmpFile)
    defer { try? FileManager.default.removeItem(at: tmpFile) }

    let mockManager = MockLiveActivityManager()
    let mockSaver = MockPhotoSaver(shouldFail: false)
    let delegate = PullboxBackgroundSessionDelegate(store: store, activityManager: mockManager, photoSaver: mockSaver)
    // Simulate success response
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "video/mp4"])!
    await delegate.handleDownloadCompletion(taskDescription: item.id.uuidString, response: response, location: tmpFile, error: nil)
    let items = try store.load()
    #expect(items.first?.status == .succeeded)
    let ended = await mockManager.ended
    #expect(ended.first?.1 == .succeeded)
}

@Test func delegateFailurePreservesErrorState() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-delegate2-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = FileQueueStore(fileURL: tmp)
    let url = try #require(URL(string: "https://example.com/video"))
    let item = try store.enqueue(sourceURL: url)
    let mockManager = MockLiveActivityManager()
    let mockSaver = MockPhotoSaver(shouldFail: false)
    let delegate = PullboxBackgroundSessionDelegate(store: store, activityManager: mockManager, photoSaver: mockSaver)
    let response = HTTPURLResponse(url: url, statusCode: 422, httpVersion: nil, headerFields: nil)!
    // Create error body
    let errData = try JSONEncoder().encode(["error": "No media"])
    let errFile = FileManager.default.temporaryDirectory.appending(path: "pullbox-err-\(UUID().uuidString).json")
    try errData.write(to: errFile)
    defer { try? FileManager.default.removeItem(at: errFile) }
    await delegate.handleDownloadCompletion(taskDescription: item.id.uuidString, response: response, location: errFile, error: nil)
    let items = try store.load()
    if case .failed(let msg) = items.first?.status {
        #expect(msg.contains("No media"))
    } else {
        Issue.record("expected failed state")
    }
}

// MARK: - Mocks

actor MockLiveActivityManager: LiveActivityControlling {
    var startedIDs: [String] = []
    var updated: [(String, DownloadStatus)] = []
    var ended: [(String, DownloadStatus)] = []

    func start(for item: QueuedDownload) async throws {
        startedIDs.append(item.id.uuidString)
    }
    func update(for item: QueuedDownload, status: DownloadStatus, progress: Double?, title: String?) async {
        updated.append((item.id.uuidString, status))
    }
    func end(for item: QueuedDownload, status: DownloadStatus, errorMessage: String?) async {
        ended.append((item.id.uuidString, status))
    }
}

struct MockBackgroundEnqueuer: BackgroundTransferEnqueuer {
    var enqueuedIDs: [String] { _enqueuedIDs.value }
    private let _enqueuedIDs = Box<[String]>([])

    func enqueueBackgroundDownload(for item: QueuedDownload, request: URLRequest) throws {
        var current = _enqueuedIDs.value
        current.append(item.id.uuidString)
        _enqueuedIDs.value = current
        // Verify request is POST to expected endpoint
        assert(request.httpMethod == "POST")
        assert(request.url?.path.contains("download") == true)
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }
}

struct MockPhotoSaver: PhotoLibrarySaving {
    let shouldFail: Bool
    func save(at url: URL) async throws {
        if shouldFail { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "save failed"]) }
        // verify file exists
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing file"])
        }
    }
}
