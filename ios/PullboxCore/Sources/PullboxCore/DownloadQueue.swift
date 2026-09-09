import Foundation
#if canImport(Darwin)
import Darwin
#endif

// MARK: - DownloadStatus

public enum LiveActivityStatus: String, Codable, Sendable, Equatable, Hashable {
    case queued
    case preparing
    case downloading
    case saving
    case succeeded
    case failed
}

public enum DownloadProgressScale {
    public static let serverUpperBound = 0.9
    public static let deviceTransferUpperBound = 0.99

    public static func deviceTransfer(rawProgress: Double) -> Double {
        let bounded = min(max(rawProgress, 0), 1)
        return serverUpperBound + bounded * (deviceTransferUpperBound - serverUpperBound)
    }
}

public enum DownloadStatus: Codable, Sendable, Equatable, Hashable {
    case queued
    case preparing
    case downloading(progress: Double?)
    case saving
    case succeeded
    case failed(String)

    private enum Kind: String, Codable {
        case queued, preparing, downloading, saving, succeeded, failed
    }
    private enum CodingKeys: String, CodingKey {
        case kind, progress, error
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .queued:
            self = .queued
        case .preparing:
            self = .preparing
        case .downloading:
            let progress = try container.decodeIfPresent(Double.self, forKey: .progress)
            self = .downloading(progress: progress)
        case .saving:
            self = .saving
        case .succeeded:
            self = .succeeded
        case .failed:
            let error = try container.decodeIfPresent(String.self, forKey: .error) ?? "unknown"
            self = .failed(error)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .queued:
            try container.encode(Kind.queued, forKey: .kind)
        case .preparing:
            try container.encode(Kind.preparing, forKey: .kind)
        case .downloading(let progress):
            try container.encode(Kind.downloading, forKey: .kind)
            try container.encodeIfPresent(progress, forKey: .progress)
        case .saving:
            try container.encode(Kind.saving, forKey: .kind)
        case .succeeded:
            try container.encode(Kind.succeeded, forKey: .kind)
        case .failed(let error):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(error, forKey: .error)
        }
    }

    public var liveActivityStatus: LiveActivityStatus {
        switch self {
        case .queued: return .queued
        case .preparing: return .preparing
        case .downloading: return .downloading
        case .saving: return .saving
        case .succeeded: return .succeeded
        case .failed: return .failed
        }
    }
}

// MARK: - QueuedDownload

public struct QueuedDownload: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let sourceURL: URL
    public let createdAt: Date
    public var status: DownloadStatus
    public var title: String?

    public init(
        id: UUID = UUID(),
        sourceURL: URL,
        createdAt: Date = Date(),
        status: DownloadStatus = .queued,
        title: String? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.createdAt = createdAt
        self.status = status
        self.title = title
    }
}

// MARK: - FileQueueStore

public enum QueueError: LocalizedError, Equatable {
    case invalidURL
    case persistenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Only HTTP and HTTPS URLs are supported"
        case .persistenceFailed(let msg): return msg
        }
    }
}

private final class FileQueueLockRegistry: @unchecked Sendable {
    static let shared = FileQueueLockRegistry()

    private let registryLock = NSLock()
    private var locks: [String: NSLock] = [:]

    func lock(for path: String) -> NSLock {
        registryLock.withLock {
            if let existing = locks[path] {
                return existing
            }
            let created = NSLock()
            locks[path] = created
            return created
        }
    }
}

