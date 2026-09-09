import Foundation

// MARK: - DownloadStatus

public enum LiveActivityStatus: String, Codable, Sendable, Equatable, Hashable {
    case queued
    case preparing
    case downloading
    case saving
    case succeeded
    case failed
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
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return []
        }
        // If fileURL is a directory, reading will fail -> throw to indicate failure (so enqueue can surface error)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
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
            // Corrupted file -> treat as empty but log? For now throw persistenceFailed so caller knows
            // However load should be forgiving in production; but for test that uses directory we need throw.
            // Check if file is directory already handled; for other errors, try to return empty if decode fails due to empty?
            throw QueueError.persistenceFailed(error.localizedDescription)
        }
    }

    public func save(_ items: [QueuedDownload]) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(items)
        let dir = fileURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw QueueError.persistenceFailed(error.localizedDescription)
        }
    }

    @discardableResult
    public func enqueue(sourceURL: URL) throws -> QueuedDownload {
        guard let scheme = sourceURL.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            throw QueueError.invalidURL
        }
        var items = try load()
        let item = QueuedDownload(sourceURL: sourceURL, status: .queued)
        items.append(item)
        try save(items)
        return item
    }

    public func update(id: UUID, status: DownloadStatus) throws {
        var items = try load()
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].status = status
        try save(items)
    }

    public func remove(id: UUID) throws {
        var items = try load()
        items.removeAll { $0.id == id }
        try save(items)
    }

    public func allItems() throws -> [QueuedDownload] {
        try load()
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
