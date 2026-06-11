import XCTest
@testable import ClaudeUsageCore

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class UsageClientTests: XCTestCase {
    private func makeClient() -> UsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return UsageClient(session: URLSession(configuration: configuration))
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testFetchDecodesSnapshotAndSendsHeaders() async throws {
        final class Box { var value: URLRequest? }
        let box = Box()
        StubURLProtocol.handler = { request in
            box.value = request
            return (200, UsageResponseDecoderTests.liveFixture)
        }
        let snapshot = try await makeClient().fetch(accessToken: "sk-test-token")
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(box.value?.url?.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(box.value?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-token")
        XCTAssertEqual(box.value?.value(forHTTPHeaderField: "anthropic-beta"), "oauth-2025-04-20")
    }

    func test401ThrowsUnauthorized() async {
        StubURLProtocol.handler = { _ in (401, Data()) }
        do {
            _ = try await makeClient().fetch(accessToken: "sk-test-token")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? UsageError, .unauthorized)
        }
    }

    func testServerErrorThrowsHTTP() async {
        StubURLProtocol.handler = { _ in (503, Data()) }
        do {
            _ = try await makeClient().fetch(accessToken: "sk-test-token")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? UsageError, .http(503))
        }
    }

    func testBadBodyThrowsDecoding() async {
        StubURLProtocol.handler = { _ in (200, Data("not json".utf8)) }
        do {
            _ = try await makeClient().fetch(accessToken: "sk-test-token")
            XCTFail("expected throw")
        } catch {
            XCTAssertEqual(error as? UsageError, .decoding)
        }
    }
}
