#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

// claude.ai guided by DNA.styx
//
// Zombie Panic: Source doesn't write kills, chat, connect IPs,
// disconnects, or "entered the game" lines to the server log file, even
// though the events happen normally in-game. This breaks HLstatsX, which
// reads the log file (and RCON status, which is also non-standard on
// this server) to track kills/deaths/skill, chat history, GeoIP/country
// flags, and ConnectAnnounce.
//
// This plugin watches those events directly and writes the missing
// lines to the log in the standard format HLstatsX already expects.
// The "entered the game" line/format was confirmed directly against the
// HLstatsZ daemon's own source (doEvent_EnterGame in
// HLstats_EventHandlers.plib, github.com/SnipeZilla/HLSTATS-2).

#define PLUGIN_VERSION "1.9.3"
#define MAX_TEAMS 8
#define TEAM_SURVIVORS 2
#define TEAM_ZOMBIES 3

char g_sTeamName[MAX_TEAMS][32];

public Plugin myinfo =
{
	name        = "DNAGames ZPS HLstatsX Helper",
	author      = "Claude.ai guided by DNA.styx",
	description = "Fixes missing kill, chat, connect/IP, disconnect, and join logging for HLstatsX on Zombie Panic: Source.",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
	CacheTeamNames();

	HookEvent("player_feed", Event_PlayerFeed);
	HookEvent("clientsound", Event_ClientSound);
	HookEvent("clientsound_player", Event_ClientSoundPlayer);
	AddCommandListener(Command_Say, "say");
	AddCommandListener(Command_Say, "say_team");
}

public void OnClientAuthorized(int client, const char[] auth)
{
	if (IsFakeClient(client))
	{
		return;
	}

	char ip[32];
	GetClientIP(client, ip, sizeof(ip));

	char playerName[MAX_NAME_LENGTH], playerAuth[32];
	GetClientName(client, playerName, sizeof(playerName));
	GetClientAuthId(client, AuthId_Steam2, playerAuth, sizeof(playerAuth));

	// Team is intentionally blank here - team selection hasn't happened yet
	// at authorization time, matching standard engine connect-line behavior
	// on other mods (e.g. DoD:S/CS:S also log connects with an empty team).
	// Port is a placeholder - confirmed the daemon's parsing regex discards
	// it and only keeps the IP portion.
	LogToGame("\"%s<%d><%s><>\" connected, address \"%s:0\"",
		playerName, GetClientUserId(client), playerAuth, ip);
}

public void OnClientPutInServer(int client)
{
	if (IsFakeClient(client))
	{
		return;
	}

	// Matches doEvent_EnterGame in the daemon, which is what drives
	// ConnectAnnounce (and requires this line to fire after the
	// "connected, address" line, since it needs an existing player
	// record with a valid userid - guaranteed here since
	// OnClientAuthorized always fires before OnClientPutInServer).
	char playerName[MAX_NAME_LENGTH], playerAuth[32], playerTeam[32];
	GetClientName(client, playerName, sizeof(playerName));
	GetClientAuthId(client, AuthId_Steam2, playerAuth, sizeof(playerAuth));
	GetTeamNameForClient(client, playerTeam, sizeof(playerTeam));

	LogToGame("\"%s<%d><%s><%s>\" entered the game",
		playerName, GetClientUserId(client), playerAuth, playerTeam);
}

public void OnClientDisconnect(int client)
{
	// Unlike OnClientAuthorized, bots are NOT skipped here. The daemon has
	// no other way to learn a bot has left (ZPS doesn't log bot
	// connects/disconnects natively, and NavBot's quota system cycles bots
	// constantly), so without this line every bot that's ever appeared in
	// a kill/weaponstats line stays "currently playing" forever. The
	// daemon's own disconnect handler already has bot-specific logic that
	// correctly excludes them from stats (matching the server's
	// IgnoreBots setting) while still removing them from tracking.
	char playerName[MAX_NAME_LENGTH], playerAuth[32], playerTeam[32];
	GetClientName(client, playerName, sizeof(playerName));
	GetClientAuthId(client, AuthId_Steam2, playerAuth, sizeof(playerAuth));
	GetTeamNameForClient(client, playerTeam, sizeof(playerTeam));

	LogToGame("\"%s<%d><%s><%s>\" disconnected (reason \"Disconnect\")",
		playerName, GetClientUserId(client), playerAuth, playerTeam);
}

