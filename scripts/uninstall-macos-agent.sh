#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$HOME/Applications/SamsungSwitch.app"
PLIST_PATH="$HOME/Library/LaunchAgents/com.samsungswitch.macos.plist"
USER_UID="$(id -u)"

echo "Stopping LaunchAgent com.samsungswitch.macos..."
launchctl bootout "gui/$USER_UID" "$PLIST_PATH" 2>/dev/null || true

if [[ -f "$PLIST_PATH" ]]; then
    rm -f "$PLIST_PATH"
    echo "Removed $PLIST_PATH"
fi

if [[ -d "$APP_DIR" ]]; then
    rm -rf "$APP_DIR"
    echo "Removed $APP_DIR"
fi

echo "Uninstalled SamsungSwitch macOS agent."
