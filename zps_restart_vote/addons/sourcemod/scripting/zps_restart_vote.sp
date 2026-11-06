#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "0.1.2"

/* SourceMod port of the AngelScript plugin "Restart Round Vote / 重启回合投票"
 * by deliciouslunch7:
 *   https://steamcommunity.com/sharedfiles/filedetails/?id=3749397608
 *   https://steamcommunity.com/profiles/76561199746396757/myworkshopfiles/?appid=17500
 */

/* RoundWinState values. 1 and 2 confirmed from CGame_Win_Zombie::WinState()
 * and CGame_Win_Human::WinState(). 3 (stalemate) confirmed live: vote passed
 * and the end-of-round screen showed a stalemate. */
#define WINSTATE_STALEMATE 3

#define ROUND_LIVE_DELAY 12.0
#define REMINDER_INTERVAL 60.0

public Plugin myinfo =
{
	name        = "ZPS Restart Round Vote",
	author      = "Claude.ai guided by DNA.styx",
	description = "Players vote to end the current round as a stalemate. Port of Restart Round Vote by deliciouslunch7.",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

ConVar g_cvPercentage;
ConVar g_cvCountdown;
ConVar g_cvWaitTime;
ConVar g_cvDebug;

Handle g_hSetWinState;

Handle g_hRoundLiveTimer;
Handle g_hCountdownTimer;
Handle g_hReminderTimer;

bool g_bVoted[MAXPLAYERS + 1];
bool g_bRoundLive;
bool g_bCountingDown;
float g_fVoteAllowedTime;
int g_iCountdown;

char g_sLogPath[PLATFORM_MAX_PATH];

public void OnPluginStart()
{
	CreateConVar("zps_restart_vote_version", PLUGIN_VERSION, "ZPS Restart Round Vote version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_cvPercentage = CreateConVar("zps_restart_vote_percentage", "50", "Percentage of human players needed to pass the vote.", FCVAR_PROTECTED, true, 0.0, true, 100.0);
	g_cvCountdown  = CreateConVar("zps_restart_vote_countdown", "15", "Countdown seconds between vote passing and the round ending.", FCVAR_PROTECTED, true, 1.0);
	g_cvWaitTime   = CreateConVar("zps_restart_vote_waittime", "30", "Seconds after round start during which voting is blocked.", FCVAR_PROTECTED, true, 0.0);
	g_cvDebug      = CreateConVar("zps_restart_vote_debug", "0", "Log detail to the plugin log.", FCVAR_PROTECTED, true, 0.0, true, 1.0);

	AutoExecConfig(true, "zps_restart_vote");

	BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/zps_restart_vote.log");

	SetupGameData();

	AddCommandListener(Command_Say, "say");
	AddCommandListener(Command_Say, "say_team");

	RegAdminCmd("sm_restartvote_test", Command_Test, ADMFLAG_ROOT, "Force SetWinState(stalemate) immediately, bypassing the vote.");

	HookEvent("clientsound", Event_ClientSound);
}

void SetupGameData()
{
	GameData gd = new GameData("zps_restart_vote.games");
	if (gd == null)
	{
		SetFailState("Failed to load gamedata: zps_restart_vote.games");
	}

	/* CASRoundManager::SetWinState never reads 'this', so it is called as a
	 * static cdecl function with a dummy first argument (the this slot). */
	StartPrepSDKCall(SDKCall_Static);
	if (!PrepSDKCall_SetFromConf(gd, SDKConf_Signature, "CASRoundManager::SetWinState"))
	{
		delete gd;
		SetFailState("Failed to find CASRoundManager::SetWinState. Check gamedata.");
	}
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	PrepSDKCall_AddParameter(SDKType_PlainOldData, SDKPass_Plain);
	g_hSetWinState = EndPrepSDKCall();

	delete gd;

	if (g_hSetWinState == null)
	{
		SetFailState("Failed to create SDKCall for CASRoundManager::SetWinState.");
	}
}

public void OnMapStart()
{
	/* TIMER_FLAG_NO_MAPCHANGE timers are already freed at this point. */
	g_hRoundLiveTimer = null;
	g_hCountdownTimer = null;
	g_hReminderTimer = null;

	g_bRoundLive = false;
	ResetVotes();
}

public void OnClientDisconnect_Post(int client)
{
	g_bVoted[client] = false;
	CheckVotes();
}

public void OnClientPutInServer(int client)
{
	g_bVoted[client] = false;
}

/* ---------- Round tracking ---------- */

public void Event_ClientSound(Event event, const char[] name, bool dontBroadcast)
{
	char sound[64];
	event.GetString("sound", sound, sizeof(sound));

	if (StrContains(sound, "Round_Starting", false) != -1)
	{
		g_bRoundLive = false;
		ResetVotes();

		delete g_hRoundLiveTimer;
		g_hRoundLiveTimer = CreateTimer(ROUND_LIVE_DELAY, Timer_RoundLive, _, TIMER_FLAG_NO_MAPCHANGE);

		DebugLog("Round_Starting detected.");
		return;
	}

	if (StrContains(sound, "Round_End.Human", false) != -1
		|| StrContains(sound, "Round_End.Zombie", false) != -1
		|| StrContains(sound, "Round_End.Stalemate", false) != -1)
	{
		g_bRoundLive = false;
		delete g_hRoundLiveTimer;
		ResetVotes();

		DebugLog("Round end detected (sound: \"%s\").", sound);
	}
}

public Action Timer_RoundLive(Handle timer)
{
	g_hRoundLiveTimer = null;
	g_bRoundLive = true;
	g_fVoteAllowedTime = GetGameTime() + g_cvWaitTime.FloatValue;

	DebugLog("Round live. Voting allowed in %.0f seconds.", g_cvWaitTime.FloatValue);
	return Plugin_Stop;
}

/* ---------- Chat trigger ---------- */

public Action Command_Say(int client, const char[] command, int args)
{
	if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
	{
		return Plugin_Continue;
	}

	char text[64];
	GetCmdArgString(text, sizeof(text));
	StripQuotes(text);
	TrimString(text);

	if (!StrEqual(text, "!restart", false) && !StrEqual(text, "/restart", false)
		&& !StrEqual(text, "!r", false) && !StrEqual(text, "/r", false))
	{
		return Plugin_Continue;
	}

	TryVote(client);

	/* Hide the "/" silent variants, let "!" show in chat as normal. */
	return (text[0] == '/') ? Plugin_Handled : Plugin_Continue;
}

void TryVote(int client)
{
	if (!g_bRoundLive)
	{
		PrintToChat(client, "[SM] Voting is only allowed when the round is in progress.");
		return;
	}

	float now = GetGameTime();
	if (now < g_fVoteAllowedTime)
	{
		PrintToChat(client, "[SM] The round just started, please wait %d seconds before voting.", RoundToCeil(g_fVoteAllowedTime - now));
		return;
	}

	if (g_bCountingDown)
	{
		PrintToChat(client, "[SM] A restart vote has already passed.");
		return;
	}

	if (g_bVoted[client])
	{
		PrintToChat(client, "[SM] You have already voted. (%d / %d)", GetVotes(), RequiredVotes());
		return;
	}

	g_bVoted[client] = true;

	PrintToChatAll("[SM] %N wants to restart the round. (%d / %d)", client, GetVotes(), RequiredVotes());
	DebugLog("%L voted. (%d / %d)", client, GetVotes(), RequiredVotes());

	if (g_hReminderTimer == null)
	{
		g_hReminderTimer = CreateTimer(REMINDER_INTERVAL, Timer_Reminder, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	}

	CheckVotes();
}

/* ---------- Vote counting ---------- */

int GetVotes()
{
	int count = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_bVoted[i] && IsClientInGame(i) && !IsFakeClient(i))
		{
			count++;
		}
	}
	return count;
}

int RequiredVotes()
{
	int humans = 0;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
		{
			humans++;
		}
	}

	int required = RoundToFloor(float(humans) * g_cvPercentage.FloatValue / 100.0);
	return (required < 1) ? 1 : required;
}

