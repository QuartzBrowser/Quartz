import CryptoKit
import Foundation

enum QuartzFlagsPageAction: Equatable {
    case setWebMCPEnabled(Bool)
}

enum QuartzFlagsPage {
    static let url = URL(string: "quartz://flags/")!

    static func isFlagsPageURL(_ url: URL?) -> Bool {
        guard let url, let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return url.scheme?.lowercased() == QuartzStartPage.scheme
            && url.host?.lowercased() == "flags"
            && url.user == nil && url.password == nil && url.port == nil
            // URL.path normalizes trailing slashes; authorize the original path.
            && (components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/")
            && url.query == nil
    }

    static func authorizedAction(
        for url: URL,
        sourcePageURL: URL?,
        sourceIsMainFrame: Bool
    ) -> QuartzFlagsPageAction? {
        guard sourceIsMainFrame, isFlagsPageURL(sourcePageURL) else { return nil }
        // Accept only the exact URLs emitted by the bundled page. In particular,
        // credentials, ports, paths, fragments, duplicate or extra parameters,
        // and encoded parameter aliases must never change a native preference.
        switch url.absoluteString {
        case "quartz-action://flags?webmcp=enabled": return .setWebMCPEnabled(true)
        case "quartz-action://flags?webmcp=disabled": return .setWebMCPEnabled(false)
        default: return nil
        }
    }

    static let script = #"""
(() => {
  'use strict';
  const form = document.getElementById('webmcp-form');
  const control = document.getElementById('webmcp');
  function save(event) {
    event.preventDefault();
    if (!['enabled', 'disabled'].includes(control.value)) return;
    window.location.href = 'quartz-action://flags?webmcp=' + control.value;
  }
  control.addEventListener('change', save);
  form.addEventListener('submit', save);
})();
"""#

    static let contentSecurityPolicy: String = {
        let hash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        return "default-src 'none'; script-src 'sha256-\(hash)'; style-src 'unsafe-inline'; form-action quartz-action:; base-uri 'none'; frame-ancestors 'none'"
    }()

    // A history restoration can reuse a document rendered before another window
    // changed the flag. Refresh its controls from native preferences on arrival.
    static let updateSettingScript = #"""
    if (window.top !== window || location.protocol !== 'quartz:') return false;
    const pageURL = new URL(location.href);
    if (pageURL.hostname.toLowerCase() !== 'flags'
        || pageURL.username || pageURL.password || pageURL.port
        || !['', '/'].includes(pageURL.pathname)
        || pageURL.href.split('#')[0].includes('?')) return false;
    const control = document.getElementById('webmcp');
    const status = document.querySelector('.current');
    if (!control || !status) return false;
    control.value = enabled ? 'enabled' : 'disabled';
    status.textContent = 'Current setting: ' + (enabled ? 'Enabled' : 'Disabled');
    return true;
    """#

    static func html(webMCPEnabled: Bool) -> String {
        let enabledSelection = webMCPEnabled ? " selected" : ""
        let disabledSelection = webMCPEnabled ? "" : " selected"
        let status = webMCPEnabled ? "Enabled" : "Disabled"
        return #"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title>Flags — Quartz</title>
  <style>
    :root {
      color-scheme: light dark;
      font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif;
      --paper: #f7f7f2; --ink: #242738; --muted: #646579; --line: #dcdde2;
      --surface: #ffffffb3; --accent: #6450ba; --accent-soft: #eae5fc;
    }
    * { box-sizing: border-box; }
    body { margin: 0; min-height: 100vh; color: var(--ink); background: var(--paper); -webkit-font-smoothing: antialiased; }
    .page { max-width: 960px; width: calc(100% - 80px); margin: 0 auto; padding: 34px 0; }
    header { display: flex; align-items: center; justify-content: space-between; gap: 24px; }
    .brand { display: inline-flex; gap: 10px; align-items: center; color: var(--ink); font-size: 22px; font-weight: 760; letter-spacing: -.8px; text-decoration: none; }
    .brand svg { width: 28px; height: 32px; color: var(--accent); }
    .local { color: var(--muted); font-size: 12px; }
    main { padding-top: 68px; }
    .eyebrow { margin: 0 0 14px; color: var(--accent); font-size: 12px; font-weight: 650; }
    h1 { margin: 0; font-size: clamp(36px, 6vw, 52px); line-height: 1.1; letter-spacing: -.05em; font-weight: 720; }
    .lede { max-width: 640px; margin: 20px 0 32px; color: var(--muted); font-size: 15px; line-height: 1.7; }
    .flag { display: grid; grid-template-columns: minmax(0, 1fr) auto; gap: 32px; padding: 28px; border: 1px solid var(--line); border-radius: 20px; background: var(--surface); }
    .flag-heading { display: flex; align-items: center; gap: 12px; flex-wrap: wrap; }
    h2 { margin: 0; font-size: 20px; font-weight: 680; letter-spacing: -.4px; }
    .badge { padding: 5px 8px; border-radius: 6px; background: var(--accent-soft); color: var(--accent); font-size: 10px; font-weight: 650; }
    .description { max-width: 570px; margin: 14px 0 12px; font-size: 14px; line-height: 1.7; color: var(--muted); }
    code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: 11px; color: var(--muted); }
    form { padding-top: 3px; min-width: 180px; }
    label { display: block; margin-bottom: 8px; font-size: 12px; font-weight: 600; }
    select { display: block; width: 100%; min-height: 42px; padding: 9px 32px 9px 12px; border: 1px solid var(--line); border-radius: 10px; font: inherit; font-size: 13px; color: var(--ink); background: var(--paper); }
    select:focus-visible, a:focus-visible, button:focus-visible { outline: 3px solid var(--accent); outline-offset: 4px; }
    .current { margin: 9px 0 0; color: var(--muted); font-size: 11px; }
    .notes { margin-top: 24px; padding: 0 2px; color: var(--muted); font-size: 13px; line-height: 1.7; }
    .notes p { margin: 8px 0; }
    footer { margin-top: 52px; color: var(--muted); font-size: 12px; }
    a { color: var(--accent); text-underline-offset: 3px; }
    @media (prefers-color-scheme: dark) {
      :root { --paper: #191c24; --ink: #f1f0f6; --muted: #b2b3c4; --line: #383b49; --surface: #252934cc; --accent: #c0adff; --accent-soft: #39314f; }
    }
    @media (max-width: 650px) {
      .page { width: calc(100% - 36px); padding-top: 22px; }
      main { padding-top: 44px; }
      .flag { grid-template-columns: 1fr; padding: 22px; gap: 24px; }
      form { max-width: 280px; }
      .local { font-size: 11px; }
      footer { margin-top: 36px; }
    }
  </style>
</head>
<body>
  <div class="page">
    <header>
      <a class="brand" href="quartz://home" aria-label="Quartz home"><svg viewBox="0 0 30 36" fill="none" aria-hidden="true"><path d="M15 1 28 10 25 27 15 35 4 26 2 10Z" fill="currentColor" opacity=".18"/><path d="m15 1 3 12-3 22L4 26 2 10Z" fill="currentColor" opacity=".45"/><path d="m18 13 10-3-3 17-10 8Z" fill="currentColor"/><path d="m2 10 16 3 10-3M15 1l3 12-3 22" stroke="currentColor" stroke-width="1.1"/></svg>Quartz</a>
      <span class="local">Browser preferences · Stored on this Mac</span>
    </header>
    <main>
      <p class="eyebrow">A little ahead of the curve</p>
      <h1>Experimental features</h1>
      <p class="lede">Try features that are still taking shape. Experiments may change as Quartz evolves, and you can turn them off at any time.</p>
      <section class="flag" id="webmcp-flag" aria-labelledby="webmcp-title">
        <div>
          <div class="flag-heading"><h2 id="webmcp-title">WebMCP</h2><span class="badge">Experimental</span></div>
          <p class="description" id="webmcp-description">Let compatible websites offer structured tools to Facet, so it can help you complete tasks on the page. Each tool use still requires your approval.</p>
          <code>#webmcp</code>
        </div>
        <form id="webmcp-form" action="quartz-action://flags" method="get">
          <label for="webmcp">WebMCP setting</label>
          <select id="webmcp" name="webmcp" aria-describedby="webmcp-description apply-notice">
            <option value="disabled"\#(disabledSelection)>Disabled (default)</option>
            <option value="enabled"\#(enabledSelection)>Enabled</option>
          </select>
          <p class="current" role="status">Current setting: \#(status)</p>
          <noscript><button type="submit">Save setting</button></noscript>
        </form>
      </section>
      <div class="notes" id="apply-notice">
        <p>Changes are saved automatically. Reload open websites to apply the setting.</p>
        <p>Turning WebMCP off stops Facet from using website tools immediately.</p>
      </div>
    </main>
    <footer><a href="quartz://home">Back to home</a></footer>
  </div>
  <script>\#(script)</script>
</body>
</html>
"""#
    }
}
