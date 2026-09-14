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
TEST_UPDATE_PRIVATE_KEY="$(cat "${TEST_DIR}/private-key")"
unset SPARKLE_PRIVATE_KEY
export SPARKLE_PUBLIC_KEY="$(cat "${TEST_DIR}/public-key")"
export SIGN_IDENTITY=-
# This fixture may test the updater with the explicit system development build;
# prepare-release otherwise requires fork products even when system mode is set.
export QUARTZ_TEST_SYSTEM_RELEASE=1
unset APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_KEY_PATH NOTARY_KEYCHAIN_PROFILE

cat > "${TEST_DIR}/bootstrap.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Quartz test updates</title></channel></rss>
XML
"${SPARKLE_TOOLS}/sign_update" --ed-key-file "${TEST_DIR}/private-key" "${TEST_DIR}/bootstrap.xml"

export PREVIOUS_APPCAST_FILE="${TEST_DIR}/bootstrap.xml"
export DIST_DIR="${TEST_DIR}/first"
SPARKLE_PRIVATE_KEY="${TEST_UPDATE_PRIVATE_KEY}" Scripts/prepare-release.sh 1.0.1 > "${TEST_DIR}/first.log" 2>&1
FIRST_APP="${DIST_DIR}/release-bundle/Quartz.app"
FIRST_ARCHIVE="${DIST_DIR}/release/Quartz-v1.0.1-macos-universal.zip"
FIRST_FEED="${DIST_DIR}/release/appcast.xml"
DOWNLOAD_URL="https://github.com/QuartzBrowser/Quartz/releases/download/v1.0.1/Quartz-v1.0.1-macos-universal.zip"
codesign --verify --deep --strict "${FIRST_APP}"
xcrun lipo "${FIRST_APP}/Contents/MacOS/Quartz" -verify_arch arm64 x86_64
"${SPARKLE_TOOLS}/sign_update" --ed-key-file "${TEST_DIR}/private-key" --verify "${FIRST_FEED}"
Scripts/verify-update.swift "${FIRST_APP}" "${FIRST_ARCHIVE}" "${FIRST_FEED}" 1.0.1 "${DOWNLOAD_URL}"

# Recreate the published v1.0.1 metadata shape to verify migration from bundles
# that have no QuartzReleaseVersion/Channel and use the semantic version as the
# numeric build. Re-sign this disposable app/archive/feed after changing it.
python3 - "${FIRST_APP}/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as source:
    info = plistlib.load(source)
info.pop('QuartzReleaseVersion')
info.pop('QuartzReleaseChannel')
info['CFBundleVersion'] = '1.0.1'
info['SUFeedURL'] = 'https://github.com/QuartzBrowser/Quartz/releases/latest/download/appcast.xml'
with open(path, 'wb') as target:
    plistlib.dump(info, target)
PY
codesign --force --sign - "${FIRST_APP}"
codesign --verify --deep --strict "${FIRST_APP}"
rm "${FIRST_ARCHIVE}"
ditto -c -k --norsrc --keepParent "${FIRST_APP}" "${FIRST_ARCHIVE}"
"${SPARKLE_TOOLS}/sign_update" --ed-key-file "${TEST_DIR}/private-key" "${FIRST_ARCHIVE}" > "${TEST_DIR}/legacy-signature.txt"
python3 - "${FIRST_FEED}" "${TEST_DIR}/legacy-signature.txt" <<'PY'
import pathlib, re, sys, xml.etree.ElementTree as ET
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
tree = ET.parse(sys.argv[1])
items = tree.findall('./channel/item')
assert len(items) == 1
items[0].find(f'{{{ns}}}version').text = '1.0.1'
signature = pathlib.Path(sys.argv[2]).read_text()
enclosure = items[0].find('enclosure')
enclosure.set(f'{{{ns}}}edSignature', re.search(r'edSignature="([^"]+)"', signature)[1])
enclosure.set('length', re.search(r'length="([0-9]+)"', signature)[1])
tree.write(sys.argv[1], encoding='utf-8', xml_declaration=True)
PY
"${SPARKLE_TOOLS}/sign_update" --ed-key-file "${TEST_DIR}/private-key" "${FIRST_FEED}"
Scripts/verify-update.swift "${FIRST_APP}" "${FIRST_ARCHIVE}" "${FIRST_FEED}" 1.0.1 "${DOWNLOAD_URL}"
echo "Passed modern stable packaging and signed legacy v1.0.1 migration fixture."

