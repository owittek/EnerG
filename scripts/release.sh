#!/bin/bash
# Build a Release EnerG.zip and publish it as GitHub release v<MARKETING_VERSION>.
# Signed by the free Personal Team "Apple Development" cert, which expires yearly:
# renew it in Xcode → Settings → Accounts before releasing once it has.
# --no-publish: stop after build/EnerG.zip.
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM=XG5GU82KF7
PUBLISH=1
case "${1:-}" in
  "") ;;
  --no-publish) PUBLISH=0 ;;
  *) echo "usage: scripts/release.sh [--no-publish]"; exit 1 ;;
esac

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"$/\1/p' project.yml)
[[ -n "$VERSION" ]] || { echo "MARKETING_VERSION not found in project.yml"; exit 1; }
TAG="v$VERSION"

if [[ $PUBLISH == 1 ]]; then
  [[ -z "$(git status --porcelain)" ]] || { echo "working tree is dirty; commit first"; exit 1; }
  if ! { git fetch -q origin main && git merge-base --is-ancestor HEAD origin/main; }; then
    echo "HEAD is not on origin/main; merge and push first"
    exit 1
  fi
  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    echo "$TAG already exists; bump MARKETING_VERSION in project.yml"
    exit 1
  fi
fi

xcodegen generate
rm -rf build/Build  # no stale Debug/incremental products
mkdir -p build
LOG=build/release.log
if ! xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates \
  OTHER_CODE_SIGN_FLAGS=--timestamp CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO build >"$LOG" 2>&1; then
  grep -E "error:" "$LOG" | head -20 || true
  echo "xcodebuild failed; full log: $LOG"
  exit 1
fi

APP=build/Build/Products/Release/EnerG.app
codesign --verify --deep --strict "$APP"
for BIN in "$APP" "$APP/Contents/MacOS/energd"; do
  INFO=$(codesign -dv "$BIN" 2>&1)
  grep -qx "TeamIdentifier=$TEAM" <<<"$INFO" || { echo "$BIN is not signed by team $TEAM"; exit 1; }
  grep -q "^Timestamp=" <<<"$INFO" || { echo "$BIN has no secure timestamp"; exit 1; }
  ENT=$(codesign -d --entitlements - "$BIN" 2>&1)
  ! grep -q get-task-allow <<<"$ENT" || { echo "$BIN has get-task-allow"; exit 1; }
done

ZIP=build/EnerG.zip
rm -f "$ZIP"
ditto -c -k --norsrc --keepParent "$APP" "$ZIP"
echo "built $ZIP ($TAG)"
[[ $PUBLISH == 1 ]] || exit 0

gh release create "$TAG" "$ZIP" --target "$(git rev-parse HEAD)" \
  --title "EnerG $VERSION" --generate-notes