void CheckVotes()
{
	if (!g_bRoundLive)
	{
		return;
	}

	int votes = GetVotes();
	int required = RequiredVotes();

	if (g_bCountingDown)
	{
		if (votes < required)
		{
			delete g_hCountdownTimer;
			g_bCountingDown = false;
			PrintToChatAll("[SM] Restart vote no longer has enough votes. Countdown cancelled. (%d / %d)", votes, required);
			DebugLog("Countdown cancelled. (%d / %d)", votes, required);
		}
		return;
	}

	if (votes > 0 && votes >= required)
	{
		StartCountdown();
	}
}

void StartCountdown()
{
	g_bCountingDown = true;
	g_iCountdown = g_cvCountdown.IntValue;

	delete g_hReminderTimer;

	PrintToChatAll("[SM] Vote passed. Round will restart in %d %s.", g_iCountdown, (g_iCountdown == 1) ? "second" : "seconds");
	DebugLog("Vote passed. Countdown %d seconds.", g_iCountdown);

	delete g_hCountdownTimer;
	g_hCountdownTimer = CreateTimer(1.0, Timer_Countdown, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_Countdown(Handle timer)
{
	if (!g_bRoundLive)
	{
		g_hCountdownTimer = null;
		g_bCountingDown = false;
		return Plugin_Stop;
	}

	g_iCountdown--;

	if (g_iCountdown > 0)
	{
		if (g_iCountdown <= 5)
		{
			PrintToChatAll("[SM] Restarting in: %d...", g_iCountdown);
		}
		return Plugin_Continue;
	}

	g_hCountdownTimer = null;
	ForceStalemate();
	return Plugin_Stop;
}

public Action Timer_Reminder(Handle timer)
{
	int votes = GetVotes();
	if (votes == 0 || g_bCountingDown || !g_bRoundLive)
	{
		g_hReminderTimer = null;
		return Plugin_Stop;
	}

	PrintToChatAll("[SM] Restart round votes: %d / %d needed. Type !restart to vote.", votes, RequiredVotes());
	return Plugin_Continue;
}

void ResetVotes()
{
	for (int i = 0; i <= MaxClients; i++)
	{
		g_bVoted[i] = false;
	}

	g_bCountingDown = false;
	delete g_hCountdownTimer;
	delete g_hReminderTimer;
}

/* ---------- Round end ---------- */

void ForceStalemate()
{
	DebugLog("Calling SetWinState(%d).", WINSTATE_STALEMATE);
	SDKCall(g_hSetWinState, 0, WINSTATE_STALEMATE);

	PrintToChatAll("[SM] Vote passed, the round will restart.");
	LogToFileEx(g_sLogPath, "Restart vote passed. SetWinState(%d) called.", WINSTATE_STALEMATE);

	ResetVotes();
}

public Action Command_Test(int client, int args)
{
	LogToFileEx(g_sLogPath, "%L ran sm_restartvote_test. Calling SetWinState(%d).", client, WINSTATE_STALEMATE);
	SDKCall(g_hSetWinState, 0, WINSTATE_STALEMATE);
	ReplyToCommand(client, "[SM] SetWinState(%d) called. Check the plugin log for the round end sound.", WINSTATE_STALEMATE);
	return Plugin_Handled;
}

void DebugLog(const char[] format, any ...)
{
	if (!g_cvDebug.BoolValue)
	{
		return;
	}

	char buffer[256];
	VFormat(buffer, sizeof(buffer), format, 2);
	LogToFileEx(g_sLogPath, "%s", buffer);
}
