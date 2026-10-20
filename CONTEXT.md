# EnerG

Menu bar app that caps a MacBook's battery charge so the Mac runs from the power adapter instead of cycling the battery.

## Language

**Charge Limit**:
The battery percentage above which charging stops while the Mac keeps running from the adapter. One of 80, 85, 90, 95, 100.
_Avoid_: max charge, cap, threshold

**Discharge**:
Cutting adapter power while plugged in so the Mac runs from the battery until a **Discharge Target** is reached.
_Avoid_: drain, force discharge

**Discharge Target**:
The percentage at which a **Discharge** stops. Defaults to the **Charge Limit**; may be lower than 80.

**Auto-Discharge**:
Starting a **Discharge** automatically whenever the battery is above the **Charge Limit**.

**Top Up**:
A one-shot charge to 100% that ignores the **Charge Limit** until the adapter is unplugged or the user stops it.

**LED Mode**:
How EnerG drives the MagSafe LED: Auto (reflects charging / at limit / discharging), Off, or Blink while discharging.

**Pause**:
Temporarily handing charging and the LED back to stock macOS behaviour without quitting EnerG.
_Avoid_: disable, off (ambiguous with **LED Mode** Off)

**Weak Adapter**:
The state where the adapter is connected but the battery is still discharging because the Mac draws more than the adapter supplies.

## Relationships

- A **Discharge** ends at its **Discharge Target**, on sleep, on lid close, or when the charger is unplugged.
- **Top Up** and **Pause** both suspend the **Charge Limit**; **Top Up** ends on unplug or when stopped, **Pause** ends only when the user resumes.

## Flagged ambiguities

- "Sailing" (charge stops at the limit and resumes only after the battery drifts some % below it) is not an EnerG concept: macOS firmware applies a fixed ~5% band itself.
- "turn it off" was used for both the LED and the whole app — resolved: **LED Mode** Off vs **Pause**.
