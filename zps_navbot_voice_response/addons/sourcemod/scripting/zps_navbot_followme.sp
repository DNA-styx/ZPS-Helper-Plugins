#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>
#include <navbot>

#define TEAM_SURVIVORS 2
#define MAX_FOLLOWERS_CAP 8
#define SQUAD_POLL_INTERVAL 1.0

DynamicDetour g_hVoiceMenuDetour;
Handle g_hSDKVoiceMenu;
ConVar g_cvChatMessage;
ConVar g_cvSquadDuration;
ConVar g_cvMaxFollowers;

int g_iSquadLeaderBot[MAXPLAYERS + 1];
float g_fSquadStartTime[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name        = "ZPS NavBot FollowMe",
	author      = "Claude.ai guided by DNA.styx",
	description = "Nearest available survivor Navbots form a squad with the caller on #VOICE_FOLLOWME.",
	version     = "0.12.0",
	url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
	CreateConVar("sm_zps_navbot_followme_version", "0.12.0", "ZPS NavBot FollowMe version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvChatMessage = CreateConVar("sm_zps_navbot_followme_chatmsg", "0", "Print a chat message to the caller when a bot joins the squad. 0 = off, 1 = on.", FCVAR_PROTECTED);
	g_cvSquadDuration = CreateConVar("sm_zps_navbot_followme_duration", "300.0", "Time in seconds a follow squad stays active before automatically disbanding.", FCVAR_PROTECTED);
	g_cvMaxFollowers = CreateConVar("sm_zps_navbot_followme_maxfollowers", "2", "Max number of bots that can join a follow squad (1 to 8).", FCVAR_PROTECTED);

	AutoExecConfig(true, "zps_navbot_followme");

	HookEvent("clientsound", Event_ClientSound);
	CreateTimer(SQUAD_POLL_INTERVAL, Timer_CheckSquads, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	char gamedataPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, gamedataPath, sizeof(gamedataPath), "gamedata/zps_navbot_followme.games.txt");

	if (!FileExists(gamedataPath))
	{
		SetFailState("Missing gamedata file: gamedata/zps_navbot_followme.games.txt");
	}

	GameData gc = new GameData("zps_navbot_followme.games");
	if (gc == null)
	{
		SetFailState("Failed to load gamedata: zps_navbot_followme");
	}

	g_hVoiceMenuDetour = DynamicDetour.FromConf(gc, "OnPlayerVoiceMenu");
	if (g_hVoiceMenuDetour == null)
	{
		delete gc;
		SetFailState("Failed to create detour for CZP_Player::VoiceMenu. Check gamedata.");
	}

	g_hVoiceMenuDetour.Enable(Hook_Post, Hook_OnVoiceMenuPost);

	StartPrepSDKCall(SDKCall_Player);
	if (!PrepSDKCall_SetFromConf(gc, SDKConf_Signature, "CZP_Player::VoiceMenu"))
	{
		delete gc;
		SetFailState("Failed to find CZP_Player::VoiceMenu signature for SDKCall. Check gamedata.");
	}
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
	g_hSDKVoiceMenu = EndPrepSDKCall();
	if (g_hSDKVoiceMenu == null)
	{
		delete gc;
		SetFailState("Failed to create SDKCall for CZP_Player::VoiceMenu.");
	}

	delete gc;
}

public void OnPluginEnd()
{
	if (g_hVoiceMenuDetour != null)
	{
		g_hVoiceMenuDetour.Disable(Hook_Post, Hook_OnVoiceMenuPost);
	}
}

void Event_ClientSound(Event event, const char[] name, bool dontBroadcast)
{
	char sound[64];
	event.GetString("sound", sound, sizeof(sound));

	if (StrEqual(sound, "Round_Starting", false))
	{
		for (int i = 1; i <= MaxClients; i++)
		{
			ClearSquadTracking(i);
		}
	}
}

public MRESReturn Hook_OnVoiceMenuPost(int client, DHookParam params)
{
	if (!(1 <= client <= MaxClients) || !IsClientInGame(client) || IsFakeClient(client))
	{
		return MRES_Ignored;
	}

	if (GetClientTeam(client) != TEAM_SURVIVORS || !IsPlayerAlive(client))
	{
		return MRES_Ignored;
	}

	char szInternal[64];
	params.GetString(1, szInternal, sizeof(szInternal));

	if (!StrEqual(szInternal, "Cover"))
	{
		return MRES_Ignored;
	}

	if (g_iSquadLeaderBot[client] != 0)
	{
		HandleRepeatTrigger(client);
		return MRES_Ignored;
	}

	int maxFollowers = g_cvMaxFollowers.IntValue;

	if (maxFollowers < 1)
	{
		maxFollowers = 1;
	}
	else if (maxFollowers > MAX_FOLLOWERS_CAP)
	{
		maxFollowers = MAX_FOLLOWERS_CAP;
	}

	int bots[MAX_FOLLOWERS_CAP];
	int count;
	FindNearestSurvivorBots(client, bots, maxFollowers, count);

	if (count == 0)
	{
		return MRES_Ignored;
	}

	StartFollow(bots, count, client);

	return MRES_Ignored;
}

void FindNearestSurvivorBots(int caller, int[] bots, int maxBots, int &count)
{
	float callerPos[3];
	GetClientAbsOrigin(caller, callerPos);

	float bestDist[MAX_FOLLOWERS_CAP];
	int bestBot[MAX_FOLLOWERS_CAP];

	for (int j = 0; j < maxBots; j++)
	{
		bestDist[j] = -1.0;
		bestBot[j] = 0;
	}

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
		{
			continue;
		}

		if (GetClientTeam(i) != TEAM_SURVIVORS)
		{
			continue;
		}

		NavBot bot = view_as<NavBot>(i);
		Address squadIface = bot.GetSquadInterface();

		if (NavBotSquadInterface.IsInASquad(squadIface) && NavBotSquadInterface.IsHumanLedSquad(squadIface))
		{
			continue;
		}

		float botPos[3];
		GetClientAbsOrigin(i, botPos);
		float dist = GetVectorDistance(callerPos, botPos);

		for (int slot = 0; slot < maxBots; slot++)
		{
			if (bestDist[slot] < 0.0 || dist < bestDist[slot])
			{
				for (int shift = maxBots - 1; shift > slot; shift--)
				{
					bestDist[shift] = bestDist[shift - 1];
					bestBot[shift] = bestBot[shift - 1];
				}

				bestDist[slot] = dist;
				bestBot[slot] = i;
				break;
			}
		}
	}

	count = 0;

	for (int j = 0; j < maxBots; j++)
	{
		if (bestBot[j] != 0)
		{
			bots[count++] = bestBot[j];
		}
	}
}

