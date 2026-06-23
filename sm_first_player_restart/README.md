# SM First Player Restart

Reloads the current map when the first real player joins a server that has been running with bots. This gives the player a clean lobby with team selection rather than being dropped into an active round.

## How It Works

When a real player connects, the plugin checks:
- The map has been running longer than the minimum age threshold
- No other real players are already in-game

If both conditions are met, the server reloads the current map. The player reconnects automatically and enters the lobby with full team selection.

The minimum map age also acts as loop prevention — after a reload, the map age resets to zero, so the plugin will not trigger again on reconnect.

## Installation

1. Copy `sm_firstplayer_restart.smx` to `addons/sourcemod/plugins/`
2. Restart the server or run `sm plugins load sm_firstplayer_restart`
3. Configuration file is created automatically at `cfg/sourcemod/sm_firstplayer_restart.cfg`

## ConVars

| ConVar | Default | Description |
|--------|---------|-------------|
| `sm_firstplayer_restart_enabled` | `1` | Enable or disable the plugin. Set to `0` to disable. |
| `sm_firstplayer_restart_minage` | `60.0` | Minimum map age in seconds before a reload can trigger. Increase this if bots take longer to fill a round on your server. |
| `sm_firstplayer_restart_version` | current | Plugin version. Read-only. |

## Notes

- Compatible with any Source game using SourceMod.
- If your server uses hibernation (`sv_hibernate_when_empty 1`), consider setting `sv_hibernate_when_empty 0` in your server config. When the server hibernates, bots are removed on player disconnect which may affect bot behaviour.
- The plugin only triggers once per map load. If multiple players join simultaneously, only the first triggers the reload.

## Author

Claude.ai guided by DNA.styx
