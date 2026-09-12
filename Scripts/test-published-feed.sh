#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="${ROOT_DIR}/Scripts/wait-for-published-feed.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "${TEST_DIR}"' EXIT
mkdir "${TEST_DIR}/bin"
export FEED_TEST_DIR="${TEST_DIR}"
export PATH="${TEST_DIR}/bin:${PATH}"
printf '%s\n' '<rss>expected signed release feed</rss>' > "${TEST_DIR}/expected.xml"
printf '%s\n' '<rss>previous signed release feed</rss>' > "${TEST_DIR}/stale.xml"
printf '%s\n' 'existing output must survive unsuccessful verification' > "${TEST_DIR}/original-output"

# These fixtures reject altered URLs/options and never perform network I/O or wait.
cat > "${TEST_DIR}/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=""
connect_timeout=""
max_time=""
write_out=""
url=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --fail|--silent|--show-error|--location) shift ;;
        --output) output="$2"; shift 2 ;;
        --connect-timeout) connect_timeout="$2"; shift 2 ;;
        --max-time) max_time="$2"; shift 2 ;;
        --write-out) write_out="$2"; shift 2 ;;
        https://*) url="$1"; shift ;;
        *) echo "unexpected curl argument: $1" > "${FEED_TEST_DIR}/fixture-error"; exit 99 ;;
    esac
done
if [[ "${url}" != "https://github.com/QuartzBrowser/Quartz/releases/latest/download/appcast.xml" \
    || "${connect_timeout}" != "10" || "${max_time}" != "30" || "${write_out}" != '%{http_code}' || -z "${output}" ]]; then
    echo "incorrect canonical URL, timeout, or output options" > "${FEED_TEST_DIR}/fixture-error"
    exit 99
fi
count="$(cat "${FEED_TEST_DIR}/calls")"
count=$((count + 1))
printf '%s\n' "${count}" > "${FEED_TEST_DIR}/calls"
case "${FEED_TEST_SCENARIO}" in
    match) cp "${FEED_TEST_DIR}/expected.xml" "${output}"; printf '200' ;;
    stale_then_match)
        if (( count < 3 )); then cp "${FEED_TEST_DIR}/stale.xml" "${output}"
        else cp "${FEED_TEST_DIR}/expected.xml" "${output}"; fi
        printf '200' ;;
    failed_partial_then_match)
        if (( count == 1 )); then
            cp "${FEED_TEST_DIR}/expected.xml" "${output}"
            printf '000'
            exit 18
        elif (( count == 2 )); then
            # Success with no output must not reuse the failed attempt's matching bytes.
            printf '200'
        else cp "${FEED_TEST_DIR}/expected.xml" "${output}"; printf '200'; fi ;;
    network_then_match)
        if (( count == 1 )); then printf '<partial' > "${output}"; printf '000'; exit 7
        else cp "${FEED_TEST_DIR}/expected.xml" "${output}"; printf '200'; fi ;;
    stale) cp "${FEED_TEST_DIR}/stale.xml" "${output}"; printf '200' ;;
    http_error) cp "${FEED_TEST_DIR}/expected.xml" "${output}"; printf '503'; exit 22 ;;
    other_status) cp "${FEED_TEST_DIR}/expected.xml" "${output}"; printf '201' ;;
    *) echo "unknown curl fixture scenario" > "${FEED_TEST_DIR}/fixture-error"; exit 99 ;;
esac
SH
cat > "${TEST_DIR}/bin/sleep" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "${FEED_TEST_DIR}/sleeps"
SH
chmod +x "${TEST_DIR}/bin/curl" "${TEST_DIR}/bin/sleep"

fail() {
    echo "FAIL: $*" >&2
    cat "${TEST_DIR}/log" >&2
    exit 1
}

reset_fixture() {
    export FEED_TEST_SCENARIO="$1"
    printf '0\n' > "${TEST_DIR}/calls"
    : > "${TEST_DIR}/sleeps"
    : > "${TEST_DIR}/log"
    rm -f "${TEST_DIR}/fixture-error"
    cp "${TEST_DIR}/original-output" "${TEST_DIR}/output.xml"
}

