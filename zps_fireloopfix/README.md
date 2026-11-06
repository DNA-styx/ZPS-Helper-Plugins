# ZPS Fire Loop Fix

Stops the burning sound (`fire_small_loop2.wav`) from looping forever after a burning player dies.

## Requirements

- SourceMod

## Install

1. Copy `zps_fireloopfix.smx` to `addons/sourcemod/plugins/`

## ConVars

No config file is generated. Set in `server.cfg` if needed.

| ConVar | Default | Description |
|---|---|---|
| `sm_fireloopfix_debug` | `0` | Log flame tracking and stops to `logs/zps_fireloopfix.log`. |