public void OnMapStart()
{
	CacheTeamNames();
}

// Proven approach used by SuperLogs/HLstatsX's loghelper.inc (GetTeams()):
// query the engine's own team list directly via SourceMod natives rather
// than relying on the team_info broadcast event, which testing confirmed
// does not fire on this server.
void CacheTeamNames()
{
	int teamCount = GetTeamCount();
	for (int i = 0; i < teamCount && i < MAX_TEAMS; i++)
	{
		char teamName[32];
		GetTeamName(i, teamName, sizeof(teamName));
		if (teamName[0] != '\0')
		{
			strcopy(g_sTeamName[i], sizeof(g_sTeamName[]), teamName);
		}
	}
}

void GetTeamNameSafe(int team, char[] buffer, int maxlen)
{
	if (team >= 0 && team < MAX_TEAMS && g_sTeamName[team][0] != '\0')
	{
		strcopy(buffer, maxlen, g_sTeamName[team]);
	}
	else
	{
		strcopy(buffer, maxlen, "Unassigned");
	}
}

// Combines the IsClientInGame guard with team lookup in one place, used
// everywhere GetClientTeam is needed. GetClientTeam can throw "Client X
// is not in game" for clients invalidated right before the calling
// callback runs (confirmed via SourceMod error log on OnClientDisconnect,
// likely due to NavBot's quota-cycle churn) - centralizing the guard here
// means every call site is protected the same way rather than relying on
// guards living at different points in different functions.
void GetTeamNameForClient(int client, char[] buffer, int maxlen)
{
	if (IsClientInGame(client))
	{
		GetTeamNameSafe(GetClientTeam(client), buffer, maxlen);
	}
	else
	{
		strcopy(buffer, maxlen, "Unassigned");
	}
}

