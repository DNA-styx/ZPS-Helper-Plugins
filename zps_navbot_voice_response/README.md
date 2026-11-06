# ZPS NavBot Voice Response

Two plugins that make NavBot survivor bots respond to player voice commands.

- **zps_navbot_followme**: when a player uses "Follow me", the nearest survivor bots join their squad. The squad disbands when the time limit runs out or when a member is critically injured.
- **zps_navbot_voicedrop**: when a player uses "Need weapon", the nearest survivor bot drops its weapon. "Need ammo" makes the nearest bot carrying that ammo type drop it.

## Requirements

- SourceMod (with DHooks)
- NavBot

## Install

1. Copy `zps_navbot_followme.smx` and `zps_navbot_voicedrop.smx` to `addons/sourcemod/plugins/`
2. Copy `zps_navbot_followme.games.txt` and `zps_navbot_voicedrop.games.txt` to `addons/sourcemod/gamedata/`

Each plugin can be installed alone.

## ConVars: followme

Set in `cfg/sourcemod/zps_navbot_followme.cfg` (auto-generated on first load).

| ConVar | Default | Description |
|---|---|---|
| `sm_zps_navbot_followme_maxfollowers` | `2` | Max bots in a squad (1 to 8). |
| `sm_zps_navbot_followme_duration` | `300.0` | Seconds before the squad disbands. |
| `sm_zps_navbot_followme_chatmsg` | `0` | Tell the caller in chat when a bot joins. |

## ConVars: voicedrop

No config file is generated. Set in `server.cfg` if needed.

| ConVar | Default | Description |
|---|---|---|
| `zps_navbot_voicedrop_cooldown` | `60.0` | Seconds between requests, per player. |
| `zps_navbot_voicedrop_log` | `1` | Log requests to `logs/zps_navbot_voicedrop.log`. |
