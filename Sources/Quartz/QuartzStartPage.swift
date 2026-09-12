import CryptoKit
import Foundation
@preconcurrency import WebKit

enum QuartzStartPageAction: Equatable {
    case navigate(String)
    case searchSpark(String)
    case showFacet
    case showExtensions
}

enum QuartzStartPage {
    static let scheme = "quartz"
    static let actionScheme = "quartz-action"
    static let url = URL(string: "quartz://home")!

    static func isStartPageURL(_ url: URL?) -> Bool {
        guard let url else {
            return false
        }

        return url.scheme?.lowercased() == scheme
            && ["home", "start"].contains(url.host?.lowercased() ?? "")
            && url.user == nil && url.password == nil && url.port == nil
            && (url.path.isEmpty || url.path == "/")
            && url.query == nil
    }

    static func isActionURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == actionScheme
    }

    static func action(for url: URL) -> QuartzStartPageAction? {
        guard isActionURL(url) else {
            return nil
        }

        switch url.host?.lowercased() {
        case "navigate", "spark-search":
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            // GET forms encode spaces as +; an actual plus sign remains %2B.
            let encodedQuery = components?.percentEncodedQuery?
                .replacingOccurrences(of: "+", with: "%20")
            components?.percentEncodedQuery = encodedQuery
            let query = components?.queryItems?
                .first(where: { $0.name == "query" })?
                .value ?? ""
            return url.host?.lowercased() == "spark-search" ? .searchSpark(query) : .navigate(query)
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

    // Only the bundled script can run; the page never fetches remote resources.
    static let contentSecurityPolicy: String = {
        let hash = Data(SHA256.hash(data: Data(script.utf8))).base64EncodedString()
        return "default-src 'none'; script-src 'sha256-\(hash)'; style-src 'unsafe-inline'; form-action quartz-action:; base-uri 'none'; frame-ancestors 'none'"
    }()

    // Pass model output as callAsyncJavaScript arguments, never as JavaScript source.
    // Recheck the document because a tab may navigate while generation is in flight.
    // The protocol gate must not call functions a remote website could override.
    static let updateCuriositySparksScript = #"""
    if (window.top !== window || location.protocol !== 'quartz:') return false;
    const pageURL = new URL(location.href);
    if (!['home', 'start'].includes(pageURL.hostname.toLowerCase())
        || pageURL.username || pageURL.password || pageURL.port
        || !['', '/'].includes(pageURL.pathname)
        || pageURL.href.split('#')[0].includes('?')
        || typeof window.quartzUpdateCuriositySparks !== 'function') return false;
    window.quartzUpdateCuriositySparks(sparks, status);
    return true;
    """#

    static let script = #"""
(() => {
  'use strict';
  const body = document.body;
  const moods = ['daydream', 'orbit', 'golden'];
  const moodButtons = Array.from(document.querySelectorAll('.mood'));
  function setMood(mood) {
    if (!moods.includes(mood)) return;
    body.dataset.mood = mood;
    moodButtons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.mood === mood)));
    try { localStorage.setItem('quartz.home.mood', mood); } catch (_) { /* Storage may be unavailable in a private context. */ }
  }
  try { setMood(localStorage.getItem('quartz.home.mood')); } catch (_) { /* Keep the default mood. */ }
  moodButtons.forEach(button => button.addEventListener('click', () => setMood(button.dataset.mood)));

  function updateGreeting() {
    const now = new Date();
    const hour = now.getHours();
    document.getElementById('greeting').textContent = hour < 12 ? 'Good morning, curious mind.' : hour < 18 ? 'Good afternoon, curious mind.' : 'Good evening, curious mind.';
    const date = document.getElementById('today');
    date.textContent = new Intl.DateTimeFormat(undefined, { weekday: 'long', month: 'short', day: 'numeric' }).format(now);
    date.dateTime = [now.getFullYear(), String(now.getMonth() + 1).padStart(2, '0'), String(now.getDate()).padStart(2, '0')].join('-');
  }
  updateGreeting();
  document.addEventListener('visibilitychange', () => { if (!document.hidden) updateGreeting(); });

  const fallbackSparks = [
    ['A universe hiding in a drop of water.', 'microscopic life in a drop of pond water', 'SMALL WORLDS'],
    ['What does the universe sound like?', 'NASA sounds of space sonification', 'SPACE & WONDER'],
    ['Buildings straight out of a daydream.', 'surreal architecture around the world', 'ART & IDEAS'],
    ['Find a color you never knew had a name.', 'unusual color names and their origins', 'COLOR & CULTURE'],
    ['Meet the ocean’s living light show.', 'bioluminescent ocean creatures', 'THE NATURAL WORLD'],
    ['Take the scenic route through history.', 'beautiful antique illustrated maps', 'LOST & FOUND'],
    ['Make something out of almost nothing.', 'beginner origami with one sheet of paper', 'TRY SOMETHING'],
    ['A tiny garden. A whole new world.', 'how to make a miniature terrarium', 'LITTLE ADVENTURES'],
    ['When mathematics makes art.', 'beautiful mathematical art and patterns', 'PATTERNS EVERYWHERE'],
    ['Get wonderfully lost in a library.', 'remarkable libraries around the world', 'PLACES TO GO'],
    ['Look up. There’s a story in the stars.', 'how to recognize constellations for beginners', 'AFTER DARK'],
    ['Discover an instrument you’ve never heard.', 'unusual musical instruments and their sounds', 'A DIFFERENT NOTE']
  ];
  const now = new Date();
  let sparks = fallbackSparks;
  let generatedSparksKey = '[]';
  let sparkIndex = Math.floor(Date.UTC(now.getFullYear(), now.getMonth(), now.getDate()) / 86400000) % sparks.length;
  function showSpark() {
    const [title, query, category] = sparks[sparkIndex];
    document.getElementById('spark-title').textContent = title;
    document.getElementById('spark-category').textContent = category;
    const action = sparks === fallbackSparks ? 'navigate' : 'spark-search';
    document.getElementById('spark-link').href = 'quartz-action://' + action + '?query=' + encodeURIComponent(query);
    document.getElementById('shuffle-spark').disabled = sparks.length < 2;
  }
  window.quartzUpdateCuriositySparks = (items, status) => {
    const generated = Array.isArray(items) ? items
      .filter(item => item && ['title', 'query', 'category'].every(key => typeof item[key] === 'string' && item[key].trim()))
      .map(item => [item.title, item.query, item.category]) : [];
    const key = JSON.stringify(generated);
    if (key !== generatedSparksKey) {
      generatedSparksKey = key;
      sparks = generated.length ? generated : fallbackSparks;
      sparkIndex = 0;
      showSpark();
    }
    document.getElementById('spark-status').textContent = typeof status === 'string' ? status : '';
  };
  showSpark();
  document.getElementById('shuffle-spark').addEventListener('click', () => {
    if (sparks.length < 2) return;
    sparkIndex = (sparkIndex + 1 + Math.floor(Math.random() * (sparks.length - 1))) % sparks.length;
    showSpark();
  });

  document.getElementById('home-search').addEventListener('submit', event => {
    event.preventDefault();
    const input = document.getElementById('search-input');
    const query = input.value.trim();
    if (!query) { input.focus(); return; }
    window.location.href = 'quartz-action://navigate?query=' + encodeURIComponent(query);
  });
  document.addEventListener('keydown', event => {
    if (event.key === '/' && !event.metaKey && !event.ctrlKey && !event.altKey && !/INPUT|TEXTAREA|SELECT/.test(document.activeElement.tagName) && !document.activeElement.isContentEditable) {
      event.preventDefault();
      document.getElementById('search-input').focus();
    }
  });

  const crystal = document.getElementById('crystal-button');
  const messages = ['A little sparkle for your next adventure.', 'Excellent. The universe approves.', 'Curiosity looks good on you.', 'One small click. Infinite possibilities.'];
  let spins = 0;
  crystal.addEventListener('click', () => {
    document.getElementById('play-status').textContent = messages[spins++ % messages.length];
    crystal.classList.remove('spinning');
    void crystal.offsetWidth;
    crystal.classList.add('spinning');
  });
  crystal.addEventListener('animationend', () => crystal.classList.remove('spinning'));
})();
"""#

    static let html = #"""
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title>Home — Quartz</title>
  <style>
    :root { color-scheme: light dark; font-family: -apple-system, BlinkMacSystemFont, "SF Pro Display", system-ui, sans-serif; }
    * { box-sizing: border-box; }
    body {
      --paper: #f7f7f2; --ink: #242738; --muted: #646579; --line: #dcdde2;
      --surface: #ffffffb3; --accent: #6450ba; --accent-soft: #eae5fc;
      --glow: #dcd3fc; --second-glow: #e8efd1; --spark: #e8efb8; --spark-ink: #343d20;
      --crystal-a: #e6deff; --crystal-b: #a696e7; --crystal-c: #6650ba; --crystal-d: #e5bbdf;
      margin: 0; min-height: 100vh; color: var(--ink); background: var(--paper);
      -webkit-font-smoothing: antialiased;
      transition: background-color .3s, color .3s;
    }
    body[data-mood="orbit"] {
      --accent: #266e82; --accent-soft: #d9eef1; --glow: #c5e8ef; --second-glow: #dfe3ff; --spark: #ddebf8; --spark-ink: #263d55;
      --crystal-a: #d8fbf5; --crystal-b: #73c7d1; --crystal-c: #34768f; --crystal-d: #bbc9f3;
    }
    body[data-mood="golden"] {
      --accent: #965323; --accent-soft: #fbe6cf; --glow: #f6d4b5; --second-glow: #f5e7ac; --spark: #f9e2b7; --spark-ink: #574025;
      --crystal-a: #fff1c7; --crystal-b: #efbb73; --crystal-c: #bd7644; --crystal-d: #f0a994;
    }
    button, input { font: inherit; }
    button, a { -webkit-tap-highlight-color: transparent; }
    button { cursor: pointer; }
    a { color: inherit; }
    button:focus-visible, a:focus-visible { outline: 3px solid var(--accent); outline-offset: 5px; }
    button, a, input { touch-action: manipulation; }
    .page { max-width: 1136px; width: calc(100% - 96px); margin: 0 auto; padding: 30px 0 22px; }
    header { display: flex; align-items: center; justify-content: space-between; gap: 24px; }
    .brand { display: flex; gap: 10px; align-items: center; font-size: 22px; font-weight: 760; letter-spacing: -.8px; }
    .brand svg { width: 28px; height: 32px; color: var(--accent); }
    .brand span { font-weight: 450; color: var(--muted); margin-left: 4px; font-size: 14px; letter-spacing: 0; }
    .mood-picker { display: flex; align-items: center; gap: 5px; padding: 5px; border: 1px solid var(--line); border-radius: 99px; background: var(--surface); }
    .mood-label { padding: 0 8px; font-size: 11px; color: var(--muted); }
    .mood { display: flex; align-items: center; gap: 7px; border: 0; padding: 8px 11px; border-radius: 99px; color: var(--muted); font-size: 11px; font-weight: 650; background: transparent; }
    .mood[aria-pressed="true"] { background: var(--accent-soft); color: var(--accent); }
    .mood-dot { width: 10px; height: 10px; border-radius: 50%; background: #aa94d8; box-shadow: inset 0 0 0 1px #00000015; }
    .mood[data-mood="orbit"] .mood-dot { background: #75bccc; }
    .mood[data-mood="golden"] .mood-dot { background: #e8b26d; }
    .hero { position: relative; display: grid; grid-template-columns: 1.2fr 1fr; align-items: center; min-height: 310px; margin-top: 24px; }
    .hero-copy { z-index: 1; padding: 26px 0; }
    .eyebrow { display: flex; align-items: center; gap: 8px; margin: 0 0 18px; color: var(--accent); font-size: 12px; font-weight: 650; }
    .eyebrow .sun { font-size: 20px; line-height: 1; }
    h1 { margin: 0; font-size: clamp(40px, 4.8vw, 62px); line-height: 1.05; font-weight: 720; letter-spacing: -.058em; }
    h1 em { font-style: normal; color: var(--accent); }
    .lede { margin: 20px 0 0; color: var(--muted); font-size: 15px; line-height: 1.6; }
    .cosmos { position: relative; display: grid; place-items: center; height: 302px; isolation: isolate; }
    .cosmos::before { content: ""; position: absolute; inset: 0 -12px; z-index: -1; background: radial-gradient(ellipse at 50% 48%, var(--glow) 0, transparent 65%), radial-gradient(ellipse at 80% 70%, var(--second-glow), transparent 58%); filter: blur(14px); opacity: .9; }
    .orbit { position: absolute; width: 340px; height: 155px; border: 1px solid color-mix(in srgb, var(--accent) 24%, transparent); border-radius: 50%; transform: rotate(-24deg); pointer-events: none; }
    .orbit.two { width: 290px; height: 210px; transform: rotate(28deg); border-style: dashed; opacity: .65; }
    .planet { position: absolute; height: 22px; width: 22px; border-radius: 50%; background: var(--spark); box-shadow: inset -5px -4px 0 #0000000b, 0 6px 16px #00000008; left: 12%; top: 59%; }
    .planet.small { width: 12px; height: 12px; background: var(--crystal-b); left: auto; right: 13%; top: 21%; }
    .star { position: absolute; color: var(--accent); font-size: 20px; pointer-events: none; }
    .star.one { left: 17%; top: 18%; transform: rotate(14deg); }
    .star.two { right: 13%; bottom: 23%; font-size: 30px; }
    .star.three { right: 28%; top: 10%; font-size: 11px; }
    #crystal-button { position: relative; display: grid; place-items: center; padding: 0; width: 206px; height: 224px; border: 0; border-radius: 45%; color: var(--accent); background: transparent; transform: rotate(8deg); }
    #crystal-button svg { width: 180px; height: 220px; overflow: visible; filter: drop-shadow(0 24px 16px #51437825); animation: levitate 5s ease-in-out; }
    #crystal-button:hover svg { filter: drop-shadow(0 24px 20px #51437845); }
    #crystal-button.spinning { animation: crystal-spin .85s cubic-bezier(.2,.65,.25,1); }
    .crystal-a { fill: var(--crystal-a); } .crystal-b { fill: var(--crystal-b); } .crystal-c { fill: var(--crystal-c); } .crystal-d { fill: var(--crystal-d); }
    .crystal-hint { position: absolute; bottom: 6px; color: var(--muted); font-size: 10px; letter-spacing: .035em; }
    .search { display: flex; align-items: center; gap: 14px; background: var(--surface); border: 1px solid var(--line); border-radius: 19px; padding: 10px 11px 10px 22px; box-shadow: 0 7px 0 #24273803, 0 12px 32px #24273805; }
    .search:focus-within { outline: 3px solid var(--accent); outline-offset: 3px; }
    .search-icon { flex: 0 0 21px; width: 21px; height: 21px; color: var(--accent); }
    .search input { flex: 1; width: 0; min-width: 0; height: 42px; border: 0; outline: 0; background: transparent; color: var(--ink); font-size: 16px; }
    .search input::placeholder { color: var(--muted); opacity: 1; }
    .search kbd { border: 1px solid var(--line); border-radius: 5px; padding: 3px 7px; color: var(--muted); font-size: 12px; }
    .search button { flex-shrink: 0; height: 44px; padding: 0 20px; border: 0; border-radius: 11px; color: white; background: var(--accent); font-size: 13px; font-weight: 650; }
    .search button:hover { filter: brightness(1.12); }
    .section-heading { display: flex; align-items: baseline; justify-content: space-between; gap: 12px; margin: 28px 0 12px; }
    .section-heading h2 { margin: 0; font-size: 13px; font-weight: 680; letter-spacing: -.2px; }
    .section-heading span { font-size: 11px; color: var(--muted); }
    .shortcuts { display: grid; grid-template-columns: repeat(6, minmax(0, 1fr)); gap: 10px; }
    .shortcut { display: flex; align-items: center; gap: 10px; padding: 15px 12px; text-decoration: none; background: var(--surface); border: 1px solid var(--line); border-radius: 14px; font-size: 12px; font-weight: 580; transition: transform .18s, border-color .18s; }
    .shortcut:hover { transform: translateY(-3px); border-color: var(--accent); }
    .shortcut-icon { display: grid; place-items: center; flex: 0 0 29px; width: 29px; height: 29px; border-radius: 9px; font-weight: 750; font-size: 16px; }
    .shortcut-icon svg { width: 17px; height: 17px; }
    .wiki { color: #303242; background: #e8e8ed; font-family: Georgia, serif; font-size: 21px; }
    .github { color: #fbfbfc; background: #343744; }
    .youtube { color: #c2373c; background: #fce5e5; }
    .reddit { color: #ad4e25; background: #fbe6d7; }
    .maps { color: #317349; background: #e2eedf; }
    .mail { color: #4d63a3; background: #e4eafb; }
    .lower-grid { display: grid; grid-template-columns: 1.15fr 1fr; gap: 18px; margin-top: 26px; }
    .spark { position: relative; display: flex; flex-direction: column; align-items: flex-start; padding: 23px 25px 21px; overflow: hidden; min-height: 190px; border-radius: 20px; background: var(--spark); color: var(--spark-ink); }
    .spark::after { content: "✳"; position: absolute; right: -12px; top: 25px; font-size: 164px; line-height: 1; opacity: .08; transform: rotate(12deg); pointer-events: none; }
    .spark-top { align-self: stretch; display: flex; align-items: center; justify-content: space-between; gap: 14px; z-index: 1; }
    .spark-label { font-size: 10px; font-weight: 750; letter-spacing: .12em; }
    #shuffle-spark { display: inline-flex; gap: 5px; align-items: center; padding: 6px 9px; border: 1px solid color-mix(in srgb, var(--spark-ink) 23%, transparent); border-radius: 20px; color: inherit; background: transparent; font-size: 10px; }
    #shuffle-spark:hover { background: #ffffff45; }
    #shuffle-spark svg { width: 12px; height: 12px; }
    #spark-title { position: relative; z-index: 1; max-width: 365px; margin: 13px 0 16px; font-size: 25px; font-weight: 650; letter-spacing: -.8px; line-height: 1.2; overflow-wrap: anywhere; }
    .spark-bottom { display: flex; align-items: center; justify-content: space-between; gap: 10px; align-self: stretch; margin-top: auto; z-index: 1; }
    #spark-link { font-size: 12px; font-weight: 700; text-decoration: none; padding: 4px 0; }
    #spark-link:hover { text-decoration: underline; }
    #spark-category { font-size: 8px; font-weight: 650; letter-spacing: .09em; text-align: right; overflow-wrap: anywhere; }
    #spark-status { position: relative; z-index: 1; margin: 12px 0 0; font-size: 10px; line-height: 1.5; opacity: .8; overflow-wrap: anywhere; }
    .tools { display: grid; grid-template-rows: 1fr 1fr; gap: 12px; }
    .tool { display: flex; align-items: center; gap: 15px; padding: 19px 20px; border: 1px solid var(--line); border-radius: 16px; background: var(--surface); text-decoration: none; transition: border-color .18s; }
    .tool:hover { border-color: var(--accent); }
    .tool-icon { flex: 0 0 38px; width: 38px; height: 38px; display: grid; place-items: center; border-radius: 12px; background: var(--accent-soft); color: var(--accent); font-size: 25px; }
    .tool-copy { flex: 1; }
    .tool h2 { margin: 0 0 5px; font-size: 13px; font-weight: 650; }
    .tool p { margin: 0; color: var(--muted); font-size: 11px; line-height: 1.5; }
    .tool-arrow { color: var(--muted); font-size: 18px; }
    footer { display: flex; justify-content: space-between; gap: 20px; align-items: center; margin-top: 26px; color: var(--muted); font-size: 10px; line-height: 1.5; }
    .local { display: flex; align-items: center; gap: 6px; }
    .local::before { content: ""; height: 5px; width: 5px; border-radius: 50%; background: var(--accent); }
    footer a { text-decoration: none; } footer a:hover { text-decoration: underline; }
    .sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0,0,0,0); white-space: nowrap; border: 0; }
    @keyframes levitate { 0%, 100% { transform: translateY(0); } 50% { transform: translateY(-9px); } }
    @keyframes crystal-spin { 0% { transform: rotate(8deg) scale(1); } 45% { transform: rotate(190deg) scale(.87); } 100% { transform: rotate(368deg) scale(1); } }
    @media (prefers-color-scheme: dark) {
      body { --paper: #191c24; --ink: #f1f0f6; --muted: #b2b3c4; --line: #383b49; --surface: #252934cc; --accent: #c0adff; --accent-soft: #39314f; --glow: #514375; --second-glow: #394536; --spark: #d3dda1; }
      body[data-mood="orbit"] { --accent: #9bdae4; --accent-soft: #243f4b; --glow: #284957; --second-glow: #3a3b61; --spark: #c1d9eb; }
      body[data-mood="golden"] { --accent: #f1be87; --accent-soft: #4b3729; --glow: #60452e; --second-glow: #554c29; --spark: #eacf9f; }
      .search button { color: #1e2432; }
      .cosmos::before { opacity: .65; }
      .spark button:focus-visible, .spark a:focus-visible { outline-color: var(--spark-ink); }
    }
    @media (min-width: 1450px) { .page { padding-top: 40px; } .hero { margin-top: 48px; min-height: 360px; } .lower-grid { margin-top: 32px; } }
    @media (max-width: 950px) { .page { width: calc(100% - 56px); } .shortcut { flex-direction: column; gap: 9px; padding: 13px 7px; } .cosmos { transform: scale(.88); transform-origin: center; } .hero { grid-template-columns: 1.25fr 1fr; } .mood-label { display: none; } }
    @media (max-width: 700px) { .crystal-hint { display: none; } .page { width: calc(100% - 36px); padding-top: 20px; } header { gap: 12px; } .brand span { display: none; } .mood { font-size: 10px; padding: 7px 8px; gap: 5px; } .hero { min-height: 260px; grid-template-columns: 1.45fr 1fr; margin-top: 14px; } .hero-copy { padding: 26px 0; } h1 { font-size: clamp(35px, 6.5vw, 46px); } .eyebrow { font-size: 11px; } .lede { font-size: 13px; max-width: 240px; margin-top: 15px; } .cosmos { height: 240px; transform: scale(.65); } .lower-grid { grid-template-columns: 1fr; } .search { padding-left: 16px; gap: 10px; } .search kbd { display: none; } .search button { padding: 0 13px; } .search input { font-size: 14px; } .spark { min-height: 185px; } footer { align-items: flex-start; } }
    @media (max-width: 460px) { .brand { font-size: 19px; } .brand svg { width: 23px; } .mood-picker { gap: 0; padding: 4px; } .mood { padding: 8px; } .mood .mood-name { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0,0,0,0); } .mood-dot { width: 14px; height: 14px; } .hero { grid-template-columns: 1fr; min-height: 0; } .hero-copy { padding-bottom: 12px; } h1 { font-size: 46px; } .lede { max-width: none; } .cosmos { height: 190px; transform: scale(.7); margin-top: -12px; margin-bottom: -6px; } .shortcuts { grid-template-columns: repeat(3, minmax(0, 1fr)); } .shortcut { flex-direction: row; font-size: 11px; padding: 12px 8px; gap: 7px; } .search button { font-size: 12px; padding: 0 12px; } .search-icon { display: none; } .search input { font-size: 13px; } .section-heading span { display: none; } footer { flex-wrap: wrap; gap: 8px; } }
    @media (prefers-reduced-motion: reduce) { *, *::before, *::after { animation: none !important; transition: none !important; } .shortcut:hover { transform: none; } }
  </style>
</head>
<body data-mood="daydream">
  <div class="page">
    <header>
      <div class="brand"><svg viewBox="0 0 30 36" fill="none" aria-hidden="true"><path d="M15 1 28 10 25 27 15 35 4 26 2 10Z" fill="currentColor" opacity=".18"/><path d="m15 1 3 12-3 22L4 26 2 10Z" fill="currentColor" opacity=".45"/><path d="m18 13 10-3-3 17-10 8Z" fill="currentColor"/><path d="m2 10 16 3 10-3M15 1l3 12-3 22" stroke="currentColor" stroke-width="1.1"/></svg>Quartz <span>home</span></div>
      <div class="mood-picker" role="group" aria-label="Page color mood">
        <span class="mood-label">Set the mood</span>
        <button class="mood" data-mood="daydream" type="button" aria-pressed="true" title="Daydream mood"><span class="mood-dot" aria-hidden="true"></span><span class="mood-name">Daydream</span></button>
        <button class="mood" data-mood="orbit" type="button" aria-pressed="false" title="Orbit mood"><span class="mood-dot" aria-hidden="true"></span><span class="mood-name">Orbit</span></button>
        <button class="mood" data-mood="golden" type="button" aria-pressed="false" title="Golden mood"><span class="mood-dot" aria-hidden="true"></span><span class="mood-name">Golden</span></button>
      </div>
    </header>
    <main>
      <section class="hero" aria-labelledby="home-title">
        <div class="hero-copy">
          <p class="eyebrow"><span class="sun" aria-hidden="true">☼</span><span id="greeting">Hello, curious mind.</span></p>
          <h1 id="home-title">A little curiosity.<br>A <em>whole internet.</em></h1>
          <p class="lede">Big ideas, tiny rabbit holes, and your next favorite thing.<br>Let’s see where today takes you.</p>
        </div>
        <div class="cosmos">
          <div class="orbit" aria-hidden="true"></div><div class="orbit two" aria-hidden="true"></div>
          <span class="planet" aria-hidden="true"></span><span class="planet small" aria-hidden="true"></span>
          <span class="star one" aria-hidden="true">✦</span><span class="star two" aria-hidden="true">✧</span><span class="star three" aria-hidden="true">✦</span>
          <button id="crystal-button" type="button" aria-label="Spin the quartz crystal" aria-describedby="play-status">
            <svg viewBox="0 0 180 220" fill="none" aria-hidden="true">
              <path class="crystal-a" d="m86 10 64 46 10 109-62 44-71-49-4-101Z"/>
              <path class="crystal-b" d="m86 10 10 67 2 132-71-49-4-101Z"/>
              <path class="crystal-c" d="m96 77 54-21 10 109-62 44Z"/>
              <path class="crystal-d" d="m23 59 40 29 33-11-10-67Z"/>
              <path class="crystal-a" d="m86 10 10 67 54-21Z"/>
              <path fill="#ffffff" opacity=".24" d="m63 88 33-11 2 132-31-70Z"/>
              <path fill="#ffffff" opacity=".38" d="m23 59 40 29 4 51-40 21Z"/>
              <path fill="#ffffff" opacity=".18" d="m67 139 31 70-71-49Z"/>
              <path fill="#000000" opacity=".08" d="m96 77 30 49 34 39-62 44Z"/>
              <path stroke="#ffffff" opacity=".55" stroke-width="1.2" d="m86 10 10 67 54-21M23 59l40 29 33-11 2 132M63 88l4 51-40 21m40-21 31 70m-2-132 30 49 34 39"/>
              <path d="m124 38 3 10 10 3-10 3-3 10-3-10-10-3 10-3Z" fill="white"/>
              <path d="m46 128 2 6 6 2-6 2-2 6-2-6-6-2 6-2Z" fill="white" opacity=".8"/>
            </svg>
          </button>
          <span class="crystal-hint">a little magic. give it a spin ↗</span>
          <span id="play-status" class="sr-only" role="status" aria-live="polite"></span>
        </div>
      </section>
      <form id="home-search" class="search" action="quartz-action://navigate" method="get" role="search">
        <svg class="search-icon" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" aria-hidden="true"><circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5" stroke-linecap="round"/></svg>
        <input id="search-input" name="query" type="search" aria-label="Search or enter an address" placeholder="Search the web or enter an address" autocomplete="off" spellcheck="false" required>
        <kbd aria-hidden="true">/</kbd><button type="submit">Let’s go <span aria-hidden="true">↗</span></button>
      </form>
      <section aria-labelledby="launchpad-title">
        <div class="section-heading"><h2 id="launchpad-title">Your launchpad</h2><span>A few places to begin</span></div>
        <nav class="shortcuts" aria-label="Website shortcuts">
          <a class="shortcut" href="https://www.wikipedia.org/"><span class="shortcut-icon wiki" aria-hidden="true">W</span>Wikipedia</a>
          <a class="shortcut" href="https://github.com/"><span class="shortcut-icon github" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="m8 7-5 5 5 5m8-10 5 5-5 5m-3-14-2 18"/></svg></span>GitHub</a>
          <a class="shortcut" href="https://www.youtube.com/"><span class="shortcut-icon youtube" aria-hidden="true"><svg viewBox="0 0 24 24" fill="currentColor"><rect x="1" y="4" width="22" height="16" rx="5"/><path d="m10 8 6 4-6 4Z" fill="white"/></svg></span>YouTube</a>
          <a class="shortcut" href="https://www.reddit.com/"><span class="shortcut-icon reddit" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M5 4h14a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2h-8l-5 4v-4H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2Z"/><path d="M7 9h10M7 13h6"/></svg></span>Reddit</a>
          <a class="shortcut" href="https://maps.google.com/"><span class="shortcut-icon maps" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M19 10c0 5-7 12-7 12S5 15 5 10a7 7 0 1 1 14 0Z"/><circle cx="12" cy="10" r="2.5"/></svg></span>Maps</a>
          <a class="shortcut" href="https://mail.google.com/"><span class="shortcut-icon mail" aria-hidden="true"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="2" y="4" width="20" height="16" rx="3"/><path d="m3 6 9 7 9-7"/></svg></span>Gmail</a>
        </nav>
      </section>
      <section class="lower-grid" aria-label="Discover and make it yours">
        <article class="spark">
          <div class="spark-top"><span class="spark-label">✳ &nbsp; CURIOSITY SPARK</span><button id="shuffle-spark" type="button"><svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.5" aria-hidden="true"><path d="M1 4h2c4 0 6 8 10 8h2M12 9l3 3-3 3M1 12h2c1.5 0 2.8-1.2 4-3M9 6c1.3-1.3 2.5-2 4-2h2m-3-3 3 3-3 3"/></svg>Shuffle</button></div>
          <h2 id="spark-title" aria-live="polite" aria-atomic="true">What does the universe sound like?</h2>
          <div class="spark-bottom"><a id="spark-link" href="quartz-action://navigate?query=NASA%20sounds%20of%20space%20sonification">Explore this <span aria-hidden="true">↗</span></a><span id="spark-category">SPACE &amp; WONDER</span></div>
          <p id="spark-status" role="status" aria-live="polite">Chat with Facet to personalize your daily sparks.</p>
        </article>
        <div class="tools">
          <a class="tool" href="quartz-action://facet" aria-label="Open Facet"><span class="tool-icon" aria-hidden="true">✦</span><div class="tool-copy"><h2>A sidekick for your rabbit holes</h2><p>Open Facet. Bring a question, leave with an idea.</p></div><span class="tool-arrow" aria-hidden="true">↗</span></a>
          <a class="tool" href="quartz-action://extensions" aria-label="Open Extensions"><span class="tool-icon" aria-hidden="true">⌘</span><div class="tool-copy"><h2>A browser with your personality</h2><p>Open Extensions and make Quartz your own.</p></div><span class="tool-arrow" aria-hidden="true">↗</span></a>
        </div>
      </section>
    </main>
    <footer><span class="local">Made for wandering. Right at home.</span><time id="today"></time><a href="https://github.com/QuartzBrowser/Quartz">Made of Quartz <span aria-hidden="true">↗</span></a></footer>
  </div>
  <script>\#(script)</script>
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

        if let url = URL(string: trimmed), QuartzStartPage.isStartPageURL(url) {
            return QuartzStartPage.url
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
                "Content-Security-Policy": QuartzStartPage.contentSecurityPolicy
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
