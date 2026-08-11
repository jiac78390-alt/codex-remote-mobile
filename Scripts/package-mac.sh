#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DERIVED_DATA="${CODEX_REMOTE_DERIVED_DATA:-$ROOT/.build/xcode/mac}"
DIST="${CODEX_REMOTE_DIST:-$ROOT/dist}"
SOURCE_APP="$DERIVED_DATA/Build/Products/Release/CodexRemoteMac.app"
ARCHIVE="$DIST/CodexRemoteMac-v0.12.0.zip"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-remote-package.XXXXXX")"
PACKAGE_APP="$STAGING_ROOT/CodexRemoteMac.app"
STAGED_ARCHIVE="$STAGING_ROOT/CodexRemoteMac-v0.12.0.zip"
trap 'rm -rf "$STAGING_ROOT"' EXIT

/bin/zsh "$ROOT/Scripts/build-mac.sh"
mkdir -p "$DIST"
rm -f "$ARCHIVE"
cp -R -X "$SOURCE_APP" "$PACKAGE_APP"
codesign --force --deep --sign - "$PACKAGE_APP"
codesign --verify --deep --strict "$PACKAGE_APP"
ditto --norsrc -c -k --keepParent "$PACKAGE_APP" "$STAGED_ARCHIVE"
unzip -t "$STAGED_ARCHIVE"
if unzip -Z1 "$STAGED_ARCHIVE" | grep -qE '(^|/)\._'; then
  echo "Archive contains AppleDouble metadata" >&2
  exit 1
fi
mkdir "$STAGING_ROOT/verify"
ditto -x -k "$STAGED_ARCHIVE" "$STAGING_ROOT/verify"
codesign --verify --deep --strict "$STAGING_ROOT/verify/CodexRemoteMac.app"
mv "$STAGED_ARCHIVE" "$ARCHIVE"
shasum -a 256 "$ARCHIVE"
