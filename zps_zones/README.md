# ZPS Zones

Per-team "god zones". When a player from the zone's team stays inside it, they get a chat warning and are then slapped for damage until they leave or die.

## Requirements

- SourceMod

## Install

1. Copy `zps_zones.smx` to `addons/sourcemod/plugins/`
2. Optional: copy the example zone files to `addons/sourcemod/data/zps_zones/`

Zones are stored per map in `addons/sourcemod/data/zps_zones/<mapname>.cfg`.

## Commands

| Command | Access | Description |
|---|---|---|
| `sm_zones` / `!zones` | Config (`i`) | Open the zone editor to create, edit, or delete zones. Also listed in `!admin` under Server Commands. |

## ConVars

Set in `cfg/sourcemod/zps_zones.cfg` (auto-generated on first load).

| ConVar | Default | Description |
|---|---|---|
| `zps_zones_enable` | `1` | Turn zone punishment on/off. |
| `zps_zones_damage` | `10` | HP removed per slap. |
| `zps_zones_interval` | `1.0` | Seconds between slaps. |
| `zps_zones_grace` | `3.0` | Seconds inside a zone before the first slap. |
| `zps_zones_slap_sound` | `1` | Play the slap sound. |
