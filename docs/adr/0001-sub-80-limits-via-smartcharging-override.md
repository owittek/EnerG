# Charge Limits below 80 % via Apple's smartcharging defaults override

macOS 27's native charge limit (PowerUI `setMCLLimit:`) only accepts 80–100, and this firmware has no charge-inhibit key. Battery longevity is EnerG's first goal, and calendar aging is markedly slower at 50–60 % than at 80 %, so EnerG offers limits from 50 to 100. Below 80 it enables the native limit at 80. It then writes `mclLimitValue` into root's `com.apple.smartcharging.topoffprotection` defaults and posts `com.apple.smartcharging.defaultschanged`. The daemon applies the value unclamped to SMC `CHLT` on its next % change or plug event. When the battery is steady, EnerG supplies the plug event by pulsing `CHIE` (adapter off ~1 s, then on). AlDente 1.39.4 uses the same method. It was verified on Mac17,8 / macOS 27 on 2026-10-21: the limit was applied at 70, the Limit Drain reached 70 and held there for 3 h on AC.

## Considered options

- **Stay at 80–100 (documented API only)**: safe, but gives up the main longevity lever.
- **Hold below 80 by cutting the adapter (`CHIE`)**: doesn't hold. A cut battery keeps draining, and when the adapter comes back the firmware recharges to the native limit.
- **Write `CHLT` directly**: not attempted. The daemon owns that key and would likely overwrite it.

## Consequences

- The method is undocumented and may break with a macOS update. `MacHardware` checks `CHLT` after every write. If a value below 80 doesn't take, EnerG falls back to 80 and warns, so the 80–100 path keeps working.
- When releasing the limit, EnerG first puts `mclLimitValue` back to a value System Settings can show (80).
- A `CHIE` pulse fires only when the notification alone didn't apply the value.
