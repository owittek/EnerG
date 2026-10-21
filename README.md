# EnerG

A menu bar app that stops your MacBook's battery from sitting at 100%. Set a Charge Limit. Once the battery reaches it, the Mac runs from the adapter and the battery stays where it is.

<img src="EnerG.avif" alt="The EnerG popover" width="386">

- **Charge Limit:** 50–100% in steps of 5. 100 means no limit.
- **Top Up:** charge to 100% once, e.g. before a trip. Ends when you unplug or stop it.
- **Pause:** hand charging and the LED back to macOS without quitting.
- **MagSafe LED:** Auto (orange while charging, green when plugged in and not charging) or Off.
- **Power flow:** live watts from adapter to Mac and battery.

A free, open-source alternative to AlDente for these features. Don't run both: they write the same SMC keys, and EnerG warns when AlDente is running. Terms are defined in [CONTEXT.md](CONTEXT.md).

**Requirements:** an Apple Silicon MacBook on macOS 27 or later. Intel Macs are not supported.

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

## How it works

- **Charge Limit** uses the native macOS limit through the private PowerUI framework. When you lower the limit while plugged in, macOS runs the Mac from the battery until it is back at the limit (the Limit Drain), then holds it there on AC.
- **Limits below 80%**, which PowerUI rejects, are written to the smartcharging daemon's own defaults. When the battery is steady, a one-second cut of adapter power (SMC key `CHIE`) makes the daemon apply them. See [ADR 0001](docs/adr/0001-sub-80-limits-via-smartcharging-override.md).
- The SMC key `AC-W` reports whether any charger is physically plugged in.
- Battery power is read live from the SMC keys `B0AC` × `B0AV`; the battery registry refreshes only about once a minute.
- **MagSafe LED** is driven through the SMC key `ACLC`.
- A root helper (`energd`, registered with `SMAppService`) does the writes. The menu bar app talks to it over XPC. Only apps signed by the same team can connect.

## Build from source

```sh
brew install xcodegen
# set DEVELOPMENT_TEAM in project.yml to your team ID
scripts/install.sh            # generates the Xcode project, builds Debug, installs to /Applications
```

Use your Team ID (the OU field of your Apple Development certificate, shown in Xcode → Settings → Accounts), not the identifier in the certificate's name.

Contributors: `project.yml` commits the author's team (`XG5GU82KF7`). Replace it with your own team ID; signing fails with someone else's.

Maintainers: `scripts/release.sh` builds a signed `EnerG.zip` and publishes it as release `v<MARKETING_VERSION>` (bump it in `project.yml` first).

## Test

Policy tests, no hardware:

```sh
swift test --package-path Packages/EnerGKit
```

The smoke test checks the real hardware: it cuts the adapter, cycles the MagSafe LED and changes the Charge Limit, then restores the original state on exit. Before running it:

- Quit AlDente. It writes the same SMC keys and would override the test's writes.
- If the EnerG helper is installed, suspend it, or it turns the adapter back on mid-test.

```sh
swift build --package-path Packages/EnerGKit --product energ-smoke
sudo launchctl kill SIGSTOP system/app.energ.energd   # only if the helper is installed
sudo scripts/smoke.sh                                 # watch the MagSafe LED
sudo launchctl kill SIGCONT system/app.energ.energd   # resume the helper
```

## Logs

The popover shows short notices; raw errors go to the system log (subsystem `app.energ`, categories `app`, `hardware`, `energd`):

```sh
log stream --predicate 'subsystem == "app.energ"' --level info
```

## Uninstall

- **Uninstall Helper** (popover footer) hands charging back to macOS, then unregisters `energd`.
- It turns the native macOS Charge Limit off, as Pause does.
- Your settings stay in `/Library/Application Support/EnerG/settings.json`, so a reinstall restores them. Delete that file for a clean slate.
- If the helper can't be reached, the notice offers **Uninstall Anyway**. It removes the helper without handing charging back first. If the helper is still running, it turns the adapter back on and hands the LED back as it stops; if not, both may stay as last set. The native macOS Charge Limit may stay at its last value.
- Switching EnerG off in System Settings → General → Login Items stops `energd` the same way: the adapter comes back on, the LED is handed back, and the native macOS Charge Limit stays at its last value.
- A limit below 80% may stay in effect after EnerG stops (Login Items off, or Uninstall Anyway). Turning the Charge Limit off in System Settings → Battery clears it.

## License

GPL-3.0-or-later. See [LICENSE.md](LICENSE.md).
