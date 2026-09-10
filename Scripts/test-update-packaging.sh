#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/quartz-update-test.XXXXXX")"
cleanup() {
    if [[ $? == 0 ]]; then
        rm -rf "${TEST_DIR}"
    else
        echo "Update test failed; diagnostics retained in ${TEST_DIR}" >&2
    fi
}
trap cleanup EXIT
cd "${ROOT_DIR}"
swift package resolve
SPARKLE_TOOLS="${ROOT_DIR}/.build/artifacts/sparkle/Sparkle/bin"

# Use disposable keys. Never access or overwrite a maintainer's Keychain key.
swift - "${TEST_DIR}" <<'SWIFT'
import CryptoKit
import Foundation
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let key = Curve25519.Signing.PrivateKey()
try key.rawRepresentation.base64EncodedData().write(to: directory.appendingPathComponent("private-key"))
try key.publicKey.rawRepresentation.base64EncodedData().write(to: directory.appendingPathComponent("public-key"))
try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("private-key").path)
SWIFT
export SPARKLE_PRIVATE_KEY="$(cat "${TEST_DIR}/private-key")"
export SPARKLE_PUBLIC_KEY="$(cat "${TEST_DIR}/public-key")"
export SIGN_IDENTITY=-
unset APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_PATH NOTARY_KEYCHAIN_PROFILE

cat > "${TEST_DIR}/bootstrap.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Quartz test updates</title></channel></rss>
XML
"${SPARKLE_TOOLS}/sign_update" --ed-key-file "${TEST_DIR}/private-key" "${TEST_DIR}/bootstrap.xml"

export PREVIOUS_APPCAST_FILE="${TEST_DIR}/bootstrap.xml"
export DIST_DIR="${TEST_DIR}/first"
Scripts/prepare-release.sh 9.8.7 > "${TEST_DIR}/first.log" 2>&1
FIRST_APP="${DIST_DIR}/release-bundle/Quartz.app"
FIRST_ARCHIVE="${DIST_DIR}/release/Quartz-v9.8.7-macos-universal.zip"
FIRST_FEED="${DIST_DIR}/release/appcast.xml"
DOWNLOAD_URL="https://github.com/QuartzBrowser/Quartz/releases/download/v9.8.7/Quartz-v9.8.7-macos-universal.zip"
codesign --verify --deep --strict "${FIRST_APP}"
xcrun lipo "${FIRST_APP}/Contents/MacOS/Quartz" -verify_arch arm64 x86_64
"${SPARKLE_TOOLS}/sign_update" --ed-key-file "${TEST_DIR}/private-key" --verify "${FIRST_FEED}"
Scripts/verify-update.swift "${FIRST_APP}" "${FIRST_ARCHIVE}" "${FIRST_FEED}" 9.8.7 "${DOWNLOAD_URL}"

python3 - "${FIRST_ARCHIVE}" "${TEST_DIR}/damaged.zip" "${FIRST_FEED}" "${TEST_DIR}/damaged.xml" <<'PY'
import pathlib, sys
archive = bytearray(pathlib.Path(sys.argv[1]).read_bytes())
archive[len(archive) // 2] ^= 1
pathlib.Path(sys.argv[2]).write_bytes(archive)
feed = pathlib.Path(sys.argv[3]).read_bytes()
assert b'9.8.7' in feed
pathlib.Path(sys.argv[4]).write_bytes(feed.replace(b'9.8.7', b'9.8.9', 1))
PY
if Scripts/verify-update.swift "${FIRST_APP}" "${TEST_DIR}/damaged.zip" "${FIRST_FEED}" 9.8.7 "${DOWNLOAD_URL}" > "${TEST_DIR}/damaged-archive.log" 2>&1; then
    echo "error: a damaged archive was accepted" >&2
    exit 1
fi
if "${SPARKLE_TOOLS}/sign_update" --ed-key-file "${TEST_DIR}/private-key" --verify "${TEST_DIR}/damaged.xml" > "${TEST_DIR}/damaged-feed.log" 2>&1; then
    echo "error: a modified appcast was accepted" >&2
    exit 1
fi

# A second release must retain the prior signed download for older supported Macs.
export PREVIOUS_APPCAST_FILE="${FIRST_FEED}"
export DIST_DIR="${TEST_DIR}/second"
Scripts/prepare-release.sh 9.8.8 > "${TEST_DIR}/second.log" 2>&1
python3 - "${DIST_DIR}/release/appcast.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
versions = [item.findtext('sparkle:version', namespaces=ns) for item in ET.parse(sys.argv[1]).findall('./channel/item')]
assert versions.count('9.8.7') == 1 and versions.count('9.8.8') == 1, versions
PY
"${SPARKLE_TOOLS}/sign_update" --ed-key-file "${TEST_DIR}/private-key" --verify "${DIST_DIR}/release/appcast.xml"

if env -u SPARKLE_PRIVATE_KEY Scripts/prepare-release.sh 9.8.9 > "${TEST_DIR}/missing-key.log" 2>&1; then
    echo "error: release preparation accepted a missing signing key" >&2
    exit 1
fi
echo "Passed: universal package, signed archive/feed, tamper rejection, retained releases, and missing-key rejection."
