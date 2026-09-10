import XCTest
@testable import Quartz

final class QuartzStartPageTests: XCTestCase {
    func testStartPageIsLocalAndNotRestorable() {
        XCTAssertEqual(QuartzStartPage.url.absoluteString, "quartz://start")
        XCTAssertTrue(QuartzStartPage.isStartPageURL(QuartzStartPage.url))
        XCTAssertFalse(QuartzURLRouting.isRestorableSessionURL(QuartzStartPage.url))
    }

    func testStartPageSurfacesCurrentProductCapabilities() {
        XCTAssertTrue(QuartzStartPage.html.contains("Meet Facet"))
        XCTAssertTrue(QuartzStartPage.html.contains("Open Extensions"))
        XCTAssertTrue(QuartzStartPage.html.contains("Search or enter an address"))
        XCTAssertFalse(QuartzStartPage.html.contains("www.example.com"))
    }

    func testStartPageActionsAreStrictlyParsed() {
        XCTAssertEqual(
            QuartzStartPage.action(for: URL(string: "quartz-action://navigate?query=example.com")!),
            .navigate("example.com")
        )
        XCTAssertEqual(
            QuartzStartPage.action(for: URL(string: "quartz-action://facet")!),
            .showFacet
        )
        XCTAssertEqual(
            QuartzStartPage.action(for: URL(string: "quartz-action://extensions")!),
            .showExtensions
        )
        XCTAssertNil(QuartzStartPage.action(for: URL(string: "https://example.com")!))
        XCTAssertNil(QuartzStartPage.action(for: URL(string: "quartz-action://unknown")!))
    }

    func testNativeActionsAreAuthorizedOnlyFromTheMainStartPageFrame() {
        let facetURL = URL(string: "quartz-action://facet")!

        XCTAssertEqual(
            QuartzStartPage.authorizedAction(
                for: facetURL,
                sourcePageURL: QuartzStartPage.url,
                sourceIsMainFrame: true
            ),
            .showFacet
        )
        XCTAssertNil(
            QuartzStartPage.authorizedAction(
                for: facetURL,
                sourcePageURL: URL(string: "https://example.org")!,
                sourceIsMainFrame: true
            )
        )
        XCTAssertNil(
            QuartzStartPage.authorizedAction(
                for: facetURL,
                sourcePageURL: QuartzStartPage.url,
                sourceIsMainFrame: false
            )
        )
    }
}

final class QuartzURLRoutingTests: XCTestCase {
    func testExplicitBrowsingURLsRemainUnchanged() {
        for value in [
            "https://example.org/path?q=one",
            "http://localhost:8080/test",
            "file:///tmp/quartz.html"
        ] {
            XCTAssertEqual(QuartzURLRouting.normalizedURL(from: value)?.absoluteString, value)
        }
    }

    func testHostLikeInputUsesHTTPS() {
        XCTAssertEqual(
            QuartzURLRouting.normalizedURL(from: "example.org")?.absoluteString,
            "https://example.org"
        )
        XCTAssertEqual(
            QuartzURLRouting.normalizedURL(from: "localhost:3000")?.absoluteString,
            "https://localhost:3000"
        )
    }

    func testOtherInputUsesDuckDuckGoSearch() {
        let url = QuartzURLRouting.normalizedURL(from: "quartz browser")
        XCTAssertEqual(url?.host, "duckduckgo.com")
        XCTAssertEqual(
            URLComponents(url: url!, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "q" })?
                .value,
            "quartz browser"
        )
    }

    func testOnlyNormalBrowsingSchemesRestore() {
        XCTAssertTrue(QuartzURLRouting.isRestorableSessionURL(URL(string: "https://example.org")!))
        XCTAssertTrue(QuartzURLRouting.isRestorableSessionURL(URL(fileURLWithPath: "/tmp/page.html")))
        XCTAssertFalse(QuartzURLRouting.isRestorableSessionURL(URL(string: "about:blank")!))
        XCTAssertFalse(QuartzURLRouting.isRestorableSessionURL(URL(string: "data:text/html,Quartz")!))
    }
}
