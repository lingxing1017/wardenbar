#!/bin/bash
set -euo pipefail

app_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$app_root"
# Source once in this build shell. Failure stops before building.
source .superpowers/sdd/env.sh

swift build -c release --product WardenBar -debug-info-format none \
    --disable-sandbox --cache-path .build/package-cache \
    --config-path .build/package-config --security-path .build/package-security

app_bundle="$app_root/.build/WardenBar.app"
mkdir -p "$app_bundle/Contents/MacOS"
cp .build/release/WardenBar "$app_bundle/Contents/MacOS/WardenBar"
cp App/Info.plist "$app_bundle/Contents/Info.plist"
codesign --force --sign - --timestamp=none "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
printf '%s\n' "$app_bundle"
