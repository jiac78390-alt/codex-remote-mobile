#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
DIST="${CODEX_REMOTE_DIST:-$ROOT/dist}"
ARCHIVE="$DIST/CodexRemoteMac-v0.12.0.zip"
INSTALL_ROOT="${CODEX_REMOTE_INSTALL_ROOT:-$HOME/Applications}"
DESTINATION="$INSTALL_ROOT/CodexRemoteMac.app"
LABEL="io.github.jiac78390-alt.CodexRemoteMac"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$UID"
STAGING_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/codex-remote-install.XXXXXX")"
trap 'rm -rf "$STAGING_ROOT"' EXIT

/bin/zsh "$ROOT/Scripts/package-mac.sh"
ditto -x -k "$ARCHIVE" "$STAGING_ROOT"
SOURCE_APP="$STAGING_ROOT/CodexRemoteMac.app"
mkdir -p "$INSTALL_ROOT" "$HOME/Library/LaunchAgents"
launchctl bootout "$DOMAIN" "$AGENT" >/dev/null 2>&1 || true
rm -rf "$DESTINATION"
ditto "$SOURCE_APP" "$DESTINATION"

cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$DESTINATION/Contents/MacOS/CodexRemoteMac</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
</dict>
</plist>
PLIST

plutil -lint "$AGENT"
launchctl bootstrap "$DOMAIN" "$AGENT"
echo "Installed $DESTINATION"
