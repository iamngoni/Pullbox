import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

public enum ActivityPushToken {
    public static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    public static func isValidHex(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count.isMultiple(of: 2) else { return false }
        return value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (65...70).contains(byte) || (97...102).contains(byte)
        }
    }
}

public protocol HTTPRequestSending: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPURLResponse
}

public struct URLSessionHTTPRequestSender: HTTPRequestSending {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> HTTPURLResponse {
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PullboxError.invalidResponse
        }
        return http
    }
}

public protocol ActivityPushTokenRegistering: Sendable {
    func registerPushToStartToken(_ token: Data) async throws
    func registerActivityUpdateToken(_ token: Data, requestID: UUID) async throws
}

public struct ActivityPushTokenRegistrationLoop: Sendable {
    private let registrar: any ActivityPushTokenRegistering
    private let retryDelaysNanoseconds: [UInt64]

    public init(
        registrar: any ActivityPushTokenRegistering,
        retryDelaysNanoseconds: [UInt64] = [500_000_000, 2_000_000_000]
    ) {
        self.registrar = registrar
        self.retryDelaysNanoseconds = retryDelaysNanoseconds
    }

    public func observePushToStartTokens<S: AsyncSequence>(_ tokens: S) async
    where S.Element == Data {
        do {
            for try await token in tokens {
                await registerWithRetry {
                    try await registrar.registerPushToStartToken(token)
                }
            }
        } catch {
            // ActivityKit owns this sequence. A future app launch starts a fresh observer.
        }
    }

    public func registerActivityUpdateToken(_ token: Data, requestID: UUID) async {
        await registerWithRetry {
            try await registrar.registerActivityUpdateToken(token, requestID: requestID)
        }
    }

    public func observeActivityUpdateTokens<S: AsyncSequence>(
        _ tokens: S,
        requestID: UUID
    ) async where S.Element == Data {
        do {
            for try await token in tokens {
                await registerActivityUpdateToken(token, requestID: requestID)
            }
        } catch {
            // ActivityKit owns this sequence. A future app launch starts a fresh observer.
        }
    }

    private func registerWithRetry(
        operation: @escaping @Sendable () async throws -> Void
    ) async {
        for attempt in 0...retryDelaysNanoseconds.count {
            do {
                try await operation()
                return
            } catch {
                guard attempt < retryDelaysNanoseconds.count else { return }
                do {
                    try await Task.sleep(nanoseconds: retryDelaysNanoseconds[attempt])
                } catch {
                    return
                }
            }
        }
    }
}

public struct ActivityPushTokenRegistrar: ActivityPushTokenRegistering, Sendable {
    private let builder: APIRequestBuilder
    private let clientID: String
    private let sender: any HTTPRequestSending

    public init(
        baseURL: URL,
        clientID: String = PullboxClientIdentityStore().clientID(),
        sender: any HTTPRequestSending = URLSessionHTTPRequestSender()
    ) {
        self.builder = APIRequestBuilder(baseURL: baseURL)
        self.clientID = clientID
        self.sender = sender
    }

    public func registerPushToStartToken(_ token: Data) async throws {
        let tokenString = ActivityPushToken.hex(token)
        let request = try builder.registerPushToStartToken(
            clientID: clientID,
            token: tokenString
        )
        try await send(request)
    }

    public func registerActivityUpdateToken(_ token: Data, requestID: UUID) async throws {
        let tokenString = ActivityPushToken.hex(token)
        let request = try builder.registerActivityUpdateToken(
            clientID: clientID,
            requestID: requestID,
            token: tokenString
        )
        try await send(request)
    }

    private func send(_ request: URLRequest) async throws {
        let response = try await sender.send(request)
        guard 200..<300 ~= response.statusCode else {
            throw PullboxError.server(
                "Push registration failed with status \(response.statusCode)."
            )
        }
    }
}

#if canImport(ActivityKit) && os(iOS)
@available(iOS 17.2, *)
@MainActor
public final class PullboxActivityPushObserver {
    private var pushToStartTask: Task<Void, Never>?
    private var activityDiscoveryTask: Task<Void, Never>?
    private var activityTokenTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    public func start(baseURL: URL) {
        guard pushToStartTask == nil, activityDiscoveryTask == nil else { return }

        let registrar = ActivityPushTokenRegistrar(baseURL: baseURL)
        let registrationLoop = ActivityPushTokenRegistrationLoop(registrar: registrar)

        pushToStartTask = Task {
            await registrationLoop.observePushToStartTokens(
                Activity<PullboxDownloadAttributes>.pushToStartTokenUpdates
            )
        }

        for activity in Activity<PullboxDownloadAttributes>.activities {
            observeUpdateTokens(for: activity, using: registrationLoop)
        }

        activityDiscoveryTask = Task { [weak self] in
            for await activity in Activity<PullboxDownloadAttributes>.activityUpdates {
                guard let self else { return }
                self.observeUpdateTokens(for: activity, using: registrationLoop)
            }
        }
    }

    private func observeUpdateTokens(
        for activity: Activity<PullboxDownloadAttributes>,
        using registrationLoop: ActivityPushTokenRegistrationLoop
    ) {
        guard activityTokenTasks[activity.id] == nil,
              let requestID = UUID(uuidString: activity.attributes.id) else { return }

        activityTokenTasks[activity.id] = Task { @MainActor in
            for await token in activity.pushTokenUpdates {
                await registrationLoop.registerActivityUpdateToken(
                    token,
                    requestID: requestID
                )
            }
        }
    }
}
#endif

public final class PullboxClientIdentityStore: @unchecked Sendable {
    private static let lock = NSLock()
    private static let key = "pullbox.clientID.v1"

    private let defaults: UserDefaults

    public init(
        defaults: UserDefaults = UserDefaults(
            suiteName: BackgroundDownloadHandoff.appGroupIdentifier
        ) ?? .standard
    ) {
        self.defaults = defaults
    }

    public func clientID() -> String {
        Self.lock.withLock {
            if let stored = defaults.string(forKey: Self.key),
               UUID(uuidString: stored) != nil {
                return stored
            }

            let generated = UUID().uuidString
            defaults.set(generated, forKey: Self.key)
            return generated
        }
    }
}
