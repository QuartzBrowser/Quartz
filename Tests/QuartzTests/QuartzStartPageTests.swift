import CryptoKit
import XCTest
@testable import Quartz

final class QuartzStartPageTests: XCTestCase {
    func testHomeAndLegacyAliasAreLocalAndNotRestorable() {
        XCTAssertEqual(QuartzStartPage.url.absoluteString, "quartz://home")
        for value in ["quartz://home", "quartz://home/", "QUARTZ://HOME", "quartz://home#explore", "quartz://start", "quartz://start/"] {
            let url = URL(string: value)!
            XCTAssertTrue(QuartzStartPage.isStartPageURL(url), value)
            XCTAssertFalse(QuartzURLRouting.isRestorableSessionURL(url), value)
        }
    }

    func testOnlyRecognizedLocalPageURLsCanAuthorizeNativeActions() {
        XCTAssertFalse(QuartzStartPage.isStartPageURL(nil))
        for value in [
            "https://home", "quartz://unknown", "quartz://home.example.org", "quartz://home/path",
            "quartz://user@home", "quartz://user:password@home", "quartz://home:443", "quartz://home?query=one",
            "quartz://start/path", "quartz://user@start", "quartz://start:443", "quartz://start?query=one"
        ] {
            let url = URL(string: value)!
            XCTAssertFalse(QuartzStartPage.isStartPageURL(url), value)
            XCTAssertNil(QuartzStartPage.authorizedAction(
                for: URL(string: "quartz-action://facet")!,
                sourcePageURL: url,
                sourceIsMainFrame: true
            ), value)
        }
    }

