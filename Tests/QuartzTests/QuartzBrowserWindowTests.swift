import AppKit
import WebKit
import XCTest
@testable import Quartz

@MainActor
final class QuartzBrowserWindowTests: XCTestCase {
    func testRealExtensionAPIsPreservePagesReportWindowsAndCloseTabs() async throws {
        guard #available(macOS 15.4, *) else { throw XCTSkip("WebExtensions require macOS 15.4") }
        _ = NSApplication.shared
        let suite = "QuartzBrowserWindowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try """
        {"manifest_version":3,"name":"Quartz window test","version":"1.0","permissions":["tabs"],"action":{"default_title":"Window test"}}
        """.write(to: directory.appendingPathComponent("manifest.json"), atomically: true, encoding: .utf8)
        for page in ["api", "second", "third", "updated"] {
            try "<!doctype html><title>\(page)</title><p>\(page) preserved page</p>".write(
                to: directory.appendingPathComponent("\(page).html"), atomically: true, encoding: .utf8
            )
        }

        let initial = BrowserController(restoresSavedSession: false, sessionDefaults: defaults)
        let support = QuartzWebExtensionSupport(browser: initial, webViewConfiguration: WKWebViewConfiguration(), defaults: defaults)
        let source = BrowserController(sharedExtensionSupport: support, restoresSavedSession: false, sessionDefaults: defaults)
        source.start()
        defer {
            for tab in support.browserTabs.reversed() { tab.browser?.extensionWindow?.close() }
        }
        try await waitUntil { source.extensionURL == QuartzStartPage.url && source.extensionWebView?.isLoading == false }

        let webExtension = try await WKWebExtension(resourceBaseURL: directory)
        let context = WKWebExtensionContext(for: webExtension)
        context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: "tabs"))
        try support.controller.load(context)
        defer { try? support.controller.unload(context) }
        let apiURL = context.baseURL.appendingPathComponent("api.html")
        support.openURLFromExtension(apiURL, context: context, in: source)
        try await waitUntil { source.extensionURL == apiURL && source.extensionWebView?.isLoading == false }
        let api = try XCTUnwrap(source.extensionWebView)
        _ = try await script("""
        window.closedTabs = [];
        window.updatedTabs = [];
        browser.tabs.onRemoved.addListener((id, info) => window.closedTabs.push({id, ...info}));
        browser.tabs.onUpdated.addListener((id, info) => window.updatedTabs.push({id, ...info}));
        return true;
        """, in: api)

        let createdValue = try await script("return await browser.tabs.create({url: browser.runtime.getURL('second.html'), active: false});", in: api)
        let created = try XCTUnwrap(createdValue as? [String: Any])
        let tabID = try XCTUnwrap(created["id"] as? Int)
        let windowID = try XCTUnwrap(created["windowId"] as? Int)
        XCTAssertEqual(support.browserTabs.count, 2)
        XCTAssertEqual(source.extensionURL, apiURL)
        XCTAssertTrue(source.extensionWebView === api)
        let secondTab = try XCTUnwrap(support.browserTabs.last)
        XCTAssertFalse(secondTab.browser === source)
        XCTAssertTrue(secondTab.browser?.extensionWebView?.configuration.webExtensionController === support.controller)
        let secondURL = context.baseURL.appendingPathComponent("second.html")
        try await waitUntil { secondTab.browser?.extensionURL == secondURL && secondTab.browser?.extensionWebView?.isLoading == false }

        let windowsValue = try await script("return await browser.windows.getAll({populate: true});", in: api)
        let windows = try XCTUnwrap(windowsValue as? [[String: Any]])
        XCTAssertEqual(windows.count, 2)
        let secondWindow = try XCTUnwrap(windows.first { ($0["id"] as? Int) == windowID })
        let tabs = try XCTUnwrap(secondWindow["tabs"] as? [[String: Any]])
        XCTAssertEqual(tabs.count, 1)
        XCTAssertEqual(tabs.first?["id"] as? Int, tabID)
        XCTAssertEqual(tabs.first?["url"] as? String, secondURL.absoluteString)
        XCTAssertEqual(tabs.first?["active"] as? Bool, true)

        _ = try await script("return await browser.tabs.update(id, {active: true});", arguments: ["id": tabID], in: api)
        // The command-line XCTest host cannot become an active macOS app. Native
        // key-window focus is verified with the packaged window-check extension.
        _ = try await script("await browser.action.setBadgeText({tabId: id, text: '2'}); return true;", arguments: ["id": tabID], in: api)
        XCTAssertEqual(context.action(for: secondTab)?.badgeText, "2")
        XCTAssertNotEqual(context.action(for: support.browserTabs[0])?.badgeText, "2")

        let thirdValue = try await script("return await browser.windows.create({url: browser.runtime.getURL('third.html'), focused: false});", in: api)
        let thirdWindow = try XCTUnwrap(thirdValue as? [String: Any])
        let thirdID = try XCTUnwrap(thirdWindow["id"] as? Int)
        XCTAssertEqual(support.browserTabs.count, 3)
        XCTAssertEqual(source.extensionURL, apiURL)

        _ = try await script("return await browser.tabs.update(id, {url: browser.runtime.getURL('updated.html')});", arguments: ["id": tabID], in: api)
        let updatedURL = context.baseURL.appendingPathComponent("updated.html")
        try await waitUntil { secondTab.browser?.extensionURL == updatedURL && secondTab.browser?.extensionWebView?.isLoading == false }
        XCTAssertTrue(support.browserTabs[1] === secondTab)
        XCTAssertEqual(source.extensionURL, apiURL)

        _ = try await script("await browser.windows.remove(id); return true;", arguments: ["id": thirdID], in: api)
        XCTAssertEqual(support.browserTabs.count, 2)
        _ = try await script("await browser.tabs.remove(id); return true;", arguments: ["id": tabID], in: api)
        XCTAssertEqual(support.browserTabs.count, 1)
        XCTAssertNil(secondTab.browser)
        let remainingValue = try await script("return await browser.tabs.query({});", in: api)
        let remaining = try XCTUnwrap(remainingValue as? [[String: Any]])
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?["url"] as? String, apiURL.absoluteString)
        let removedValue = try await script("return window.closedTabs;", in: api)
        let removed = try XCTUnwrap(removedValue as? [[String: Any]])
        XCTAssertTrue(removed.contains { ($0["id"] as? Int) == tabID && ($0["isWindowClosing"] as? Bool) == true })
        let updatesValue = try await script("return window.updatedTabs;", in: api)
        let updates = try XCTUnwrap(updatesValue as? [[String: Any]])
        XCTAssertTrue(updates.contains { ($0["id"] as? Int) == tabID && ($0["url"] as? String) == updatedURL.absoluteString })
    }

    private func script(_ body: String, arguments: [String: Any] = [:], in webView: WKWebView) async throws -> Any? {
        try await webView.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !condition() {
            guard Date() < deadline else { throw NSError(domain: "QuartzBrowserWindowTests.Timeout", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
