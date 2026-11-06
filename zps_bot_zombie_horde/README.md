# ZPS Bot Zombie Horde

Ramps the NavBot zombie bot count in waves on listed maps. Zombies are frozen briefly at round start, and survivor bots hold position at the start of each round.

## Requirements

- SourceMod
- NavBot

## Install

1. Copy `zps_bot_zombie_horde.smx` to `addons/sourcemod/plugins/`
2. Copy `zps_bot_zombie_horde.phrases.txt` to `addons/sourcemod/translations/`
3. Copy `zps_bot_zombie_horde_maps.cfg` to `addons/sourcemod/configs/zps_bot_zombie_horde/`

## Map list

Only maps listed in `zps_bot_zombie_horde_maps.cfg` use horde mode. All other maps get the default NavBot settings below.

```
"Maps"
{
	"zpo_biotec"	"1"		// use cvar defaults
	"zpo_tanker"
	{
		"freeze"			"0"	// seconds, 0 = no zombie freeze
		"zombies_per_player"	"3"	// 0 = fill to free slots
	}
}
```

## ConVars

Set in `cfg/sourcemod/zps_bot_zombie_horde.cfg` (auto-generated on first load).

| ConVar | Default | Description |
|---|---|---|
| `zps_bot_zombie_horde_enabled` | `1` | Turn the plugin on/off. |
| `zps_bot_zombie_horde_wave_interval` | `60.0` | Seconds between zombie waves. |
| `zps_bot_zombie_horde_zombies_per_player` | `0` | Max zombie bots per real survivor. `0` = fill free slots. |
| `zps_bot_zombie_horde_freeze_duration` | `30.0` | Seconds zombies stand still after round start. `0` = off. |
| `zps_bot_zombie_horde_unfreeze_warning_seconds` | `10.0` | Seconds before unfreeze to show a warning. |
| `zps_bot_zombie_horde_bot_hold_duration` | `60.0` | Seconds survivor bots stand still at map and round start. `0` = off. |
| `zps_bot_zombie_horde_skill_level` | `3` | `sm_navbot_skill_level` on horde maps. |
| `zps_bot_zombie_horde_default_skill_level` | `1` | `sm_navbot_skill_level` on other maps. |
| `zps_bot_zombie_horde_default_quota_fixed` | `0` | `sm_navbot_quota_fixed` restored on other maps. |
| `zps_bot_zombie_horde_default_quota_target` | `-1` | `sm_navbot_quota_target` restored on other maps. |
| `zps_bot_zombie_horde_debug` | `0` | Log wave target changes. |
