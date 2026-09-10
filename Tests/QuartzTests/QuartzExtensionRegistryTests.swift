import XCTest
@testable import Quartz

final class QuartzExtensionRegistryTests: XCTestCase {
    func testMigrationDisabledStateAndRemovalSurviveReload() throws {
        let suite = "QuartzExtensionRegistryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["/tmp/original-extension", "/tmp/original-extension"], forKey: "QuartzInstalledExtensionPaths")
        let registry = QuartzExtensionRegistry(defaults: defaults)
        var records = registry.read()
        XCTAssertEqual(records.count, 1)
        XCTAssertTrue(records[0].approvedPermissions.isEmpty)
        records[0].isEnabled = false
        records[0].approvedPermissions = ["tabs"]
        registry.write(records)
        XCTAssertEqual(QuartzExtensionRegistry(defaults: defaults).read(), records)
        registry.write([])
        XCTAssertTrue(QuartzExtensionRegistry(defaults: defaults).read().isEmpty)
        XCTAssertEqual(defaults.stringArray(forKey: "QuartzInstalledExtensionPaths"), [])
    }

    func testOnlyOwnedCopiesCanBeRemovedIncludingSymlinkEscape() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let storage = temporary.appendingPathComponent("Extensions")
        let original = temporary.appendingPathComponent("Original")
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        XCTAssertNotNil(QuartzExtensionRegistry.ownedRemovalURL(for: storage.appendingPathComponent("copy").path, storageDirectory: storage))
        XCTAssertNil(QuartzExtensionRegistry.ownedRemovalURL(for: original.path, storageDirectory: storage))
        XCTAssertNil(QuartzExtensionRegistry.ownedRemovalURL(for: storage.path, storageDirectory: storage))
        XCTAssertNil(QuartzExtensionRegistry.ownedRemovalURL(for: storage.appendingPathComponent("nested/copy").path, storageDirectory: storage))
        let link = storage.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        XCTAssertNil(QuartzExtensionRegistry.ownedRemovalURL(for: link.path, storageDirectory: storage))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }
}
