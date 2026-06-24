# Quartz

A native macOS web browser.

## Screenshots

<p>
  <img src="screenshots/quartz-home.png" alt="Quartz home screen showing the native toolbar and product overview">
</p>

<table>
  <tr>
    <td><img src="screenshots/quartz-field-notes.png" alt="Quartz displaying a field notes reading page"></td>
    <td><img src="screenshots/quartz-extensions.png" alt="Quartz displaying WebExtension support"></td>
  </tr>
</table>

## Run

```sh
swift run Quartz
```

## Build

```sh
swift build
```

## Package

Create a local macOS app bundle:

```sh
Scripts/package-macos-app.sh
open dist/Quartz.app
```

The default package is ad-hoc signed for local development. If macOS blocks a downloaded ad-hoc build with "Apple could not verify...", remove the quarantine attribute from the copy you trust:

```sh
xattr -dr com.apple.quarantine /path/to/Quartz.app
```

Public downloads require a Developer ID certificate and Apple notarization:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ZIP_APP=1 Scripts/package-macos-app.sh
xcrun notarytool submit dist/Quartz.zip --keychain-profile <profile> --wait
xcrun stapler staple dist/Quartz.app
```

## Features

- WebKit-powered browsing
- Tiny built-in ad blocker for obvious third-party ad resources
- Reading mode for article-focused pages
- Optional one-file `.qrx` WebExtension package installation on macOS 15.4+
- Direct GitHub issue submission for the Quartz repository through a configured issue relay
- Address/search field
- Back, forward, reload, stop, home, and reading controls
- Basic keyboard menu items

## Extensions

Quartz extensions install as a single `.qrx` package. A `.qrx` file is a ZIP archive containing a WebExtension `manifest.json` at its root, saved with the `.qrx` file extension.

Users can opt into extensions with **Extensions > Install .qrx Extension...** and choose a `.qrx` package. Quartz copies installed packages into Application Support and restores them on launch.

Quartz includes a tiny built-in blocker for a few obvious third-party ad resources. The former larger bundled ad-blocking filters now live in a separate Quartz Ad Blocker extension package.

## Issue Submission

Quartz can submit browser issues without asking users for a GitHub token. Configure a server-side issue relay that owns the GitHub credential, then point the app at it:

```sh
QUARTZ_ISSUE_SUBMISSION_URL="https://example.com/quartz/issues" swift run Quartz
ISSUE_SUBMISSION_URL="https://example.com/quartz/issues" Scripts/package-macos-app.sh
```

The relay receives JSON from the app and creates the GitHub issue with a token stored on the server. `Scripts/github-issue-relay-worker.js` is a Cloudflare Worker relay and `wrangler.toml` is ready for deployment.

For a Cloudflare Worker deployment:

```sh
node Scripts/test-github-issue-relay.mjs
npx wrangler kv namespace create QUARTZ_ISSUE_RELAY_KV
npx wrangler secret put GITHUB_TOKEN
npx wrangler deploy
```

Store a fine-grained GitHub token as the `GITHUB_TOKEN` secret with **Issues: write** access to `QuartzBrowser/Quartz`. Add the KV namespace id that Wrangler prints to `wrangler.toml` to enable per-IP rate limiting, then deploy again. Browser-origin requests are rejected unless the Worker has an `ALLOWED_ORIGIN` environment variable; native Quartz submissions do not need it.
