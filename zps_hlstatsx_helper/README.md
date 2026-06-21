# DNAGames ZPS HLstatsX Helper

**Game:** Zombie Panic: Source (ZPS)
**Requires:** SourceMod 1.10+, SDK Tools extension
**Repo:** https://github.com/DNA-styx/ZPS-Helper-Plugins

## What this fixes

Zombie Panic: Source doesn't write kills, chat, connect IPs, or disconnects to the server log file, even though the events happen normally in-game. HLstatsX relies on reading these from the log file, so without this plugin it only ever shows connects/disconnects — no kill data, no chat history, and no player country flags.

This plugin watches those events directly and writes the missing lines to the log in the format HLstatsX already expects. No configuration needed.

Runs alongside SuperLogs: ZPS and the HLstatsX CE Ingame Plugin — doesn't replace either.

## Installation

1. Compile `zps_hlstatsx_helper.sp`.
2. Copy the `.smx` to `addons/sourcemod/plugins/`.
3. Load it:
   ```
   sm plugins load zps_hlstatsx_helper
   ```

## Changes

- Kill/death/skill tracking restored (including headshots).
- Chat logging restored, with team messages marked `(Team)`.
- Real connect IPs logged, fixing GeoIP/country flags.
- Disconnects logged, closing out player sessions cleanly.
