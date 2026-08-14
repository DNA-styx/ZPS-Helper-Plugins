#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>
#include <navbot>

#define TEAM_SURVIVORS 2

DynamicDetour g_hVoiceMenuDetour;
Handle g_hSDKVoiceMenu;
ConVar g_cvFollowTime;
ConVar g_cvFollowMinDist;
ConVar g_cvChatMessage;
ConVar g_cvMaxFollowers;

int g_FollowingTargetUserId[MAXPLAYERS + 1]; // indexed by bot client index, 0 = not tracked as following. Best-effort bookkeeping only - no engine query native exists to confirm live state.

enum VoiceLineType
{
	VOICELINE_AGREE = 0,
	VOICELINE_DECLINE,
	VOICELINE_NEEDHEALTH
};

public Plugin myinfo =
{
	name        = "ZPS NavBot FollowMe",
	author      = "Claude.ai guided by DNA.styx",
	description = "Nearest survivor Navbot follows the caller on #VOICE_FOLLOWME.",
	version     = "0.10.0",
	url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
	CreateConVar("sm_zps_navbot_followme_version", "0.10.0", "ZPS NavBot FollowMe version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvFollowTime = CreateConVar("sm_zps_navbot_followme_time", "300.0", "Max time in seconds a bot will follow before the order expires.", FCVAR_PROTECTED);
	g_cvFollowMinDist = CreateConVar("sm_zps_navbot_followme_mindist", "120.0", "Minimum distance the bot keeps from the followed player.", FCVAR_PROTECTED);
	g_cvChatMessage = CreateConVar("sm_zps_navbot_followme_chatmsg", "0", "Print a chat message to the caller when a bot starts following. 0 = off, 1 = on.", FCVAR_PROTECTED);
	g_cvMaxFollowers = CreateConVar("sm_zps_navbot_followme_maxfollowers", "2", "Max number of bots that can follow a single player at once.", FCVAR_PROTECTED);

	AutoExecConfig(true, "zps_navbot_followme");

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

	CreateTimer(2.0, Timer_HealthCheck, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

	AddCommandListener(Command_OnBotPanic, "dopanic");
}

public void OnClientDisconnect(int client)
{
	g_FollowingTargetUserId[client] = 0;
}

public Action Command_OnBotPanic(int client, const char[] command, int argc)
{
	if (!(1 <= client <= MaxClients) || g_FollowingTargetUserId[client] == 0)
	{
		return Plugin_Continue;
	}

	NavBot bot = view_as<NavBot>(client);
	bot.SendPluginCommand(NAVBOT_PLUGINCMD_STOPCMD);
	g_FollowingTargetUserId[client] = 0;

	LogMessage("[FollowMe] Bot %N broke off following due to panic.", client);

	return Plugin_Continue;
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

	int bot = FindNearestSurvivorBot(client);
	if (bot == 0)
	{
		return MRES_Ignored;
	}

	int callerUserId = GetClientUserId(client);
	int followerCount = CountFollowersOf(callerUserId);

	if (followerCount >= g_cvMaxFollowers.IntValue)
	{
		DeclineFollow(bot, client);
		return MRES_Ignored;
	}

	StartFollow(bot, client);

	return MRES_Ignored;
}

int CountFollowersOf(int targetUserId)
{
	int count = 0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_FollowingTargetUserId[i] == targetUserId)
		{
			count++;
		}
	}

	return count;
}

int FindNearestSurvivorBot(int caller)
{
	float callerPos[3];
	GetClientAbsOrigin(caller, callerPos);

	int nearestBot = 0;
	float nearestDist = -1.0;

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

		float botPos[3];
		GetClientAbsOrigin(i, botPos);
		float dist = GetVectorDistance(callerPos, botPos);

		if (nearestDist < 0.0 || dist < nearestDist)
		{
			nearestDist = dist;
			nearestBot = i;
		}
	}

	return nearestBot;
}

