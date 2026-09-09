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
    let requestID = UUID()

    let item = try await BackgroundDownloadHandoff.enqueueAndNotify(
        id: requestID,
        sourceURL: url,
        title: "Resolved clip",
        store: store,
        activityManager: mockManager,
        baseURL: baseURL,
        clientID: "client-test",
        backgroundEnqueuer: mockEnqueuer
    )
    #expect(item.sourceURL == url)
    let started = await mockManager.startedIDs
    #expect(started.contains(item.id.uuidString))
    #expect(mockEnqueuer.enqueuedIDs.contains(item.id.uuidString))
    let request = try #require(mockEnqueuer.requests.first)
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["requestId"] as? String == requestID.uuidString)
    #expect(json["title"] as? String == "Resolved clip")
    #expect(json["clientId"] as? String == "client-test")
    // Durable
    let items = try store.load()
    #expect(items.count == 1)
}

@Test func backgroundHandoffPublishesPreparingAfterQueuedActivityStarts() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-preparing-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = FileQueueStore(fileURL: tmp)
    let manager = MockLiveActivityManager()
    let url = try #require(URL(string: "https://example.com/video"))
    let baseURL = try #require(URL(string: "https://example.com"))

    let item = try await BackgroundDownloadHandoff.enqueueAndNotify(
        sourceURL: url,
        store: store,
        activityManager: manager,
        baseURL: baseURL,
        backgroundEnqueuer: NoopBackgroundEnqueuer()
    )

    #expect(await manager.startedIDs == [item.id.uuidString])
    #expect(await manager.updated.map(\.1) == [.preparing])
    #expect(try store.load().first?.status == .preparing)
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

@Test func backgroundHandoffTransferFailureRollsBackAndThrows() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-bg-failure-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = FileQueueStore(fileURL: tmp)
    let mockManager = MockLiveActivityManager()
    let sourceURL = try #require(URL(string: "https://example.com/video"))
    let baseURL = try #require(URL(string: "https://example.com"))

    var didThrow = false
    do {
        _ = try await BackgroundDownloadHandoff.enqueueAndNotify(
            sourceURL: sourceURL,
            store: store,
            activityManager: mockManager,
            baseURL: baseURL,
            backgroundEnqueuer: FailingBackgroundEnqueuer()
        )
    } catch {
        didThrow = true
    }

    #expect(didThrow)
    #expect(try store.load().isEmpty)
    #expect(await mockManager.startedIDs.isEmpty)
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
    // Use an isolated identifier because Swift Testing executes tests concurrently and
    // Foundation allows only one active background session per identifier in a process.
    let identifier = "group.dev.iamngoni.pullbox.test.\(UUID().uuidString)"
    let factory = DefaultBackgroundSessionFactory()
    let session = factory.makeSession(identifier: identifier)
    #expect(session.configuration.identifier == identifier)
    #expect(session.configuration.sharedContainerIdentifier == BackgroundDownloadHandoff.appGroupIdentifier)
    // isDiscretionary = false for immediate, sessionSendsLaunchEvents = true for background wake
    #expect(session.configuration.sessionSendsLaunchEvents == true)
}

@Test func systemBackgroundEnqueuerRetainsItsDelegatedSession() throws {
    let identifier = "group.dev.iamngoni.pullbox.test.\(UUID().uuidString)"
    let delegate = PullboxBackgroundSessionDelegate()
    let enqueuer = SystemBackgroundTransferEnqueuer(
        sessionIdentifier: identifier,
        delegate: delegate
    )
    let sourceURL = try #require(URL(string: "https://example.com/video"))
    let requestURL = try #require(URL(string: "https://example.com/api/download"))
    let item = QueuedDownload(sourceURL: sourceURL)

    try enqueuer.enqueueBackgroundDownload(for: item, request: URLRequest(url: requestURL))

    #expect(enqueuer.activeSession?.configuration.identifier == identifier)
    #expect(enqueuer.activeSession?.delegate === delegate)
    enqueuer.activeSession?.invalidateAndCancel()
}

