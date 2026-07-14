#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <dhooks>
#include <navbot>

#define TEAM_SURVIVORS 2

DynamicDetour g_hVoiceMenuDetour;
int g_FollowTargetUserId[MAXPLAYERS + 1]; // indexed by bot client index, 0 = not following

public Plugin myinfo =
{
	name        = "ZPS NavBot FollowMe",
	author      = "Claude.ai guided by DNA.styx",
	description = "Nearest survivor bot follows the caller on #VOICE_FOLLOWME.",
	version     = "0.0.3",
	url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
	CreateConVar("sm_zps_navbot_followme_version", "0.0.3", "ZPS NavBot FollowMe version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);

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

public void OnClientDisconnect(int client)
{
	// If this client was a bot that was following someone, clear its state.
	g_FollowTargetUserId[client] = 0;
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
	g_FollowTargetUserId[botClient] = GetClientUserId(callerClient);

	NavBot bot = view_as<NavBot>(botClient);
	bot.SendScriptedPluginCommand(FollowUpdate);

	char botName[MAX_NAME_LENGTH];
	GetClientName(botClient, botName, sizeof(botName));
	PrintToChat(callerClient, "\x05[NAV]\x01 %s is now following you.", botName);

	LogMessage("[FollowMe] Bot %N now following %N (userid %d).", botClient, callerClient, g_FollowTargetUserId[botClient]);
}

public Action FollowUpdate(NavBot bot, float moveGoal[3], NavBotRouteType routeType)
{
	int botClient = view_as<int>(bot);
	int target = GetClientOfUserId(g_FollowTargetUserId[botClient]);

	if (target == 0 || !IsClientInGame(target) || !IsPlayerAlive(target))
	{
		g_FollowTargetUserId[botClient] = 0;
		return Plugin_Stop;
	}

	GetClientAbsOrigin(target, moveGoal);
	return Plugin_Handled;
}
