import Foundation
@preconcurrency import WebKit

enum QuartzStartPageAction: Equatable {
    case navigate(String)
    case showFacet
    case showExtensions
}

enum QuartzStartPage {
    static let scheme = "quartz"
    static let actionScheme = "quartz-action"
    static let url = URL(string: "quartz://start")!

    static func isStartPageURL(_ url: URL?) -> Bool {
        guard let url else {
            return false
        }

        return url.scheme?.lowercased() == scheme
            && url.host?.lowercased() == "start"
    }

    static func isActionURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == actionScheme
    }

    static func action(for url: URL) -> QuartzStartPageAction? {
        guard isActionURL(url) else {
            return nil
        }

        switch url.host?.lowercased() {
        case "navigate":
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "query" })?
                .value ?? ""
            return .navigate(query)
        case "facet":
            return .showFacet
        case "extensions":
            return .showExtensions
        default:
            return nil
        }
    }

    static func authorizedAction(
        for url: URL,
        sourcePageURL: URL?,
        sourceIsMainFrame: Bool
    ) -> QuartzStartPageAction? {
        guard sourceIsMainFrame,
              isStartPageURL(sourcePageURL)
        else {
            return nil
        }

        return action(for: url)
    }

    static let html = #"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title>Quartz</title>
  <style>
    :root {
      color-scheme: light dark;
      --ink: #152139;
      --muted: #657187;
      --line: rgba(100, 116, 145, 0.20);
      --surface: rgba(255, 255, 255, 0.76);
      --surface-strong: rgba(255, 255, 255, 0.94);
      --blue: #2468df;
      --blue-strong: #1956c1;
      --eyebrow: #1d5dc8;
      --focus: #0957c9;
      --purple: #7657d6;
      --purple-action: #5935b5;
      --green: #27976b;
      --green-action: #116a48;
      --shadow: rgba(31, 48, 78, 0.12);
    }

    * { box-sizing: border-box; }

    body {
      margin: 0;
      min-height: 100vh;
      color: var(--ink);
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
      background:
        radial-gradient(circle at 16% 8%, rgba(36, 104, 223, 0.16), transparent 31%),
        radial-gradient(circle at 88% 12%, rgba(48, 178, 186, 0.14), transparent 29%),
        radial-gradient(circle at 78% 88%, rgba(218, 154, 48, 0.10), transparent 31%),
        linear-gradient(145deg, #f9fbff 0%, #eef4fa 52%, #fffaf2 100%);
    }

    .page {
      width: min(1080px, calc(100% - 48px));
      margin: 0 auto;
      padding: clamp(28px, 5vh, 52px) 0 34px;
    }

    header {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 20px;
    }

    .brand {
      display: flex;
      align-items: center;
      gap: 11px;
      font-size: 16px;
      font-weight: 750;
      letter-spacing: -0.01em;
    }

    .mark {
      width: 32px;
      height: 32px;
      border-radius: 10px;
      background:
        linear-gradient(135deg, rgba(255,255,255,0.58), transparent 42%),
        conic-gradient(from 210deg, #286de8, #20a6b8, #76b852, #d89b25, #d95f76, #286de8);
      box-shadow: inset 0 0 0 1px rgba(255,255,255,0.58), 0 10px 24px rgba(40,109,232,0.22);
    }

    .local-label {
      color: var(--muted);
      font-size: 12px;
      font-weight: 650;
      letter-spacing: 0.02em;
    }

    main {
      display: grid;
      gap: 28px;
      margin-top: clamp(38px, 7vh, 72px);
    }

    .intro {
      max-width: 780px;
    }

    .eyebrow {
      margin: 0 0 12px;
      color: var(--eyebrow);
      font-size: 12px;
      font-weight: 800;
      letter-spacing: 0.08em;
      text-transform: uppercase;
    }

    h1 {
      margin: 0;
      max-width: 720px;
      font-size: clamp(38px, 6vw, 68px);
      line-height: 0.98;
      letter-spacing: -0.055em;
    }

    .lede {
      margin: 18px 0 0;
      max-width: 720px;
      color: #3f4d64;
      font-size: clamp(17px, 2vw, 21px);
      line-height: 1.45;
      letter-spacing: -0.01em;
    }

    .search {
      display: grid;
      grid-template-columns: minmax(0, 1fr) auto;
      gap: 10px;
      width: min(800px, 100%);
      padding: 9px;
      border: 1px solid var(--line);
      border-radius: 15px;
      background: var(--surface-strong);
      box-shadow: 0 20px 52px var(--shadow);
    }

    .search input {
      min-width: 0;
      height: 46px;
      padding: 0 14px;
      border: 0;
      outline: 0;
      color: var(--ink);
      background: transparent;
      font: inherit;
      font-size: 16px;
    }

    .search input::placeholder { color: #8490a3; }

    .search:focus-within {
      border-color: var(--focus);
      outline: 3px solid var(--focus);
      outline-offset: 2px;
      box-shadow: 0 20px 52px var(--shadow);
    }

    .search button,
    .card-action {
      min-height: 42px;
      border: 0;
      border-radius: 10px;
      font: inherit;
      font-size: 14px;
      font-weight: 720;
      text-decoration: none;
      cursor: pointer;
    }

    .search button {
      padding: 0 20px;
      color: white;
      background: var(--blue);
      box-shadow: 0 10px 24px rgba(36,104,223,0.24);
    }

    .search button:hover { background: var(--blue-strong); }

    .search button:focus-visible,
    .card-action:focus-visible,
    footer a:focus-visible {
      outline: 3px solid var(--focus);
      outline-offset: 3px;
    }

    .feature-grid {
      display: grid;
      grid-template-columns: repeat(2, minmax(0, 1fr));
      gap: 16px;
    }

    .card {
      position: relative;
      overflow: hidden;
      min-height: 228px;
      padding: 24px;
      border: 1px solid var(--line);
      border-radius: 16px;
      background: var(--surface);
      box-shadow: 0 18px 46px rgba(31,48,78,0.08);
    }

    .card::after {
      content: "";
      position: absolute;
      width: 190px;
      height: 190px;
      right: -80px;
      top: -95px;
      border-radius: 50%;
      background: color-mix(in srgb, var(--accent) 17%, transparent);
      pointer-events: none;
    }

    .facet {
      --accent: var(--purple);
      --action-ink: var(--purple-action);
    }

    .extensions {
      --accent: var(--green);
      --action-ink: var(--green-action);
    }

    .card-top {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 12px;
    }

    .icon {
      display: grid;
      width: 38px;
      height: 38px;
      place-items: center;
      border-radius: 11px;
      color: white;
      background: var(--accent);
      font-size: 19px;
      font-weight: 800;
      box-shadow: 0 10px 24px color-mix(in srgb, var(--accent) 26%, transparent);
    }

    .badge {
      padding: 5px 8px;
      border-radius: 999px;
      color: var(--muted);
      background: rgba(112, 126, 150, 0.10);
      font-size: 11px;
      font-weight: 750;
    }

    h2 {
      margin: 18px 0 7px;
      font-size: 22px;
      letter-spacing: -0.025em;
    }

    .card p {
      min-height: 60px;
      margin: 0;
      color: var(--muted);
      font-size: 14px;
      line-height: 1.48;
    }

    .card-action {
      display: inline-flex;
      align-items: center;
      margin-top: 18px;
      padding: 0 14px;
      color: var(--action-ink);
      background: color-mix(in srgb, var(--accent) 10%, transparent);
      border: 1px solid color-mix(in srgb, var(--accent) 22%, transparent);
    }

    .card-action:hover {
      background: color-mix(in srgb, var(--accent) 15%, transparent);
    }

    .essentials {
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 18px;
      padding: 15px 18px;
      border: 1px solid var(--line);
      border-radius: 13px;
      color: var(--muted);
      background: rgba(255,255,255,0.48);
      font-size: 13px;
      line-height: 1.4;
    }

    .essentials strong { color: var(--ink); }

    footer {
      margin-top: 22px;
      color: var(--muted);
      font-size: 12px;
      text-align: center;
    }

    footer a { color: inherit; }

    @media (prefers-color-scheme: dark) {
      :root {
        --ink: #eef4ff;
        --muted: #a9b5c8;
        --line: rgba(190, 205, 228, 0.17);
        --surface: rgba(25, 34, 51, 0.78);
        --surface-strong: rgba(25, 34, 51, 0.94);
        --eyebrow: #8db8ff;
        --focus: #a7c9ff;
        --purple-action: #c4afff;
        --green-action: #77deb1;
        --shadow: rgba(0, 0, 0, 0.28);
      }

      body {
        background:
          radial-gradient(circle at 16% 8%, rgba(52, 119, 237, 0.22), transparent 31%),
          radial-gradient(circle at 88% 12%, rgba(48, 178, 186, 0.16), transparent 29%),
          radial-gradient(circle at 78% 88%, rgba(218, 154, 48, 0.10), transparent 31%),
          linear-gradient(145deg, #101724 0%, #151f2e 55%, #211d19 100%);
      }

      .lede { color: #c6d0df; }
      .essentials { background: rgba(25,34,51,0.52); }
    }

    @media (max-width: 680px) {
      .page { width: min(100% - 28px, 1080px); padding-top: 22px; }
      .local-label { display: none; }
      main { margin-top: 32px; gap: 20px; }
      .feature-grid { grid-template-columns: 1fr; }
      .card { min-height: 0; }
      .card p { min-height: 0; }
      .essentials { align-items: flex-start; flex-direction: column; }
    }

    @media (max-width: 460px) {
      .search { grid-template-columns: 1fr; }
      .search button { height: 42px; }
    }
  </style>
</head>
<body>
  <div class="page">
    <header>
      <div class="brand"><span class="mark" aria-hidden="true"></span>Quartz</div>
      <div class="local-label">Native start page · no remote content</div>
    </header>

    <main>
      <section class="intro">
        <p class="eyebrow">Ready when you are</p>
        <h1>A calmer starting point for the web.</h1>
        <p class="lede">Search, open a site, or use Quartz's built-in tools without leaving your browser.</p>
      </section>

      <form class="search" action="quartz-action://navigate" method="get" role="search">
        <input name="query" type="search" aria-label="Search or enter an address" placeholder="Search or enter an address" required>
        <button type="submit">Go</button>
      </form>

      <section class="feature-grid" aria-label="Quartz features">
        <article class="card facet">
          <div class="card-top">
            <span class="icon" aria-hidden="true">✦</span>
            <span class="badge">⇧⌘F</span>
          </div>
          <h2>Meet Facet</h2>
          <p>Ask about the current page or selected text, then choose the Codex model and reasoning level that fit the job.</p>
          <a class="card-action" href="quartz-action://facet">Open Facet</a>
        </article>

        <article class="card extensions">
          <div class="card-top">
            <span class="icon" aria-hidden="true">◇</span>
            <span class="badge">macOS 15.4+</span>
          </div>
          <h2>Bring your extensions</h2>
          <p>Install Chromium WebExtensions from the Chrome Web Store, a folder, ZIP, or CRX. Quartz restores them on launch.</p>
          <a class="card-action" href="quartz-action://extensions">Open Extensions</a>
        </article>
      </section>

      <div class="essentials">
        <span><strong>Reading Mode</strong> turns article pages into a focused reading view.</span>
        <span><strong>Basic protection</strong> blocks obvious third-party ad resources.</span>
      </div>
    </main>

    <footer>Quartz uses WebKit and your normal address/search routing. <a href="https://github.com/QuartzBrowser/Quartz">View the project</a></footer>
  </div>
</body>
</html>
"""#
}

enum QuartzURLRouting {
    static func normalizedURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        if let url = URL(string: trimmed),
           let scheme = url.scheme?.lowercased(),
           isStandardBrowsingScheme(scheme) {
            return url
        }

        if looksLikeHost(trimmed), let url = URL(string: "https://\(trimmed)") {
            return url
        }

        var components = URLComponents(string: "https://duckduckgo.com/")!
        components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
        return components.url
    }

    static func isRestorableSessionURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return isStandardBrowsingScheme(scheme)
    }

    static func isStandardBrowsingURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }

        return isStandardBrowsingScheme(scheme)
    }

    private static func isStandardBrowsingScheme(_ scheme: String) -> Bool {
        ["http", "https", "file"].contains(scheme)
    }

    private static func looksLikeHost(_ text: String) -> Bool {
        text == "localhost"
            || text.contains(".")
            || text.hasPrefix("localhost:")
            || text.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?$"#, options: .regularExpression) != nil
    }
}

final class QuartzStartPageSchemeHandler: NSObject, WKURLSchemeHandler {
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard QuartzStartPage.isStartPageURL(urlSchemeTask.request.url) else {
            urlSchemeTask.didFailWithError(resourceError(for: urlSchemeTask.request.url))
            return
        }

        let data = Data(QuartzStartPage.html.utf8)
        let requestURL = urlSchemeTask.request.url ?? QuartzStartPage.url
        let response = HTTPURLResponse(
            url: requestURL,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: [
                "Content-Type": "text/html; charset=utf-8",
                "Content-Length": String(data.count),
                "Cache-Control": "no-store",
                "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action quartz-action:"
            ]
        ) ?? URLResponse(
            url: requestURL,
            mimeType: "text/html",
            expectedContentLength: data.count,
            textEncodingName: "utf-8"
        )

        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    private func resourceError(for url: URL?) -> NSError {
        NSError(
            domain: NSURLErrorDomain,
            code: NSURLErrorFileDoesNotExist,
            userInfo: [NSURLErrorFailingURLErrorKey: url as Any]
        )
    }
}
