# ZPS NavBot Zombie Skills

Lets NavBot Carrier zombie bots use the Spot skill when their Feed-O-Meter is high enough.

## Requirements

- SourceMod
- NavBot

## Install

1. Copy `zps_navbot_zombie_skills.smx` to `addons/sourcemod/plugins/`

## ConVars

Set in `cfg/sourcemod/zps_navbot_carrier_skills.cfg` (auto-generated on first load).

| ConVar | Default | Description |
|---|---|---|
| `sm_zps_navbot_carrier_spot_suitpower_min` | `35.0` | Minimum Feed-O-Meter before Spot is tried. The game requires 35. |
| `sm_zps_navbot_carrier_spot_interval` | `2.0` | Seconds between checks. |
| `sm_zps_navbot_carrier_skill_cooldown` | `30.0` | Seconds between Spot attempts. |
| `sm_zps_navbot_carrier_debug_log` | `0` | Log attempts to `logs/zps_navbot_carrier_skills.log`. |
