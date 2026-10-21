# EnerG Prebuilt Install Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Others install EnerG with one command, no Xcode, no paid Apple Developer Program.

**Architecture:** `scripts/release.sh` builds a Release `EnerG.app` signed (with secure timestamp) by the free Personal Team cert, zips it and publishes a GitHub release. `scripts/get.sh` downloads the latest release zip with curl (no quarantine flag), installs it to `/Applications`, restarts energd if registered. README gets Install / Manual install / Update sections; the old Build section becomes "Build from source".

**Tech Stack:** bash, xcodegen, xcodebuild, codesign, ditto, gh CLI.

Spec: `docs/superpowers/specs/2026-10-22-prebuilt-install-design.md`

## Global Constraints

- Team ID `XG5GU82KF7`; signing identity "Apple Development" (free Personal Team, expires 2027-10-20).
- Release asset name `EnerG.zip`; tag `v<MARKETING_VERSION>` from `project.yml` (currently `0.1.0`).
- Download URL: `https://github.com/owittek/EnerG/releases/latest/download/EnerG.zip`.
- One-liner: `curl -fsSL https://raw.githubusercontent.com/owittek/EnerG/main/scripts/get.sh | bash`.
- Requirements: Apple Silicon, macOS 27 or later.
- Existing `scripts/install.sh` (build from source) stays unchanged.
- Scripts follow `scripts/install.sh` style: `#!/bin/bash`, one-line purpose comment, `set -euo pipefail`.
- Commit messages: conventional (`feat:`, `docs:`), no Co-Authored-By/Claude trailers.
- Deviation from spec step 1 (release): the dirty-tree / existing-tag / pushed-HEAD checks run only when publishing, so `--no-publish` works on a dirty tree for testing.

---

### Task 1: Release script

**Files:**
- Create: `scripts/release.sh`

**Interfaces:**
- Produces: `build/EnerG.zip` containing `EnerG.app` at its root (consumed by Task 2 and the GitHub release). `scripts/release.sh [--no-publish]`.

- [ ] **Step 1: Install shellcheck**

Run: `brew install shellcheck`

- [ ] **Step 2: Write `scripts/release.sh`**

```bash
#!/bin/bash
# Build a Release EnerG.zip and publish it as GitHub release v<MARKETING_VERSION>.
# Signed by the free Personal Team "Apple Development" cert, which expires yearly:
# renew it in Xcode → Settings → Accounts before releasing once it has.
# --no-publish: stop after build/EnerG.zip.
set -euo pipefail
cd "$(dirname "$0")/.."
TEAM=XG5GU82KF7
PUBLISH=1
[[ "${1:-}" == "--no-publish" ]] && PUBLISH=0

VERSION=$(sed -n 's/^ *MARKETING_VERSION: *"\(.*\)"$/\1/p' project.yml)
[[ -n "$VERSION" ]] || { echo "MARKETING_VERSION not found in project.yml"; exit 1; }
TAG="v$VERSION"

if [[ $PUBLISH == 1 ]]; then
  [[ -z "$(git status --porcelain)" ]] || { echo "working tree is dirty; commit first"; exit 1; }
  [[ -n "$(git branch -r --contains HEAD)" ]] || { echo "HEAD is not pushed; push first"; exit 1; }
  if gh release view "$TAG" >/dev/null 2>&1; then
    echo "$TAG is already released; bump MARKETING_VERSION in project.yml"
    exit 1
  fi
fi

xcodegen generate
mkdir -p build
LOG=build/release.log
if ! xcodebuild -project EnerG.xcodeproj -scheme EnerG -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates \
  OTHER_CODE_SIGN_FLAGS=--timestamp build >"$LOG" 2>&1; then
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
done

ZIP=build/EnerG.zip
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "built $ZIP ($TAG)"
[[ $PUBLISH == 1 ]] || exit 0

gh release create "$TAG" "$ZIP" --target "$(git rev-parse HEAD)" \
  --title "EnerG $VERSION" --generate-notes
```

Then `chmod +x scripts/release.sh`.

Note: if energd is not at `Contents/MacOS/energd` (check `find build/Build/Products/Release/EnerG.app -name energd -type f`), fix that path in the loop.

- [ ] **Step 3: Lint**

Run: `shellcheck scripts/release.sh`
Expected: no output, exit 0.

- [ ] **Step 4: Build without publishing**

Run: `scripts/release.sh --no-publish`
Expected: ends with `built build/EnerG.zip (v0.1.0)`. If the timestamp check fails, Apple's timestamp server rejected the dev cert: stop and report (spec assumption broken).

- [ ] **Step 5: Check the zip**

Run: `unzip -l build/EnerG.zip | head -5 && codesign -d --entitlements - build/Build/Products/Release/EnerG.app 2>&1 | grep -c get-task-allow`
Expected: first entry is `EnerG.app/`; get-task-allow count `0`.

- [ ] **Step 6: Commit**

```bash
git add scripts/release.sh
git commit -m "feat: release script for a signed EnerG.zip on GitHub Releases"
```

### Task 2: User installer

**Files:**
- Create: `scripts/get.sh`

**Interfaces:**
- Consumes: `build/EnerG.zip` from Task 1 (for local testing via `ENERG_ZIP_URL`).
- Produces: `scripts/get.sh`, run as the one-liner from Global Constraints.

