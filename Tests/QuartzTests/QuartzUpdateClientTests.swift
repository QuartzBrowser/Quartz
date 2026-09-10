import Foundation
import XCTest
@testable import Quartz

final class QuartzUpdateClientTests: XCTestCase, @unchecked Sendable {
    func testReleasePageURLAcceptsOnlyValidatedVersionTags() {
        XCTAssertEqual(QuartzUpdateClient.releasePageURL(for: "v0.8.0")?.absoluteString, "https://github.com/QuartzBrowser/Quartz/releases/tag/v0.8.0")
        XCTAssertEqual(QuartzUpdateClient.releasePageURL(for: "1.0.0+build.1")?.lastPathComponent, "1.0.0+build.1")
        for tag in Self.invalidVersions + ["v1.0.0/../../evil", "https://untrusted.example", "v1.0.0?redirect=evil", "v1.0.0#evil", "v1.0.0%2fevil"] {
            XCTAssertNil(QuartzUpdateClient.releasePageURL(for: tag), tag)
        }
    }

    func testUsesPublicGitHubEndpointAndCanonicalReleaseLinkWithoutRequiringAssets() async throws {
        let harness = makeClient { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/repos/QuartzBrowser/Quartz/releases/latest")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2022-11-28")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Quartz/0.7.0")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(request.timeoutInterval, 30)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            return .json(Self.release(tag: "v0.8.0", htmlURL: "https://untrusted.example/install"))
        }
        defer { harness.finish() }