void StartFollow(const int[] bots, int count, int callerClient)
{
	FreeBotFromExistingSquad(bots[0]);

	NavBot leaderBot = view_as<NavBot>(bots[0]);
	Address leaderSquad = leaderBot.GetSquadInterface();

	if (!NavBotSquadInterface.CreateSquad(leaderSquad, callerClient))
	{
		LogMessage("[FollowMe] CreateSquad failed for bot %N (caller %N).", bots[0], callerClient);
		return;
	}

	g_iSquadLeaderBot[callerClient] = bots[0];
	g_fSquadStartTime[callerClient] = GetGameTime();

	OnBotJoinedSquad(bots[0], callerClient);

	for (int i = 1; i < count; i++)
	{
		FreeBotFromExistingSquad(bots[i]);

		if (NavBotSquadInterface.AddMemberToSquad(leaderSquad, bots[i]))
		{
			OnBotJoinedSquad(bots[i], callerClient);
		}
	}
}

void FreeBotFromExistingSquad(int botClient)
{
	NavBot bot = view_as<NavBot>(botClient);
	Address squadIface = bot.GetSquadInterface();

	if (NavBotSquadInterface.IsInASquad(squadIface))
	{
		NavBotSquadInterface.DestroySquad(squadIface);
	}
}

void OnBotJoinedSquad(int botClient, int callerClient)
{
	RequestFrame(Frame_PlayAgreeVoiceLine, botClient);
	AnnounceJoin(botClient, callerClient);

	LogMessage("[FollowMe] Bot %N joined the follow squad for %N.", botClient, callerClient);
}

void HandleRepeatTrigger(int caller)
{
	int leaderBot = g_iSquadLeaderBot[caller];

	if (!IsClientInGame(leaderBot) || !IsFakeClient(leaderBot))
	{
		ClearSquadTracking(caller);
		return;
	}

	NavBot leaderNavBot = view_as<NavBot>(leaderBot);
	Address leaderSquad = leaderNavBot.GetSquadInterface();

	if (!NavBotSquadInterface.IsInASquad(leaderSquad))
	{
		// Tracking was stale, squad is already gone. Let the next trigger form a new one.
		ClearSquadTracking(caller);
		return;
	}

	AnnounceCurrentSquad(caller, leaderSquad);
}

void AnnounceCurrentSquad(int caller, Address leaderSquad)
{
	if (!g_cvChatMessage.BoolValue)
	{
		return;
	}

	char list[192];
	list[0] = '\0';
	int botsFound = 0;

	int count = NavBotSquadInterface.GetSquadMemberCount(leaderSquad);

	for (int i = 0; i < count; i++)
	{
		int member = NavBotSquadInterface.GetSquadMemberEntity(leaderSquad, i);

		if (member <= 0 || !IsClientInGame(member) || !IsFakeClient(member))
		{
			continue;
		}

		char name[MAX_NAME_LENGTH];
		GetClientName(member, name, sizeof(name));

		if (botsFound > 0)
		{
			StrCat(list, sizeof(list), ", ");
		}

		StrCat(list, sizeof(list), name);
		botsFound++;
	}

	if (botsFound == 0)
	{
		PrintToChat(caller, "\x05[NAV]\x01 Your squad has no bots in it right now.");
	}
	else
	{
		PrintToChat(caller, "\x05[NAV]\x01 Your squad: %s", list);
	}
}

