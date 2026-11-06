# ZPS NavBot Crates

NavBot survivor bots break any supply crates (`prop_itemcrate`) they can see nearby.

## Requirements

- SourceMod
- NavBot

## Install

1. Copy `zps_navbot_crates.smx` to `addons/sourcemod/plugins/`

## ConVars

No config file is generated. Set in `server.cfg` if needed.

| ConVar | Default | Description |
|---|---|---|
| `sm_navbot_crates_enabled` | `1` | Turn the plugin on/off. |
| `sm_navbot_crates_radius` | `512.0` | Max distance (units) from a bot to a crate. |
| `sm_navbot_crates_interval` | `1.0` | Seconds between crate scans. Applied on map change. |
| `sm_navbot_crates_timeout` | `15.0` | Seconds before a bot gives up on a crate. |

## Commands

| Command | Access | Description |
|---|---|---|
| `sm_crate_test` | Root | Sends the nearest survivor bot to break the crate you are aiming at. |
