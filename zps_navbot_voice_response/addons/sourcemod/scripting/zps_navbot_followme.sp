#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>
#include <navbot>

#define TEAM_SURVIVORS 2

DynamicDetour g_hVoiceMenuDetour;
ConVar g_cvFollowTime;
ConVar g_cvFollowMinDist;

public Plugin myinfo =
{
	name        = "ZPS NavBot FollowMe",
	author      = "Claude.ai guided by DNA.styx",
	description = "Nearest survivor bot follows the caller on #VOICE_FOLLOWME, using NAVBOT_PLUGINCMD_FOLLOW_ENTITY.",
	version     = "0.4.0",
	url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
	CreateConVar("sm_zps_navbot_followme_version", "0.4.0", "ZPS NavBot FollowMe version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvFollowTime = CreateConVar("sm_zps_navbot_followme_time", "500.0", "Max time in seconds a bot will follow before the order expires.", FCVAR_PROTECTED);
	g_cvFollowMinDist = CreateConVar("sm_zps_navbot_followme_mindist", "80.0", "Minimum distance the bot keeps from the followed player.", FCVAR_PROTECTED);

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

	delete gc;
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

	StartFollow(bot, client);

	return MRES_Ignored;
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

	NavBot bot = view_as<NavBot>(botClient);
	bot.SendPluginCommand(NAVBOT_PLUGINCMD_FOLLOW_ENTITY, callerClient, followTime, followMinDist);

	char botName[MAX_NAME_LENGTH];
	GetClientName(botClient, botName, sizeof(botName));
	PrintToChat(callerClient, "\x05[NAV]\x01 %s is now following you.", botName);

	LogMessage("[FollowMe] Bot %N now following %N (max %.1fs, mindist %.1f).", botClient, callerClient, followTime, followMinDist);
}
