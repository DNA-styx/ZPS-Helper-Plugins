# ZPS NavBot Unstuck

Stuck NavBot zombie bots crouch, then crouch-jump, then alternate between crouch-jumping and standing jumps to get past props. The response escalates the longer a bot stays stuck.

## Requirements

- SourceMod
- NavBot

## Install

1. Copy `zps_navbot_unstuck.smx` to `addons/sourcemod/plugins/`

## ConVars

Set in `cfg/sourcemod/zps_navbot_unstuck.cfg` (auto-generated on first load). Stuck events occur once per second.

| ConVar | Default | Description |
|---|---|---|
| `sm_navbot_zunstuck_enabled` | `1` | Turn the plugin on/off. |
| `sm_navbot_zunstuck_crouch_count` | `3` | Stuck events before the bot crouches. `0` = skip stage. |
| `sm_navbot_zunstuck_jump_count` | `6` | Stuck events before the bot crouch-jumps. `0` = skip stage. |
| `sm_navbot_zunstuck_alternate_count` | `10` | Stuck events before the bot alternates crouch and standing jumps. `0` = skip stage. |
| `sm_navbot_zunstuck_crouch_duration` | `1.5` | Seconds crouch is held per stuck event. |
| `sm_navbot_zunstuck_debug` | `0` | Log each action to `logs/zps_navbot_unstuck.log`. |
