import AppKit
import WebKit
import XCTest
@testable import Quartz

@available(macOS 15.4, *)
@MainActor
final class QuartzWebExtensionSupportTests: XCTestCase {
    @MainActor
    private final class PermissionChoice { var shouldAllow = true }

    private struct Fixture {
        let root: URL
        let source: URL
        let storage: URL
        let suite: String
        let defaults: UserDefaults

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("QuartzExtensionTests-\(UUID().uuidString)")
            source = root.appendingPathComponent("Original")
            storage = root.appendingPathComponent("Extensions")
            suite = "QuartzWebExtensionSupportTests.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let manifest = """
            {"manifest_version":3,"name":"Permission Fixture","version":"1.0","permissions":["tabs","storage"],"host_permissions":["https://*/*"],"action":{"default_title":"Fixture"}}
            """
            try Data(manifest.utf8).write(to: source.appendingPathComponent("manifest.json"))
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeSupport(_ fixture: Fixture, prompt: @escaping @MainActor (String, Set<String>, Set<String>, Bool) -> Bool) -> QuartzWebExtensionSupport {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        return QuartzWebExtensionSupport(browser: BrowserController(), webViewConfiguration: configuration,
                                         defaults: fixture.defaults, storageDirectory: fixture.storage, permissionPrompt: prompt)
    }

    private func install(_ source: URL, into support: QuartzWebExtensionSupport) async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            support.installExtension(from: source) { continuation.resume(returning: $0) }
        }
    }

    private func setEnabled(_ enabled: Bool, identifier: String, support: QuartzWebExtensionSupport) async -> Result<Void, Error> {
        await withCheckedContinuation { continuation in
            support.setEnabled(enabled, identifier: identifier) { continuation.resume(returning: $0) }
        }
    }

    private func restore(_ support: QuartzWebExtensionSupport) async {
        await withCheckedContinuation { continuation in support.loadSavedExtensions { continuation.resume() } }
    }

    func testCancelInstallLoadsNothingAndPreservesOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var promptCount = 0
        let support = makeSupport(fixture) { name, permissions, patterns, installing in
            promptCount += 1
            XCTAssertEqual(name, "Permission Fixture")
            XCTAssertTrue(permissions.contains("tabs"))
            XCTAssertFalse(patterns.isEmpty)
            XCTAssertTrue(installing)
            return false
        }
        if case .success = await install(fixture.source, into: support) { XCTFail("Canceled extension installed") }
        XCTAssertEqual(promptCount, 1)
        XCTAssertTrue(support.controller.extensionContexts.isEmpty)
        XCTAssertTrue(support.installedExtensions.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("manifest.json").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.storage.path), [])
    }

    func testInstallDisableRestoreEnableAndUninstallPersist() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var promptCount = 0
        let support = makeSupport(fixture) { _, _, _, _ in promptCount += 1; return true }
        var changes = 0
        support.onChange = { changes += 1 }
        _ = try await install(fixture.source, into: support).get()
        let item = try XCTUnwrap(support.installedExtensions.first)
        XCTAssertTrue(item.isEnabled)
        let context = try XCTUnwrap(support.controller.extensionContexts.first)
        XCTAssertEqual(context.permissionStatus(for: WKWebExtension.Permission(rawValue: "tabs")), .grantedExplicitly)
        XCTAssertFalse(context.grantedPermissionMatchPatterns.isEmpty)
        let installedRecord = try XCTUnwrap(QuartzExtensionRegistry(defaults: fixture.defaults).read().first)
        XCTAssertEqual(installedRecord.contextIdentifier, context.uniqueIdentifier)
        try await setEnabled(false, identifier: item.identifier, support: support).get()
        XCTAssertTrue(support.controller.extensionContexts.isEmpty)
        XCTAssertFalse(try XCTUnwrap(support.installedExtensions.first).isActionEnabled)
        let restarted = makeSupport(fixture) { _, _, _, _ in XCTFail("Already approved permissions prompted again"); return false }
        await restore(restarted)
        XCTAssertTrue(restarted.controller.extensionContexts.isEmpty)
        XCTAssertFalse(try XCTUnwrap(restarted.installedExtensions.first).isEnabled)
        XCTAssertEqual(QuartzExtensionRegistry(defaults: fixture.defaults).read().first?.contextIdentifier, installedRecord.contextIdentifier)
        try await setEnabled(true, identifier: item.identifier, support: restarted).get()
        XCTAssertEqual(restarted.controller.extensionContexts.count, 1)
        XCTAssertEqual(restarted.controller.extensionContexts.first?.uniqueIdentifier, context.uniqueIdentifier)
        XCTAssertEqual(restarted.controller.extensionContexts.first?.baseURL, context.baseURL)
        XCTAssertTrue(try XCTUnwrap(restarted.installedExtensions.first).isEnabled)
        try restarted.uninstall(identifier: item.identifier)
        XCTAssertTrue(restarted.controller.extensionContexts.isEmpty)
        XCTAssertTrue(restarted.installedExtensions.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.identifier))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.path))
        let afterUninstall = makeSupport(fixture) { _, _, _, _ in XCTFail("Uninstalled extension requested access"); return false }
        await restore(afterUninstall)
        XCTAssertTrue(afterUninstall.installedExtensions.isEmpty)
        XCTAssertTrue(afterUninstall.controller.extensionContexts.isEmpty)
        XCTAssertEqual(promptCount, 1)
        XCTAssertGreaterThanOrEqual(changes, 2)
    }

    func testRuntimeDenyAndAllowCompleteWithExactRequestedPermissions() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let choice = PermissionChoice()
        let support = makeSupport(fixture) { _, _, _, _ in choice.shouldAllow }
        _ = try await install(fixture.source, into: support).get()
        let context = try XCTUnwrap(support.controller.extensionContexts.first)
        let permissions: Set<WKWebExtension.Permission> = [.init(rawValue: "clipboardRead")]
        let patterns: Set<WKWebExtension.MatchPattern> = [try WKWebExtension.MatchPattern(string: "https://example.org/*")]
        let urls: Set<URL> = [URL(string: "https://example.org/private")!]
        for allow in [false, true] {
            choice.shouldAllow = allow
            var completions = 0
            support.webExtensionController(support.controller, promptForPermissions: permissions, in: nil, for: context) { granted, _ in
                completions += 1
                XCTAssertEqual(granted, allow ? permissions : [])
            }
            support.webExtensionController(support.controller, promptForPermissionMatchPatterns: patterns, in: nil, for: context) { granted, _ in
                completions += 1
                XCTAssertEqual(granted, allow ? patterns : [])
            }
            support.webExtensionController(support.controller, promptForPermissionToAccess: urls, in: nil, for: context) { granted, _ in
                completions += 1
                XCTAssertEqual(granted, allow ? urls : [])
            }
            XCTAssertEqual(completions, 3)
        }
        try support.uninstall(identifier: try XCTUnwrap(support.installedExtensions.first).identifier)
    }

    func testPopupFollowsAssociatedTabAndRejectsClosedTab() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let firstBrowser = BrowserController()
        let secondBrowser = BrowserController()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let support = QuartzWebExtensionSupport(browser: firstBrowser, webViewConfiguration: configuration,
                                                defaults: fixture.defaults, storageDirectory: fixture.storage,
                                                permissionPrompt: { _, _, _, _ in true })
        support.registerBrowser(firstBrowser)
        support.registerBrowser(secondBrowser)
        _ = try await install(fixture.source, into: support).get()
        let context = try XCTUnwrap(support.controller.extensionContexts.first)
        let targetTab = try XCTUnwrap(support.browserTabs.last)
        let action = try XCTUnwrap(context.action(for: targetTab))
        XCTAssertTrue(action.associatedTab === targetTab)
        XCTAssertTrue(support.popupBrowser(for: action) === secondBrowser)
        let globalAction = try XCTUnwrap(context.action(for: nil))
        XCTAssertNil(globalAction.associatedTab)
        XCTAssertTrue(support.popupBrowser(for: globalAction) === firstBrowser)
        support.unregisterBrowser(secondBrowser)
        XCTAssertNil(support.popupBrowser(for: action))
        try support.uninstall(identifier: try XCTUnwrap(support.installedExtensions.first).identifier)
        var completed = false
        support.webExtensionController(support.controller, presentActionPopup: action, for: context) { error in
            completed = true
            XCTAssertNotNil(error)
        }
        XCTAssertTrue(completed)
        support.unregisterBrowser(firstBrowser)
    }

    func testUninstallLegacyExternalFolderKeepsOriginal() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set([fixture.source.path], forKey: "QuartzInstalledExtensionPaths")
        let support = makeSupport(fixture) { _, _, _, _ in true }
        await restore(support)
        XCTAssertEqual(support.controller.extensionContexts.count, 1)
        try support.uninstall(identifier: fixture.source.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.source.appendingPathComponent("manifest.json").path))
        XCTAssertTrue(support.installedExtensions.isEmpty)
    }

    func testPresentedPopupRunsInspectAndCreateTabActions() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try """
        {"manifest_version":3,"name":"Popup Fixture","version":"1.0","permissions":["tabs"],"action":{"default_popup":"popup.html"}}
        """.write(to: fixture.source.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        try """
        <!doctype html><title>Popup actions</title>
        <button id="inspect">Inspect windows</button><button id="create">New tab</button>
        <script src="popup.js"></script>
        """.write(to: fixture.source.appendingPathComponent("popup.html"), atomically: true, encoding: .utf8)
        try """
        document.getElementById('inspect').addEventListener('click', () => {
            window.actionResult = browser.tabs.query({});
        });
        document.getElementById('create').addEventListener('click', () => {
            window.actionResult = browser.tabs.create({url: browser.runtime.getURL('target.html'), active: false});
        });
        """.write(to: fixture.source.appendingPathComponent("popup.js"), atomically: true, encoding: .utf8)
        try "<!doctype html><title>Created page</title><p>Popup-created tab</p>".write(
            to: fixture.source.appendingPathComponent("target.html"), atomically: true, encoding: .utf8
        )
        let support = makeSupport(fixture) { _, _, _, _ in true }
        let source = BrowserController(sharedExtensionSupport: support, restoresSavedSession: false,
                                       focusesWindow: false, sessionDefaults: fixture.defaults)
        source.start()
        defer { for tab in support.browserTabs.reversed() { tab.browser?.extensionWindow?.close() } }
        _ = try await install(fixture.source, into: support).get()
        let item = try XCTUnwrap(support.installedExtensions.first)
        let context = try XCTUnwrap(support.controller.extensionContexts.first)
        let sourceTab = try XCTUnwrap(support.browserTabs.first)
        let action = try XCTUnwrap(context.action(for: sourceTab))
        try support.performAction(forInstalledExtensionWithIdentifier: item.identifier)
        let popover = try XCTUnwrap(action.popupPopover)
        let deadline = Date().addingTimeInterval(10)
        while !popover.isShown {
            guard Date() < deadline else { XCTFail("Action popover did not present"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        let popup = try XCTUnwrap(action.popupWebView)
        XCTAssertTrue(popover.contentViewController?.view === popup)
        XCTAssertNotNil(popup.window)
        let inspectionValue = try await popup.callAsyncJavaScript(
            "document.getElementById('inspect').click(); return await window.actionResult;",
            arguments: [:], in: nil, contentWorld: .page
        )
        let inspectedTabs = try XCTUnwrap(inspectionValue as? [[String: Any]])
        XCTAssertEqual(inspectedTabs.count, 1)
        XCTAssertTrue(popover.isShown, "Inspecting tabs must leave the popup open")
        _ = try await popup.callAsyncJavaScript(
            "document.getElementById('create').click(); return true;",
            arguments: [:], in: nil, contentWorld: .page
        )
        while support.browserTabs.count < 2 {
            guard Date() < deadline else { XCTFail("Popup action did not create a tab"); return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(support.browserTabs.count, 2)
        XCTAssertTrue(support.browserTabs.first === sourceTab)
        action.closePopup()
        while popover.isShown, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(popover.isShown)
        try support.uninstall(identifier: item.identifier)
    }
}
