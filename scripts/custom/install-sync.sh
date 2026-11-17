#!/bin/bash
# Installs the daily upstream sync and rebuild (custom-sync.plist) for this checkout.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
PLIST="$HOME/Library/LaunchAgents/dev.yab.custom-sync.plist"
sed "s#__REPO__#$REPO#g" "$REPO/scripts/custom/custom-sync.plist" > "$PLIST"
launchctl bootout "gui/$(id -u)/dev.yab.custom-sync" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: daily at 4:30, log $REPO/build/sync.log"
