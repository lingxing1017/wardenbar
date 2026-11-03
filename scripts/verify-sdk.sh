#!/bin/bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
    printf 'Usage: %s <executable> <minimum-macos> <sdk-version>\n' "$0" >&2
    exit 2
fi

build_info="$(xcrun vtool -show-build "$1")"
actual_platform="$(awk '$1 == "platform" { print $2 }' <<< "$build_info")"
actual_minimum="$(awk '$1 == "minos" { print $2 }' <<< "$build_info")"
actual_sdk="$(awk '$1 == "sdk" { print $2 }' <<< "$build_info")"

if [[ "$actual_platform" != "MACOS" || "$actual_minimum" != "$2" || "$actual_sdk" != "$3" ]]; then
    printf 'Build version mismatch: platform=%s minimum=%s sdk=%s; expected MACOS %s %s\n' \
        "$actual_platform" "$actual_minimum" "$actual_sdk" "$2" "$3" >&2
    exit 1
fi

printf 'Build versions verified: minimum macOS %s, SDK %s\n' "$actual_minimum" "$actual_sdk"
