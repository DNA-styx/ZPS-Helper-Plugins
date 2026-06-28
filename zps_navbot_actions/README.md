# ZPS NavBot Actions - Server Admin Guide

Version: 1.0
Source: https://github.com/DNA-styx/ZPS-Helper-Plugins

Supersedes: zps_bot_flashlight (remove that plugin before installing this one)

## What it does

Adds ambient behaviours to NavBot-controlled bots:

- **Flashlight** — Bots randomly turn their flashlight on and off. On-duration
  is 60-100 seconds, kept under the ~120 second in-game battery life. Affects
  bots on both teams.

- **Zombie taunt** — Zombie-team bots randomly taunt (the Z key sound) every
  30-90 seconds per bot.

Both features can be toggled independently via cvars.

## Installation

1. Compile `zps_navbot_actions.sp` to `.smx`.
2. Remove `zps_bot_flashlight.smx` if present.
3. Place `.smx` in `addons/sourcemod/plugins/`.
4. Place `zps_navbot_actions.cfg` in `cfg/sourcemod/`.
5. Load via server restart or `sm plugins load zps_navbot_actions`.

## CVars

| CVar | Default | Description |
|---|---|---|
| `zps_navbot_actions_flashlight_enabled` | 1 | Toggle flashlight behaviour |
| `zps_navbot_actions_zombie_taunt_enabled` | 1 | Toggle zombie taunt behaviour |

CVars are set in `cfg/sourcemod/zps_navbot_actions.cfg`.

## Known limitations

- Flashlight on/off state is tracked locally. A roll near the top of the
  60-100s range carries a small risk of desyncing with natural battery drain.
- Zombie taunt timing is checked every 8 seconds, so actual taunt intervals
  may be up to 8 seconds longer than the scheduled time.

## Version history

v1.0: Initial release. Merges and supersedes zps_bot_flashlight. Adds zombie
taunt feature and cvars.
