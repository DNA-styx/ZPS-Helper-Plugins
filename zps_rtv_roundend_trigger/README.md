# ZPS RTV Round End Trigger

Makes SourceMod's Rock The Vote "change at round end" mode work in ZPS. After an RTV vote passes, the map changes when the round ends.

## Requirements

- SourceMod with `rockthevote.smx` and `nextmap.smx` loaded
- `sm_rtv_changetime 1` (change at round end). The plugin does nothing with any other value.

## Install

1. Copy `zps_rtv_roundend_trigger.smx` to `addons/sourcemod/plugins/`

## ConVars

Set in `cfg/sourcemod/zps_rtv_roundend_trigger.cfg` (auto-generated on first load).

| ConVar | Default | Description |
|---|---|---|
| `zps_rtv_roundend_trigger_delay` | `10.0` | Seconds after round end before the map changes. |
| `zps_rtv_roundend_trigger_debug` | `0` | Log detection steps to `logs/zps_rtv_roundend_trigger.log`. |
