# Quartz

A native macOS web browser.

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
- Built-in uBlock Origin 1.71.0 content blocking through bundled filter assets adapted to WebKit content rules
- Address/search field
- Back, forward, reload, stop, and home controls
- Basic keyboard menu items

## uBlock Origin integration

Quartz vendors the official uBlock Origin 1.71.0 Chromium release assets and compiles the compatible network-filter subset into `WKContentRuleList` rules at startup. The full uBlock Origin extension UI and dynamic filtering engine require browser extension APIs that are not available inside `WKWebView`, so Quartz uses the shipped filter assets natively instead.
