# ZPS Beacon Last Bot

Beacons the last surviving bot on the Survivor team.

## What it does

When exactly one Survivor Bot remains alive, the plugin:

- Prints `[NAV] Last bot beaconed` to chat 
- Triggers a beacon effect on that bot

## Why it's useful

If a bot gets stuck (bad nav mesh, blocked path, stuck on geometry), it can be the last
one alive for an extended period. This plugin makes that bot easy to find.

## Installation

Place `zps_beacon_lastbot.smx` in `addons/sourcemod/plugins/`.
