# Update verification

Verified locally on September 10, 2026 with Xcode 26.6 / Swift 6.3.3 on Apple Silicon.

- `swift test`: 59 tests passed, including 31 updater tests covering consent,
  cancellation, progress, stale callbacks, secure configuration, and preference migration.
- `Scripts/test-update-packaging.sh`: passed using disposable keys. Built two
  universal releases, verified archive/feed signatures, rejected altered bytes
  and missing keys, and retained the previous release in the next feed.
- Universal `arm64` and `x86_64` app/framework binaries and nested code signatures
  verified. Sparkle and its third-party license notices are included in the app.
- Native UI test used an isolated bundle identifier,
  `org.quartzbrowser.Quartz.UpdateSmoke`, and a loopback server with signed fixtures.
  A changed archive was rejected with an invalid-signature message; the installed
  app remained version 9.8.6 with a valid code signature. An altered appcast was
  rejected before an update was offered.
- With the valid signed feed restored, one click on **Update & Restart** downloaded
  and installed 9.8.7. The process restarted, the installed bundle version changed
  to 9.8.7, and the browser restored its saved test page. A subsequent manual check
  reported that 9.8.7 was the newest version.
- The repository's free signing secret and matching public-key variable were
  configured and their presence verified. The private key is retained in the
  dedicated Quartz Keychain account; it is not stored in this repository.

The live update test required no paid Apple Developer account. It used ad-hoc app
signatures plus Sparkle Ed25519 signatures for both the archive and feed.

These results cover local builds and installation on this Mac. Hosted Xcode 16.4
CI, public release downloads, first-download Gatekeeper behavior, and Intel runtime
execution have not been verified for this change. The release workflow includes
an anonymous public-download audit after publication. Existing users must install
the first updater-enabled version once before they can use the button.
