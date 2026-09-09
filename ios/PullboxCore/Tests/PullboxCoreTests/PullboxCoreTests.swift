import Foundation
import Testing
@testable import PullboxCore

@Test func mediaInfoDecodesBackendPayload() throws {
    let data = Data(#"{"title":"A clip","thumbnail":"https://example.com/thumb.jpg","duration":12.5,"sourceUrl":"https://example.com/video"}"#.utf8)
    let info = try JSONDecoder().decode(MediaInfo.self, from: data)
    #expect(info.title == "A clip")
    #expect(info.duration == 12.5)
    #expect(info.sourceURL.absoluteString == "https://example.com/video")
}

@Test func requestBuilderTargetsDownloadEndpoint() throws {
    let baseURL = try #require(URL(string: "http://127.0.0.1:8787"))
    let sourceURL = try #require(URL(string: "https://example.com/video"))
    let request = try APIRequestBuilder(baseURL: baseURL).download(sourceURL: sourceURL)
    #expect(request.url?.absoluteString == "http://127.0.0.1:8787/api/download")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["url"] as? String == sourceURL.absoluteString)
}

@Test func downloadRequestCarriesTheLiveActivityJoinKeys() throws {
    let baseURL = try #require(URL(string: "https://pullbox.example"))
    let sourceURL = try #require(URL(string: "https://example.com/video"))
    let requestID = UUID()

    let request = try APIRequestBuilder(baseURL: baseURL).download(
        sourceURL: sourceURL,
        requestID: requestID,
        title: "Resolved clip",
        clientID: "client-123"
    )

    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["requestId"] as? String == requestID.uuidString)
    #expect(json["title"] as? String == "Resolved clip")
    #expect(json["clientId"] as? String == "client-123")
}

@Test func clientIdentityIsStableInSharedDefaults() throws {
    let suiteName = "dev.iamngoni.pullbox.tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let store = PullboxClientIdentityStore(defaults: defaults)

    let first = store.clientID()
    let second = PullboxClientIdentityStore(defaults: defaults).clientID()

    #expect(UUID(uuidString: first) != nil)
    #expect(second == first)
}

@Test func pushToStartTokenRegistrationRequestUsesTheBackendContract() throws {
    let baseURL = try #require(URL(string: "https://pullbox.example"))
    let request = try APIRequestBuilder(baseURL: baseURL).registerPushToStartToken(
        clientID: "client-123",
        token: "aabbccdd"
    )

    #expect(request.url?.path == "/api/live-activity/push-to-start-token")
    #expect(request.httpMethod == "POST")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["clientId"] as? String == "client-123")
    #expect(json["token"] as? String == "aabbccdd")
}

@Test func activityUpdateTokenRegistrationRequestUsesTheRequestID() throws {
    let baseURL = try #require(URL(string: "https://pullbox.example"))
    let requestID = UUID()
    let request = try APIRequestBuilder(baseURL: baseURL).registerActivityUpdateToken(
        clientID: "client-123",
        requestID: requestID,
        token: "00112233"
    )

    #expect(request.url?.path == "/api/live-activity/update-token")
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["clientId"] as? String == "client-123")
    #expect(json["requestId"] as? String == requestID.uuidString)
    #expect(json["token"] as? String == "00112233")
}

@Test func activityPushTokensUseLosslessLowercaseHex() {
    #expect(ActivityPushToken.hex(Data([0x00, 0x0f, 0xff])) == "000fff")
    #expect(ActivityPushToken.isValidHex("000fff"))
    #expect(!ActivityPushToken.isValidHex("0ff"))
    #expect(!ActivityPushToken.isValidHex("00zz"))
}

@Test func pushTokenRegistrarSendsTheEncodedPushToStartToken() async throws {
    let baseURL = try #require(URL(string: "https://pullbox.example"))
    let sender = RecordingHTTPRequestSender(statusCode: 204)
    let registrar = ActivityPushTokenRegistrar(
        baseURL: baseURL,
        clientID: "client-123",
        sender: sender
    )

    try await registrar.registerPushToStartToken(Data([0x00, 0xab]))

    let request = try #require(await sender.requests.first)
    let body = try #require(request.httpBody)
    let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
    #expect(json["token"] as? String == "00ab")
}

@Test func pushToStartObserverRegistersEveryTokenRotation() async {
    let registrar = RecordingActivityPushRegistrar()
    let observer = ActivityPushTokenRegistrationLoop(registrar: registrar)
    let tokens = AsyncStream<Data> { continuation in
        continuation.yield(Data([0x01]))
        continuation.yield(Data([0x02]))
        continuation.finish()
    }

    await observer.observePushToStartTokens(tokens)

    #expect(await registrar.pushToStartTokens == [Data([0x01]), Data([0x02])])
}

@Test func tokenObserverRetriesTransientRegistrationFailures() async {
    let registrar = FlakyActivityPushRegistrar(failuresBeforeSuccess: 2)
    let observer = ActivityPushTokenRegistrationLoop(
        registrar: registrar,
        retryDelaysNanoseconds: [0, 0]
    )
    let tokens = AsyncStream<Data> { continuation in
        continuation.yield(Data([0xab]))
        continuation.finish()
    }

    await observer.observePushToStartTokens(tokens)

    #expect(await registrar.pushToStartAttempts == 3)
    #expect(await registrar.registeredToken == Data([0xab]))
}

@Test func activityUpdateRegistrationRetriesTransientFailures() async {
    let registrar = FlakyActivityPushRegistrar(failuresBeforeSuccess: 2)
    let observer = ActivityPushTokenRegistrationLoop(
        registrar: registrar,
        retryDelaysNanoseconds: [0, 0]
    )
    let requestID = UUID()

    await observer.registerActivityUpdateToken(Data([0xcd]), requestID: requestID)

    #expect(await registrar.activityUpdateAttempts == 3)
    #expect(await registrar.registeredRequestID == requestID)
}

private actor FlakyActivityPushRegistrar: ActivityPushTokenRegistering {
    private var failuresRemaining: Int
    private(set) var pushToStartAttempts = 0
    private(set) var activityUpdateAttempts = 0
    private(set) var registeredToken: Data?
    private(set) var registeredRequestID: UUID?

    init(failuresBeforeSuccess: Int) {
        self.failuresRemaining = failuresBeforeSuccess
    }

    func registerPushToStartToken(_ token: Data) async throws {
        pushToStartAttempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw PullboxError.server("transient")
        }
        registeredToken = token
    }

    func registerActivityUpdateToken(_ token: Data, requestID: UUID) async throws {
        activityUpdateAttempts += 1
        if failuresRemaining > 0 {
            failuresRemaining -= 1
            throw PullboxError.server("transient")
        }
        registeredToken = token
        registeredRequestID = requestID
    }
}

private actor RecordingActivityPushRegistrar: ActivityPushTokenRegistering {
    private(set) var pushToStartTokens: [Data] = []
    private(set) var activityTokens: [(UUID, Data)] = []

    func registerPushToStartToken(_ token: Data) async throws {
        pushToStartTokens.append(token)
    }

    func registerActivityUpdateToken(_ token: Data, requestID: UUID) async throws {
        activityTokens.append((requestID, token))
    }
}

private actor RecordingHTTPRequestSender: HTTPRequestSending {
    let statusCode: Int
    private(set) var requests: [URLRequest] = []

    init(statusCode: Int) {
        self.statusCode = statusCode
    }

    func send(_ request: URLRequest) async throws -> HTTPURLResponse {
        requests.append(request)
        return HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
    }
}
