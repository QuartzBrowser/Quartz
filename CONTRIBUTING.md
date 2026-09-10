# Contributing to Quartz

Thanks for helping improve Quartz. This guide covers the usual local setup,
development checks, and pull request expectations for the macOS browser.

## Before You Start

- Read and follow the [Code of Conduct](CODE_OF_CONDUCT.md).
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

## Style

- Prefer small, readable AppKit/WebKit changes over broad rewrites.
- Keep UI behavior native to macOS where possible.
- Use clear names and add comments only when they explain non-obvious behavior.
- Preserve existing keyboard shortcuts and menu behavior when changing browser
  controls.
