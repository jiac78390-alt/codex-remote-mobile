#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED_DATA="${CODEX_REMOTE_DERIVED_DATA:-$ROOT/.build/xcode/mac}"

xcodebuild \
  -quiet \
  -project "$ROOT/CodexRemoteMac.xcodeproj" \
  -scheme CodexRemoteMac \
  -configuration Release \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  build

echo "$DERIVED_DATA/Build/Products/Release/CodexRemoteMac.app"
