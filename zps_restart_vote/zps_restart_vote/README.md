# ZPS Restart Round Vote

Players vote in chat to end the current round as a stalemate. SourceMod replacement for the AngelScript "Restart Round Vote" plugin.

**Version:** 0.1.1
**Author:** Claude.ai guided by DNA.styx

## Credits

Based on the AngelScript plugin [Restart Round Vote / 重启回合投票](https://steamcommunity.com/sharedfiles/filedetails/?id=3749397608) by [deliciouslunch7](https://steamcommunity.com/profiles/76561199746396757/myworkshopfiles/?appid=17500).
**Requires:** SourceMod 1.12+, SDK Tools

## Installation

1. Copy `gamedata/zps_restart_vote.games.txt` to `addons/sourcemod/gamedata/`.
2. Compile `zps_restart_vote.sp` and copy the `.smx` to `addons/sourcemod/plugins/`.
3. Remove the AngelScript version if installed.
4. Change map, or `sm plugins load zps_restart_vote`. Voting becomes available from the next round start.

## Usage

Type `!restart`, `/restart`, `!r` or `/r` in chat. When enough human players have voted, a countdown runs and the round ends as a stalemate.

## ConVars

| ConVar | Default | Description |
|---|---|---|
| `zps_restart_vote_percentage` | `50` | Percentage of human players needed (minimum 1 vote). |
| `zps_restart_vote_countdown` | `15` | Seconds between the vote passing and the round ending. |
| `zps_restart_vote_waittime` | `30` | Seconds after the round goes live during which voting is blocked. |
| `zps_restart_vote_debug` | `0` | Log detail to `logs/zps_restart_vote.log`. |

## Admin command

`sm_restartvote_test` (root) calls the stalemate immediately, bypassing the vote. Used to confirm the win-state value.

## Notes

- Bots are not counted and cannot vote.
- The round is ended via `CASRoundManager::SetWinState`, the same engine function the AngelScript plugin uses.
- The round is treated as live 12 seconds after `Round_Starting`; the wait time starts from that point.
