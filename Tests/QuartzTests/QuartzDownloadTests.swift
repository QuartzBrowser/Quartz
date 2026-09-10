import AppKit
import Network
import WebKit
import XCTest
@testable import Quartz

/// A loopback HTTP origin exercises real WebKit transfers without internet access.
private final class DownloadHTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "QuartzDownloadTests.HTTP")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { connection in
            connection.start(queue: DispatchQueue.global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { data, _, _, _ in
                let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let body = "Quartz download fixture\n"
                let length = request.contains("GET /failure ") ? 100_000 : body.utf8.count
                let response = "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename=fixture.txt\r\nContent-Length: \(length)\r\nConnection: close\r\n\r\n\(body)"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }

    func start() async throws -> URL {
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return URL(string: "http://127.0.0.1:\(port)/")!
    }

    func stop() { listener.cancel() }
}

@MainActor
final class QuartzDownloadTests: XCTestCase {
    func testWebKitDownloadSavesExactBytesToChosenDestination() async throws {
        _ = NSApplication.shared
        let server = try DownloadHTTPServer()
        let url = try await server.start()
        defer { server.stop() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("chosen.txt")
        let finished = expectation(description: "WebKit download finished")
        let coordinator = QuartzDownloadCoordinator(chooseDestination: { name, completion in
            XCTAssertEqual(name, "fixture.txt")
            completion(destination)
        }, report: { result in
            switch result {
            case .success(let savedURL): XCTAssertEqual(savedURL, destination)
            case .failure(let error): XCTFail("Download failed: \(error)")
            }
            finished.fulfill()
        })
        let webView = WKWebView()
        webView.startDownload(using: URLRequest(url: url)) { coordinator.begin($0) }
        await fulfillment(of: [finished], timeout: 20)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Quartz download fixture\n")
        XCTAssertEqual(coordinator.activeDownloadCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["chosen.txt"])
    }

    func testCancelDestinationPickerDoesNotWriteOrReportAnError() async throws {
        _ = NSApplication.shared
        let server = try DownloadHTTPServer()
        let url = try await server.start()
        defer { server.stop() }
        let cancelled = expectation(description: "Destination cancelled")
        let coordinator = QuartzDownloadCoordinator(chooseDestination: { _, completion in
            completion(nil)
            cancelled.fulfill()
        }, report: { _ in XCTFail("Cancellation should be silent") })
        let webView = WKWebView()
        webView.startDownload(using: URLRequest(url: url)) { coordinator.begin($0) }
        await fulfillment(of: [cancelled], timeout: 20)
        XCTAssertEqual(coordinator.activeDownloadCount, 0)
    }

    func testFailedWebKitTransferReportsErrorAndPreservesExistingFile() async throws {
        _ = NSApplication.shared
        let server = try DownloadHTTPServer()
        let url = try await server.start().appendingPathComponent("failure")
        defer { server.stop() }
        let directory = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("existing.txt")
        try Data("keep existing content".utf8).write(to: destination)
        let failed = expectation(description: "Incomplete HTTP response reported")
        let coordinator = QuartzDownloadCoordinator(chooseDestination: { _, completion in
            completion(destination)
        }, report: { result in
            guard case .failure = result else { XCTFail("Partial transfer succeeded"); failed.fulfill(); return }
            failed.fulfill()
        })
        let webView = WKWebView()
        webView.startDownload(using: URLRequest(url: url)) { coordinator.begin($0) }
        await fulfillment(of: [failed], timeout: 20)
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "keep existing content")
        XCTAssertEqual(coordinator.activeDownloadCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["existing.txt"])
    }

    private func makeDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
