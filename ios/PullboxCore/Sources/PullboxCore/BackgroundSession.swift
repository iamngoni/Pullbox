import Foundation
#if canImport(Darwin)
import Darwin
#endif
#if canImport(Photos) && os(iOS)
import Photos
#endif

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

public enum PhotoLibrarySaveError: LocalizedError, Equatable {
    case notConfigured
    case permissionDenied
    case saveFailed

    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            "Photo library saving is not configured for this process."
        case .permissionDenied:
            "Allow Pullbox to add media to Photos."
        case .saveFailed:
            "The media could not be saved to Photos."
        }
    }
}

/// Failing fallback used where Photos is unavailable (for example the share extension).
/// It must never silently acknowledge a save because that would lose the downloaded file.
public struct NoopPhotoSaver: PhotoLibrarySaving {
    public init() {}

    public func save(at url: URL) async throws {
        throw PhotoLibrarySaveError.notConfigured
    }
}

public enum PhotoLibraryAssetKind: Sendable, Equatable {
    case image
    case video

    public init(fileExtension: String) {
        let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "webp"]
        self = imageExtensions.contains(fileExtension.lowercased()) ? .image : .video
    }
}

#if canImport(Photos) && os(iOS)
public struct SystemPhotoLibrarySaver: PhotoLibrarySaving {
    public init() {}

    public func save(at url: URL) async throws {
        let authorization = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard authorization == .authorized || authorization == .limited else {
            throw PhotoLibrarySaveError.permissionDenied
        }

        let assetKind = PhotoLibraryAssetKind(fileExtension: url.pathExtension)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                switch assetKind {
                case .image:
                    PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: url)
                case .video:
                    PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                }
            } completionHandler: { saved, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if saved {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: PhotoLibrarySaveError.saveFailed)
                }
            }
        }
    }
}
#endif

/// Moves CFNetwork's callback-scoped download into a durable location before the
/// URLSession delegate method returns. Apple's temporary location is otherwise deleted.
public struct DownloadedFileStager: Sendable {
    public let directory: URL

    public init(directory: URL = BackgroundDownloadHandoff.stagingDirectory) {
        self.directory = directory
    }

    public func stage(fileAt source: URL, taskID: UUID, response: URLResponse?) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appending(path: "\(taskID.uuidString).\(fileExtension(for: response))")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: source, to: destination)
        return destination
    }

    private func fileExtension(for response: URLResponse?) -> String {
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")?
            .lowercased() ?? ""

        if contentType.contains("application/json") { return "json" }
        if contentType.contains("image/png") { return "png" }
        if contentType.contains("image/webp") { return "webp" }
        if contentType.contains("image/heic") || contentType.contains("image/heif") { return "heic" }
        if contentType.hasPrefix("image/") { return "jpg" }
        if contentType.contains("video/quicktime") { return "mov" }
        return "mp4"
    }
}

public struct StagedTransferReceipt: Codable, Sendable, Equatable {
    public let taskID: UUID
    public let payloadFilename: String?
    public let statusCode: Int?
    public let contentType: String?
    public let errorDescription: String?
    public let photoSaved: Bool?

    var hasSavedToPhotos: Bool { photoSaved == true }
}

final class StagedTransferClaim: @unchecked Sendable {
    let receipt: StagedTransferReceipt
    let lockURL: URL
    private let lock = NSLock()
    private var descriptor: Int32?

    init(receipt: StagedTransferReceipt, lockURL: URL, descriptor: Int32?) {
        self.receipt = receipt
        self.lockURL = lockURL
        self.descriptor = descriptor
    }

    func release() {
        let descriptor = lock.withLock {
            let descriptor = self.descriptor
            self.descriptor = nil
            return descriptor
        }
        #if canImport(Darwin)
        if let descriptor {
            _ = flock(descriptor, LOCK_UN)
            _ = close(descriptor)
        }
        #endif
    }

