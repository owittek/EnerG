# EnerG

Menu bar app that keeps a MacBook below a Charge Limit and runs it from the adapter instead of cycling the battery. Open-source alternative to the parts of AlDente its author uses: Charge Limit, Discharge / Auto-Discharge, MagSafe LED control, Top Up and Pause. Terms are defined in [CONTEXT.md](CONTEXT.md).

**Requirements:** an Apple Silicon MacBook on macOS 27, with firmware that gates the SMC charge-inhibit keys (macOS 27, or the 26.7 / 15.8 security updates). Intel Macs are not supported.

## How it works

- **Charge Limit** uses the native macOS limit (80/85/90/95/100%) through the private PowerUI framework.
- **Discharge** cuts adapter power with the SMC key `CHIE`.
- **MagSafe LED** is driven through the SMC key `ACLC`.
- A root helper (`energd`, registered with `SMAppService`) does the writes. The menu bar app talks to it over XPC. Only apps signed by the same team can connect.

## Build

```sh
brew install xcodegen
# set DEVELOPMENT_TEAM in project.yml to your team ID
scripts/install.sh            # generates the Xcode project, builds Debug, installs to /Applications
```

Use your Team ID (the OU field of your Apple Development certificate, shown in Xcode → Settings → Accounts), not the identifier in the certificate's name.

On first launch, click **Install helper** and allow EnerG under System Settings → General → Login Items.

## Test

```sh
swift test --package-path Packages/EnerGKit                       # policy tests, no hardware
swift build --package-path Packages/EnerGKit --product energ-smoke
sudo scripts/smoke.sh                                             # on-device hardware check, restores state on exit
```

Quit AlDente first; its helper writes the same SMC keys.

## Uninstall

- **Uninstall Helper** (popover footer) hands charging back to macOS, then unregisters `energd`.
- It turns the native macOS Charge Limit off, as Pause does.
- Your settings stay in `/Library/Application Support/EnerG/settings.json`, so a reinstall restores them. Delete that file for a clean slate.
- If the helper can't be reached, the notice offers **Uninstall Anyway**. The adapter and LED are still restored, but the native macOS Charge Limit may stay at its last value.
- Switching EnerG off in System Settings → General → Login Items stops `energd` the same way: the adapter and LED are restored, and the native macOS Charge Limit stays at its last value.

## License

Not decided yet.