python3 - "${FIRST_ARCHIVE}" "${TEST_DIR}/damaged.zip" "${FIRST_FEED}" "${TEST_DIR}/damaged.xml" <<'PY'
import pathlib, sys
archive = bytearray(pathlib.Path(sys.argv[1]).read_bytes())
archive[len(archive) // 2] ^= 1
pathlib.Path(sys.argv[2]).write_bytes(archive)
feed = pathlib.Path(sys.argv[3]).read_bytes()
assert b'1.0.1' in feed
pathlib.Path(sys.argv[4]).write_bytes(feed.replace(b'1.0.1', b'1.0.9', 1))
PY
if Scripts/verify-update.swift "${FIRST_APP}" "${TEST_DIR}/damaged.zip" "${FIRST_FEED}" 1.0.1 "${DOWNLOAD_URL}" > "${TEST_DIR}/damaged-archive.log" 2>&1; then
    echo "error: a damaged archive was accepted" >&2
    exit 1
fi
if "${SPARKLE_TOOLS}/sign_update" --ed-key-file "${TEST_DIR}/private-key" --verify "${TEST_DIR}/damaged.xml" > "${TEST_DIR}/damaged-feed.log" 2>&1; then
    echo "error: a modified appcast was accepted" >&2
    exit 1
fi
if Scripts/verify-update.swift "${FIRST_APP}" "${FIRST_ARCHIVE}" "${TEST_DIR}/damaged.xml" 1.0.1 "${DOWNLOAD_URL}" > "${TEST_DIR}/public-feed-tamper.log" 2>&1; then
    echo "error: public-key verification accepted a modified appcast" >&2
    exit 1
fi

# Generate two real beta packages and then the same line's stable package. Each
# stage carries the complete mixed-channel feed; beta publication must leave the
# legacy/default entry intact so stable installations cannot select a beta.
export PREVIOUS_APPCAST_FILE="${FIRST_FEED}"
for version in 1.1.0-beta.1 1.1.0-beta.2 1.1.0; do
    export DIST_DIR="${TEST_DIR}/${version}"
    SPARKLE_PRIVATE_KEY="${TEST_UPDATE_PRIVATE_KEY}" Scripts/prepare-release.sh "${version}" > "${TEST_DIR}/${version}.log" 2>&1
    "${SPARKLE_TOOLS}/sign_update" --ed-key-file "${TEST_DIR}/private-key" --verify "${DIST_DIR}/release/appcast.xml"
    python3 - "${DIST_DIR}/release/appcast.xml" "${version}" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}
items = ET.parse(sys.argv[1]).findall('./channel/item')
entries = {item.findtext('sparkle:shortVersionString', namespaces=ns): item for item in items}
expected = ['1.0.1', '1.1.0-beta.1']
if sys.argv[2] != '1.1.0-beta.1':
    expected.append('1.1.0-beta.2')
if sys.argv[2] == '1.1.0':
    expected.append('1.1.0')
assert set(entries) == set(expected), (entries.keys(), expected)
assert len(items) == len(expected), len(items)
stable = []
for label, item in entries.items():
    channel = item.findtext('sparkle:channel', namespaces=ns)
    assert channel == ('beta' if '-beta.' in label else None), (label, channel)
    if channel is None:
        stable.append(label)
assert set(stable) == ({'1.0.1', '1.1.0'} if sys.argv[2] == '1.1.0' else {'1.0.1'}), stable
PY
    export PREVIOUS_APPCAST_FILE="${DIST_DIR}/release/appcast.xml"
    echo "Passed ${version}: signed package, full display label, channel isolation, retained history."
done

# Every previous archive remains publicly verifiable against the final feed.
for version in 1.1.0-beta.1 1.1.0-beta.2 1.1.0; do
    Scripts/verify-update.swift "${TEST_DIR}/${version}/release-bundle/Quartz.app" \
        "${TEST_DIR}/${version}/release/Quartz-v${version}-macos-universal.zip" \
        "${PREVIOUS_APPCAST_FILE}" "${version}" \
        "https://github.com/QuartzBrowser/Quartz/releases/download/v${version}/Quartz-v${version}-macos-universal.zip"
done
Scripts/verify-update.swift "${FIRST_APP}" "${FIRST_ARCHIVE}" "${PREVIOUS_APPCAST_FILE}" 1.0.1 "${DOWNLOAD_URL}"

# A valid feed signature cannot excuse putting a beta on the stable channel or
# hiding its beta label. Re-sign both malformed fixtures with the disposable key.
for mutation in channel label; do
    python3 - "${PREVIOUS_APPCAST_FILE}" "${TEST_DIR}/${mutation}.xml" "${mutation}" <<'PY'
import sys, xml.etree.ElementTree as ET
ns = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', ns)
tree = ET.parse(sys.argv[1])
entry = next(item for item in tree.findall('./channel/item') if item.findtext(f'{{{ns}}}shortVersionString') == '1.1.0-beta.2')
if sys.argv[3] == 'channel':
    entry.remove(entry.find(f'{{{ns}}}channel'))
else:
    entry.find(f'{{{ns}}}shortVersionString').text = '1.1.0'
tree.write(sys.argv[2], encoding='utf-8', xml_declaration=True)
PY
    "${SPARKLE_TOOLS}/sign_update" --ed-key-file "${TEST_DIR}/private-key" "${TEST_DIR}/${mutation}.xml"
    if Scripts/verify-update.swift "${TEST_DIR}/1.1.0-beta.2/release-bundle/Quartz.app" \
        "${TEST_DIR}/1.1.0-beta.2/release/Quartz-v1.1.0-beta.2-macos-universal.zip" \
        "${TEST_DIR}/${mutation}.xml" 1.1.0-beta.2 \
        "https://github.com/QuartzBrowser/Quartz/releases/download/v1.1.0-beta.2/Quartz-v1.1.0-beta.2-macos-universal.zip" \
        > "${TEST_DIR}/wrong-${mutation}.log" 2>&1; then
        echo "error: signed feed with incorrect beta ${mutation} was accepted" >&2
        exit 1
    fi
done

if env -u SPARKLE_PRIVATE_KEY Scripts/prepare-release.sh 1.1.1 > "${TEST_DIR}/missing-key.log" 2>&1; then
    echo "error: release preparation accepted a missing signing key" >&2
    exit 1
fi
unset TEST_UPDATE_PRIVATE_KEY
echo "Passed: universal packages, legacy migration, beta-to-beta-to-stable, stable isolation, signed history, tamper/channel/label rejection, and missing-key rejection."