public void Event_PlayerFeed(Event event, const char[] name, bool dontBroadcast)
{
	int victim   = GetClientOfUserId(event.GetInt("userid"));
	int attacker = GetClientOfUserId(event.GetInt("attacker"));
	bool death    = event.GetBool("death");
	bool headshot = event.GetBool("headshot");

	// Environmental deaths: attacker=0 means a world/map source killed the player.
	// Only FALL (dmgbits 32), DROWN (dmgbits 16384), and BURN (dmgbits 8 or
	// 268435456) are logged. trigger_hurt generic (dmgbits 0) and crush
	// (dmgbits 1) are skipped — confirmed via feed logger analysis.
	// entityflame (268435456) is ZPS-specific fire damage, mapped to zps_burn.
	if (victim > 0 && attacker <= 0 && death && IsClientInGame(victim))
	{
		int dmgbits = event.GetInt("dmgbits");
		char suicideWeapon[32];

		if (dmgbits & 32)
		{
			strcopy(suicideWeapon, sizeof(suicideWeapon), "zps_fall");
		}
		else if (dmgbits & 16384)
		{
			strcopy(suicideWeapon, sizeof(suicideWeapon), "zps_drown");
		}
		else if ((dmgbits & 8) || (dmgbits & 268435456))
		{
			strcopy(suicideWeapon, sizeof(suicideWeapon), "zps_burn");
		}

		if (suicideWeapon[0] != '\0')
		{
			char victimName[MAX_NAME_LENGTH], victimAuth[32], victimTeam[32];
			GetClientName(victim, victimName, sizeof(victimName));
			GetClientAuthId(victim, AuthId_Steam2, victimAuth, sizeof(victimAuth));
			GetTeamNameForClient(victim, victimTeam, sizeof(victimTeam));

			LogToGame("\"%s<%d><%s><%s>\" committed suicide with \"%s\"",
				victimName, GetClientUserId(victim), victimAuth, victimTeam,
				suicideWeapon);

			// Additional "triggered" line so these deaths also show as
			// zero-reward PlayerActions on the Actions page, matching the
			// zps_panic pattern. Requires matching hlstats_Actions rows
			// (game='zps', code=zps_fall/zps_drown/zps_burn) - deliberately
			// reuses the same code strings as the hlstats_Weapons entries
			// since Actions and Weapons are separate tables with no naming
			// conflict.
			LogToGame("\"%s<%d><%s><%s>\" triggered \"%s\"",
				victimName, GetClientUserId(victim), victimAuth, victimTeam,
				suicideWeapon);
		}
		return;
	}

	// Player-on-player kills and infections only.
	// All other world/environment deaths are skipped.
	if (victim <= 0 || attacker <= 0 || victim == attacker)
	{
		return;
	}
	if (!IsClientInGame(victim) || !IsClientInGame(attacker))
	{
		return;
	}

	char weapon[64];
	event.GetString("weapon", weapon, sizeof(weapon));

	// Strip "weapon_" classname prefix if present, matching the short
	// weapon names HLstatsX/SuperLogs already use (e.g. "weapon_ak47" -> "ak47").
	// "zombie_claws_of_death" has no such prefix and passes through unchanged,
	// matching the daemon's existing special case for it.
	if (strncmp(weapon, "weapon_", 7) == 0)
	{
		strcopy(weapon, sizeof(weapon), weapon[7]);
	}

	char attackerName[MAX_NAME_LENGTH], attackerAuth[32], attackerTeam[32];
	GetClientName(attacker, attackerName, sizeof(attackerName));
	GetClientAuthId(attacker, AuthId_Steam2, attackerAuth, sizeof(attackerAuth));
	GetTeamNameForClient(attacker, attackerTeam, sizeof(attackerTeam));

	// When weapon is "infected" and death is false, the carrier has tagged a
	// survivor with infection - the survivor is still alive and may self-heal.
	// Logged as a Player-vs-Player action ("triggered X against Y") rather
	// than a plain player action, since hlstats_Actions.zps_infected_player
	// is now for_PlayerPlayerActions=1 / for_PlayerActions=0 (v1.9.3). The
	// daemon's hlstats.pl "triggered ... against ..." regex requires both
	// full player strings (confirmed against HLstats_EventHandlers.plib
	// doEvent_PlayerPlayerAction call path).
	if (StrEqual(weapon, "infected") && !death)
	{
		char victimName[MAX_NAME_LENGTH], victimAuth[32], victimTeam[32];
		GetClientName(victim, victimName, sizeof(victimName));
		GetClientAuthId(victim, AuthId_Steam2, victimAuth, sizeof(victimAuth));
		GetTeamNameForClient(victim, victimTeam, sizeof(victimTeam));

		LogToGame("\"%s<%d><%s><%s>\" triggered \"zps_infected_player\" against \"%s<%d><%s><%s>\"",
			attackerName, GetClientUserId(attacker), attackerAuth, attackerTeam,
			victimName, GetClientUserId(victim), victimAuth, victimTeam);
		return;
	}

	// Skip non-death events for all other weapons.
	if (!death)
	{
		return;
	}

	char victimName[MAX_NAME_LENGTH], victimAuth[32], victimTeam[32];
	GetClientName(victim, victimName, sizeof(victimName));
	GetClientAuthId(victim, AuthId_Steam2, victimAuth, sizeof(victimAuth));
	GetTeamNameForClient(victim, victimTeam, sizeof(victimTeam));

	char props[16];
	props[0] = '\0';
	if (headshot)
	{
		strcopy(props, sizeof(props), " (headshot)");
	}

	LogToGame("\"%s<%d><%s><%s>\" killed \"%s<%d><%s><%s>\" with \"%s\"%s",
		attackerName, GetClientUserId(attacker), attackerAuth, attackerTeam,
		victimName, GetClientUserId(victim), victimAuth, victimTeam,
		weapon, props);
}

