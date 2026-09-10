# Writing and packaging a Quartz extension

Quartz loads Chromium-format WebExtensions through WebKit on **macOS 15.4 or
newer**. The browser itself runs on macOS 14+, but its extension controls require
the newer OS. WebKit implements the extension APIs, so installing a Chrome package
does not guarantee that every Chrome API it uses will work. See Apple's
[WKWebExtension reference](https://developer.apple.com/documentation/webkit/wkwebextension).

## Try the small sample

The repository includes [Hello Quartz](../examples/extensions/hello-quartz), an
offline popup. It has no JavaScript, permissions, background tasks, content
scripts, or network requests. Its entire manifest is:

```json
{
  "manifest_version": 3,
  "name": "Hello Quartz",
  "version": "1.0.0",
  "description": "A small, offline popup for trying extensions in Quartz.",
  "action": {
    "default_title": "Hello Quartz",
    "default_popup": "popup.html"
  }
}
```

`action.default_popup` names the bundled HTML file that opens when the user
chooses the extension. Start here and add permissions only for behavior your
extension needs. Google's [manifest reference](https://developer.chrome.com/docs/extensions/reference/manifest)
explains the format.

From a fresh checkout, run these commands at the repository root:

```sh
swift build
swift run Quartz
```

1. Choose **Extensions > Install Extension from File...** in the macOS menu bar.
2. Select `examples/extensions/hello-quartz`, the folder containing
   `manifest.json`, then click **Install**. Select the folder itself, not the JSON
   file or the whole repository.
3. Dismiss the **Extension Installed** message. Choose **Extensions > Manage
   Extensions…** and confirm **Hello Quartz** appears with status **Enabled**.
4. Click the Extensions button in the browser toolbar, then **Hello Quartz**.
   Its popup should say **Hello, Quartz!**. Click outside the popup to dismiss it.
5. Quit and relaunch Quartz. Confirm the name remains in Manage Extensions and the
   popup still opens.

Quartz copies the folder to
`~/Library/Application Support/Quartz/Extensions/` and restores saved extensions
on launch. Editing your source folder does not edit the installed copy. To try
changes, uninstall the sample from **Manage Extensions…**, then install the edited
source folder again. Each installation creates its own copy.

## Manage extensions and permissions

In **Extensions > Manage Extensions…**, select an installed extension and choose
**Disable**, **Enable**, or **Uninstall…**. Disabling stops the extension while
keeping it installed. Uninstalling removes Quartz's installed copy and saved
registration, keeping your original source file or folder. Check that a disabled
extension's action is unavailable, enable it and try the action again, then
uninstall it and restart Quartz to confirm it stays removed.

Quartz shows a native **Allow** / **Cancel** prompt before granting requested
browser permissions or website access. Canceling install-time permission access
stops that installation; canceling a later request leaves the requested access
denied. Hello Quartz needs no permissions, so it does not trigger this prompt.
Install-time approvals are remembered for the installed copy. Extensions installed
by an older Quartz version may ask for consent when first loaded after upgrading.

## Package a ZIP

An extension ZIP must have `manifest.json` at its root, alongside the files it
references. Do not use the app-bundle packaging command's `--keepParent` option
for an extension: that would add a wrapping folder.

The following creates a new temporary output directory each time, so old ZIP
entries cannot remain after you rename or remove a source file:

```sh
QUARTZ_EXTENSION_DIST="$(mktemp -d -t quartz-extension)"
(
  cd examples/extensions/hello-quartz
  /usr/bin/zip -X "$QUARTZ_EXTENSION_DIST/hello-quartz.zip" manifest.json popup.html
)
/usr/bin/unzip -t "$QUARTZ_EXTENSION_DIST/hello-quartz.zip"
/usr/bin/unzip -Z1 "$QUARTZ_EXTENSION_DIST/hello-quartz.zip"
open "$QUARTZ_EXTENSION_DIST"
```

The listing should contain exactly:

```text
manifest.json
popup.html
```

Choose **Extensions > Install Extension from File...**, select the resulting
`hello-quartz.zip`, and repeat the status, popup, and restart checks above. Folder
and ZIP installations have separate stored paths; testing both can produce two
entries named Hello Quartz. Uninstall the sample through **Manage Extensions…**
before testing the other format to keep the results easy to identify.

## CRX and the Chrome Web Store

The same file picker accepts Chromium `.crx` packages (CRX2 or CRX3); Quartz reads
the package's ZIP payload. For Web Store installs, visit a listing in Quartz and
use its native toolbar **Install** button or **Extensions > Install This Web
Store Extension**. You can also use **Extensions > Install from Chrome Web
Store...** and paste a listing URL or a 32-character extension ID. Store downloads
require a network connection and may fail if the package is unavailable.

No Store upload or CRX signing is needed to try your own folder or ZIP. Review the
permission prompt before allowing a third-party extension access to your pages or
browser data.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Extension controls are unavailable | Run on macOS 15.4+. |
| Quartz cannot find `manifest.json` | Select the extension directory, or rebuild the ZIP from inside it. |
| The ZIP fails to load | Run `unzip -t` and `unzip -Z1`; check valid JSON and exact, case-sensitive resource names. |
| The extension installs but has no popup | Declare `action.default_popup` and include that file; select the extension from the toolbar's Extensions menu. |
| Edits are not visible | Quartz runs its installed copy; follow the sample replacement steps above. |
| An extension is disabled after launch | Read its error in Manage Extensions, then enable it again after fixing the source or approving the requested access. |
| A Store extension only partly works | Check its WebKit API requirements; report the macOS version and exact error, not just successful installation. |

## Optional window API diagnostics

[Quartz Window Check](../examples/extensions/window-check) is a separate manual
fixture for contributors. Install its folder with the same file picker. Unlike
Hello Quartz, it requests the `tabs` permission to display tab URLs and titles.
Choose **Allow** in the permission prompt to run these diagnostics, or **Cancel**
to verify that Quartz stops the installation without granting access.
It queries browser state only when **Inspect windows** is clicked, keeps results
in the popup, and opens `https://example.com/` only when a page button is clicked.

Quartz represents each browser page as a separate native window, with one tab
per window in the extension API. It does not have a tab strip. Check these cases
from an existing page whose URL is easy to recognize:

| Action | Expected result |
| --- | --- |
| New tab / New window | A new window opens example.com; the original page remains intact. |
| Background tab / Background window | A new window opens without taking focus from the source window. |
| Blank tab | A new window opens the local Quartz start page. |
| Inspect windows | Each live window has one tab; IDs differ, and URLs match the visible pages. |

Reopen the popup in the destination window and inspect again to check extension
availability there. Close the created windows, return to the source, and inspect
again; closed tabs/windows should disappear. Every window's sole tab is active
within that window; use the window's `focused` field to identify the front window.
Record API failures and the macOS version. The basic sample's successful popup
does not establish that these window APIs work.