        let update = try await harness.client.latestUpdate(currentVersion: "0.7.0")
        XCTAssertEqual(update, QuartzUpdateRelease(
            version: "0.8.0",
            url: URL(string: "https://github.com/QuartzBrowser/Quartz/releases/tag/v0.8.0")!
        ))
    }

    func testComparesAllVersionComponentsNumericallyWithoutOverflow() async throws {
        for (installed, released, expected) in [
            ("0.9.0", "v0.10.0", true),
            ("0.10.0", "v0.9.9", false),
            ("0.8.9", "v0.8.10", true),
            ("9.99.99", "v10.0.0", true),
            ("1.99.99", "v2.0.0", true),
            ("2.0.0", "v1.99.99", false),
            ("0.8.0", "v0.8.0", false),
            ("0.8.1", "v0.8.0", false),
            ("999999999999999999999999.0.0", "v1000000000000000000000000.0.0", true)
        ] {
            let harness = makeClient { _ in .json(Self.release(tag: released)) }
            defer { harness.finish() }
            let update = try await harness.client.latestUpdate(currentVersion: installed)
            XCTAssertEqual(update != nil, expected, "Installed \(installed), released \(released)")
        }
    }

    func testStableReleaseReplacesSameVersionPrereleaseAndIgnoresBuildMetadata() async throws {
        for (installed, released, expected) in [
            ("1.0.0-alpha.1", "v1.0.0", true),
            ("1.0.0-rc.999999999999999999999999+build.01", "v1.0.0", true),
            ("1.1.0-beta", "v1.0.0", false),
            ("1.0.0+build.1", "v1.0.0+build.2", false),
            ("1.0.0", "v1.0.0+build.2", false),
            ("v1.0.0", "1.0.1+build.01", true)
        ] {
            let harness = makeClient { _ in .json(Self.release(tag: released)) }
            defer { harness.finish() }
            let update = try await harness.client.latestUpdate(currentVersion: installed)
            XCTAssertEqual(update != nil, expected, "Installed \(installed), released \(released)")
            if expected {
                XCTAssertEqual(update?.version, released.hasPrefix("v") ? String(released.dropFirst()) : released)
                XCTAssertEqual(update?.url.lastPathComponent, released)
            }
        }
    }

    func testDraftsPrereleasesAndPrereleaseTagsAreNotOffered() async throws {
        for json in [
            Self.release(tag: "v2.0.0", draft: true),
            Self.release(tag: "v2.0.0", prerelease: true),
            Self.release(tag: "v2.0.0-beta.1")
        ] {
            let harness = makeClient { _ in .json(json) }
            defer { harness.finish() }
            let update = try await harness.client.latestUpdate(currentVersion: "1.0.0")
            XCTAssertNil(update)
        }
    }

    func testNoPublishedReleasesIsNotAnError() async throws {
        let harness = makeClient { _ in .json(#"{"message":"Not Found"}"#, status: 404) }
        defer { harness.finish() }
        let update = try await harness.client.latestUpdate(currentVersion: "1.0.0")
        XCTAssertNil(update)
    }

    func testInvalidInstalledVersionFailsBeforeNetwork() async {
        let harness = makeClient { _ in
            XCTFail("Invalid installed versions must not start a request")
            return .json(Self.release(tag: "v2.0.0"))
        }
        defer { harness.finish() }
        for version in Self.invalidVersions {
            do {
                _ = try await harness.client.latestUpdate(currentVersion: version)
                XCTFail("Accepted invalid version: \(version)")
            } catch {
                XCTAssertEqual(error as? QuartzUpdateError, .invalidCurrentVersion, version)
            }
        }
    }

    func testMalformedOrUnsafeReleaseTagsAreErrors() async {
        for tag in Self.invalidVersions + ["v1.0.0/../../evil", "https://untrusted.example", "v1.0.0?redirect=evil", "v1.0.0#evil", "v1.0.0%2fevil"] {
            let harness = makeClient { _ in .json(Self.release(tag: tag)) }
            defer { harness.finish() }
            do {
                _ = try await harness.client.latestUpdate(currentVersion: "0.1.0")
                XCTFail("Accepted invalid release tag: \(tag)")
            } catch {
                XCTAssertEqual(error as? QuartzUpdateError, .invalidResponse, tag)
            }
        }
    }

    func testMalformedReleaseResponsesAreErrors() async {
        for json in [
            "not JSON", "{}", "[]", "null",
            #"{"tag_name":"v1.0.0","draft":false}"#,
            #"{"tag_name":"v1.0.0","draft":false,"prerelease":"false"}"#,
            #"{"tag_name":42,"draft":false,"prerelease":false}"#,
            #"{"tag_name":"v1.0.0","draft":null,"prerelease":false}"#
        ] {
            let harness = makeClient { _ in .json(json) }
            defer { harness.finish() }
            do {
                _ = try await harness.client.latestUpdate(currentVersion: "0.1.0")
                XCTFail("Accepted malformed release: \(json)")
            } catch {
                XCTAssertEqual(error as? QuartzUpdateError, .invalidResponse, json)
            }
        }
    }

    func testHTTPFailuresRemainDistinctFromNoUpdate() async {
        for status in [204, 301, 401, 403, 429, 500, 503] {
            let harness = makeClient { _ in .json(Self.release(tag: "v2.0.0"), status: status) }
            defer { harness.finish() }
            do {
                _ = try await harness.client.latestUpdate(currentVersion: "1.0.0")
                XCTFail("Accepted HTTP failure: \(status)")
            } catch {
                XCTAssertEqual(error as? QuartzUpdateError, .httpStatus(status))
            }
        }
    }

    func testNonHTTPResponseIsRejected() async {
        let harness = makeClient { _ in .nonHTTP }
        defer { harness.finish() }
        do {
            _ = try await harness.client.latestUpdate(currentVersion: "1.0.0")
            XCTFail("Accepted a non-HTTP response")
        } catch {
            XCTAssertEqual(error as? QuartzUpdateError, .invalidResponse)
        }
    }

    func testNetworkFailuresAreReported() async {
        for code in [URLError.Code.notConnectedToInternet, .timedOut, .secureConnectionFailed] {
            let harness = makeClient { _ in throw URLError(code) }
            defer { harness.finish() }
            do {
                _ = try await harness.client.latestUpdate(currentVersion: "1.0.0")
                XCTFail("Accepted a failed network request")
            } catch {
                XCTAssertEqual(error as? QuartzUpdateError, .connection)
            }
        }
    }

    func testCancellingUpdateCheckStopsTheRequest() async {
        let started = expectation(description: "Update request started")
        let stopped = expectation(description: "Update request stopped")
        let harness = makeClient { _ in
            .pending(onStart: { started.fulfill() }, onStop: { stopped.fulfill() })
        }
        defer { harness.finish() }
        let task = Task { try await harness.client.latestUpdate(currentVersion: "1.0.0") }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled update check must not return a result")
        } catch is CancellationError {
            // Cancellation remains distinct from a network failure.
        } catch { XCTFail("Unexpected cancellation error: \(error)") }
        await fulfillment(of: [stopped], timeout: 2)
    }

    private static let invalidVersions = [
        "", "v", "1", "1.0", "1.0.0.0", " 1.0.0", "1.0.0\n", "V1.0.0", "vv1.0.0",
        "01.0.0", "1.00.0", "1.0.00", "-1.0.0", "1.0.x", "１.0.0",
        "1.0.0-", "1.0.0-alpha..1", "1.0.0-01", "1.0.0-alpha.01",
        "1.0.0+", "1.0.0+build..1", "1.0.0+build+other", "1.0.0+build_name"
    ]

    private static func release(tag: String, draft: Bool = false, prerelease: Bool = false, htmlURL: String = "https://github.com/QuartzBrowser/Quartz/releases") -> String {
        let json: [String: Any] = [
            "tag_name": tag, "draft": draft, "prerelease": prerelease, "html_url": htmlURL, "assets": []
        ]
        return String(data: try! JSONSerialization.data(withJSONObject: json), encoding: .utf8)!
    }

    private func makeClient(handler: @escaping @Sendable (URLRequest) throws -> UpdateStubURLProtocol.Reply) -> Harness {
        let id = UUID().uuidString
        UpdateStubURLProtocol.handlers.set(handler, for: id)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateStubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Quartz-Update-Test": id]
        let session = URLSession(configuration: configuration)
        return Harness(client: QuartzUpdateClient(session: session), session: session, id: id)
    }

    private struct Harness: Sendable {
        let client: QuartzUpdateClient
        let session: URLSession
        let id: String

        func finish() {
            session.invalidateAndCancel()
            UpdateStubURLProtocol.handlers.remove(id)
        }
    }
}

