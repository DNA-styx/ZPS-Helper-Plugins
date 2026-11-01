/**
 * zps_navbot_crates.sp
 * Version: 0.2.0
 * Author:  Claude.ai guided by DNA.styx
 *
 * Survivor NavBots opportunistically destroy prop_itemcrate entities they can see.
 */

#include <sourcemod>
#include <sdktools>
#include <navbot>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "0.2.0"
#define ZPS_TEAM_SURVIVORS 2
#define ASSIGN_GRACE_TIME 2.0

ConVar g_cvEnabled;
ConVar g_cvRadius;
ConVar g_cvInterval;
ConVar g_cvTimeout;

Handle g_hPollTimer = null;

int g_iCrateRef[MAXPLAYERS + 1];
float g_fAssignTime[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name        = "ZPS NavBot Crates",
	author      = "Claude.ai guided by DNA.styx",
	description = "Survivor NavBots destroy prop_itemcrate entities they can see",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	g_cvEnabled  = CreateConVar("sm_navbot_crates_enabled", "1", "Enable survivor NavBots destroying nearby visible prop_itemcrate entities.", _, true, 0.0, true, 1.0);
	g_cvRadius   = CreateConVar("sm_navbot_crates_radius", "512.0", "Maximum distance from a bot to a crate for it to be targeted.", _, true, 64.0);
	g_cvInterval = CreateConVar("sm_navbot_crates_interval", "1.0", "Seconds between crate scans. Applied on map change.", _, true, 0.2);
	g_cvTimeout  = CreateConVar("sm_navbot_crates_timeout", "15.0", "Seconds before a bot gives up on its crate.", _, true, 1.0);

	RegAdminCmd("sm_crate_test", Command_CrateTest, ADMFLAG_ROOT, "Send the nearest survivor NavBot to destroy the prop_itemcrate you are aiming at.");

	ClearAllAssignments();
	StartPollTimer();
}

public void OnMapStart()
{
	ClearAllAssignments();
	StartPollTimer();
}

public void OnClientDisconnect(int client)
{
	ClearAssignment(client);
}

static void StartPollTimer()
{
	if (g_hPollTimer != null)
	{
		delete g_hPollTimer;
	}

	g_hPollTimer = CreateTimer(g_cvInterval.FloatValue, Timer_Poll, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnMapEnd()
{
	g_hPollTimer = null;
}

static void ClearAllAssignments()
{
	for (int i = 0; i <= MaxClients; i++)
	{
		ClearAssignment(i);
	}
}

static void ClearAssignment(int client)
{
	g_iCrateRef[client] = INVALID_ENT_REFERENCE;
	g_fAssignTime[client] = 0.0;
}

static bool IsSurvivorNavBot(int client)
{
	return IsClientInGame(client) && IsPlayerAlive(client) && GetClientTeam(client) == ZPS_TEAM_SURVIVORS && NavBotManager.IsNavBot(client);
}

static bool IsCrateClaimed(int crateRef)
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (g_iCrateRef[i] == crateRef)
		{
			return true;
		}
	}

	return false;
}

static void UpdateAssignment(int client, NavBot bot)
{
	if (g_iCrateRef[client] == INVALID_ENT_REFERENCE)
	{
		return;
	}

	if (!IsSurvivorNavBot(client) || EntRefToEntIndex(g_iCrateRef[client]) == INVALID_ENT_REFERENCE)
	{
		ClearAssignment(client);
		return;
	}

	float elapsed = GetGameTime() - g_fAssignTime[client];

	if (elapsed < ASSIGN_GRACE_TIME)
	{
		return;
	}

	if (!NavBotBehaviorInterface.IsRunningPluginCommand(bot.GetBehaviorInterface()))
	{
		ClearAssignment(client);
		return;
	}

	if (elapsed >= g_cvTimeout.FloatValue)
	{
		bot.SendPluginCommand(NAVBOT_PLUGINCMD_STOPCMD);
		ClearAssignment(client);
	}
}

