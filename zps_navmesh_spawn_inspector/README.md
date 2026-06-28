# ZPS NavMesh Spawn Inspector

A SourceMod plugin for Zombie Panic: Source that lets server admins walk through every spawn point that lacks NavMesh coverage, as reported by [spawnpoint_checker](https://github.com/DNA-styx/ZPS-Helper-Plugins). Designed for use during NavBot navmesh authoring on new or updated maps.

---

## Overview

When building a NavBot navmesh for a new ZPS map, spawn points that fall outside navmesh coverage will cause bots to behave incorrectly — they will not be able to navigate to or from those locations. The `spawnpoint_checker` plugin logs these problem positions at map start. This plugin reads those logs and lets you teleport to each position in sequence from an in-game menu, so you can identify and fix gaps in the navmesh without manually entering coordinates.

---

## Requirements

- SourceMod 1.12
- [spawnpoint_checker.smx](https://github.com/DNA-styx/ZPS-Helper-Plugins) — generates the log files this plugin reads
- `ADMFLAG_ROOT` admin flag

---

## Installation

1. Copy `zps_navmesh_spawn_inspector.smx` to `addons/sourcemod/plugins/`
2. Copy `zps_navmesh_spawn_inspector.phrases.txt` to `addons/sourcemod/translations/`
3. Restart the server or run `sm plugins load zps_navmesh_spawn_inspector`

---

## Workflow

1. Load the map you want to inspect
2. `spawnpoint_checker` runs automatically at map start and writes a log to `addons/sourcemod/logs/spchecker_<mapname>_YYYY-MM-DD.log`
3. Open the inspector via `!spcheck` in chat or `sm_spcheck` in console
4. Select the current map from the menu
5. Use **Next** and **Previous** to step through each flagged spawn point — the plugin teleports you there automatically
6. At each position, open the navmesh editor (`nav_edit 1`) and add or extend nav areas to cover the spawn point
7. When all positions have navmesh coverage, selecting that map from the list will show a confirmation menu offering to delete all dated log files for that map. Deleting them removes the map from the inspector's list once the work is complete.

---

## Commands

| Command | Access | Description |
|---|---|---|
| `!spcheck` / `sm_spcheck` | `ADMFLAG_ROOT` | Open the NavMesh Spawn Inspector menu |

The menu opens automatically when an admin connects to the server, if logs exist.

---

## Menu Reference

### Map Selection Menu

Lists all maps that have a spawnpoint_checker log, sorted most recent first. The current map is marked `[current]`. Each entry shows the map name and the date of its most recent log run.

If the current map has no log yet, a disabled placeholder entry is shown — run `spawnpoint_checker` first (`sm_check_spawnpoints` if that command is available, or restart the map).

Selecting a map that is not currently loaded will prompt a map change confirmation.

### Navigation Menu

Displays the current position number, total count, entity type, and coordinates in the menu title. Use **Next** and **Previous** to move through the list — teleportation happens immediately on click.

The inspector skips `info_player_commons` (lobby/AI spawn points) and `info_player_observer` (spectator spawns), as these do not require navmesh coverage. Only `info_player_zombie`, `info_player_human`, and `info_player_carrier` spawn points are shown.

### Delete Log Menu

If all positions in a log are filtered out — meaning every spawn point for that map has navmesh coverage — selecting the map instead opens a confirmation menu:

```
All valid spawn positions have Navmesh.
Delete log file?
```

Confirming deletes **all dated log files** for that map (e.g. both `spchecker_zps_town_2026-06-26.log` and `spchecker_zps_town_2026-06-27.log`), not just the most recent one. The map is then removed from the inspector's list. The number of files deleted is reported in chat.

Declining returns to the map list without deleting anything.

---

## Log File Format

Logs are written by `spawnpoint_checker` to:

```
addons/sourcemod/logs/spchecker_<mapname>_YYYY-MM-DD.log
```

If `sm_check_spawnpoints` is run more than once on the same day, positions will be duplicated in the log. This does not cause errors — duplicate coordinates will appear as repeated entries in the navigation menu.

---

## Notes

- `sv_cheats 1` is **not** required — teleportation is handled server-side via `TeleportEntity`
- The menu closes automatically on map change
- The plugin unloads cleanly and cancels open menus via `OnPluginEnd`
- Only the most recent log per map is shown in the inspector's map list — older dated logs are not displayed, but **are deleted** when you confirm the delete action

---

## Part of ZPS Helper Plugins

[https://github.com/DNA-styx/ZPS-Helper-Plugins](https://github.com/DNA-styx/ZPS-Helper-Plugins)
