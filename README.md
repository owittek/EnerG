# EnerG

[![Latest release](https://img.shields.io/github/v/release/owittek/EnerG)](https://github.com/owittek/EnerG/releases/latest)
[![License: GPL-3.0-or-later](https://img.shields.io/badge/license-GPL--3.0--or--later-blue)](LICENSE.md)
[![Platform: macOS 27+, Apple Silicon](https://img.shields.io/badge/macOS-27%2B%20·%20Apple%20Silicon-lightgrey)](#requirements)

EnerG caps your MacBook's charge from the menu bar. Once the battery reaches your limit, the Mac runs from the adapter and the battery stays put.

A free, open-source alternative to AlDente, built around just the essentials.

<img src="EnerG.avif" alt="The EnerG popover" width="386">

## Features

- **Charge Limit:** 50–100% in steps of 5. 100 means no limit.
- **Top Up:** charge to 100% once, e.g. before a trip. Ends when you unplug or stop it.
- **Pause:** hand charging and the LED back to macOS without quitting.
- **MagSafe LED:** Auto (orange while charging, green when plugged in and not charging) or Off.
- **Power flow:** live watts from adapter to Mac and battery.

Terms are defined in [CONTEXT.md](CONTEXT.md).

> [!WARNING]
> Don't run EnerG and AlDente together. Both write the same SMC keys; EnerG warns when AlDente is running.

## Requirements

- Apple Silicon MacBook (Intel Macs are not supported)
- macOS 27 or later

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/owittek/EnerG/main/scripts/get.sh | bash
```

The script checks your Mac, verifies the download's signature, installs to `/Applications` and opens EnerG.

<details>
<summary>Install by hand</summary>

EnerG isn't notarized (that needs a paid Apple Developer account), so Gatekeeper blocks a browser download. The command above downloads with `curl`, which Gatekeeper doesn't check.

1. Download `EnerG.zip` from [Releases](https://github.com/owittek/EnerG/releases/latest) and move `EnerG.app` to Applications.
2. Open it. macOS says it can't verify the app; click **Done**.
3. In System Settings → Privacy & Security, click **Open Anyway** next to EnerG.

</details>

### First launch

Click **Install Helper** in the popover, then allow EnerG under System Settings → General → Login Items → Background App Activity.

### Update

Run the install command again. It replaces the app and restarts the helper (asks for your password).

## How it works

A root helper, `energd`, does all hardware writes. It is registered with `SMAppService`, and the menu bar app talks to it over XPC; only apps signed by the same team can connect.

- **Charge Limit** uses the native macOS limit through the private PowerUI framework. When you lower the limit while plugged in, macOS runs the Mac from the battery until it is back at the limit (the Limit Drain), then holds it there on AC.
- **Limits below 80%**, which PowerUI rejects, are written to the smartcharging daemon's own defaults. When the battery is steady, a one-second cut of adapter power makes the daemon apply them. See [ADR 0001](docs/adr/0001-sub-80-limits-via-smartcharging-override.md).

SMC keys used:

| Key | Purpose |
| --- | --- |
| `CHIE` | Cut adapter power (applies limits below 80%) |
| `AC-W` | Whether a charger is physically plugged in |
| `B0AC` × `B0AV` | Live battery power (the battery registry refreshes only about once a minute) |
| `ACLC` | MagSafe LED |

EnerG relies on private frameworks and undocumented SMC keys, so a macOS update can break it.

## Uninstall

1. Click **Uninstall Helper** in the popover footer. It hands charging back to macOS, turns the native Charge Limit off (as Pause does) and unregisters `energd`.
2. Quit EnerG and move `EnerG.app` to the Trash.

Your settings stay in `/Library/Application Support/EnerG/settings.json`, so a reinstall restores them. Delete that file for a clean slate.

<details>
<summary>If the helper can't be reached, or you stop it another way</summary>

- **Uninstall Anyway** (offered in the notice when the helper can't be reached) removes the helper without handing charging back first. If the helper is still running, it turns the adapter back on and hands the LED back as it stops; if not, both may stay as last set. The native Charge Limit may stay at its last value.
- **Switching EnerG off** in System Settings → General → Login Items stops `energd` the same way: the adapter comes back on, the LED is handed back, and the native Charge Limit stays at its last value.
- In both cases a limit below 80% may stay in effect. Turning the Charge Limit off in System Settings → Battery clears it.

</details>

## Troubleshooting

The popover shows short notices; raw errors go to the system log (subsystem `app.energ`, categories `app`, `hardware`, `energd`):

```sh
log stream --predicate 'subsystem == "app.energ"' --level info
```

## Development

### Build from source

```sh
brew install xcodegen
scripts/install.sh   # generates the Xcode project, builds Debug, installs to /Applications
```

First set `DEVELOPMENT_TEAM` in `project.yml` to your own Team ID; it ships with the author's (`XG5GU82KF7`), and signing fails with someone else's. Use the OU field of your Apple Development certificate (Xcode → Settings → Accounts), not the identifier in the certificate's name.

### Test

Policy tests, no hardware needed:

```sh
swift test --package-path Packages/EnerGKit
```

The smoke test exercises real hardware: it cuts the adapter, cycles the MagSafe LED and changes the Charge Limit, then restores the original state on exit. Before running it, quit AlDente (it would override the test's writes) and, if the EnerG helper is installed, suspend it (it turns the adapter back on mid-test):

```sh
swift build --package-path Packages/EnerGKit --product energ-smoke
sudo launchctl kill SIGSTOP system/app.energ.energd   # only if the helper is installed
sudo scripts/smoke.sh                                 # watch the MagSafe LED
sudo launchctl kill SIGCONT system/app.energ.energd   # resume the helper
```

### Release

Bump `MARKETING_VERSION` in `project.yml`, commit and push, then run `scripts/release.sh`. It builds a signed `EnerG.zip` and publishes it as GitHub release `v<MARKETING_VERSION>`. Pass `--no-publish` to stop after the build.

## License

[GPL-3.0-or-later](LICENSE.md)
