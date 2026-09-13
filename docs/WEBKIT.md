# Quartz WebKit

Quartz builds against the [QuartzBrowser/WebKit fork](https://github.com/QuartzBrowser/WebKit).
[`WebKit.lock.json`](../WebKit.lock.json) selects the exact source revision,
currently `7f1d29889cbd13cb4627b31f4db73651bbcf12e0`. Default builds require
prepared products from that revision. Missing or stale engine metadata fails the
build with setup instructions.

## Build the engine

Use full Xcode 26.2 or newer and its public macOS SDK. CI selects Xcode 26.6 and
macOS SDK 26.5. Install the Metal toolchain if needed:

```sh
xcodebuild -downloadComponent MetalToolchain
Scripts/build-webkit.sh --check
Scripts/build-webkit.sh
```

The script fetches a shallow sparse checkout of the locked fork, builds the
upstream **Everything up to WebKit** scheme in Release, and prepares the engine
for Quartz. It uses two concurrent build jobs by default and builds both `arm64`
and `x86_64`. The first build needs substantial time and disk space. Source and
raw build files use `~/Library/Caches/Quartz/WebKit/REVISION/`. WebKit's
upstream Makefiles require those two paths to have no whitespace; a Quartz
checkout whose path contains spaces is supported. Prepared engine products stay
under ignored `.build/` paths.

On machines with limited RAM, `WEBKIT_JOBS=1` reduces concurrent compiler memory
use at the cost of slower C++ compilation. WebKit's Swift compilation can still
require swap space on an 8 GB Mac.

Engine Release builds omit debug symbols and compiler indexing to reduce storage
use. They retain the normal upstream feature configuration. Source-level engine
debugging requires a separate WebKit build with debug information enabled.

For local Apple Silicon development:

```sh
WEBKIT_ARCHS=arm64 Scripts/build-webkit.sh
Scripts/quartz.sh build
Scripts/quartz.sh test
Scripts/quartz.sh run
```

Native-only products cannot be used for universal release packaging. Re-run
`Scripts/build-webkit.sh` without `WEBKIT_ARCHS` to produce both architectures.
To test a local app bundle with the native build, run
`QUARTZ_APP_ARCHS=arm64 Scripts/package-macos-app.sh`. Public release preparation
always selects both architectures.

| Variable | Default | Purpose |
| --- | --- | --- |
| `WEBKIT_CACHE_DIR` | `~/Library/Caches/Quartz/WebKit/REVISION` | Engine cache; use a path without whitespace. |
| `WEBKIT_SOURCE_DIR` | `WEBKIT_CACHE_DIR/source` | Clean checkout of the exact fork revision. |
| `WEBKIT_BUILD_DIR` | `WEBKIT_CACHE_DIR/build` | Raw Xcode build root; Release products are below it. |
| `WEBKIT_PRODUCTS_DIR` | `.build/quartz-webkit/products/Release` | Prepared relocatable engine output. |
| `WEBKIT_ARCHS` | `arm64 x86_64` | Space-separated target architectures. |
| `WEBKIT_JOBS` | `2` | Concurrent build jobs. |
| `QUARTZ_WEBKIT_PRODUCTS_DIR` | `.build/quartz-webkit/products/Release` | Prepared engine used by Quartz build, test, run, and packaging commands. |
| `QUARTZ_APP_ARCHS` | `arm64 x86_64` | App packaging architectures; use `arm64` for a local Apple Silicon smoke test. Release preparation always uses both. |
| `DEVELOPER_DIR` | Selected Xcode | Full Xcode developer directory for this shell. |

If `WEBKIT_PRODUCTS_DIR` is customized, set `QUARTZ_WEBKIT_PRODUCTS_DIR` to the
same absolute path when building or running Quartz. Source, raw build, and
prepared products directories must be separate. An existing source checkout with
the wrong remote, local changes, or a different revision is rejected without
resetting it.

## macOS compatibility

`WebKit.lock.json` pins `macOSDeploymentTarget` to **15.4**, matching the fork's
upstream Sequoia Release builders. The script passes this setting explicitly so
the build does not inherit the developer machine's OS version. Upstream has
[successfully built this configuration](https://build.webkit.org/#/builders/1223/builds/26899)
with the public macOS SDK for both architectures. macOS 14 is absent from the
pinned source's supported downlevel version list; the earlier system-WebKit
build's compatibility does not establish compatibility for the bundled fork.

Preparation reads every bundled Mach-O binary's minimum OS and records the
highest requirement as `minimumSystemVersion` in `QuartzWebKit.json`, alongside
the requested deployment target. Quartz's
package deployment target, app metadata, and release feed use the engine's
minimum. Validate the resulting app on every macOS version and architecture
claimed for a release.

## Loading and packaging

```sh
python3 Scripts/webkit-bundle.py verify .build/quartz-webkit/products/Release --arch arm64 --arch x86_64
ZIP_APP=1 Scripts/package-macos-app.sh
dist/Quartz.app/Contents/MacOS/Quartz --quartz-webkit-info
python3 Scripts/test-webkit-runtime.py dist/Quartz.app/Contents/MacOS/Quartz
open dist/Quartz.app
```

Preparation carries WebKit, JavaScriptCore, WebCore, supporting frameworks and
libraries, and XPC services together. It preserves the upstream relative layout,
rewrites engine dependencies for relocation, signs the prepared code, and records
binary hashes, architecture coverage, source revision, and minimum OS.
Packaging checks this inventory, embeds the engine, signs nested code before the
app, and runs the diagnostic and isolated rendering/network smoke tests against the
resulting executable on the host architecture.
Sparkle's release-note view also depends on WebKit. The launcher and packaging
scripts redirect the copied Sparkle framework to the fork before running Quartz
or its tests. The downloaded Sparkle artifact stays unchanged.
Fork builds also disable macOS Writing Tools in native text controls, menus, and
web views. Its assistant frameworks otherwise load Apple's WebKit into the
browser process. Quartz applies Apple's
[public per-view opt-outs](https://developer.apple.com/documentation/appkit/customizing-writing-tools-behavior-for-system-views)
before displaying controls.
The pinned fork also checks an explicit Writing Tools opt-out before loading its
UI frameworks, including for editable web views, and avoids loading Quick Look
while destroying a view that never opened a preview.
After signing the embedded engine, it refreshes the packaged manifest's binary
hashes before sealing the app. The prepared cache keeps its original hashes;
the app's manifest describes its own signed engine binaries.

The packaged `Quartz` executable is a small native launcher. It finds its own
bundle after moves, clears inherited `DYLD_*` and `__XPC_DYLD_*` settings, and
starts `QuartzRuntime` with framework search paths pointing only into that
bundle. This redirects absolute engine imports in macOS integrations such as
Quick Look as well as Quartz's own links. The inner runtime carries Apple's
[allow-DYLD-environment entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-dyld-environment-variables)
for Developer ID builds. The outer launcher has no such exception; library
validation remains enabled. `Scripts/quartz.sh run` and `test` apply equivalent
prepared-framework paths only to the launched process, after build and staging.

`--quartz-webkit-info` prints JSON without creating a browser window or opening
the browsing profile. For a fork build, `mode` must be `fork`, `valid` must be
`true`, and `loadedFrameworkPath` must identify the configured products directory
or the packaged app's own WebKit framework. A packaged app always checks its own
embedded framework even when launched from a development shell. Startup stops
if the expected engine is missing or the loaded path differs. `loadedEngineImages`
also lists the actual loaded WebKit, WebCore, and JavaScriptCore images; fork mode
rejects engine images outside its configured directory. The Swift test suite
checks the engine loaded into its own process as well.

The info diagnostic proves which WebKit framework supplies `WKWebView`.
`--quartz-webkit-smoke-test` goes further: it creates a nonpersistent web view,
loads offline HTML, and checks layout and JavaScript within a 45-second timeout.
It leaves the user's browsing profile untouched. `Scripts/test-webkit-runtime.py`
runs this offline check and a second check that fetches a unique page from a
temporary loopback HTTP server. The server must confirm the HTTP request and the
web view must validate layout and JavaScript. The driver removes incoming
`DYLD_*` and `__XPC_DYLD_*` overrides and runs the app from a temporary working
directory; the packaged launcher supplies its own framework paths. These tests run
only on the host architecture; a universal binary still needs separate Intel runtime checks.
Check a real HTTPS page, networking, downloads, and extensions
in the packaged app, including after moving it away from the build directory.
Local integration tests, a completed engine build, packaged runtime tests, and
hosted CI are separate validation results. The new build and packaging path must
complete those checks before it is treated as release-validated. Passing the
system-engine development tests does not verify the fork's runtime.

WebKit's source license files and source revision are included with the prepared
products and packaged application. Retain those notices and the exact source pin
with distributed builds.

## Explicit system-engine development

For browser UI work that does not require the fork, select the system engine
explicitly:

```sh
QUARTZ_USE_SYSTEM_WEBKIT=1 Scripts/quartz.sh build
QUARTZ_USE_SYSTEM_WEBKIT=1 Scripts/quartz.sh test
QUARTZ_USE_SYSTEM_WEBKIT=1 Scripts/quartz.sh run
```

The diagnostic labels this mode `system-development`. Its test results apply to
the installed macOS WebKit. Normal release preparation refuses this mode.
`QUARTZ_TEST_SYSTEM_RELEASE=1` is reserved for disposable updater fixtures and
does not establish fork or release compatibility.

## Updating the fork and CI cache

Change the complete revision in `WebKit.lock.json`, then build from a clean
checkout of that exact revision. To retain an existing checkout and its build,
select new source, raw build, and products directories with the variables above.
Do not relabel existing products by editing `QuartzWebKit.json`.

The shared GitHub composite action caches only verified prepared products. Its
exact key includes the lock, build and bundling scripts, action definition,
Xcode/compiler identity, SDK settings, Metal compiler, host OS, and runner
architecture. There are no prefix restore keys. A cache miss builds the fork;
a cache hit still verifies provenance, binary hashes, dependencies, and both
architectures. The build and release jobs then test Quartz against that engine
and package a universal app. They allow up to six hours for an uncached build.
Set the repository variable `QUARTZ_WEBKIT_RUNNER` to a configured runner label
when using a dedicated engine builder with Xcode 26.6. Otherwise the workflows
keep Quartz's existing Blacksmith provider and six-CPU tier, updated to
`blacksmith-6vcpu-macos-26`. This runner provides 24 GB RAM and 150 GB SSD according
to [Blacksmith's runner specifications](https://docs.blacksmith.sh/blacksmith-runners/overview#macos-runners).
CI uses four compile jobs; set `QUARTZ_WEBKIT_JOBS` as a repository variable to
adjust concurrency for a different runner. Local builds default to two jobs.
A cold universal engine build still needs hosted validation for its time limit;
a cache hit avoids that compilation but always revalidates the prepared products.

## Upstream implementation references

- [Build requirements and application launch helpers](https://github.com/QuartzBrowser/WebKit/blob/7f1d29889cbd13cb4627b31f4db73651bbcf12e0/Tools/Scripts/webkitdirs.pm): Xcode minimum and the upstream development `DYLD_*` launch path.
- [SDK and deployment selection](https://github.com/QuartzBrowser/WebKit/blob/7f1d29889cbd13cb4627b31f4db73651bbcf12e0/Configurations/SDKVariant.xcconfig): public Release builds and the Apple-internal Production configuration.
- [Upstream builder configuration](https://github.com/QuartzBrowser/WebKit/blob/7f1d29889cbd13cb4627b31f4db73651bbcf12e0/Tools/CISupport/build-webkit-org/config.json) and [supported downlevel versions](https://github.com/QuartzBrowser/WebKit/blob/7f1d29889cbd13cb4627b31f4db73651bbcf12e0/Configurations/Makefile): the macOS 15.4 deployment target.
- [Release configuration](https://github.com/QuartzBrowser/WebKit/blob/7f1d29889cbd13cb4627b31f4db73651bbcf12e0/Source/WebKit/Configurations/DebugRelease.xcconfig) and [relocatable service paths](https://github.com/QuartzBrowser/WebKit/blob/7f1d29889cbd13cb4627b31f4db73651bbcf12e0/Source/WebKit/Configurations/RelocatableFrameworksLinkerFlags.xcconfig): service layout and loader paths.
- [WebKit project](https://github.com/QuartzBrowser/WebKit/blob/7f1d29889cbd13cb4627b31f4db73651bbcf12e0/Source/WebKit/WebKit.xcodeproj/project.pbxproj): framework-to-XPC and library symlinks.
- [Service entitlement generation](https://github.com/QuartzBrowser/WebKit/blob/7f1d29889cbd13cb4627b31f4db73651bbcf12e0/Source/WebKit/Scripts/process-entitlements.sh): JIT and per-service signing requirements.
- [GitHub macOS 26 runner image](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md): currently available Xcode installations and SDKs.
