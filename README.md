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

## Features

- WebKit-powered browsing
- Optional one-file `.qrx` WebExtension package installation on macOS 15.4+
- Address/search field
- Back, forward, reload, stop, and home controls
- Basic keyboard menu items

## Extensions

Quartz extensions install as a single `.qrx` package. A `.qrx` file is a ZIP archive containing a WebExtension `manifest.json` at its root, saved with the `.qrx` file extension.

Users can opt into extensions with **Extensions > Install .qrx Extension...** and choose a `.qrx` package. Quartz copies installed packages into Application Support and restores them on launch.

The former bundled ad-blocking filters now live in a separate Quartz Ad Blocker extension package.