void StartFollow(int botClient, int callerClient)
{
	float followTime = g_cvFollowTime.FloatValue;
	float followMinDist = g_cvFollowMinDist.FloatValue;
	int callerUserId = GetClientUserId(callerClient);

	NavBot bot = view_as<NavBot>(botClient);
	bot.SendPluginCommand(NAVBOT_PLUGINCMD_FOLLOW_ENTITY, callerClient, followTime, followMinDist);

	Address controllerAddr = bot.GetPlayerControllerInterface();
	NavBotPlayerControllerInterface.AimAtEntity(controllerAddr, callerClient, LOOK_ALLY, 1.0, "FollowMe accept");

	g_FollowingTargetUserId[botClient] = callerUserId;

	DataPack pack = new DataPack();
	pack.WriteCell(botClient);
	pack.WriteCell(callerUserId);
	CreateTimer(followTime, Timer_ExpireFollowTracking, pack, TIMER_FLAG_NO_MAPCHANGE);

	RequestFrame(Frame_PlayVoiceLine, GetVoiceLineFrameData(botClient, VOICELINE_AGREE));

	if (g_cvChatMessage.BoolValue)
	{
		char botName[MAX_NAME_LENGTH];
		GetClientName(botClient, botName, sizeof(botName));
		PrintToChat(callerClient, "\x05[NAV]\x01 %s is now following you.", botName);
	}

	LogMessage("[FollowMe] Bot %N now following %N (max %.1fs, mindist %.1f).", botClient, callerClient, followTime, followMinDist);
}

void DeclineFollow(int botClient, int callerClient)
{
	NavBot bot = view_as<NavBot>(botClient);
	Address controllerAddr = bot.GetPlayerControllerInterface();
	NavBotPlayerControllerInterface.AimAtEntity(controllerAddr, callerClient, LOOK_ALLY, 1.0, "FollowMe decline");

	RequestFrame(Frame_PlayVoiceLine, GetVoiceLineFrameData(botClient, VOICELINE_DECLINE));

	LogMessage("[FollowMe] Bot %N declined to follow - max followers reached.", botClient);
}

public Action Timer_ExpireFollowTracking(Handle timer, DataPack pack)
{
	pack.Reset();
	int botClient = pack.ReadCell();
	int expectedUserId = pack.ReadCell();

	// Only clear if this bot's current target still matches the one this timer was started for.
	// A newer follow order started in the meantime would have overwritten this already.
	if (g_FollowingTargetUserId[botClient] == expectedUserId)
	{
		g_FollowingTargetUserId[botClient] = 0;
	}

	return Plugin_Continue;
}

public Action Timer_HealthCheck(Handle timer)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_FollowingTargetUserId[i] == 0)
		{
			continue;
		}

		if (!IsClientInGame(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
		{
			g_FollowingTargetUserId[i] = 0;
			continue;
		}

		NavBot bot = view_as<NavBot>(i);
		NavBotHealthState state = bot.GetHealthState();

		if (state != NAVBOT_HEALTH_OK)
		{
			bot.SendPluginCommand(NAVBOT_PLUGINCMD_STOPCMD);
			g_FollowingTargetUserId[i] = 0;

			RequestFrame(Frame_PlayVoiceLine, GetVoiceLineFrameData(i, VOICELINE_NEEDHEALTH));

			LogMessage("[FollowMe] Bot %N broke off following due to low health.", i);
		}
	}

	return Plugin_Continue;
}

// Packs botClient (low 16 bits) and VoiceLineType (high bits) into a single 'any' cell for RequestFrame.
any GetVoiceLineFrameData(int botClient, VoiceLineType lineType)
{
	return (botClient & 0xFFFF) | (view_as<int>(lineType) << 16);
}

public void Frame_PlayVoiceLine(any data)
{
	int botClient = data & 0xFFFF;
	VoiceLineType lineType = view_as<VoiceLineType>(data >> 16);

	if (!IsClientInGame(botClient) || !IsFakeClient(botClient) || !IsPlayerAlive(botClient))
	{
		return;
	}

	char szInternal[64];
	char szExternal[64];

	switch (lineType)
	{
		case VOICELINE_AGREE:
		{
			strcopy(szInternal, sizeof(szInternal), "Acknowledge");
			strcopy(szExternal, sizeof(szExternal), "#VOICE_AGREE");
		}
		case VOICELINE_DECLINE:
		{
			strcopy(szInternal, sizeof(szInternal), "Decline");
			strcopy(szExternal, sizeof(szExternal), "#VOICE_DISAGREE");
		}
		case VOICELINE_NEEDHEALTH:
		{
			strcopy(szInternal, sizeof(szInternal), "NeedHealth");
			strcopy(szExternal, sizeof(szExternal), "#VOICE_NEED_HEALTH");
		}
	}

	SDKCall(g_hSDKVoiceMenu, botClient, szInternal, szExternal);
}
