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

The automated release workflow uses free Ed25519 update signing without an Apple
Developer account; see [update setup](docs/UPDATES.md). If Developer ID credentials
are available, signing and notarization can remove the initial macOS warning:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ZIP_APP=1 Scripts/package-macos-app.sh
xcrun notarytool submit dist/Quartz.zip --keychain-profile <profile> --wait
xcrun stapler staple dist/Quartz.app
```

## Features

- WebKit-powered browsing
- Native local start page with direct access to search, Facet, and extensions
- In-browser updates with verified downloads, progress, and automatic restart
- Tiny built-in ad blocker for obvious third-party ad resources
- Reading mode for article-focused pages
- Facet side-panel assistant powered by OpenRouter
- Optional Chromium-format WebExtension installation on macOS 15.4+, including Chrome Web Store downloads
- Address/search field
- Back, forward, reload, stop, home, reading, and Facet controls
- Basic keyboard menu items

## Start Page

When there is no saved browsing session, Quartz opens a self-contained local start page instead of contacting a placeholder website. Its search box uses the same URL and DuckDuckGo search routing as the native address field, and its feature cards open the existing Facet panel and Extensions menu. The Home button always returns there; a valid saved web or file URL still takes precedence at launch.

## Updates

Release builds check for updates about once an hour while Quartz is running. When a compatible update is available, an **Update & Restart** button appears in the browser toolbar. Click it to download, verify, and install the update, then restart Quartz and restore your current page. Download and installation progress appear in the browser. You can cancel while checking or downloading; installation starts only after you choose to update.

Use **Quartz > Check for Updates…** to check immediately, or turn off **Quartz > Automatically Check for Updates** to disable automatic checks. Your existing preference is preserved. Manual checks still work when automatic checking is off.

[Sparkle](https://sparkle-project.org/) verifies the signed release feed and the update archive before extraction. A failed check or download shows an explanation and can be retried. Quartz keeps browsing data, extensions, and settings outside the app bundle, and the updater replaces the app itself.

Update requests go to GitHub without browsing history or Facet data. Running with `swift run Quartz`, or packaging without an update signing key, provides a development build with updates unavailable. Existing releases that predate the updater need one manual installation of an updater-enabled release. Maintainers can find signing, release setup, and verification instructions in [docs/UPDATES.md](docs/UPDATES.md).

## Facet

Facet is a docked AI assistant panel inside Quartz, powered by OpenRouter. Open it from the sparkles toolbar button or **View > Show Facet**. Create an [OpenRouter API key](https://openrouter.ai/settings/keys), enter it in the secure API key field, and click **Save** to store it in your macOS Keychain. **Remove** deletes the saved key. Facet can also use `OPENROUTER_API_KEY` from the environment that launches Quartz when no saved key is available.

Choose an OpenRouter model and an optional reasoning level, then ask a question. The default model uses OpenRouter's automatic routing; the default reasoning option lets the model use its own settings. Available models and supported reasoning options depend on OpenRouter and the selected provider.

Facet sends your prompt and recent conversation to OpenRouter and the selected model provider. When **Current page** is enabled, the request also includes the active page URL, title, selected text, description, and a bounded visible-text excerpt. Turn **Current page** off to omit that page context from future requests.

## Extensions

Quartz installs Chromium-format WebExtensions from the Chrome Web Store, an unpacked extension folder, a `.zip` archive, or a `.crx` package.

Users can opt into extensions from a Chrome Web Store listing with the native **Install** button that appears in the Quartz toolbar, or with **Extensions > Install This Web Store Extension**. Users can also choose **Extensions > Install from Chrome Web Store...** and paste a store listing URL or extension ID. Local packages are still available through **Extensions > Install Extension from File...**. Quartz copies installed extensions into Application Support and restores them on launch.

Quartz includes a tiny built-in blocker for a few obvious third-party ad resources. The former larger bundled ad-blocking filters now live in a separate Quartz Ad Blocker extension package.