assert_counts() {
    [[ ! -e "${TEST_DIR}/fixture-error" ]] || fail "$(cat "${TEST_DIR}/fixture-error")"
    [[ "$(cat "${TEST_DIR}/calls")" == "$1" ]] || fail "unexpected curl count"
    local sleeps
    sleeps="$(wc -l < "${TEST_DIR}/sleeps" | tr -d ' ')"
    [[ "${sleeps}" == "$2" ]] || fail "unexpected sleep count"
}

expect_success() {
    reset_fixture "$1"
    if ! LATEST_FEED_ATTEMPTS=4 LATEST_FEED_RETRY_DELAY=0 "${HELPER}" \
        "${TEST_DIR}/expected.xml" "${TEST_DIR}/output.xml" > "${TEST_DIR}/log" 2>&1; then
        fail "$1 should succeed"
    fi
    cmp -s "${TEST_DIR}/expected.xml" "${TEST_DIR}/output.xml" || fail "$1 output differs"
    assert_counts "$2" "$3"
}

expect_exhaustion() {
    reset_fixture "$1"
    if LATEST_FEED_ATTEMPTS="$2" LATEST_FEED_RETRY_DELAY=0 "${HELPER}" \
        "${TEST_DIR}/expected.xml" "${TEST_DIR}/output.xml" > "${TEST_DIR}/log" 2>&1; then
        fail "$1 should fail"
    fi
    assert_counts "$2" "$3"
    cmp -s "${TEST_DIR}/original-output" "${TEST_DIR}/output.xml" || fail "unsuccessful download replaced output"
    [[ "$(cat "${TEST_DIR}/log")" == *"failed after $2 attempts"* ]] || fail "missing exhaustion diagnostic"
}

expect_success match 1 0
expect_success stale_then_match 3 2
expect_success failed_partial_then_match 3 2
expect_success network_then_match 2 1
expect_exhaustion stale 3 2
expect_exhaustion http_error 3 2
expect_exhaustion other_status 3 2
expect_exhaustion stale 1 0

# Unset overrides use the documented bounded defaults, including no final sleep.
reset_fixture stale
if (unset LATEST_FEED_ATTEMPTS LATEST_FEED_RETRY_DELAY; "${HELPER}" \
    "${TEST_DIR}/expected.xml" "${TEST_DIR}/output.xml") > "${TEST_DIR}/log" 2>&1; then
    fail "default retries should exhaust"
fi
assert_counts 12 11
while IFS= read -r delay; do [[ "${delay}" == "10" ]] || fail "incorrect default retry delay"; done < "${TEST_DIR}/sleeps"

for invalid in '' 0 -1 01 61 999999999999999999999999999 1.5 two; do
    reset_fixture match
    if LATEST_FEED_ATTEMPTS="${invalid}" LATEST_FEED_RETRY_DELAY=0 "${HELPER}" \
        "${TEST_DIR}/expected.xml" "${TEST_DIR}/output.xml" > "${TEST_DIR}/log" 2>&1; then
        fail "invalid attempt limit was accepted: '${invalid}'"
    fi
    assert_counts 0 0
done
for invalid in '' -1 01 61 999999999999999999999999999 0.5 two; do
    reset_fixture match
    if LATEST_FEED_ATTEMPTS=1 LATEST_FEED_RETRY_DELAY="${invalid}" "${HELPER}" \
        "${TEST_DIR}/expected.xml" "${TEST_DIR}/output.xml" > "${TEST_DIR}/log" 2>&1; then
        fail "invalid retry delay was accepted: '${invalid}'"
    fi
    assert_counts 0 0
done

for expected in "${TEST_DIR}/missing.xml" "${TEST_DIR}/empty.xml"; do
    reset_fixture match
    : > "${TEST_DIR}/empty.xml"
    if LATEST_FEED_ATTEMPTS=1 LATEST_FEED_RETRY_DELAY=0 "${HELPER}" \
        "${expected}" "${TEST_DIR}/output.xml" > "${TEST_DIR}/log" 2>&1; then
        fail "missing or empty expected feed was accepted"
    fi
    assert_counts 0 0
done

echo "Published-feed retry fixtures passed (no network requests or real sleeps)."
