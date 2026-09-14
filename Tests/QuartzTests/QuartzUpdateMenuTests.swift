import AppKit
import XCTest
@testable import Quartz

@MainActor
final class QuartzUpdateMenuTests: XCTestCase {
    func testNativeMenuPersistsChannelChoiceAndShowsStableReturnBehavior() throws {
        _ = NSApplication.shared
        let suite = "QuartzUpdateMenuTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let browser = BrowserController(restoresSavedSession: false, focusesWindow: false, sessionDefaults: defaults)
        browser.start()
        let window = try XCTUnwrap(browser.extensionWindow)
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        browser.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
        let appMenu = try XCTUnwrap(NSApplication.shared.mainMenu?.items.first?.submenu)
        let channelItem = try XCTUnwrap(appMenu.items.first { $0.title.hasPrefix("Update Channel:") })
        let choices = try XCTUnwrap(channelItem.submenu)
        let stable = try XCTUnwrap(choices.item(withTitle: "Stable"))
        let beta = try XCTUnwrap(choices.item(withTitle: "Beta"))
        XCTAssertEqual(stable.state, .on)
        XCTAssertEqual(beta.state, .off)
        XCTAssertTrue(stable.isEnabled)
        XCTAssertTrue(beta.isEnabled)
        XCTAssertNotNil(appMenu.item(withTitle: "About Quartz…"))

        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(beta.action), to: beta.target, from: beta))
        XCTAssertEqual(QuartzUpdateChannel.selected(in: defaults), .beta)
        XCTAssertEqual(channelItem.title, "Update Channel: Beta")
        XCTAssertEqual(stable.state, .off)
        XCTAssertEqual(beta.state, .on)
        if let sheet = window.attachedSheet { window.endSheet(sheet) }

        XCTAssertTrue(NSApplication.shared.sendAction(try XCTUnwrap(stable.action), to: stable.target, from: stable))
        XCTAssertEqual(QuartzUpdateChannel.selected(in: defaults), .stable)
        XCTAssertEqual(channelItem.title, "Update Channel: Stable")
        XCTAssertEqual(stable.state, .on)
        XCTAssertTrue(try XCTUnwrap(stable.toolTip).contains("does not downgrade"))
    }
}