public void Event_ClientSound(Event event, const char[] name, bool dontBroadcast)
{
	char sound[64];
	event.GetString("sound", sound, sizeof(sound));

	if (StrContains(sound, "Round_Starting", false) != -1)
	{
		// Resets the daemon's internal round_status counter, which gates
		// team-reward processing in doEvent_TeamAction (confirmed via
		// HLstatsZ source, HLstats_EventHandlers.plib). ZPS's native
		// round_start event is unreliable, so without this line only the
		// first round win after a daemon restart would ever pay out -
		// round_status never resets and every subsequent win gets
		// silently ignored as "round in progress".
		LogToGame("World triggered \"Round_Start\"");
	}
	else if (StrContains(sound, "Round_End.Human", false) != -1)
	{
		LogRoundWin(TEAM_SURVIVORS, "zps_survivor_win", "zps_survivor_alive");
	}
	else if (StrContains(sound, "Round_End.Zombie", false) != -1)
	{
		LogRoundWin(TEAM_ZOMBIES, "zps_zombie_win", "zps_zombie_alive");
	}
	// Round_End.Stalemate intentionally produces no log lines - no
	// reward is configured for a draw.
}

// Single Team-triggered line rewards every tracked player on the
// winning team via the daemon's rewardTeam(), regardless of alive/dead
// status. Per-player triggered lines on top of that give an additional
// bonus only to players still alive when the round ended.
void LogRoundWin(int winningTeam, const char[] teamAction, const char[] aliveAction)
{
	char teamName[32];
	GetTeamNameSafe(winningTeam, teamName, sizeof(teamName));

	LogToGame("Team \"%s\" triggered \"%s\"", teamName, teamAction);

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != winningTeam)
		{
			continue;
		}

		char playerName[MAX_NAME_LENGTH], playerAuth[32];
		GetClientName(i, playerName, sizeof(playerName));
		GetClientAuthId(i, AuthId_Steam2, playerAuth, sizeof(playerAuth));

		LogToGame("\"%s<%d><%s><%s>\" triggered \"%s\"",
			playerName, GetClientUserId(i), playerAuth, teamName, aliveAction);
	}
}

public void Event_ClientSoundPlayer(Event event, const char[] name, bool dontBroadcast)
{
	char sound[64];
	event.GetString("sound", sound, sizeof(sound));

	// ZPlayer.Panic fires via clientsound_player when a survivor panics.
	// Confirmed via sound monitor log (07/01/2026). Logged as a zero-point
	// player action for statistical tracking only.
	if (!StrEqual(sound, "ZPlayer.Panic", false))
	{
		return;
	}

	int client = event.GetInt("entindex");

	if (client < 1 || client > MaxClients || !IsClientInGame(client))
	{
		return;
	}

	char playerName[MAX_NAME_LENGTH], playerAuth[32], playerTeam[32];
	GetClientName(client, playerName, sizeof(playerName));
	GetClientAuthId(client, AuthId_Steam2, playerAuth, sizeof(playerAuth));
	GetTeamNameForClient(client, playerTeam, sizeof(playerTeam));

	LogToGame("\"%s<%d><%s><%s>\" triggered \"zps_panic\"",
		playerName, GetClientUserId(client), playerAuth, playerTeam);
}

public Action Command_Say(int client, const char[] command, int args)
{
	if (client <= 0 || !IsClientInGame(client))
	{
		return Plugin_Continue;
	}

	char text[192];
	GetCmdArgString(text, sizeof(text));

	// The engine wraps the say argument string in quotes (e.g. "hello") -
	// strip them so the log doesn't end up with doubled/nested quotes.
	int len = strlen(text);
	if (len >= 2 && text[0] == '"' && text[len - 1] == '"')
	{
		text[len - 1] = '\0';
		strcopy(text, sizeof(text), text[1]);
	}

	bool teamOnly = StrEqual(command, "say_team", false);

	char playerName[MAX_NAME_LENGTH], playerAuth[32], playerTeam[32];
	GetClientName(client, playerName, sizeof(playerName));
	GetClientAuthId(client, AuthId_Steam2, playerAuth, sizeof(playerAuth));
	GetTeamNameForClient(client, playerTeam, sizeof(playerTeam));

	// Per DNA.styx: log all chat (public + team) through one "say" stream,
	// with team-restricted messages marked via a "(Team)" text prefix
	// rather than a separate say_team verb.
	char message[224];
	if (teamOnly)
	{
		Format(message, sizeof(message), "(Team) %s", text);
	}
	else
	{
		strcopy(message, sizeof(message), text);
	}

	LogToGame("\"%s<%d><%s><%s>\" say \"%s\"",
		playerName, GetClientUserId(client), playerAuth, playerTeam, message);

	return Plugin_Continue;
}
