#!/bin/bash
# On-device check of MacHardware. Build first as your user:
#   swift build --package-path Packages/EnerGKit --product energ-smoke
# Then: sudo scripts/smoke.sh     (quit AlDente first; watch the MagSafe LED)
# Suspend energd first, or its adapter heal undoes `adapter off`:
#   sudo launchctl kill SIGSTOP system/app.energ.energd     (afterwards: SIGCONT)
set -euo pipefail
cd "$(dirname "$0")/.."
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
BIN=Packages/EnerGKit/.build/debug/energ-smoke
[ -x "$BIN" ] || { echo "build energ-smoke first (see header)"; exit 1; }
S() { "$BIN" "$@"; }

ORIG=$(S get-limit | cut -d' ' -f1)
restore() {
  echo "== restore (limit $ORIG)"
  S adapter on
  S led system
  if [ "$ORIG" = off ]; then
    S limit off
  elif [ "$ORIG" -lt 50 ]; then
    echo "original limit $ORIG is below energ-smoke's 50...100; restoring 50"
    S limit 50
  else
    S limit "$ORIG"
  fi
  S get-limit
}
trap restore EXIT

echo "== baseline (limit $ORIG)"; S status
echo "== adapter off 6s (expect batteryWatts < 0; adapterConnected stays true when plugSensed, false otherwise)"; S adapter off; sleep 6; S status
echo "== adapter on 4s (expect adapterConnected: true, batteryWatts back up)"; S adapter on; sleep 4; S status
for led in off green orange system; do
  echo "== LED $led (watch MagSafe) 3s"; S led "$led"; sleep 3
done
echo "== limit 85 (expect 85)"; S limit 85; S get-limit
echo "== limit 60 (expect 60; 80 means this macOS rejects the override)"; S limit 60; S get-limit
echo "== limit off (expect off)"; S limit off; S get-limit
echo "== done"
