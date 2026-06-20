# Third-party notices

Quartz bundles filter assets from uBlock Origin 1.71.0.

- Project: uBlock Origin
- Upstream: https://github.com/gorhill/uBlock
- Release: https://github.com/gorhill/uBlock/releases/tag/1.71.0
- Bundled asset: `uBlock0_1.71.0.chromium.zip`
- SHA-256: `5313a13fdbe748c23abdde6d24671635a3711a7ab0cf53f420bfa4aecdc36bf6`
- License: GPL-3.0-or-later, preserved at `Sources/Quartz/Resources/uBlockOrigin/LICENSE.txt`

The Quartz integration adapts bundled uBlock Origin filter lists into WebKit content blocker rules. It does not embed a browser-extension runtime, because `WKWebView` does not expose the Chromium/Firefox WebExtension APIs that uBlock Origin uses.
