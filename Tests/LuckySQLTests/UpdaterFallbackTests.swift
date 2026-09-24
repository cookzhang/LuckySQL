import Foundation
import XCTest
@testable import LuckySQL

final class UpdaterFallbackTests: XCTestCase {
    func testRateLimitUsesCanonicalPageChecksumAndPackageSize() async throws {
        for status in [403, 429] {
            let session = session(status: status)
            let release = try await UpdateService(session: session).latest()
            XCTAssertEqual(release.tag_name, "v9.8.7")
            let asset = try XCTUnwrap(release.update(after: "0.3.2"))
            XCTAssertEqual(asset.size, 4096)
            XCTAssertEqual(asset.digest, "sha256:" + String(repeating: "a", count: 64))
            session.invalidateAndCancel()
        }
    }
    func testFallbackRejectsUntrustedRedirectAndBadChecksum() async throws {
        for mode in ["bad-host", "bad-checksum", "checksum-404", "archive-403", "missing-size"] {
            let session = session(status: 429, mode: mode)
            do { _ = try await UpdateService(session: session).latest(); XCTFail("Expected rejection for \(mode)") }
            catch { XCTAssertTrue(error.localizedDescription.contains("fallback failed")) }
            session.invalidateAndCancel()
        }
    }
    private func session(status: Int, mode: String = "valid") -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [UpdaterFixtureProtocol.self]
        config.httpAdditionalHeaders = ["X-Fixture-Status": String(status), "X-Fixture-Mode": mode]
        return URLSession(configuration: config)
    }
}
private final class UpdaterFixtureProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!, mode = request.value(forHTTPHeaderField: "X-Fixture-Mode") ?? "valid"
        var responseURL = url, status = 200, data = Data(), headers: [String: String] = [:]
        if url.host == "api.github.com" { status = Int(request.value(forHTTPHeaderField: "X-Fixture-Status") ?? "429")! }
        else if url.path.hasSuffix("/latest") {
            responseURL = URL(string: mode == "bad-host" ? "https://example.invalid/cookzhang/LuckySQL/releases/tag/v9.8.7" : "https://github.com/cookzhang/LuckySQL/releases/tag/v9.8.7")!
        } else if url.path.hasSuffix(".sha256") {
            status = mode == "checksum-404" ? 404 : 200
            data = Data((String(repeating: "a", count: 64) + "  " + (mode == "bad-checksum" ? "wrong.zip" : "LuckySQL-v9.8.7-macos-arm64.zip")).utf8)
        } else {
            status = mode == "archive-403" ? 403 : 200
            if mode != "missing-size" { headers["Content-Length"] = "4096" }
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: responseURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
