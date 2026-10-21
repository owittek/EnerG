# EnerG Prebuilt Install — Design

Let others install EnerG without Xcode and without a paid Apple Developer Program membership.

## Constraints

- Signing identity: free Personal Team "Apple Development" cert, team `XG5GU82KF7`, expires 2027-10-20 (renewed yearly in Xcode). No Developer ID, so no notarization.
- App ↔ energd XPC requires the same team (`isFromSameTeam`), so app and helper must be signed by this team.
- No special entitlements, so no provisioning profile is needed on other Macs.
- Downloads made with `curl` carry no `com.apple.quarantine` attribute, so Gatekeeper does not block the app.
- The GitHub repo must be public for the raw script URL and release download to work.

## Release: `scripts/release.sh` (maintainer)

1. Refuses if the working tree is dirty or tag `v<MARKETING_VERSION>` (read from `project.yml`) already exists.
2. `xcodegen generate`, then `xcodebuild` Release with `OTHER_CODE_SIGN_FLAGS=--timestamp` into `build/`.
3. Verifies: `codesign --verify --deep --strict` passes and `TeamIdentifier=XG5GU82KF7`.
4. Zips with `ditto -c -k --keepParent` → `build/EnerG.zip`.
5. `gh release create v<MARKETING_VERSION> build/EnerG.zip`. With `--no-publish`, stops after step 4.
6. A comment notes the cert expires yearly and must be renewed in Xcode before the next release.

## User installer: `scripts/get.sh`

The existing `scripts/install.sh` stays as the build-from-source script.

1. `set -euo pipefail`; temp dir removed on exit.
2. Checks Apple Silicon (`uname -m` = `arm64`) and macOS ≥ 27 (`sw_vers -productVersion`); otherwise exits with a clear message.
3. Downloads `https://github.com/owittek/EnerG/releases/latest/download/EnerG.zip` with `curl -fL`. `ENERG_ZIP_URL` overrides the URL (testing).
4. Unzips to the temp dir, quits EnerG (`pkill -x EnerG`), replaces `/Applications/EnerG.app`, removes any quarantine attribute (`xattr -dr com.apple.quarantine`).
5. If `system/app.energ.energd` is registered, `sudo launchctl kickstart -k system/app.energ.energd` (one password prompt).
6. `open /Applications/EnerG.app`.

## README

- **Install** at the top: `curl -fsSL https://raw.githubusercontent.com/owittek/EnerG/main/scripts/get.sh | bash`, then **Install Helper** and allow EnerG under System Settings → General → Login Items → Background App Activity.
- **Manual install**: download `EnerG.zip` from Releases, drag to Applications, open once, then System Settings → Privacy & Security → **Open Anyway**.
- **Update**: re-run the one-liner.
- **Build from source**: the current Build section, unchanged.

## Out of scope

In-app updater, Homebrew tap, GitHub Actions releases, notarization.

## Verification

- `shellcheck scripts/release.sh scripts/get.sh`.
- `scripts/release.sh --no-publish`, then `ENERG_ZIP_URL=file://$PWD/build/EnerG.zip scripts/get.sh`; app launches and the existing helper is restarted.
- First real release: install on a second Apple Silicon Mac on macOS 27 before announcing. If `SMAppService` registration of energd fails there, fall back to a build-from-source install guide.
