# ZPS Bot Flashlight - Server Admin Guide

Version: 1.3
Source: https://github.com/DNA-styx/ZPS-Helper-Plugins

## What it does

Randomly turns NavBot-controlled bots' flashlights on and off, simulating
the player's F key (`enhancevision`). Cosmetic only, no effect on bot AI.
No team filtering - zombie-team bots are also affected, toggling Zombie
Vision for them instead.

## Installation

1. Compile `zps-bot-flashlight.sp` to `.smx`.
2. Place in `addons/sourcemod/plugins/`.
3. Load via server restart or `sm plugins load zps-bot-flashlight`.

## Configuration

No cvars yet; settings are fixed in source (recompile to change):

| Setting | Value |
|---|---|
| Check interval | 8s |
| Toggle chance | 20% per check |
| On-duration | 60-100s |
| Battery life (reference) | 120s |

## Known limitations

- No team filtering (intentional for now).
- On/off state is tracked locally, not read from the game. A roll near
  the top of the on-duration range carries a small risk of desyncing
  with natural battery drain.

## Version history

v1.0-1.2: initial build, tuned on-duration to real battery life, removed
dev logging. v1.3: added project URL.
