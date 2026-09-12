import CryptoKit
import XCTest
@testable import Quartz

final class QuartzFlagsPageTests: XCTestCase {
    func testOnlyFlagsDocumentURLsAreRecognized() {
        XCTAssertEqual(QuartzFlagsPage.url.absoluteString, "quartz://flags/")
        for value in ["quartz://flags", "quartz://flags/", "QUARTZ://FLAGS/", "quartz://flags#webmcp", "quartz://flags/#webmcp"] {
            XCTAssertTrue(QuartzFlagsPage.isFlagsPageURL(URL(string: value)), value)
        }
        XCTAssertFalse(QuartzFlagsPage.isFlagsPageURL(nil))
        for value in [
            "https://flags/", "quartz://home", "quartz://flags.example.org", "quartz://flags/path",
            "quartz://flags//", "quartz://flags///", "quartz://flags/%2F", "quartz://flags/%2f",
            "quartz://flags/./", "quartz://flags/../", "quartz://user@flags/", "quartz://user:password@flags/",
            "quartz://flags:443/", "quartz://flags/?", "quartz://flags/?webmcp=enabled"
        ] {
            XCTAssertFalse(QuartzFlagsPage.isFlagsPageURL(URL(string: value)), value)
        }
    }

    func testValidActionsRequireMainFlagsDocument() {
        for enabled in [false, true] {
            let url = URL(string: "quartz-action://flags?webmcp=\(enabled ? "enabled" : "disabled")")!
            for page in ["quartz://flags", "quartz://flags/", "quartz://flags/#webmcp"] {
                XCTAssertEqual(QuartzFlagsPage.authorizedAction(
                    for: url, sourcePageURL: URL(string: page), sourceIsMainFrame: true
                ), .setWebMCPEnabled(enabled))
                XCTAssertNil(QuartzFlagsPage.authorizedAction(
                    for: url, sourcePageURL: URL(string: page), sourceIsMainFrame: false
                ))
            }
            for page in [nil, "https://example.org", "quartz://home", "quartz://flags.example.org", "quartz://flags/?webmcp=enabled", "quartz://flags/path", "quartz://flags//", "quartz://flags/%2F", "quartz://flags/./"] as [String?] {
                XCTAssertNil(QuartzFlagsPage.authorizedAction(
                    for: url, sourcePageURL: page.flatMap(URL.init(string:)), sourceIsMainFrame: true
                ))
            }
        }
    }

    func testMalformedOrAmbiguousActionURLsNeverChangeSettings() {
        for value in [
            "https://flags?webmcp=enabled", "quartz-action://flags", "quartz-action://flags?",
            "quartz-action://flags?webmcp", "quartz-action://flags?webmcp=", "quartz-action://flags?webmcp=true",
            "quartz-action://flags?webmcp=Enabled", "quartz-action://flags?WebMCP=enabled",
            "quartz-action://flags?unknown=enabled", "quartz-action://flags?webmcp=enabled&extra=one",
            "quartz-action://flags?webmcp=enabled&webmcp=disabled", "quartz-action://flags?webmcp=enabled&webmcp=enabled",
            "quartz-action://flags?webmcp=enabled&", "quartz-action://flags?%77ebmcp=enabled",
            "quartz-action://flags?webmcp=%65nabled", "quartz-action://flags?webmcp=enabled#fragment",
            "quartz-action://flags?webmcp=enabled#", "quartz-action://flags/?webmcp=enabled",
            "quartz-action://flags/path?webmcp=enabled", "quartz-action://user@flags?webmcp=enabled",
            "quartz-action://user:password@flags?webmcp=enabled", "quartz-action://flags:443?webmcp=enabled",
            "quartz-action://flags.example.org?webmcp=enabled", "quartz-action://facet?webmcp=enabled"
        ] {
            XCTAssertNil(QuartzFlagsPage.authorizedAction(
                for: URL(string: value)!, sourcePageURL: QuartzFlagsPage.url, sourceIsMainFrame: true
            ), value)
        }
    }

    func testPageReflectsStoredChoiceAndExplainsApplicationAndConsent() {
        let disabled = QuartzFlagsPage.html(webMCPEnabled: false)
        XCTAssertTrue(disabled.contains("<title>Flags — Quartz</title>"))
        XCTAssertTrue(disabled.contains(#"<option value="disabled" selected>Disabled (default)</option>"#))
        XCTAssertTrue(disabled.contains(#"<option value="enabled">Enabled</option>"#))
        XCTAssertTrue(disabled.contains("Current setting: Disabled"))
        let enabled = QuartzFlagsPage.html(webMCPEnabled: true)
        XCTAssertTrue(enabled.contains(#"<option value="enabled" selected>Enabled</option>"#))
        XCTAssertTrue(enabled.contains(#"<option value="disabled">Disabled (default)</option>"#))
        XCTAssertTrue(enabled.contains("Current setting: Enabled"))
        for html in [disabled, enabled] {
            XCTAssertTrue(html.contains("Changes are saved automatically."))
            XCTAssertTrue(html.contains("Reload open websites to apply the setting."))
            XCTAssertTrue(html.contains("Turning WebMCP off stops Facet from using website tools immediately."))
            XCTAssertTrue(html.contains("Each tool use still requires your approval."))
            XCTAssertTrue(html.contains(#"<label for="webmcp">WebMCP setting</label>"#))
            XCTAssertFalse(html.contains("https://"))
            XCTAssertFalse(html.contains("http://"))
        }
    }

    func testContentSecurityPolicyHashesTheExactBundledScript() throws {
        let pattern = try NSRegularExpression(pattern: #"<script>([\s\S]*?)</script>"#)
        for enabled in [false, true] {
            let html = QuartzFlagsPage.html(webMCPEnabled: enabled)
            let matches = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
            XCTAssertEqual(matches.count, 1)
            let scriptPolicy = try XCTUnwrap(QuartzFlagsPage.contentSecurityPolicy.split(separator: ";")
                .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("script-src ") })
            XCTAssertFalse(scriptPolicy.contains("'unsafe-inline'"))
            XCTAssertFalse(scriptPolicy.contains("'unsafe-eval'"))
            XCTAssertTrue(QuartzFlagsPage.contentSecurityPolicy.contains("default-src 'none'"))
            XCTAssertTrue(QuartzFlagsPage.contentSecurityPolicy.contains("form-action quartz-action:"))
            XCTAssertTrue(QuartzFlagsPage.contentSecurityPolicy.contains("frame-ancestors 'none'"))
            for match in matches {
                let range = try XCTUnwrap(Range(match.range(at: 1), in: html))
                let digest = Data(SHA256.hash(data: Data(html[range].utf8))).base64EncodedString()
                XCTAssertTrue(scriptPolicy.contains("'sha256-\(digest)'"))
            }
        }
    }
}