    deinit {
        release()
    }
}

/// Durable per-transfer receipts stored alongside App Group payloads.
public struct StagedTransferJournal: Sendable {
    public let directory: URL

    public init(directory: URL = BackgroundDownloadHandoff.stagingDirectory) {
        self.directory = directory
    }

    public func record(
        taskID: UUID,
        payloadURL: URL?,
        response: URLResponse?,
        errorDescription: String?
    ) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let payloadURL {
            guard payloadURL.deletingLastPathComponent().standardizedFileURL == directory.standardizedFileURL else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        let http = response as? HTTPURLResponse
        let receipt = StagedTransferReceipt(
            taskID: taskID,
            payloadFilename: payloadURL?.lastPathComponent,
            statusCode: http?.statusCode,
            contentType: http?.value(forHTTPHeaderField: "Content-Type"),
            errorDescription: errorDescription,
            photoSaved: false
        )
        let data = try JSONEncoder().encode(receipt)
        try data.write(to: receiptURL(for: taskID), options: [.atomic])
    }

    public func markPhotoSaved(_ receipt: StagedTransferReceipt) throws {
        let updated = StagedTransferReceipt(
            taskID: receipt.taskID,
            payloadFilename: receipt.payloadFilename,
            statusCode: receipt.statusCode,
            contentType: receipt.contentType,
            errorDescription: receipt.errorDescription,
            photoSaved: true
        )
        let data = try JSONEncoder().encode(updated)
        try data.write(to: receiptURL(for: receipt.taskID), options: [.atomic])
    }

    public func pendingReceipts() throws -> [StagedTransferReceipt] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        try recoverOrphanedPayloads()
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        .filter { $0.lastPathComponent.hasSuffix(".receipt.json") }
        .compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? JSONDecoder().decode(StagedTransferReceipt.self, from: data)
        }
        .sorted { $0.taskID.uuidString < $1.taskID.uuidString }
    }

    func claimPendingReceipts() throws -> [StagedTransferClaim] {
        let receipts = try pendingReceipts()
        #if canImport(Darwin)
        return receipts.compactMap { receipt in
            let lockURL = lockURL(for: receipt.taskID)
            let descriptor = open(
                lockURL.path,
                O_CREAT | O_RDWR,
                mode_t(S_IRUSR | S_IWUSR)
            )
            guard descriptor >= 0 else { return nil }
            _ = fchmod(descriptor, mode_t(S_IRUSR | S_IWUSR))
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                _ = close(descriptor)
                return nil
            }
            guard FileManager.default.fileExists(atPath: receiptURL(for: receipt.taskID).path) else {
                _ = flock(descriptor, LOCK_UN)
                _ = close(descriptor)
                return nil
            }
            return StagedTransferClaim(
                receipt: receipt,
                lockURL: lockURL,
                descriptor: descriptor
            )
        }
        #else
        return receipts.map {
            StagedTransferClaim(receipt: $0, lockURL: lockURL(for: $0.taskID), descriptor: nil)
        }
        #endif
    }

    func removeLock(for claim: StagedTransferClaim) {
        try? FileManager.default.removeItem(at: claim.lockURL)
    }

    public func payloadURL(for receipt: StagedTransferReceipt) -> URL? {
        guard let payloadFilename = receipt.payloadFilename else { return nil }
        return directory.appending(path: payloadFilename)
    }

    public func remove(_ receipt: StagedTransferReceipt) throws {
        if let payloadURL = payloadURL(for: receipt), FileManager.default.fileExists(atPath: payloadURL.path) {
            try FileManager.default.removeItem(at: payloadURL)
        }
        let receiptURL = receiptURL(for: receipt.taskID)
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            try FileManager.default.removeItem(at: receiptURL)
        }
    }

    private func recoverOrphanedPayloads() throws {
        let contentTypes = [
            "jpg": "image/jpeg",
            "jpeg": "image/jpeg",
            "png": "image/png",
            "webp": "image/webp",
            "heic": "image/heic",
            "heif": "image/heif",
            "mov": "video/quicktime",
            "mp4": "video/mp4",
        ]
        let quarantineDate = Date().addingTimeInterval(-5)
        let payloads = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        )
        for payloadURL in payloads {
            let fileExtension = payloadURL.pathExtension.lowercased()
            guard let contentType = contentTypes[fileExtension] else { continue }
            let stem = payloadURL.deletingPathExtension().lastPathComponent
            guard let taskID = UUID(uuidString: stem) else { continue }
            guard !FileManager.default.fileExists(atPath: receiptURL(for: taskID).path) else { continue }
            let values = try payloadURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true,
                  let modified = values.contentModificationDate,
                  modified <= quarantineDate else { continue }
            let response = HTTPURLResponse(
                url: URL(string: "https://pullbox.invalid/download")!,
                statusCode: 200,
                httpVersion: nil,
                headerFields: ["Content-Type": contentType]
            )
            try record(
                taskID: taskID,
                payloadURL: payloadURL,
                response: response,
                errorDescription: nil
            )
        }
    }

    private func receiptURL(for taskID: UUID) -> URL {
        directory.appending(path: "\(taskID.uuidString).receipt.json")
    }

    private func lockURL(for taskID: UUID) -> URL {
        directory.appending(path: "\(taskID.uuidString).receipt.lock")
    }
}