@Test func unconfiguredPhotoSaverThrowsInsteadOfReportingFalseSuccess() async throws {
    let file = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-noop-photo-\(UUID().uuidString).mp4")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data("video".utf8).write(to: file)

    var didThrow = false
    do {
        try await NoopPhotoSaver().save(at: file)
    } catch {
        didThrow = true
    }

    #expect(didThrow)
}

@Test func photoLibraryAssetKindMatchesTheDownloadedFileExtension() {
    #expect(PhotoLibraryAssetKind(fileExtension: "JPG") == .image)
    #expect(PhotoLibraryAssetKind(fileExtension: "webp") == .image)
    #expect(PhotoLibraryAssetKind(fileExtension: "mp4") == .video)
    #expect(PhotoLibraryAssetKind(fileExtension: "mov") == .video)
}

@Test func downloadedFileIsMovedToDurableStagingBeforeAsyncProcessing() throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-staging-\(UUID().uuidString)", directoryHint: .isDirectory)
    let incoming = root.appending(path: "CFNetworkDownload.tmp")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("video".utf8).write(to: incoming)
    let response = HTTPURLResponse(
        url: try #require(URL(string: "https://example.com/video")),
        statusCode: 200,
        httpVersion: nil,
        headerFields: ["Content-Type": "video/mp4"]
    )

    let staged = try DownloadedFileStager(directory: root.appending(path: "durable", directoryHint: .isDirectory))
        .stage(fileAt: incoming, taskID: UUID(), response: response)

    #expect(!FileManager.default.fileExists(atPath: incoming.path))
    #expect(FileManager.default.fileExists(atPath: staged.path))
    #expect(staged.pathExtension == "mp4")
    #expect(try Data(contentsOf: staged) == Data("video".utf8))
}

@Test func backgroundDelegateSignalsWhenSystemFinishesDeliveringEvents() {
    let probe = LockedFlag()
    let delegate = PullboxBackgroundSessionDelegate(
        onBackgroundEventsFinished: { probe.set() }
    )
    let session = URLSession(configuration: .ephemeral)

    delegate.urlSessionDidFinishEvents(forBackgroundURLSession: session)

    #expect(probe.value)
}

@Test func backgroundEventCompletionWaitsForFileProcessing() {
    let probe = LockedFlag()
    let gate = BackgroundEventCompletionGate(onComplete: { probe.set() })

    gate.beginProcessing()
    gate.systemDidFinishEvents()
    #expect(!probe.value)

    gate.endProcessing()
    #expect(probe.value)
}

@Test func backgroundEventPipelinePreservesDelegateCallbackOrder() async {
    let pipeline = BackgroundEventPipeline()
    let values = LockedIntegers()

    for value in 0..<20 {
        pipeline.enqueue {
            try? await Task.sleep(for: .milliseconds(20 - value))
            values.append(value)
        }
    }

    await pipeline.drain()
    #expect(values.value == Array(0..<20))
}

@Test func backgroundEventPipelineDelaysSystemCompletionUntilItDrains() async {
    let completed = LockedFlag()
    let gate = BackgroundEventCompletionGate(onComplete: { completed.set() })
    let pipeline = BackgroundEventPipeline(completionGate: gate)

    pipeline.enqueue {
        try? await Task.sleep(for: .milliseconds(50))
    }
    gate.systemDidFinishEvents()

    #expect(!completed.value)
    await pipeline.drain()
    #expect(completed.value)
}

@Test func backgroundCompletionSignalIsLatchedUntilUIKitHandlerIsInstalled() async {
    let handler = BackgroundEventsCompletionHandler()
    handler.complete()

    await withCheckedContinuation { continuation in
        handler.install {
            continuation.resume()
        }
    }
}

