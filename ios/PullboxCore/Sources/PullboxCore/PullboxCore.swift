import Foundation

public struct MediaInfo: Codable, Sendable, Equatable {
    public let title: String
    public let thumbnail: URL?
    public let duration: Double?
    public let sourceURL: URL

    enum CodingKeys: String, CodingKey {
        case title, thumbnail, duration
        case sourceURL = "sourceUrl"
    }
}

public enum PullboxError: LocalizedError {
    case invalidResponse
    case server(String)

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: "Pullbox returned an invalid response."
        case .server(let message): message
        }
    }
}

public struct APIRequestBuilder: Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    public func analyze(sourceURL: URL) throws -> URLRequest {
        try request(path: "api/analyze", body: ["url": sourceURL.absoluteString])
    }

    public func download(
        sourceURL: URL,
        requestID: UUID? = nil,
        title: String? = nil,
        clientID: String? = nil
    ) throws -> URLRequest {
        var body: [String: Any] = ["url": sourceURL.absoluteString]
        if let requestID { body["requestId"] = requestID.uuidString }
        if let title { body["title"] = title }
        if let clientID { body["clientId"] = clientID }
        return try request(path: "api/download", body: body)
    }

    public func registerPushToStartToken(clientID: String, token: String) throws -> URLRequest {
        try request(
            path: "api/live-activity/push-to-start-token",
            body: ["clientId": clientID, "token": token]
        )
    }

    public func registerActivityUpdateToken(
        clientID: String,
        requestID: UUID,
        token: String
    ) throws -> URLRequest {
        try request(
            path: "api/live-activity/update-token",
            body: [
                "clientId": clientID,
                "requestId": requestID.uuidString,
                "token": token,
            ]
        )
    }

    private func request(path: String, body: [String: Any]) throws -> URLRequest {
        let endpoint = baseURL.appending(path: path)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 900
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }
}

public actor APIClient {
    private let builder: APIRequestBuilder
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        builder = APIRequestBuilder(baseURL: baseURL)
        self.session = session
    }

    public func analyze(sourceURL: URL) async throws -> MediaInfo {
        let request = try builder.analyze(sourceURL: sourceURL)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response: response, data: data)
        return try JSONDecoder().decode(MediaInfo.self, from: data)
    }

    public func download(sourceURL: URL) async throws -> URL {
        let request = try builder.download(sourceURL: sourceURL)
        let (temporaryURL, response) = try await session.download(for: request)
        let errorData = (try? Data(contentsOf: temporaryURL)) ?? Data()
        try Self.validate(response: response, data: errorData)
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        let isImage = contentType.hasPrefix("image/")
        let ext = isImage ? (contentType.contains("png") ? "png" : "jpg") : "mp4"
        let destination = FileManager.default.temporaryDirectory
            .appending(path: "Pullbox-\(UUID().uuidString).\(ext)")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporaryURL, to: destination)
        return destination
    }

    private static func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw PullboxError.invalidResponse
        }
        guard 200..<300 ~= http.statusCode else {
            let message = (try? JSONDecoder().decode(ServerError.self, from: data).error)
                ?? "Download failed with status \(http.statusCode)."
            throw PullboxError.server(message)
        }
    }
}

private struct ServerError: Decodable {
    let error: String
}