// MARK: - Background Download Enqueuer (system-owned transfer)

public protocol BackgroundTransferEnqueuer: Sendable {
    func enqueueBackgroundDownload(for item: QueuedDownload, request: URLRequest) throws
}

public final class SystemBackgroundTransferEnqueuer: BackgroundTransferEnqueuer, @unchecked Sendable {
    let activeSession: URLSession

    public init(
        factory: DefaultBackgroundSessionFactory = DefaultBackgroundSessionFactory(),
        sessionIdentifier: String = BackgroundDownloadHandoff.backgroundSessionIdentifier,
        delegate: PullboxBackgroundSessionDelegate
    ) {
        self.activeSession = factory.makeSession(
            identifier: sessionIdentifier,
            delegate: delegate
        )
    }

    public func enqueueBackgroundDownload(for item: QueuedDownload, request: URLRequest) throws {
        let task = activeSession.downloadTask(with: request)
        task.taskDescription = item.id.uuidString
        task.resume()
    }
}

// MARK: - Background Session Delegate (drives completion honestly)

public final class BackgroundEventsCompletionHandler: @unchecked Sendable {
    /// UIKit's delegate API predates Swift concurrency, so its callback isn't
    /// annotated `Sendable`. The box is only read after transfer through the
    /// lock and its closure is always invoked on the main queue.
    private final class Callback: @unchecked Sendable {
        let run: () -> Void

        init(_ run: @escaping () -> Void) {
            self.run = run
        }
    }

    private let lock = NSLock()
    private var completion: Callback?
    private var completedBeforeInstall = false

    public init() {}

    public func install(_ completion: @escaping () -> Void) {
        let installed = Callback(completion)
        let callback = lock.withLock { () -> Callback? in
            if completedBeforeInstall {
                completedBeforeInstall = false
                return installed
            }
            self.completion = installed
            return nil
        }
        if let callback {
            dispatchOnMain(callback)
        }
    }

    public func complete() {
        let callback = lock.withLock { () -> Callback? in
            guard let completion else {
                completedBeforeInstall = true
                return nil
            }
            self.completion = nil
            return completion
        }
        if let callback {
            dispatchOnMain(callback)
        }
    }

    private func dispatchOnMain(_ callback: Callback) {
        if Thread.isMainThread {
            callback.run()
        } else {
            DispatchQueue.main.async {
                callback.run()
            }
        }
    }
}

