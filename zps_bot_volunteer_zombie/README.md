# ZPS Bot Volunteer Zombie

Flags bots to be prioritized as zombies at round start, so real players are less likely to be selected.

## How it works

At `Round_Starting`, every connected bot is flagged via a confirmed engine field that ZPS's own zombie-selection logic (`ChooseRandomZombies()`) checks first. Flagged bots are picked before anyone else. This does not force team changes directly — it lets the game's own selection prioritize bots.

This is not a guarantee. Real players can still occasionally be selected if there aren't enough eligible bots, or if they pick Zombies themselves.

## ConVars

| ConVar | Default | Description |
|---|---|---|
| `zps_bot_volunteer_zombie_maxplayers` | `2` | Only active while real player count is at or below this value. Set to `0` to always be active regardless of player count. |
| `zps_bot_volunteer_zombie_logging` | `0` | Enable/disable logging. `0` = off, `1` = on. |

Config file: `cfg/sourcemod/zps_bot_volunteer_zombie.cfg` (generated on first load).

## Log file

When logging is enabled: `addons/sourcemod/logs/zps_bot_volunteer_zombie.log`

Logs one line per round (how many bots were flagged, or why the round was skipped), plus one line whenever a player is actually selected as a zombie at round start.

## Requirements

- SourceMod 1.12

## Known limitations

- The engine offset this plugin relies on has changed between ZPS updates before, and may change again. If bots stop being prioritized after a game update, this offset likely needs re-verifying.
