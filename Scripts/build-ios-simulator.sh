#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED_DATA="${CODEX_REMOTE_IOS_DERIVED_DATA:-$ROOT/.build/xcode/ios-simulator}"

xcodebuild \
  -quiet \
  -project "$ROOT/CodexRemoteIOS.xcodeproj" \
  -scheme CodexRemote \
  -configuration Release \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

echo "$DERIVED_DATA/Build/Products/Release-iphonesimulator/CodexRemote.app"