public struct FileQueueStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Production initializer using App Group container. Falls back to ApplicationSupport/temporaryDirectory if group not available (e.g., tests).
    public init(appGroupIdentifier: String = "group.dev.iamngoni.pullbox", filename: String = "pullbox-queue.json") {
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) {
            self.fileURL = container.appending(path: filename)
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.fileURL = base.appending(path: filename)
        }
    }

    public func load() throws -> [QueuedDownload] {
        try withExclusiveLock {
            try loadUnlocked()
        }
    }

    public func save(_ items: [QueuedDownload]) throws {
        try withExclusiveLock {
            try saveUnlocked(items)
        }
    }

    @discardableResult
    public func enqueue(sourceURL: URL, id: UUID = UUID(), title: String? = nil) throws -> QueuedDownload {
        guard let scheme = sourceURL.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw QueueError.invalidURL
        }

        return try withExclusiveLock {
            var items = try loadUnlocked()
            let item = QueuedDownload(id: id, sourceURL: sourceURL, status: .queued, title: title)
            items.append(item)
            try saveUnlocked(items)
            return item
        }
    }

    public func update(id: UUID, status: DownloadStatus) throws {
        try withExclusiveLock {
            var items = try loadUnlocked()
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].status = status
            try saveUnlocked(items)
        }
    }

    public func updateTitle(id: UUID, title: String) throws {
        try withExclusiveLock {
            var items = try loadUnlocked()
            guard let index = items.firstIndex(where: { $0.id == id }) else { return }
            items[index].title = title
            try saveUnlocked(items)
        }
    }

    /// Records progress only while the transfer is still active. This prevents a
    /// delayed URLSession progress callback from reopening a saving or terminal item.
    @discardableResult
    public func updateProgressIfActive(id: UUID, progress: Double) throws -> QueuedDownload? {
        try withExclusiveLock {
            var items = try loadUnlocked()
            guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
            let boundedProgress = min(max(progress, 0), 1)
            switch items[index].status {
            case .queued, .preparing:
                items[index].status = .downloading(progress: boundedProgress)
                try saveUnlocked(items)
                return items[index]
            case .downloading(let existingProgress):
                let monotonicProgress = max(existingProgress ?? 0, boundedProgress)
                items[index].status = .downloading(progress: monotonicProgress)
                try saveUnlocked(items)
                return items[index]
            case .saving, .succeeded, .failed:
                return nil
            }
        }
    }

    public func remove(id: UUID) throws {
        try withExclusiveLock {
            var items = try loadUnlocked()
            items.removeAll { $0.id == id }
            try saveUnlocked(items)
        }
    }

    public func allItems() throws -> [QueuedDownload] {
        try load()
    }

    private func loadUnlocked() throws -> [QueuedDownload] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw QueueError.persistenceFailed("queue path is a directory")
        }

        do {
            let data = try Data(contentsOf: fileURL)
            if data.isEmpty { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode([QueuedDownload].self, from: data)
        } catch let error as QueueError {
            throw error
        } catch {
            throw QueueError.persistenceFailed(error.localizedDescription)
        }
    }

    private func saveUnlocked(_ items: [QueuedDownload]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(items)
        let directory = fileURL.deletingLastPathComponent()

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw QueueError.persistenceFailed(error.localizedDescription)
        }
    }

    private func withExclusiveLock<T>(_ operation: () throws -> T) throws -> T {
        let directory = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw QueueError.persistenceFailed(error.localizedDescription)
        }

        let inProcessLock = FileQueueLockRegistry.shared.lock(for: fileURL.standardizedFileURL.path)
        inProcessLock.lock()
        defer { inProcessLock.unlock() }

        #if canImport(Darwin)
        let lockURL = fileURL.appendingPathExtension("lock")
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw QueueError.persistenceFailed(String(cString: strerror(errno)))
        }
        defer { _ = Darwin.close(descriptor) }

        guard Darwin.lockf(descriptor, F_LOCK, 0) == 0 else {
            throw QueueError.persistenceFailed(String(cString: strerror(errno)))
        }
        defer { _ = Darwin.lockf(descriptor, F_ULOCK, 0) }
        #endif

        return try operation()
    }
}

// MARK: - ShareURLExtractor (extension-safe)

public enum ShareURLExtractor {
    public static func firstWebURL(in value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), isWebURL(url) {
            return url
        }
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else {
            return nil
        }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let matches = detector.matches(in: trimmed, range: range)
        for match in matches {
            if let url = match.url, isWebURL(url) {
                return url
            }
        }
        return nil
    }

    public static func isWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }
}
