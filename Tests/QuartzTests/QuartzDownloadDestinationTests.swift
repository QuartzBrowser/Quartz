import XCTest
@testable import Quartz

final class QuartzDownloadDestinationTests: XCTestCase {
    func testAttachmentsDownloadEvenWhenWebKitCanDisplayTheirMIMEType() throws {
        for mime in ["text/plain", "text/html", "application/pdf"] {
            for disposition in ["attachment", "attachment; filename=readme.txt", " Attachment ; filename=page.html"] {
                let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com/file")!, statusCode: 200,
                    httpVersion: "HTTP/1.1", headerFields: ["Content-Type": mime, "Content-Disposition": disposition]))
                XCTAssertTrue(QuartzDownloadPolicy.shouldDownload(response, canShowMIMEType: true))
            }
        }
    }

    func testInlineDisplayAndUnsupportedContentUseDifferentPolicies() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://example.com/file")!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Disposition": "inline; filename=attachment.txt"]))
        XCTAssertFalse(QuartzDownloadPolicy.shouldDownload(response, canShowMIMEType: true))
        XCTAssertTrue(QuartzDownloadPolicy.shouldDownload(response, canShowMIMEType: false))
    }

    func testCompletedDownloadReplacesAnExistingFileAndRemovesStaging() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = directory.appendingPathComponent("file.txt")
        try Data("old content".utf8).write(to: selected)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: selected.path)
        let destination = try QuartzDownloadDestination(selectedURL: selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.transferURL.path))
        try Data("download content".utf8).write(to: destination.transferURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.transferURL.path)
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "old content")
        try destination.commit()
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "download content")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: selected.path)[.posixPermissions] as? Int, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.stagingDirectory.path))
    }

    func testFailedTransferPreservesExistingFileAndDiscardsPartialBytes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = directory.appendingPathComponent("file.txt")
        try Data("keep me".utf8).write(to: selected)
        let destination = try QuartzDownloadDestination(selectedURL: selected)
        try Data("partial transfer".utf8).write(to: destination.transferURL)
        destination.discard()
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "keep me")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.stagingDirectory.path))
    }

    func testCompletedDownloadCreatesTheChosenFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let selected = directory.appendingPathComponent("chosen.txt")
        let destination = try QuartzDownloadDestination(selectedURL: selected)
        try Data("new file".utf8).write(to: destination.transferURL)
        try destination.commit()
        XCTAssertEqual(try String(contentsOf: selected, encoding: .utf8), "new file")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["chosen.txt"])
    }
}
