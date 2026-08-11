#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
TEST_BUILD="$ROOT/.build/tests"
MODULE_CACHE="$ROOT/.build/swift-module-cache"
NODE_BIN="${NODE_BIN:-node}"
mkdir -p "$TEST_BUILD" "$MODULE_CACHE"

swift build --package-path "$ROOT" -c release
/bin/zsh "$ROOT/Scripts/build-mac.sh"
/bin/zsh "$ROOT/Scripts/build-ios-simulator.sh"

plutil -lint "$ROOT/CodexRemoteIOS/Info.plist" "$ROOT/CodexRemoteMac/Info.plist"
for test_file in "$ROOT"/Tests/*.mjs; do
  "$NODE_BIN" --check "$test_file"
done
"$NODE_BIN" "$ROOT/Tests/mobile-interrupt-fallback-regression.mjs"
"$NODE_BIN" "$ROOT/Tests/companion-turn-reconciliation-regression.mjs"
"$NODE_BIN" "$ROOT/Tests/desktop-ipc-refresh-regression.mjs"

xcrun swiftc -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/CodexRemoteShared/RemoteProtocol.swift" \
  "$ROOT/Sources/CodexRemoteShared/ComposerDraftState.swift" \
  "$ROOT/Tests/composer-draft-state-regression.swift" \
  -o "$TEST_BUILD/composer-draft-state-regression"
"$TEST_BUILD/composer-draft-state-regression"

xcrun swiftc -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/CodexRemoteShared/RemoteProtocol.swift" \
  "$ROOT/Sources/CodexRemoteShared/ComposerDraftState.swift" \
  "$ROOT/Tests/mobile-recovery-state-regression.swift" \
  -o "$TEST_BUILD/mobile-recovery-state-regression"
"$TEST_BUILD/mobile-recovery-state-regression"

xcrun swiftc -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/CodexRemoteShared/RemoteProtocol.swift" \
  "$ROOT/Sources/CodexRemoteShared/ComposerDraftState.swift" \
  "$ROOT/Tests/shared-policy-regression.swift" \
  -o "$TEST_BUILD/shared-policy-regression"
"$TEST_BUILD/shared-policy-regression"

xcrun swiftc -parse-as-library -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/CodexRemoteMac/DesktopIPCRequestCoordinator.swift" \
  "$ROOT/Tests/desktop-ipc-history-request-regression.swift" \
  -o "$TEST_BUILD/desktop-ipc-history-request-regression"
"$TEST_BUILD/desktop-ipc-history-request-regression"

xcrun swiftc -parse-as-library -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/CodexRemoteMac/DesktopIPCRequestCoordinator.swift" \
  "$ROOT/Tests/desktop-history-recovery-policy-regression.swift" \
  -o "$TEST_BUILD/desktop-history-recovery-policy-regression"
"$TEST_BUILD/desktop-history-recovery-policy-regression"

xcrun swiftc -parse-as-library -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/CodexRemoteMac/DesktopGlobalStateStore.swift" \
  "$ROOT/Tests/desktop-global-state-store-regression.swift" \
  -o "$TEST_BUILD/desktop-global-state-store-regression"
"$TEST_BUILD/desktop-global-state-store-regression"

xcrun swiftc -module-cache-path "$MODULE_CACHE" \
  "$ROOT/Sources/CodexRemoteShared/RemoteProtocol.swift" \
  "$ROOT/Tests/speech-input-restart-regression.swift" \
  -o "$TEST_BUILD/speech-input-restart-regression"
"$TEST_BUILD/speech-input-restart-regression"

echo "All offline checks passed."
