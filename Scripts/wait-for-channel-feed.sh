#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -ne 5 ]]; then
    echo "usage: wait-for-channel-feed.sh EXPECTED_FEED OUTPUT_FILE VERSION PUBLIC_KEY FEED_URL" >&2
    exit 1
fi
EXPECTED_FEED="$1"
OUTPUT_FILE="$2"
VERSION="$3"
PUBLIC_KEY="$4"
FEED_URL="$5"
if [[ -d "$OUTPUT_FILE" ]]; then
    echo "error: feed output must be a file" >&2
    exit 1
fi
ATTEMPTS="${CHANNEL_FEED_ATTEMPTS:-36}"
RETRY_DELAY="${CHANNEL_FEED_RETRY_DELAY:-10}"
if [[ ! "$ATTEMPTS" =~ ^[1-9][0-9]?$ ]] || (( ATTEMPTS > 60 )) \
    || [[ ! "$RETRY_DELAY" =~ ^(0|[1-9][0-9]?)$ ]] || (( RETRY_DELAY > 60 )); then
    echo "error: feed attempts must be 1–60 and retry delay 0–60 seconds" >&2
    exit 1
fi
case "$FEED_URL" in
    https://raw.githubusercontent.com/QuartzBrowser/Quartz/update-feed/appcast.xml|https://github.com/QuartzBrowser/Quartz/releases/latest/download/appcast.xml) ;;
    *) echo "error: unrecognized Quartz update feed URL" >&2; exit 1 ;;
esac
python3 "$ROOT_DIR/Scripts/release-version.py" "$VERSION" > /dev/null
swift "$ROOT_DIR/Scripts/verify-feed.swift" "$EXPECTED_FEED" "$PUBLIC_KEY" > /dev/null
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
for (( attempt=1; attempt<=ATTEMPTS; attempt++ )); do
    rm -f "$TEMP_DIR/current.xml"
    if curl --fail --silent --show-error --location --connect-timeout 10 --max-time 30 \
        "$FEED_URL" --output "$TEMP_DIR/current.xml" \
        && python3 "$ROOT_DIR/Scripts/publish-update-feed.py" "$VERSION" --feed "$EXPECTED_FEED" \
            --public-key "$PUBLIC_KEY" --check-feed "$TEMP_DIR/current.xml" > "$TEMP_DIR/check.log" 2>&1; then
        cp "$TEMP_DIR/current.xml" "$OUTPUT_FILE"
        echo "Update feed advertises the verified release (attempt $attempt/$ATTEMPTS)."
        exit 0
    fi
    if (( attempt < ATTEMPTS )); then
        echo "Update feed has not propagated the verified release (attempt $attempt/$ATTEMPTS); retrying in ${RETRY_DELAY}s." >&2
        sleep "$RETRY_DELAY"
    fi
done
echo "error: the public feed did not advertise the verified release after $ATTEMPTS attempts" >&2
exit 1
