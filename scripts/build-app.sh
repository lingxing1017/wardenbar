#!/bin/bash
set -euo pipefail

app_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$app_root"
# Source once in this build shell. Failure stops before building.
source .superpowers/sdd/env.sh

build_sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
build_sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
minimum_macos="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' App/Info.plist)"

# Swift Build can compile against the current SDK while linking an old SDK marker.
# Specify the actual SDK separately from the application's deployment target.
swift build -c release --product WardenBar -debug-info-format none \
    --sdk "$build_sdk_path" \
    -Xlinker -platform_version -Xlinker macos \
    -Xlinker "$minimum_macos" -Xlinker "$build_sdk_version" \
    --disable-sandbox --cache-path .build/package-cache \
    --config-path .build/package-config --security-path .build/package-security

scripts/verify-sdk.sh .build/release/WardenBar "$minimum_macos" "$build_sdk_version"

app_bundle="$app_root/.build/WardenBar.app"
icon_build="$app_root/.build/app-icon"
mkdir -p "$app_bundle/Contents/MacOS" "$app_bundle/Contents/Resources" "$icon_build"
cp .build/release/WardenBar "$app_bundle/Contents/MacOS/WardenBar"
cp App/Info.plist "$app_bundle/Contents/Info.plist"
cp -R .build/release/WardenBar_WardenBarApp.bundle "$app_bundle/Contents/Resources/"

# Compile appearance variants and the legacy icon using Apple's asset pipeline.
xcrun actool App/WardenBar.icon \
    --compile "$icon_build" \
    --output-format human-readable-text --notices --warnings --errors \
    --app-icon WardenBar --platform macosx --target-device mac \
    --minimum-deployment-target "$minimum_macos" \
    --output-partial-info-plist "$icon_build/icon-info.plist"
cp "$icon_build/Assets.car" "$icon_build/WardenBar.icns" "$app_bundle/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Merge \"$icon_build/icon-info.plist\"" "$app_bundle/Contents/Info.plist"

scripts/verify-sdk.sh "$app_bundle/Contents/MacOS/WardenBar" "$minimum_macos" "$build_sdk_version"
codesign --force --sign - --timestamp=none "$app_bundle"
codesign --verify --deep --strict "$app_bundle"
printf '%s\n' "$app_bundle"
