import Foundation
import Testing
@testable import PullboxCore

// MARK: - Queue persistence (TDD RED)

@Test func enqueueValidHttpURLPersistsQueuedItem() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = try #require(FileQueueStore(fileURL: tmp))
    let url = try #require(URL(string: "https://example.com/video"))
    let item = try store.enqueue(sourceURL: url)
    #expect(item.sourceURL == url)
    #expect(item.status == .queued)
    // Durable: reload from new store instance reads back
    let store2 = try #require(FileQueueStore(fileURL: tmp))
    let items = try store2.load()
    #expect(items.count == 1)
    #expect(items[0].id == item.id)
}

@Test func enqueueInvalidSchemeThrowsAndDoesNotPersist() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = try #require(FileQueueStore(fileURL: tmp))
    let bad = try #require(URL(string: "file:///etc/passwd"))
    #expect(throws: (any Error).self) {
        _ = try store.enqueue(sourceURL: bad)
    }
    let items = try store.load()
    #expect(items.isEmpty)
}

@Test func enqueueDurablePersistsAcrossInstances() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-test-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tmp) }
    let store = try #require(FileQueueStore(fileURL: tmp))
    for i in 0..<3 {
        let url = try #require(URL(string: "https://example.com/video\(i)"))
        _ = try store.enqueue(sourceURL: url)
    }
    let store2 = try #require(FileQueueStore(fileURL: tmp))
    let items = try store2.load()
    #expect(items.count == 3)
}

@Test func enqueueFailureDoesNotFalselyReportSuccess() throws {
    // Use a directory as file URL to force write failure
    let tmpDir = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-dir-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }
    // fileURL points to directory, not file -> save should fail
    let store = FileQueueStore(fileURL: tmpDir)
    let url = try #require(URL(string: "https://example.com/video"))
    var didThrow = false
    do {
        _ = try store.enqueue(sourceURL: url)
    } catch {
        didThrow = true
    }
    #expect(didThrow == true)
}

@Test func loadReturnsEmptyWhenNoFile() throws {
    let tmp = FileManager.default.temporaryDirectory
        .appending(path: "pullbox-missing-\(UUID().uuidString).json")
    let store = FileQueueStore(fileURL: tmp)
    let items = try store.load()
    #expect(items.isEmpty)
}

@Test func downloadStatusCodableRoundTrip() throws {
    let statuses: [DownloadStatus] = [
        .queued,
        .preparing,
        .downloading(progress: 0.42),
        .saving,
        .succeeded,
        .failed("boom")
    ]
    for status in statuses {
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(DownloadStatus.self, from: data)
        #expect(decoded == status)
    }
}

@Test func queuedDownloadCodableRoundTrip() throws {
    let url = try #require(URL(string: "https://example.com/video"))
    let item = QueuedDownload(sourceURL: url, status: .downloading(progress: 0.5))
    let data = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(QueuedDownload.self, from: data)
    #expect(decoded == item)
}

// MARK: - Share URL extraction (extension-safe)

@Test func shareURLExtractorFindsWebURLInText() throws {
    let text = "Check https://example.com/video?id=123 wow"
    let url = ShareURLExtractor.firstWebURL(in: text)
    #expect(url?.absoluteString == "https://example.com/video?id=123")
}

@Test func shareURLExtractorRejectsNonWebURLs() throws {
    #expect(ShareURLExtractor.firstWebURL(in: "file:///etc/passwd") == nil)
    #expect(ShareURLExtractor.firstWebURL(in: "not a link") == nil)
    #expect(ShareURLExtractor.firstWebURL(in: "javascript:alert(1)") == nil)
}

@Test func shareURLExtractorPrefersDirectWebURL() throws {
    let url = ShareURLExtractor.firstWebURL(in: "https://example.com/video")
    #expect(url?.absoluteString == "https://example.com/video")
}

// MARK: - Live Activity

@Test func liveActivityAttributesEncodeContentState() throws {
    let attrs = PullboxDownloadAttributes(id: "test-123", sourceURL: "https://example.com/video")
    #expect(attrs.id == "test-123")
    let states: [PullboxDownloadAttributes.ContentState] = [
        .init(status: .queued, progress: nil, title: nil),
        .init(status: .preparing, progress: nil, title: "Preparing"),
        .init(status: .downloading, progress: 0.0, title: "Clip"),
        .init(status: .downloading, progress: 0.75, title: "Clip"),
        .init(status: .saving, progress: nil, title: "Clip"),
        .init(status: .succeeded, progress: 1.0, title: "Clip"),
        .init(status: .failed, progress: nil, title: "Clip", errorMessage: "Nope")
    ]
    for state in states {
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(PullboxDownloadAttributes.ContentState.self, from: data)
        #expect(decoded.status == state.status)
        #expect(decoded.progress == state.progress)
    }
}

@Test func downloadStatusMapsToLiveActivityState() throws {
    #expect(DownloadStatus.queued.liveActivityStatus == .queued)
    #expect(DownloadStatus.preparing.liveActivityStatus == .preparing)
    #expect(DownloadStatus.downloading(progress: 0.5).liveActivityStatus == .downloading)
    #expect(DownloadStatus.saving.liveActivityStatus == .saving)
    #expect(DownloadStatus.succeeded.liveActivityStatus == .succeeded)
    #expect(DownloadStatus.failed("x").liveActivityStatus == .failed)
}
