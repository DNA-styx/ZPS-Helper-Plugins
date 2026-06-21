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

#define PLUGIN_VERSION "1.5.0"
#define MAX_TEAMS 8

char g_sTeamName[MAX_TEAMS][32];

public Plugin myinfo =
{
	name        = "DNAGames ZPS HLstatsX Helper",
	author      = "claude.ai guided by DNA.styx",
	description = "Fixes missing kill, chat, connect/IP, disconnect, and join logging for HLstatsX on Zombie Panic: Source.",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
	CacheTeamNames();

	HookEvent("player_feed", Event_PlayerFeed);
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
	bool headshot = event.GetBool("headshot");

	// Player-on-player kills and infections only.
	// World/environment deaths (no valid attacker) are skipped.
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

	char victimName[MAX_NAME_LENGTH], attackerName[MAX_NAME_LENGTH];
	char victimAuth[32], attackerAuth[32];
	char victimTeam[32], attackerTeam[32];

	GetClientName(victim, victimName, sizeof(victimName));
	GetClientName(attacker, attackerName, sizeof(attackerName));
	GetClientAuthId(victim, AuthId_Steam2, victimAuth, sizeof(victimAuth));
	GetClientAuthId(attacker, AuthId_Steam2, attackerAuth, sizeof(attackerAuth));
	GetTeamNameForClient(victim, victimTeam, sizeof(victimTeam));
	GetTeamNameForClient(attacker, attackerTeam, sizeof(attackerTeam));

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
