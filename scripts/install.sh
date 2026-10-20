#!/bin/bash
# Build EnerG (Debug), install to /Applications, restart energd if registered.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
mkdir -p build
LOG=build/xcodebuild.log
if ! xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20 || true
  echo "xcodebuild failed; full log: $LOG"
  exit 1
fi
tail -3 "$LOG"
pkill -x EnerG || true
rm -rf /Applications/EnerG.app
ditto build/Build/Products/Debug/EnerG.app /Applications/EnerG.app
if launchctl print system/app.energ.energd >/dev/null 2>&1; then
  echo "restarting energd (sudo)"
  sudo -n launchctl kickstart -k system/app.energ.energd 2>/dev/null || echo "energd not restarted; run: sudo launchctl kickstart -k system/app.energ.energd"
fi
open /Applications/EnerG.app
