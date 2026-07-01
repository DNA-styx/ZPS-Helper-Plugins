# ZPS Player ID

Shows the name of an opposite-team player when you aim at them. Uses a world-aware trace, so it will not show a name through walls or other solid geometry.

## Requirements

- SourceMod 1.12+
- Zombie Panic: Source

## Installation

1. Copy `zps_player_id.smx` to `addons/sourcemod/plugins/`
2. Copy `zps_player_id.phrases.txt` to `addons/sourcemod/translations/`
3. Load the plugin: `sm plugins load zps_player_id`

A config file (`cfg/sourcemod/zps_player_id.cfg`) is generated automatically on first load.

## ConVars

| ConVar | Default | Description |
|---|---|---|
| `zps_playerid_enabled` | `1` | Enable/disable the plugin |
| `zps_playerid_display` | `1` | Display method: `1` = PrintHintText, `2` = PrintCenterText |
| `zps_playerid_show_bots` | `1` | Allow bots to be identified by players |
| `zps_playerid_version` | (current) | Plugin version (read-only) |
