#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?usage: verify-published-update.sh VERSION [--feed]}"
if [[ $# -gt 2 || ( $# == 2 && "$2" != --feed ) ]]; then
    echo "error: usage: verify-published-update.sh VERSION [--feed]" >&2
    exit 1
fi
python3 "${ROOT_DIR}/Scripts/release-version.py" "${VERSION}" > /dev/null
if [[ -z "${SPARKLE_PUBLIC_KEY:-}" ]]; then
    echo "error: SPARKLE_PUBLIC_KEY is required to authenticate public release downloads" >&2
    exit 1
fi
LOCAL_RELEASE="${DIST_DIR:-${ROOT_DIR}/dist}/release"
VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "${VERIFY_DIR}"' EXIT
ARCHIVE_NAME="Quartz-v${VERSION}-macos-universal.zip"
DOWNLOAD_PREFIX="https://github.com/QuartzBrowser/Quartz/releases/download/v${VERSION}/"
for asset in "${ARCHIVE_NAME}" appcast.xml SHA256SUMS; do
    curl --fail --silent --show-error --location --retry 5 --retry-all-errors \
        --connect-timeout 20 --max-time 180 "${DOWNLOAD_PREFIX}${asset}" --output "${VERIFY_DIR}/${asset}"
    cmp "${LOCAL_RELEASE}/${asset}" "${VERIFY_DIR}/${asset}"
done
(
    cd "${VERIFY_DIR}"
    shasum -a 256 --check SHA256SUMS
)
swift "${ROOT_DIR}/Scripts/verify-release-archive.swift" "${VERIFY_DIR}/${ARCHIVE_NAME}" \
    "${VERIFY_DIR}/appcast.xml" "${VERSION}" "${SPARKLE_PUBLIC_KEY}"
ditto -x -k "${VERIFY_DIR}/${ARCHIVE_NAME}" "${VERIFY_DIR}/unpacked"
codesign --verify --deep --strict "${VERIFY_DIR}/unpacked/Quartz.app"
python3 - "${VERIFY_DIR}/unpacked/Quartz.app/Contents/Info.plist" "${VERIFY_DIR}" <<'PY'
import os, pathlib, plistlib, sys
with open(sys.argv[1], 'rb') as source:
    info = plistlib.load(source)
key = info.get('SUPublicEDKey')
feed = info.get('SUFeedURL')
if not isinstance(key, str) or not isinstance(feed, str):
    sys.exit('error: published app has no update key or feed URL')
if key != os.environ['SPARKLE_PUBLIC_KEY']:
    sys.exit('error: published app does not use the configured trusted public key')
pathlib.Path(sys.argv[2], 'public-key').write_text(key)
pathlib.Path(sys.argv[2], 'feed-url').write_text(feed)
PY
swift "${ROOT_DIR}/Scripts/verify-update.swift" "${VERIFY_DIR}/unpacked/Quartz.app" \
    "${VERIFY_DIR}/${ARCHIVE_NAME}" "${VERIFY_DIR}/appcast.xml" "${VERSION}" "${DOWNLOAD_PREFIX}${ARCHIVE_NAME}"
if [[ "${2:-}" == --feed ]]; then
    CANONICAL_FEED="https://raw.githubusercontent.com/QuartzBrowser/Quartz/update-feed/appcast.xml"
    "${ROOT_DIR}/Scripts/wait-for-channel-feed.sh" "${VERIFY_DIR}/appcast.xml" "${VERIFY_DIR}/current.xml" \
        "${VERSION}" "$(cat "${VERIFY_DIR}/public-key")" "${CANONICAL_FEED}"
    # The first channel-aware release migrates old installations. Verify their
    # bundled legacy route too, but never mistake it for the newly activated URL.
    BUNDLED_FEED="$(cat "${VERIFY_DIR}/feed-url")"
    if [[ "${BUNDLED_FEED}" != "${CANONICAL_FEED}" ]]; then
        "${ROOT_DIR}/Scripts/wait-for-channel-feed.sh" "${VERIFY_DIR}/appcast.xml" "${VERIFY_DIR}/legacy.xml" \
            "${VERSION}" "$(cat "${VERIFY_DIR}/public-key")" "${BUNDLED_FEED}"
    fi
fi
echo "Verified public archive, signed feed, checksums, and update metadata."
