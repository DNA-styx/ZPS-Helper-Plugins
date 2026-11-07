# ZPS Helper Plugins

SourceMod plugins for running Zombie Panic: Source servers. They fix game issues, add admin tools, and improve NavBot bot behaviour.

Each plugin lives in its own folder with an `addons/sourcemod/` layout that mirrors the server, and each folder has a README covering install steps, ConVars, and commands. Install only the plugins you need.

## Requirements

- SourceMod 1.12 or later
- [NavBot](https://github.com/caxanga334/NavBot) for plugins marked **NavBot**

## Server Fixes

| Plugin | Description |
|---|---|
| [zps_fireloopfix](zps_fireloopfix) | Stops the fire sound from looping after a burning player dies. |
| [zps_hlstatsx_helper](zps_hlstatsx_helper) | Writes kills, chat, and connect data to the server log so HLstatsX can track them. |
| [zps_rtv_roundend_trigger](zps_rtv_roundend_trigger) | Makes Rock The Vote's "change at round end" mode work in ZPS. |

## Admin and Player Tools

| Plugin | Description |
|---|---|
| [sm_first_player_restart](sm_first_player_restart) | Reloads the map when the first real player joins a bot-only server. |
| [zps_player_id](zps_player_id) | Shows an enemy player's name when you aim at them, without showing it through walls. |
| [zps_restart_vote](zps_restart_vote) | Lets players vote in chat to end the current round as a stalemate. |
| [zps_voicemenu_control](zps_voicemenu_control) | Blocks voice commands from gagged or muted players and adds a voice command cooldown. |
| [zps_zones](zps_zones) | In-game editor for per-team zones that punish players who camp in them. |

## Bot Management

| Plugin | Description |
|---|---|
| [sm_navbot_vote](sm_navbot_vote) | **NavBot.** Lets players vote to add or remove bots or change bot skill. |
| [zps_beacon_lastbot](zps_beacon_lastbot) | Beacons the last surviving survivor bot. |
| [zps_bot_volunteer_zombie](zps_bot_volunteer_zombie) | Picks bots before real players when choosing starting zombies. |
| [zps_bot_zombie_horde](zps_bot_zombie_horde) | **NavBot.** Adds zombie bots in timed waves on selected maps. |
| [zps_navmesh_spawn_inspector](zps_navmesh_spawn_inspector) | Admin tool for checking spawn points with no navmesh coverage. |

## Bot Behaviour

| Plugin | Description |
|---|---|
| [zps_bot_panic](zps_bot_panic) | **NavBot.** Survivor bots use panic when they are hurt, low on ammo, or near zombies. |
| [zps_callout_suppress](zps_callout_suppress) | **NavBot.** Stops survivor bots from spamming "spotted at" messages in team chat. |
| [zps_navbot_actions](zps_navbot_actions) | **NavBot.** Bots switch their flashlights on and off at random, and zombie bots taunt. |
| [zps_navbot_crates](zps_navbot_crates) | **NavBot.** Survivor bots break supply crates they can see. |
| [zps_navbot_unstuck](zps_navbot_unstuck) | **NavBot.** Stuck zombie bots crouch and jump to get past props. |
| [zps_navbot_voice_response](zps_navbot_voice_response) | **NavBot.** Bots respond to the "Follow me", "Need weapon", and "Need ammo" voice commands. |
| [zps_navbot_zombie_skills](zps_navbot_zombie_skills) | **NavBot.** Carrier zombie bots use the Spot skill. |

## Installation

1. Download or clone the repository.
2. Copy the contents of the plugin's `addons/` folder to your server's `addons/` folder.
3. Restart the server or change map.
4. Adjust settings in `cfg/sourcemod/` where the plugin's README says a config file is generated.

## Credits

Written by Claude.ai, guided by DNA.styx.