void AnnounceJoin(int botClient, int callerClient)
{
	if (!g_cvChatMessage.BoolValue)
	{
		return;
	}

	char botName[MAX_NAME_LENGTH];
	GetClientName(botClient, botName, sizeof(botName));
	PrintToChat(callerClient, "\x05[NAV]\x01 %s has joined your squad.", botName);
}

public void Frame_PlayAgreeVoiceLine(any data)
{
	int botClient = data;

	if (!IsClientInGame(botClient) || !IsFakeClient(botClient) || !IsPlayerAlive(botClient))
	{
		return;
	}

	char szInternal[64] = "Acknowledge";
	char szExternal[64] = "#VOICE_AGREE";
	SDKCall(g_hSDKVoiceMenu, botClient, szInternal, szExternal);
}

public Action Timer_CheckSquads(Handle timer)
{
	for (int caller = 1; caller <= MaxClients; caller++)
	{
		int leaderBot = g_iSquadLeaderBot[caller];

		if (leaderBot == 0)
		{
			continue;
		}

		if (!IsClientInGame(caller))
		{
			ClearSquadTracking(caller);
			continue;
		}

		if (!IsClientInGame(leaderBot) || !IsFakeClient(leaderBot))
		{
			ClearSquadTracking(caller);
			continue;
		}

		NavBot leaderNavBot = view_as<NavBot>(leaderBot);
		Address leaderSquad = leaderNavBot.GetSquadInterface();

		if (!NavBotSquadInterface.IsInASquad(leaderSquad))
		{
			// Squad already gone, e.g. the leader bot died and respawned.
			ClearSquadTracking(caller);
			continue;
		}

		bool expired = (GetGameTime() - g_fSquadStartTime[caller]) >= g_cvSquadDuration.FloatValue;
		bool critical = !expired && IsAnyMemberCritical(leaderSquad);

		if (expired || critical)
		{
			DisbandSquad(caller, leaderSquad, critical);
		}
	}

	return Plugin_Continue;
}

bool IsAnyMemberCritical(Address leaderSquad)
{
	int count = NavBotSquadInterface.GetSquadMemberCount(leaderSquad);

	for (int i = 0; i < count; i++)
	{
		int member = NavBotSquadInterface.GetSquadMemberEntity(leaderSquad, i);

		if (member <= 0 || !IsClientInGame(member) || !IsFakeClient(member) || !IsPlayerAlive(member))
		{
			continue;
		}

		NavBot bot = view_as<NavBot>(member);

		if (bot.GetHealthState() == NAVBOT_HEALTH_CRITICAL)
		{
			return true;
		}
	}

	return false;
}

void DisbandSquad(int caller, Address leaderSquad, bool critical)
{
	int members[MAX_FOLLOWERS_CAP];
	int botCount = 0;

	int count = NavBotSquadInterface.GetSquadMemberCount(leaderSquad);

	for (int i = 0; i < count && botCount < MAX_FOLLOWERS_CAP; i++)
	{
		int member = NavBotSquadInterface.GetSquadMemberEntity(leaderSquad, i);

		if (member > 0 && IsClientInGame(member) && IsFakeClient(member))
		{
			members[botCount++] = member;
		}
	}

	NavBotSquadInterface.DestroySquad(leaderSquad);

	for (int i = 0; i < botCount; i++)
	{
		RequestFrame(Frame_PlayRunawayVoiceLine, members[i]);
	}

	AnnounceDisband(caller, critical);

	LogMessage("[FollowMe] Squad disbanded for %N (%s).", caller, critical ? "critical health" : "duration expired");

	ClearSquadTracking(caller);
}

void AnnounceDisband(int caller, bool critical)
{
	if (!g_cvChatMessage.BoolValue || !IsClientInGame(caller))
	{
		return;
	}

	if (critical)
	{
		PrintToChat(caller, "\x05[NAV]\x01 Your squad has disbanded, a member was critically injured.");
	}
	else
	{
		PrintToChat(caller, "\x05[NAV]\x01 Your squad has disbanded.");
	}
}

void ClearSquadTracking(int caller)
{
	g_iSquadLeaderBot[caller] = 0;
	g_fSquadStartTime[caller] = 0.0;
}

public void Frame_PlayRunawayVoiceLine(any data)
{
	int botClient = data;

	if (!IsClientInGame(botClient) || !IsFakeClient(botClient) || !IsPlayerAlive(botClient))
	{
		return;
	}

	char szInternal[64] = "Escape";
	char szExternal[64] = "#VOICE_RUNAWAY";
	SDKCall(g_hSDKVoiceMenu, botClient, szInternal, szExternal);
}