public Action Timer_Poll(Handle timer)
{
	if (!g_cvEnabled.BoolValue)
	{
		return Plugin_Continue;
	}

	int crates[256];
	int crateCount = 0;
	int ent = -1;

	while ((ent = FindEntityByClassname(ent, "prop_itemcrate")) != -1 && crateCount < sizeof(crates))
	{
		crates[crateCount++] = ent;
	}

	float radius = g_cvRadius.FloatValue;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !NavBotManager.IsNavBot(client))
		{
			continue;
		}

		NavBot bot = NavBotManager.GetNavBotByIndex(client);
		UpdateAssignment(client, bot);

		if (crateCount == 0 || g_iCrateRef[client] != INVALID_ENT_REFERENCE || !IsSurvivorNavBot(client))
		{
			continue;
		}

		if (NavBotBehaviorInterface.IsRunningPluginCommand(bot.GetBehaviorInterface()))
		{
			continue;
		}

		Address sensor = bot.GetSensorInterface();

		if (NavBotSensorInterface.GetPrimaryKnownThreatIndex(sensor, true) > 0)
		{
			continue;
		}

		float botPos[3];
		GetClientAbsOrigin(client, botPos);

		int bestCrate = -1;
		float bestDist = radius;

		for (int c = 0; c < crateCount; c++)
		{
			int crate = crates[c];

			if (!IsValidEntity(crate) || IsCrateClaimed(EntIndexToEntRef(crate)))
			{
				continue;
			}

			float cratePos[3];
			GetEntPropVector(crate, Prop_Data, "m_vecAbsOrigin", cratePos);
			float dist = GetVectorDistance(botPos, cratePos);

			if (dist > bestDist)
			{
				continue;
			}

			if (!NavBotSensorInterface.IsAbleToSeeEntity(sensor, crate, true))
			{
				continue;
			}

			bestCrate = crate;
			bestDist = dist;
		}

		if (bestCrate == -1)
		{
			continue;
		}

		bot.SendPluginCommand(NAVBOT_PLUGINCMD_SEEK_AND_DESTROY, bestCrate);
		g_iCrateRef[client] = EntIndexToEntRef(bestCrate);
		g_fAssignTime[client] = GetGameTime();
	}

	return Plugin_Continue;
}

public Action Command_CrateTest(int client, int args)
{
	if (client <= 0 || !IsClientInGame(client))
	{
		ReplyToCommand(client, "[Crates] Must be used in-game.");
		return Plugin_Handled;
	}

	int crate = GetClientAimTarget(client, false);

	if (crate <= MaxClients || !IsValidEntity(crate))
	{
		ReplyToCommand(client, "[Crates] Not aiming at an entity.");
		return Plugin_Handled;
	}

	char classname[64];
	GetEntityClassname(crate, classname, sizeof(classname));

	if (!StrEqual(classname, "prop_itemcrate"))
	{
		ReplyToCommand(client, "[Crates] Aim target is %s, not prop_itemcrate.", classname);
		return Plugin_Handled;
	}

	float cratePos[3];
	GetEntPropVector(crate, Prop_Data, "m_vecAbsOrigin", cratePos);

	int bestBot = -1;
	float bestDist = -1.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsSurvivorNavBot(i))
		{
			continue;
		}

		float botPos[3];
		GetClientAbsOrigin(i, botPos);
		float dist = GetVectorDistance(botPos, cratePos);

		if (bestBot == -1 || dist < bestDist)
		{
			bestBot = i;
			bestDist = dist;
		}
	}

	if (bestBot == -1)
	{
		ReplyToCommand(client, "[Crates] No alive survivor NavBot found.");
		return Plugin_Handled;
	}

	NavBot bot = NavBotManager.GetNavBotByIndex(bestBot);
	bot.SendPluginCommand(NAVBOT_PLUGINCMD_SEEK_AND_DESTROY, crate);
	g_iCrateRef[bestBot] = EntIndexToEntRef(crate);
	g_fAssignTime[bestBot] = GetGameTime();

	ReplyToCommand(client, "[Crates] Sent %N to destroy prop_itemcrate %i (%.1f units away).", bestBot, crate, bestDist);
	return Plugin_Handled;
}
