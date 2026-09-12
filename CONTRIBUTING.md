# Contributing to Quartz

Thanks for helping improve Quartz. This guide covers the usual local setup,
development checks, and pull request expectations for the macOS browser.

## Before You Start

- Read and follow the [Code of Conduct](CODE_OF_CONDUCT.md).
- Follow the [Extensions Policy](EXTENSIONS_POLICY.md): ad blockers are welcome,
  including alternatives to Quartz's built-in blocker. Changes must not ban or
  deliberately obstruct them or force users to use the built-in blocker.
- Use GitHub issues for bug reports, feature requests, and design discussion.
- Report vulnerabilities through the process in [SECURITY.md](SECURITY.md)
  instead of opening a public issue with exploit details.

## Requirements

- macOS 14 or newer
- Xcode command line tools
- Swift 6.0 or newer

Check your Swift toolchain with:

```sh
swift --version
```

## Development

Clone the repository, then run Quartz from the package root:

```sh
swift run Quartz
```

Build without launching the app:

```sh
swift build
```

Most browser UI work lives under `Sources/Quartz/`. Keep changes close to the
existing AppKit and WebKit flow unless the feature really needs a new surface.

### Browser behavior checks

Run the focused reader and download checks with:

```sh
swift test --filter QuartzReaderModeTests
swift test --filter 'QuartzDownloadTests|QuartzDownloadDestinationTests'
```

The reader tests load the HTML fixtures under `Tests/QuartzTests/Fixtures/Reader`
in a real WebKit view. They cover article text, images, surrounding clutter, and
short pages, including restoring the original document and styles when reading
mode exits. Keep new extraction regressions as small HTML fixtures.

For changes to downloads, also test the packaged browser against both a response
with `Content-Disposition: attachment` and an HTML link with the `download`
attribute. Confirm the **Save Download** panel appears, save the file, check its
contents, and use **Show in Finder** from the completion message. Repeat with a
canceled save dialog and an interrupted or failed network transfer; existing
destination files must remain intact and failures must not report success.

The [window API diagnostic extension](docs/extensions.md#optional-window-api-diagnostics)
provides manual checks for extension-created pages and window queries.

## Packaging

Create a local `.app` bundle with:

```sh
Scripts/package-macos-app.sh
open dist/Quartz.app
```

The default local package is ad-hoc signed. Automated releases use Ed25519
signatures for the update feed and app archive without requiring a paid Apple
Developer account. See [update setup](docs/UPDATES.md) for signing configuration
and the initial macOS download warning.

## Pull Requests

Before opening a pull request:

- Keep the change focused on one bug, feature, or documentation improvement.
- Update `README.md` or other docs when user-facing behavior changes.
- Run `swift build` and, when relevant, `swift run Quartz`.
- For packaging changes, run `bash -n Scripts/package-macos-app.sh` and smoke
  test `Scripts/package-macos-app.sh`.
- For extension changes, follow the [sample installation checks](docs/extensions.md)
  on macOS 15.4 or newer, including the popup and persistence after restarting.
- Do not commit local build output such as `.build/`, `dist/`, or `.swiftpm/`.

In the pull request description, include:

- What changed
- How you tested it
- Any follow-up work or known limitations

## Releases

Quartz uses semantic-release to publish versions directly from commits merged
into `main`. The release workflow analyzes commit titles, updates
`CHANGELOG.md` and `version.txt`, builds the macOS archive, tags the release,
and publishes the GitHub release without a release pull request.

Use Conventional Commit titles for squash merges so semantic-release can classify
changes:

- `fix: describe the bug fix` for patch releases
- `feat: describe the user-facing feature` for minor releases
- `feat!: describe the breaking change` for major releases

Follow the [release signing and notarization checklist](docs/releases.md) for
universal packaging, archive verification, and a packaged-app smoke test. It
distinguishes the automated ad-hoc releases from the optional Developer ID and
Apple notarization process. Record checks that require unavailable credentials
or hardware as unrun.

## Style

- Prefer small, readable AppKit/WebKit changes over broad rewrites.
- Keep UI behavior native to macOS where possible.
- Use clear names and add comments only when they explain non-obvious behavior.
- Preserve existing keyboard shortcuts and menu behavior when changing browser
  controls.
