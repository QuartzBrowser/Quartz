#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "usage: wait-for-published-feed.sh EXPECTED_FEED OUTPUT_FILE" >&2
    exit 1
fi
EXPECTED_FEED="$1"
OUTPUT_FILE="$2"
ATTEMPTS="${LATEST_FEED_ATTEMPTS-12}"
RETRY_DELAY="${LATEST_FEED_RETRY_DELAY-10}"
LATEST_URL="https://github.com/QuartzBrowser/Quartz/releases/latest/download/appcast.xml"

if [[ ! "${ATTEMPTS}" =~ ^[1-9][0-9]?$ ]] || (( ATTEMPTS > 60 )); then
    echo "error: LATEST_FEED_ATTEMPTS must be an integer from 1 to 60" >&2
    exit 1
fi
if [[ ! "${RETRY_DELAY}" =~ ^(0|[1-9][0-9]?)$ ]] || (( RETRY_DELAY > 60 )); then
    echo "error: LATEST_FEED_RETRY_DELAY must be an integer from 0 to 60 seconds" >&2
    exit 1
fi
if [[ ! -f "${EXPECTED_FEED}" || ! -r "${EXPECTED_FEED}" || ! -s "${EXPECTED_FEED}" ]]; then
    echo "error: expected release feed must be a readable, nonempty file: ${EXPECTED_FEED}" >&2
    exit 1
fi
if [[ -d "${OUTPUT_FILE}" ]]; then
    echo "error: latest feed output must be a file: ${OUTPUT_FILE}" >&2
    exit 1
fi

ATTEMPT_DIR="$(mktemp -d)"
trap 'rm -rf "${ATTEMPT_DIR}"' EXIT
CANDIDATE="${ATTEMPT_DIR}/latest.xml"
LAST_FAILURE=""

for (( attempt = 1; attempt <= ATTEMPTS; attempt++ )); do
    # A failed curl may leave partial bytes. Never compare them or reuse a prior attempt.
    rm -f "${CANDIDATE}"
    if HTTP_STATUS="$(curl --fail --silent --show-error --location \
        --connect-timeout 10 --max-time 30 --write-out '%{http_code}' \
        "${LATEST_URL}" --output "${CANDIDATE}")"; then
        if [[ "${HTTP_STATUS}" == "200" ]] && cmp -s "${EXPECTED_FEED}" "${CANDIDATE}"; then
            mv "${CANDIDATE}" "${OUTPUT_FILE}"
            echo "Latest feed matches the expected release feed (attempt ${attempt}/${ATTEMPTS})."
            exit 0
        fi
        if [[ "${HTTP_STATUS}" == "200" ]]; then
            LAST_FAILURE="HTTP 200 content does not match the expected release feed"
        else
            LAST_FAILURE="unexpected HTTP status ${HTTP_STATUS}"
        fi
    else
        LAST_FAILURE="latest-feed download failed (HTTP ${HTTP_STATUS:-unknown})"
    fi

    if (( attempt < ATTEMPTS )); then
        echo "Latest feed not ready (attempt ${attempt}/${ATTEMPTS}): ${LAST_FAILURE}; retrying in ${RETRY_DELAY}s." >&2
        sleep "${RETRY_DELAY}"
    fi
done

echo "error: latest-feed verification failed after ${ATTEMPTS} attempts: ${LAST_FAILURE}." >&2
echo "error: ${LATEST_URL} must match the expected release feed byte-for-byte." >&2
exit 1