- [ ] **Step 1: Write `scripts/get.sh`**

```bash
#!/bin/bash
# Install or update EnerG from the latest GitHub release:
#   curl -fsSL https://raw.githubusercontent.com/owittek/EnerG/main/scripts/get.sh | bash
# ENERG_ZIP_URL overrides the download URL (testing).
set -euo pipefail
URL=${ENERG_ZIP_URL:-https://github.com/owittek/EnerG/releases/latest/download/EnerG.zip}
APP=/Applications/EnerG.app

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

pkill -x EnerG || true
rm -rf "$APP"
ditto "$TMP/EnerG.app" "$APP"
xattr -dr com.apple.quarantine "$APP" 2>/dev/null || true

if launchctl print system/app.energ.energd >/dev/null 2>&1; then
  echo "Restarting the EnerG helper (asks for your password)…"
  sudo launchctl kickstart -k system/app.energ.energd
fi
open "$APP"
echo "EnerG is installed. On first launch, click Install Helper in the menu bar popover."
```

`sysctl hw.optional.arm64` is used instead of `uname -m` because `uname -m` reports `x86_64` in a Rosetta shell. Then `chmod +x scripts/get.sh`.

- [ ] **Step 2: Lint**

Run: `shellcheck scripts/get.sh`
Expected: no output, exit 0.

- [ ] **Step 3: Test the failure path**

Run: `ENERG_ZIP_URL=file:///nonexistent/EnerG.zip bash scripts/get.sh; echo "exit=$?"; ls -d /Applications/EnerG.app`
Expected: curl error, `exit=` non-zero, `/Applications/EnerG.app` still exists (nothing removed before download succeeded).

- [ ] **Step 4: Test install from the local zip**

Requires `build/EnerG.zip` from Task 1. The sudo prompt needs a terminal: if running as an agent without a TTY, ask the user to run it with `! ENERG_ZIP_URL=file://$PWD/build/EnerG.zip bash scripts/get.sh`.

Run: `ENERG_ZIP_URL=file://$PWD/build/EnerG.zip bash scripts/get.sh`
Expected: "Downloading EnerG…", helper restart (if registered), EnerG opens, final message. Then:
Run: `codesign -dv /Applications/EnerG.app 2>&1 | grep TeamIdentifier && xattr /Applications/EnerG.app`
Expected: `TeamIdentifier=XG5GU82KF7`; no `com.apple.quarantine`. Popover shows status from the helper (XPC same-team check passes with the Release build).

- [ ] **Step 5: Commit**

```bash
git add scripts/get.sh
git commit -m "feat: one-line installer from the latest GitHub release"
```

### Task 3: README install section

**Files:**
- Modify: `README.md` (insert after the `**Requirements:**` line; rename `## Build`)

- [ ] **Step 1: Insert after the `**Requirements:** …` paragraph, before `## How it works`:**

````markdown
## Install

```sh
curl -fsSL https://raw.githubusercontent.com/owittek/EnerG/main/scripts/get.sh | bash
```

On first launch, click **Install Helper** and allow EnerG under System Settings → General → Login Items → Background App Activity.

EnerG isn't notarized (that needs a paid Apple Developer account), so a browser download is blocked by Gatekeeper. The command above downloads with `curl`, which isn't. To install by hand instead:

1. Download `EnerG.zip` from [Releases](https://github.com/owittek/EnerG/releases/latest) and move `EnerG.app` to Applications.
2. Open it. macOS says it can't verify the app; click **Done**.
3. In System Settings → Privacy & Security, click **Open Anyway** next to EnerG.

**Update:** run the command again. It replaces the app and restarts the helper (asks for your password).
````

- [ ] **Step 2: In the existing Build section**

- Rename `## Build` to `## Build from source`.
- Delete the line `On first launch, click **Install Helper** and allow EnerG under System Settings → General → Login Items → Background App Activity.` (now in Install).
- Append after the Contributors paragraph:

```markdown
Maintainers: `scripts/release.sh` builds a signed `EnerG.zip` and publishes it as release `v<MARKETING_VERSION>` (bump it in `project.yml` first).
```

- [ ] **Step 3: Check**

Run: `grep -n "^## " README.md`
Expected order: Install, How it works, Build from source, Test, Logs, Uninstall, License.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: install from a prebuilt release"
```

### Task 4: First release (needs user approval)

Publishing is outward-facing: confirm with the user before Step 2.

- [ ] **Step 1: Push**

Run: `git push origin main`

- [ ] **Step 2: Publish**

Run: `scripts/release.sh`
Expected: release URL `https://github.com/owittek/EnerG/releases/tag/v0.1.0`.

- [ ] **Step 3: Test the real one-liner**

Ask the user to run: `! curl -fsSL https://raw.githubusercontent.com/owittek/EnerG/main/scripts/get.sh | bash`
Expected: installs and opens EnerG; helper status shows in the popover.

- [ ] **Step 4: Second-Mac test (user, manual)**

The user installs with the one-liner on another Apple Silicon Mac on macOS 27 and clicks Install Helper. Pass: helper registers, popover shows battery status. Fail (helper won't register): report back; fallback per spec is a build-from-source guide.
