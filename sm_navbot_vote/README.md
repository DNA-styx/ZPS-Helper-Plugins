# NavBot Vote

Lets any connected player start a vote to remove/add NavBot bots or change the bot skill level, without requiring an admin present.

**Version:** 1.3.0
**Author:** Claude.ai guided by DNA.styx

## Requirements

- SourceMod 1.12+
- [NavBot](https://github.com/caxanga334/NavBot) extension loaded (`sm_navbot_quota_target`, `sm_navbot_skill_level`, `sm_navbot_reload_difficulty_profiles` must be available)

## Installation

1. Compile `sm_navbot_vote.sp` and place `sm_navbot_vote.smx` in `addons/sourcemod/plugins/`.
2. Restart the map or run `sm plugins load sm_navbot_vote`.
3. A default config is generated at `cfg/sourcemod/sm_navbot_vote.cfg` on first load.

## Usage

Players type `!bots` in chat, or run `sm_navbot_vote`, to open a menu with two options:

- **Remove Bots / Add Bots** — label switches automatically depending on current bot state. Passing sets `sm_navbot_quota_target` to `-1` and kicks all bots (`sm_kick @bots`), or restores the quota target to bring bots back.
- **Change Skill** — shows Easy / Normal / Hard / Expert. The currently active level is shown but not selectable. Passing sets `sm_navbot_skill_level` and reloads NavBot's difficulty profiles.

Each selection starts a server-wide Yes/No vote. No admin flag is required to trigger a vote.

## ConVars

| ConVar | Default | Description |
|---|---|---|
| `sm_navbot_vote_cooldown` | `300.0` | Seconds between vote attempts (shared across bot-count and skill votes). |
| `sm_navbot_vote_percent` | `0.60` | Fraction of Yes votes required to pass (0.05–1.0). |
| `sm_navbot_vote_restore_target` | `10` | `sm_navbot_quota_target` value applied when a vote re-enables bots. |
| `sm_navbot_vote_version` | — | Plugin version (read-only). |

## Notes

- Skill level names (Easy/Normal/Hard/Expert) are hardcoded to NavBot's default `bot_difficulty.cfg`. If your server uses a customized profile file, update `g_sSkillNames[]` in the source to match.
- Your `server.cfg` skill setting will override the vote result on map change/restart, as expected.