    func testStartPageSurfacesCurrentProductCapabilities() {
        XCTAssertTrue(QuartzStartPage.html.contains("Home — Quartz"))
        XCTAssertTrue(QuartzStartPage.html.contains("Open Facet"))
        XCTAssertTrue(QuartzStartPage.html.contains("Open Extensions"))
        XCTAssertTrue(QuartzStartPage.html.contains(#"href="quartz://flags/">Flags</a>"#))
        XCTAssertTrue(QuartzStartPage.html.contains("Search or enter an address"))
        XCTAssertFalse(QuartzStartPage.html.contains("www.example.com"))
    }

    func testContentSecurityPolicyAllowsOnlyTheShippedInlineScript() throws {
        let html = QuartzStartPage.html
        let pattern = try NSRegularExpression(pattern: #"<script>([\s\S]*?)</script>"#)
        let matches = pattern.matches(in: html, range: NSRange(html.startIndex..., in: html))
        XCTAssertEqual(matches.count, 1, "Keep home interactions in one script with an explicit CSP hash")
        let scriptPolicy = try XCTUnwrap(QuartzStartPage.contentSecurityPolicy.split(separator: ";")
            .first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("script-src ") })
        XCTAssertFalse(scriptPolicy.contains("'unsafe-inline'"))
        XCTAssertFalse(scriptPolicy.contains("'unsafe-eval'"))
        XCTAssertTrue(QuartzStartPage.contentSecurityPolicy.contains("default-src 'none'"))
        for match in matches {
            let range = try XCTUnwrap(Range(match.range(at: 1), in: html))
            let digest = Data(SHA256.hash(data: Data(html[range].utf8))).base64EncodedString()
            XCTAssertTrue(scriptPolicy.contains("'sha256-\(digest)'"), "CSP must hash the exact emitted script, including whitespace")
        }
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

    func testNavigationActionPreservesEncodedSearchText() {
        let query = "fox+owl & 雪 #1 / 50%"
        let url = URL(string: "quartz-action://navigate?query=fox%2Bowl%20%26%20%E9%9B%AA%20%231%20%2F%2050%25")!
        XCTAssertEqual(QuartzStartPage.action(for: url), .navigate(query))
    }

    func testNavigationActionDecodesFallbackFormSpacesWithoutLosingLiteralPlus() {
        let url = URL(string: "quartz-action://navigate?query=fox+%2B+owl")!
        XCTAssertEqual(QuartzStartPage.action(for: url), .navigate("fox + owl"))
    }

    func testGeneratedSparkActionsAlwaysRemainSearches() {
        for query in ["fox+owl & 雪 #1 / 50%", "https://example.org", "file:///tmp/private", "javascript:alert(1)", "quartz-action://facet"] {
            var components = URLComponents(string: "quartz-action://spark-search")!
            components.queryItems = [URLQueryItem(name: "query", value: query)]
            // The page uses encodeURIComponent, which percent-encodes a literal +.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            let url = components.url!
            XCTAssertEqual(QuartzStartPage.action(for: url), .searchSpark(query))
            XCTAssertEqual(QuartzStartPage.authorizedAction(
                for: url, sourcePageURL: QuartzStartPage.url, sourceIsMainFrame: true
            ), .searchSpark(query))
            XCTAssertNil(QuartzStartPage.authorizedAction(
                for: url, sourcePageURL: URL(string: "https://example.org"), sourceIsMainFrame: true
            ))
            XCTAssertNil(QuartzStartPage.authorizedAction(
                for: url, sourcePageURL: QuartzStartPage.url, sourceIsMainFrame: false
            ))
        }
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
        XCTAssertNil(QuartzStartPage.authorizedAction(for: facetURL, sourcePageURL: nil, sourceIsMainFrame: true))
        XCTAssertEqual(QuartzStartPage.authorizedAction(
            for: facetURL,
            sourcePageURL: URL(string: "quartz://start")!,
            sourceIsMainFrame: true
        ), .showFacet)
    }
}

final class QuartzURLRoutingTests: XCTestCase {
    func testFlagsURLsNormalizeAndRemainRestorable() {
        for input in ["quartz://flags", "quartz://flags/", "QUARTZ://FLAGS/", "quartz://flags/#webmcp", " \nquartz://flags/\t"] {
            let url = QuartzURLRouting.normalizedURL(from: input)
            XCTAssertEqual(url, QuartzFlagsPage.url, input)
            XCTAssertTrue(QuartzURLRouting.isStandardBrowsingURL(QuartzFlagsPage.url), input)
            XCTAssertTrue(QuartzURLRouting.isRestorableSessionURL(QuartzFlagsPage.url), input)
        }
    }

    func testMalformedFlagsURLsAreNotAllowedAsInternalBrowsingPages() {
        for input in ["quartz://flags/path", "quartz://flags//", "quartz://flags/%2F", "quartz://flags?webmcp=enabled", "quartz://user@flags", "quartz://flags:443"] {
            let url = URL(string: input)!
            XCTAssertFalse(QuartzURLRouting.isStandardBrowsingURL(url), input)
            XCTAssertFalse(QuartzURLRouting.isRestorableSessionURL(url), input)
            XCTAssertEqual(QuartzURLRouting.normalizedURL(from: input)?.host, "duckduckgo.com", input)
        }
    }

    func testHomeURLsAndLegacyAliasNormalizeToCanonicalHome() {
        for input in ["quartz://home", "quartz://home/", "QUARTZ://HOME", "quartz://home#explore", "quartz://start", "quartz://start/", " \nquartz://home\t"] {
            XCTAssertEqual(QuartzURLRouting.normalizedURL(from: input), QuartzStartPage.url, input)
        }
    }

    func testUnknownInternalURLsAreNotTreatedAsTheHomePage() {
        for input in ["quartz://unknown", "quartz://home/path", "quartz://start?query=one"] {
            let url = QuartzURLRouting.normalizedURL(from: input)
            XCTAssertFalse(QuartzStartPage.isStartPageURL(url), input)
            XCTAssertEqual(url?.host, "duckduckgo.com", input)
            XCTAssertEqual(
                url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?.queryItems?.first { $0.name == "q" }?.value,
                input
            )
        }
    }

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
