# ZPS VoiceMenu Control

Stops gagged or muted players from using voice menu commands and adds a per-player cooldown between voice commands. Bots are not affected.

## Requirements

- SourceMod (with DHooks and `basecomm.smx` loaded)

## Install

1. Copy `zps_voicemenu_control.smx` to `addons/sourcemod/plugins/`
2. Copy `zps_voicemenu_control.games.txt` to `addons/sourcemod/gamedata/`

## ConVars

No config file is generated. Set in `server.cfg` if needed.

| ConVar | Default | Description |
|---|---|---|
| `sm_vmc_block_enable` | `1` | Block voice commands for gagged or muted players. |
| `sm_vmc_cooldown` | `5.0` | Seconds between voice commands, per player. `0` = off. |
| `sm_vmc_log_block` | `1` | Log gag/mute blocks to `logs/zps_voicemenu_control_block.log`. |
| `sm_vmc_log_cooldown` | `1` | Log cooldown blocks to `logs/zps_voicemenu_control_cooldown.log`. |

## Immunity

Admins with the Generic flag (`b`) are exempt. Override with `sm_vmc_immunity` in `admin_overrides.cfg`.
