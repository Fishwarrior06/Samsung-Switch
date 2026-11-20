#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MACOS_DIR="$REPO_ROOT/macos"
APP_DIR="$HOME/Applications/SamsungSwitch.app"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_PATH="$PLIST_DIR/com.samsungswitch.macos.plist"

echo "Building SamsungSwitch release binary..."
cd "$MACOS_DIR"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)/SamsungSwitch"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "Release binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "Bundling $APP_DIR..."
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$BIN_PATH" "$APP_DIR/Contents/MacOS/SamsungSwitch"
cp "$MACOS_DIR/Sources/App/Info.plist" "$APP_DIR/Contents/Info.plist"
chmod +x "$APP_DIR/Contents/MacOS/SamsungSwitch"

echo "Ad-hoc signing app bundle for stable TCC permissions..."
codesign --force --deep --sign - "$APP_DIR"

echo "Installing LaunchAgent at $PLIST_PATH..."
mkdir -p "$PLIST_DIR"
cat > "$PLIST_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.samsungswitch.macos</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP_DIR/Contents/MacOS/SamsungSwitch</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ProcessType</key>
    <string>Background</string>
</dict>
</plist>
EOF

USER_UID="$(id -u)"
launchctl bootout "gui/$USER_UID" "$PLIST_PATH" 2>/dev/null || true
launchctl bootstrap "gui/$USER_UID" "$PLIST_PATH"
echo "Installed and started com.samsungswitch.macos."
