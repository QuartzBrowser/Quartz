import AppKit
import XCTest
@testable import Quartz

@MainActor
final class QuartzBrowserFocusTests: XCTestCase {
    func testOwnedPopupPreservesBrowserFocusWithoutRepeatedNotifications() {
        _ = NSApplication.shared
        let browser = makeWindow()
        let otherBrowser = makeWindow()
        let popup = makeWindow()
        let browsers = [browser, otherBrowser]
        var changes = QuartzBrowserFocusChange()
        func focus(key: NSWindow?, main: NSWindow?) -> NSWindow? {
            QuartzBrowserFocus.window(applicationIsActive: true, keyWindow: key, mainWindow: main,
                                      browserWindows: browsers, popupWindow: popup, popupOwner: browser)
        }

        XCTAssertTrue(changes.update(window: focus(key: browser, main: browser)))
        // AppKit clears the key window during the browser-to-popover transition.
        XCTAssertTrue(focus(key: nil, main: browser) === browser)
        XCTAssertFalse(changes.update(window: focus(key: nil, main: browser)))
        XCTAssertTrue(focus(key: popup, main: browser) === browser)
        XCTAssertFalse(changes.update(window: focus(key: popup, main: browser)))
        XCTAssertFalse(changes.update(window: focus(key: browser, main: browser)))
        XCTAssertTrue(changes.update(window: focus(key: otherBrowser, main: otherBrowser)))
        XCTAssertFalse(changes.update(window: focus(key: otherBrowser, main: otherBrowser)))
    }

    func testManagerDeactivationAndClosedPopupOwnerDoNotReportBrowserFocus() {
        _ = NSApplication.shared
        let browser = makeWindow()
        let popup = makeWindow()
        let manager = makeWindow()
        XCTAssertNil(QuartzBrowserFocus.window(
            applicationIsActive: true, keyWindow: manager, mainWindow: browser,
            browserWindows: [browser], popupWindow: popup, popupOwner: browser
        ))
        XCTAssertNil(QuartzBrowserFocus.window(
            applicationIsActive: false, keyWindow: popup, mainWindow: browser,
            browserWindows: [browser], popupWindow: popup, popupOwner: browser
        ))
        XCTAssertNil(QuartzBrowserFocus.window(
            applicationIsActive: true, keyWindow: popup, mainWindow: browser,
            browserWindows: [], popupWindow: popup, popupOwner: browser
        ))
        XCTAssertNil(QuartzBrowserFocus.window(
            applicationIsActive: true, keyWindow: popup, mainWindow: manager,
            browserWindows: [browser], popupWindow: popup, popupOwner: browser
        ))
        var changes = QuartzBrowserFocusChange()
        XCTAssertTrue(changes.update(window: browser))
        XCTAssertTrue(changes.update(window: nil))
        XCTAssertFalse(changes.update(window: nil))
        XCTAssertTrue(changes.update(window: browser))
    }

    private func makeWindow() -> NSWindow {
        NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                 styleMask: [.titled], backing: .buffered, defer: true)
    }
}
