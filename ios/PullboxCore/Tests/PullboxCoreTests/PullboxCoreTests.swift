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
