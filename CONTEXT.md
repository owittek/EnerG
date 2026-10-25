# EnerG

Menu bar app that caps a MacBook's battery charge so the Mac runs from the power adapter instead of cycling the battery.

## Language

**Charge Limit**:
The battery percentage above which charging stops while the Mac keeps running from the adapter. A multiple of 5 from 50 to 100; 100 means no limit.
_Avoid_: max charge, cap, threshold

**Limit Drain**:
macOS's own behaviour when the adapter is attached and the battery is above the **Charge Limit**: the battery powers the Mac until it is back at the limit, and the adapter sits idle. Not started or stopped by EnerG.
_Avoid_: discharge, force discharge

**Calibration**:
A macOS battery-gauge recalibration charge (PowerUI `ChargingUpForGauging`) during which macOS ignores every **Charge Limit** and SMC `CHLT` reads off. Started and ended by macOS; EnerG only reports it and leaves the limit in place for macOS to apply afterwards.
_Avoid_: gauging, mitigation

**Top Up**:
A one-shot charge to 100% that ignores the **Charge Limit** until the adapter is unplugged or the user stops it.

**LED Mode**:
How EnerG drives the MagSafe LED: Auto (reflects charging / at limit) or Off.

**Pause**:
Temporarily handing charging and the LED back to stock macOS behaviour without quitting EnerG.
_Avoid_: disable, off (ambiguous with **LED Mode** Off)

## Relationships

- **Top Up** and **Pause** both suspend the **Charge Limit**; **Top Up** ends on unplug or when stopped, **Pause** ends only when the user resumes.
- During **Calibration** the **Charge Limit** is not enforced; it applies again on its own once **Calibration** ends.

## Flagged ambiguities

- "Sailing" (charge stops at the limit and resumes only after the battery drifts some % below it) is not an EnerG concept: macOS firmware applies a fixed ~5% band itself.
- "turn it off" was used for both the LED and the whole app — resolved: **LED Mode** Off vs **Pause**.