final class BackgroundEventCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private let onComplete: @Sendable () -> Void
    private var pendingProcessing = 0
    private var systemFinishedEvents = false

    init(onComplete: @escaping @Sendable () -> Void) {
        self.onComplete = onComplete
    }

    func beginProcessing() {
        lock.withLock {
            pendingProcessing += 1
        }
    }

    func endProcessing() {
        let shouldComplete = lock.withLock {
            pendingProcessing = max(0, pendingProcessing - 1)
            guard pendingProcessing == 0, systemFinishedEvents else { return false }
            systemFinishedEvents = false
            return true
        }
        if shouldComplete { onComplete() }
    }

    func systemDidFinishEvents() {
        let shouldComplete = lock.withLock {
            systemFinishedEvents = true
            guard pendingProcessing == 0 else { return false }
            systemFinishedEvents = false
            return true
        }
        if shouldComplete { onComplete() }
    }
}

final class BackgroundEventPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let completionGate: BackgroundEventCompletionGate?
    private var tail: Task<Void, Never>?
    private var generation = 0

    init(completionGate: BackgroundEventCompletionGate? = nil) {
        self.completionGate = completionGate
    }

    func enqueue(_ operation: @escaping @Sendable () async -> Void) {
        completionGate?.beginProcessing()

        let (task, taskGeneration): (Task<Void, Never>, Int) = lock.withLock {
            let previous = tail
            generation += 1
            let currentGeneration = generation
            let task = Task { [completionGate] in
                if let previous {
                    await previous.value
                }
                await operation()
                completionGate?.endProcessing()
            }
            tail = task
            return (task, currentGeneration)
        }

        Task { [weak self] in
            await task.value
            self?.clearTail(ifGenerationIs: taskGeneration)
        }
    }

    func drain() async {
        let pending = lock.withLock { tail }
        await pending?.value
    }

    private func clearTail(ifGenerationIs completedGeneration: Int) {
        lock.withLock {
            if generation == completedGeneration {
                tail = nil
            }
        }
    }
}

public final class PullboxBackgroundSessionDelegate: NSObject, Sendable {
    private let store: FileQueueStore
    private let activityManager: LiveActivityControlling
    private let photoSaver: PhotoLibrarySaving
    private let fileStager: DownloadedFileStager
    private let transferJournal: StagedTransferJournal
    private let completionGate: BackgroundEventCompletionGate
    private let eventPipeline: BackgroundEventPipeline

    public init(
        store: FileQueueStore = BackgroundDownloadHandoff.sharedStore,
        activityManager: LiveActivityControlling = PullboxLiveActivityManager.shared,
        photoSaver: PhotoLibrarySaving = NoopPhotoSaver(),
        fileStager: DownloadedFileStager = DownloadedFileStager(),
        transferJournal: StagedTransferJournal? = nil,
        onBackgroundEventsFinished: @escaping @Sendable () -> Void = {}
    ) {
        let completionGate = BackgroundEventCompletionGate(onComplete: onBackgroundEventsFinished)
        self.store = store
        self.activityManager = activityManager
        self.photoSaver = photoSaver
        self.fileStager = fileStager
        self.transferJournal = transferJournal ?? StagedTransferJournal(directory: fileStager.directory)
        self.completionGate = completionGate
        self.eventPipeline = BackgroundEventPipeline(completionGate: completionGate)
        super.init()
    }

    func stageDownloadedFile(
        taskDescription: String?,
        response: URLResponse?,
        location: URL
    ) throws -> URL {
        guard let taskDescription, let taskID = UUID(uuidString: taskDescription) else {
            throw URLError(.badURL)
        }
        let stagedLocation = try fileStager.stage(
            fileAt: location,
            taskID: taskID,
            response: response
        )
        do {
            try transferJournal.record(
                taskID: taskID,
                payloadURL: stagedLocation,
                response: response,
                errorDescription: nil
            )
            return stagedLocation
        } catch {
            try? FileManager.default.removeItem(at: stagedLocation)
            throw error
        }
    }

