#!/bin/bash
# Build EnerG (Debug), install to /Applications, restart energd if registered.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate
xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates build | tail -3
pkill -x EnerG || true
rm -rf /Applications/EnerG.app
ditto build/Build/Products/Debug/EnerG.app /Applications/EnerG.app
if launchctl print system/app.energ.energd >/dev/null 2>&1; then
  echo "restarting energd (sudo)"
  sudo -n launchctl kickstart -k system/app.energ.energd 2>/dev/null || echo "energd not restarted; run: sudo launchctl kickstart -k system/app.energ.energd"
fi
open /Applications/EnerG.app
