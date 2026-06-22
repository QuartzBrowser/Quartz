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
- Address/search field
- Back, forward, reload, stop, home, and reading controls
- Basic keyboard menu items

## Extensions

Quartz extensions install as a single `.qrx` package. A `.qrx` file is a ZIP archive containing a WebExtension `manifest.json` at its root, saved with the `.qrx` file extension.

Users can opt into extensions with **Extensions > Install .qrx Extension...** and choose a `.qrx` package. Quartz copies installed packages into Application Support and restores them on launch.

Quartz includes a tiny built-in blocker for a few obvious third-party ad resources. The former larger bundled ad-blocking filters now live in a separate Quartz Ad Blocker extension package.
