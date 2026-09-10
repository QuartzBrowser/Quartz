import XCTest
@testable import Quartz

final class QuartzChromeWebStoreReferenceTests: XCTestCase {
    private let identifier = "abcdefghijklmnopabcdefghijklmnop"

    func testAcceptsStandaloneIDsAndOfficialListingURLs() {
        for value in [
            identifier,
            "  \(identifier.uppercased())\n",
            "https://chromewebstore.google.com/detail/\(identifier)",
            "https://chromewebstore.google.com/detail/example-extension/\(identifier)?hl=en",
            "https://chrome.google.com/webstore/detail/example/\(identifier)/"
        ] {
            XCTAssertEqual(QuartzChromeWebStoreReference.extensionID(from: value), identifier, value)
        }
    }

    func testRejectsTokensHiddenInMalformedReferences() {
        for value in [
            "", String(repeating: "K", count: 32), String(identifier.dropLast()), identifier + "a", "q" + String(identifier.dropFirst()),
            "install \(identifier)", "prefix-\(identifier)",
            "https://example.org/detail/\(identifier)",
            "http://chromewebstore.google.com/detail/\(identifier)",
            "https://chromewebstore.google.com.evil.example/detail/\(identifier)",
            "https://chromewebstore.google.com@evil.example/detail/\(identifier)",
            "https://user@chromewebstore.google.com/detail/\(identifier)",
            "https://chromewebstore.google.com:444/detail/\(identifier)",
            "https://chromewebstore.google.com/search?q=\(identifier)",
            "https://chromewebstore.google.com/detail/\(identifier)/extra",
            "https://chromewebstore.google.com/detail//\(identifier)",
            "https://chromewebstore.google.com/detail/prefix-\(identifier)",
            "https://chromewebstore.google.com/detail/x/\(identifier)%2Fextra",
            "https://chromewebstore.google.com/detail/name with spaces/\(identifier)",
            "https://chrome.google.com/detail/\(identifier)"
        ] {
            XCTAssertNil(QuartzChromeWebStoreReference.extensionID(from: value), value)
        }
    }

    func testPageDetectionUsesSameRulesAsPastedReferences() {
        for reference in [
            "https://chromewebstore.google.com/detail/example/\(identifier)",
            "https://example.com/detail/\(identifier)",
            "https://chrome.google.com/webstore/detail/example/\(identifier)?hl=en"
        ] {
            XCTAssertEqual(QuartzChromeWebStoreReference.extensionID(from: reference),
                           QuartzChromeWebStoreReference.extensionID(fromURL: URL(string: reference)!))
        }
    }
}