    func recordTransportFailure(
        taskDescription: String?,
        response: URLResponse?,
        error: Error
    ) throws {
        guard let taskDescription, let taskID = UUID(uuidString: taskDescription) else {
            throw URLError(.badURL)
        }
        let existingReceipt = try transferJournal.pendingReceipts()
            .first(where: { $0.taskID == taskID })
        try transferJournal.record(
            taskID: taskID,
            payloadURL: existingReceipt.flatMap(transferJournal.payloadURL(for:)),
            response: response,
            errorDescription: error.localizedDescription
        )
    }

    public func recoverPendingDownloads() async {
        guard let claims = try? transferJournal.claimPendingReceipts() else { return }
        for claim in claims {
            let isTerminal = await process(receipt: claim.receipt)
            if isTerminal {
                try? transferJournal.remove(claim.receipt)
            }
            claim.release()
            if isTerminal {
                transferJournal.removeLock(for: claim)
            }
        }
    }

    private func process(receipt: StagedTransferReceipt) async -> Bool {
        guard let item = try? store.load().first(where: { $0.id == receipt.taskID }) else {
            return false
        }
        switch item.status {
        case .succeeded, .failed:
            return true
        case .queued, .preparing, .downloading, .saving:
            break
        }

        if let errorDescription = receipt.errorDescription {
            return await persistFailure(for: item, message: errorDescription)
        }
        guard let statusCode = receipt.statusCode else {
            return await persistFailure(for: item, message: "Invalid response")
        }
        guard 200..<300 ~= statusCode else {
            var message = "Download failed with status \(statusCode)."
            if let payloadURL = transferJournal.payloadURL(for: receipt),
               let data = try? Data(contentsOf: payloadURL),
               let server = try? JSONDecoder().decode(ServerError.self, from: data) {
                message = server.error
            }
            return await persistFailure(for: item, message: message)
        }
        if receipt.hasSavedToPhotos {
            do {
                try store.update(id: item.id, status: .succeeded)
            } catch {
                return false
            }
            await activityManager.end(for: item, status: .succeeded, errorMessage: nil)
            return true
        }
        guard let payloadURL = transferJournal.payloadURL(for: receipt),
              FileManager.default.fileExists(atPath: payloadURL.path) else {
            return await persistFailure(for: item, message: "Missing downloaded file")
        }

        do {
            try store.update(id: item.id, status: .saving)
        } catch {
            return false
        }
        await activityManager.update(for: item, status: .saving, progress: nil, title: nil)

        do {
            try await photoSaver.save(at: payloadURL)
            do {
                try transferJournal.markPhotoSaved(receipt)
            } catch {
                return false
            }
        } catch {
            return await persistFailure(for: item, message: error.localizedDescription)
        }

        do {
            try store.update(id: item.id, status: .succeeded)
        } catch {
            return false
        }
        await activityManager.end(for: item, status: .succeeded, errorMessage: nil)
        return true
    }

    private func persistFailure(for item: QueuedDownload, message: String) async -> Bool {
        do {
            try store.update(id: item.id, status: .failed(message))
        } catch {
            return false
        }
        await activityManager.end(for: item, status: .failed(message), errorMessage: message)
        return true
    }

