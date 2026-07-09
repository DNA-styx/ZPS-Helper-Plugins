# ZPS Bot Panic

Makes NavBot survivor bots use the ZPS panic ability when low health, low ammo, zombies nearby.

## Install

1. Copy `zps_bot_panic.smx` to `addons/sourcemod/plugins/`
2. Copy `zps_bot_panic.games.txt` to `addons/sourcemod/gamedata/`

## ConVars

Set in `cfg/sourcemod/zps_bot_panic.cfg` (auto-generated on first load).

| ConVar | Default | Description |
|---|---|---|
| `zps_bot_panic_enabled` | `1` | Turn the behaviour on/off. |
| `zps_bot_panic_health_pct` | `100.0` | Health % at or below which a bot will consider panicking. |
| `zps_bot_panic_ammo_threshold` | `10` | Total ammo (clip + reserve) at or below which a bot will consider panicking. |
| `zps_bot_panic_zombie_radius` | `300.0` | Distance (units) a zombie must be within to count as a threat. |
| `zps_bot_panic_cooldown` | `20.0` | Seconds between panic attempts per bot. |
| `zps_bot_panic_debug` | `0` | Log every eligibility check to `logs/zps_bot_panic.log`. Turn on `1` if bots aren't panicking and you need to see why. |

## Debug logging

With `zps_bot_panic_debug 1`, each check for a bot looks like:

```
[2026-07-09 20:28:24] [NAV] Bot 4: health=64.9% (need<=100.0%) ammo=0 (need<=10) zombieNearby=yes
[2026-07-09 20:28:24] [NAV] Bot 4: PANIC triggered (direct call), next allowed at +20.0s
```

To confirm the panic actually took effect in-game, check the main console
log for a matching line at the same time:

```
grep -i "zps_panic" /home/zpsserver/log/console/*.log
```
