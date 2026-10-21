#!/bin/bash
# Install or update EnerG from the latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/owittek/EnerG/main/scripts/get.sh | bash
# ENERG_ZIP_URL overrides the download URL (testing).
set -euo pipefail
# main() so a truncated download under `curl | bash` runs nothing
main() {
  URL=${ENERG_ZIP_URL:-https://github.com/owittek/EnerG/releases/latest/download/EnerG.zip}
  APP=/Applications/EnerG.app
  TEAM=XG5GU82KF7

  if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != 1 ]]; then
    echo "EnerG needs an Apple Silicon Mac."
    exit 1
  fi
  if (( $(sw_vers -productVersion | cut -d. -f1) < 27 )); then
    echo "EnerG needs macOS 27 or later."
    exit 1
  fi

  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  echo "Downloading EnerG…"
  curl -fsSL "$URL" -o "$TMP/EnerG.zip"
  ditto -x -k "$TMP/EnerG.zip" "$TMP"
  INFO=$(codesign -dv "$TMP/EnerG.app" 2>&1 || true)
  if ! codesign --verify --deep --strict "$TMP/EnerG.app" 2>/dev/null \
    || ! grep -qx "TeamIdentifier=$TEAM" <<<"$INFO"; then
    echo "The download isn't a valid EnerG build; nothing was changed."
    exit 1
  fi

  pkill -x EnerG || true
  rm -rf "$APP"
  ditto "$TMP/EnerG.app" "$APP"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

  if launchctl print system/app.energ.energd >/dev/null 2>&1; then
    echo "Restarting the EnerG helper (asks for your password)…"
    sudo launchctl kickstart -k system/app.energ.energd \
      || echo "Helper not restarted; run: sudo launchctl kickstart -k system/app.energ.energd"
    echo "EnerG is installed."
  else
    echo "EnerG is installed. On first launch, click Install Helper in the menu bar popover."
  fi
  open "$APP"
}

main "$@"