    // Exposed for testing: handle downloaded file location
    public func handleDownloadCompletion(taskDescription: String?, response: URLResponse?, location: URL?, error: Error?) async {
        guard let idStr = taskDescription, let uuid = UUID(uuidString: idStr) else { return }
        let items = (try? store.load()) ?? []
        guard let item = items.first(where: { $0.id == uuid }) else { return }
        defer {
            if let location {
                try? FileManager.default.removeItem(at: location)
            }
        }

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

        // Save the already-staged file to Photos. Success is recorded only after
        // the Photos transaction completes; defer removes the staging file on every path.
        do {
            try? store.update(id: uuid, status: .saving)
            await activityManager.update(for: item, status: .saving, progress: nil, title: nil)
            try await photoSaver.save(at: location)

            try? store.update(id: uuid, status: .succeeded)
            await activityManager.end(for: item, status: .succeeded, errorMessage: nil)
        } catch {
            let msg = error.localizedDescription
            try? store.update(id: uuid, status: .failed(msg))
            await activityManager.end(for: item, status: .failed(msg), errorMessage: msg)
        }
    }

    public func handleProgress(taskDescription: String?, progress: Double) async {
        guard let idString = taskDescription, let uuid = UUID(uuidString: idString) else { return }
        guard let item = try? store.updateProgressIfActive(id: uuid, progress: progress),
              case .downloading(let storedProgress) = item.status else { return }
        let publishedProgress = storedProgress ?? progress
        let status = DownloadStatus.downloading(progress: publishedProgress)
        await activityManager.update(
            for: item,
            status: status,
            progress: publishedProgress,
            title: nil
        )
    }
}

extension PullboxBackgroundSessionDelegate: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let response = downloadTask.response
        let description = downloadTask.taskDescription
        guard let description, UUID(uuidString: description) != nil else { return }
        do {
            // CFNetwork deletes `location` when this callback returns, so both the move
            // and durable receipt write must remain synchronous.
            _ = try stageDownloadedFile(
                taskDescription: description,
                response: response,
                location: location
            )
            eventPipeline.enqueue { [self] in
                await recoverPendingDownloads()
            }
        } catch {
            let stagingError = error
            eventPipeline.enqueue { [self] in
                await handleDownloadCompletion(
                    taskDescription: description,
                    response: response,
                    location: nil,
                    error: stagingError
                )
            }
        }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let rawProgress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let progress = DownloadProgressScale.deviceTransfer(rawProgress: rawProgress)
        guard let description = downloadTask.taskDescription else { return }
        eventPipeline.enqueue { [self] in
            await handleProgress(taskDescription: description, progress: progress)
        }
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let description = task.taskDescription
            let response = task.response
            do {
                try recordTransportFailure(
                    taskDescription: description,
                    response: response,
                    error: error
                )
                eventPipeline.enqueue { [self] in
                    await recoverPendingDownloads()
                }
            } catch {
                let journalError = error
                eventPipeline.enqueue { [self] in
                    await handleDownloadCompletion(
                        taskDescription: description,
                        response: response,
                        location: nil,
                        error: journalError
                    )
                }
            }
        }
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        completionGate.systemDidFinishEvents()
    }
}

private struct ServerError: Decodable { let error: String }

public protocol BackgroundSessionInvalidating: AnyObject {
    func finishTasksAndInvalidate()
}

extension URLSession: BackgroundSessionInvalidating {}

/// Retains the host-side background session only while UIKit-delivered events are being drained.
public final class BackgroundSessionOwnership: @unchecked Sendable {
    private let lock = NSLock()
    private var session: (any BackgroundSessionInvalidating)?

    public init() {}

    public var hasRetainedSession: Bool {
        lock.withLock { session != nil }
    }

    public func retain(_ session: any BackgroundSessionInvalidating) {
        lock.withLock { self.session = session }
    }

    public func finishAndRelease() {
        let retainedSession = lock.withLock {
            let retainedSession = session
            session = nil
            return retainedSession
        }
        retainedSession?.finishTasksAndInvalidate()
    }
}

public enum PullboxBackgroundSessionCoordinator {
    public static func makeSession(
        delegate: PullboxBackgroundSessionDelegate,
        identifier: String = BackgroundDownloadHandoff.backgroundSessionIdentifier
    ) -> URLSession {
        DefaultBackgroundSessionFactory().makeSession(
            identifier: identifier,
            delegate: delegate
        )
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