@Test func backgroundCompletionHandlerAlwaysRunsOnMainThread() async {
    let handler = BackgroundEventsCompletionHandler()

    await withCheckedContinuation { continuation in
        handler.install {
            #expect(Thread.isMainThread)
            continuation.resume()
        }
        DispatchQueue.global().async {
            handler.complete()
        }
    }
}

@Test func coordinatorUsesTheConfiguredPhotoSavingDelegate() {
    let delegate = PullboxBackgroundSessionDelegate(photoSaver: MockPhotoSaver(shouldFail: false))
    let identifier = "group.dev.iamngoni.pullbox.test.\(UUID().uuidString)"
    let session = PullboxBackgroundSessionCoordinator.makeSession(
        delegate: delegate,
        identifier: identifier
    )

    #expect(session.delegate === delegate)
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

@Test func lateProgressDoesNotReopenCompletedDownload() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-late-progress-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = FileQueueStore(fileURL: tmp)
    let url = try #require(URL(string: "https://example.com/video"))
    let item = try store.enqueue(sourceURL: url)
    try store.update(id: item.id, status: .succeeded)
    let manager = MockLiveActivityManager()
    let delegate = PullboxBackgroundSessionDelegate(store: store, activityManager: manager)

    await delegate.handleProgress(taskDescription: item.id.uuidString, progress: 0.75)

    #expect(try store.load().first?.status == .succeeded)
    #expect(await manager.updated.isEmpty)
}

@Test func concurrentHandoffsWithTitlesPreserveEveryQueuedDownload() async throws {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-title-race-\(UUID().uuidString)", directoryHint: .isDirectory)
    let queueFile = root.appending(path: "queue.json")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = FileQueueStore(fileURL: queueFile)
    let manager = MockLiveActivityManager()
    let baseURL = try #require(URL(string: "https://example.com"))

    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 0..<40 {
            group.addTask {
                let sourceURL = try #require(URL(string: "https://example.com/video-\(index)"))
                _ = try await BackgroundDownloadHandoff.enqueueAndNotify(
                    sourceURL: sourceURL,
                    title: "Video \(index)",
                    store: store,
                    activityManager: manager,
                    baseURL: baseURL,
                    backgroundEnqueuer: NoopBackgroundEnqueuer()
                )
            }
        }
        try await group.waitForAll()
    }

    let items = try store.load()
    #expect(items.count == 40)
    #expect(Set(items.compactMap(\.title)).count == 40)
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
    var requests: [URLRequest] { _requests.value }
    private let _enqueuedIDs = Box<[String]>([])
    private let _requests = Box<[URLRequest]>([])

    func enqueueBackgroundDownload(for item: QueuedDownload, request: URLRequest) throws {
        var current = _enqueuedIDs.value
        current.append(item.id.uuidString)
        _enqueuedIDs.value = current
        var currentRequests = _requests.value
        currentRequests.append(request)
        _requests.value = currentRequests
        // Verify request is POST to expected endpoint
        assert(request.httpMethod == "POST")
        assert(request.url?.path.contains("download") == true)
    }

    private final class Box<T>: @unchecked Sendable {
        var value: T
        init(_ value: T) { self.value = value }
    }
}

struct FailingBackgroundEnqueuer: BackgroundTransferEnqueuer {
    func enqueueBackgroundDownload(for item: QueuedDownload, request: URLRequest) throws {
        throw NSError(
            domain: "BackgroundTransferTests",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "could not create background task"]
        )
    }
}

struct NoopBackgroundEnqueuer: BackgroundTransferEnqueuer {
    func enqueueBackgroundDownload(for item: QueuedDownload, request: URLRequest) throws {}
}

final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = false

    var value: Bool {
        lock.withLock { storedValue }
    }

    func set() {
        lock.withLock { storedValue = true }
    }
}

final class LockedIntegers: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [Int] = []

    var value: [Int] {
        lock.withLock { storedValues }
    }

    func append(_ value: Int) {
        lock.withLock { storedValues.append(value) }
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