private final class UpdateStubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply: Sendable {
        case json(String, status: Int = 200)
        case nonHTTP
        case pending(onStart: @Sendable () -> Void, onStop: @Sendable () -> Void)
    }

    final class Handlers: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String: @Sendable (URLRequest) throws -> Reply] = [:]

        func set(_ handler: @escaping @Sendable (URLRequest) throws -> Reply, for id: String) {
            lock.withLock { values[id] = handler }
        }

        func get(_ id: String) -> (@Sendable (URLRequest) throws -> Reply)? {
            lock.withLock { values[id] }
        }

        func remove(_ id: String) {
            _ = lock.withLock { values.removeValue(forKey: id) }
        }
    }

    static let handlers = Handlers()
    private let lock = NSLock()
    private var onStop: (@Sendable () -> Void)?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let id = request.value(forHTTPHeaderField: "X-Quartz-Update-Test"), let handler = Self.handlers.get(id) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            switch try handler(request) {
            case let .json(json, status):
                let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(json.utf8))
                client?.urlProtocolDidFinishLoading(self)
            case .nonHTTP:
                let response = URLResponse(url: request.url!, mimeType: "application/json", expectedContentLength: 0, textEncodingName: "utf-8")
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            case let .pending(onStart, onStop):
                lock.withLock { self.onStop = onStop }
                onStart()
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {
        let callback = lock.withLock {
            let callback = onStop
            onStop = nil
            return callback
        }
        callback?()
    }
}
