#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <navbot>

#define PLUGIN_VERSION "0.7.0"

#define ZPS_TEAM_SURVIVORS 2
#define ZPS_BREAKABLETARGET_CONFIG_FOLDER "zps_navbot_breakable_target"
#define MAX_TARGETS 8

ConVar g_hCvarPollInterval;
ConVar g_hCvarVerbose;
ConVar g_hCvarEngageRadius;

char g_TargetName[64];
Handle g_hPollTimer = null;

public Plugin myinfo =
{
	name = "ZPS NavBot Breakable Target",
	author = "Claude.ai guided by DNA.styx",
	description = "Redirects survivor NavBot bots to attack a configured func_breakable, with whatever weapon they currently have, once they can see it within range",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	CreateConVar("zps_navbot_breakabletarget_version", PLUGIN_VERSION, "ZPS NavBot Breakable Target plugin version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_hCvarPollInterval = CreateConVar("zps_navbot_breakabletarget_poll_interval", "1.0", "How often (in seconds) to re-check survivor bots and (re)apply the threat override.", _, true, 0.2, true, 5.0);
	g_hCvarVerbose = CreateConVar("zps_navbot_breakabletarget_verbose", "0", "If 1, logs every override (re)application. If 0, only logs errors.", _, true, 0.0, true, 1.0);
	g_hCvarEngageRadius = CreateConVar("zps_navbot_breakabletarget_engage_radius", "600.0", "Max distance (units) from a target breakable within which a survivor bot may be redirected to attack it.", _, true, 120.0, true, 2000.0);

	AutoExecConfig(true, "zps_navbot_breakabletarget");

	RegAdminCmd("sm_zps_breakabletarget_status", Cmd_Status, ADMFLAG_ROOT, "Prints status of the configured breakable target(s).");
}

public void OnMapStart()
{
	LoadTargetConfig();

	delete g_hPollTimer;
	g_hPollTimer = CreateTimer(g_hCvarPollInterval.FloatValue, Timer_PollAndApply, _, TIMER_REPEAT);
}

void LoadTargetConfig()
{
	g_TargetName[0] = '\0';

	char mapName[64];
	GetCurrentMap(mapName, sizeof(mapName));

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/%s/%s.cfg", ZPS_BREAKABLETARGET_CONFIG_FOLDER, mapName);

	if (!FileExists(path))
	{
		ReportIssue("No breakable target config found for map \"%s\" at \"%s\".", mapName, path);
		return;
	}

	KeyValues kv = new KeyValues("ZPSNavBotBreakableTarget");

	if (!kv.ImportFromFile(path))
	{
		ReportIssue("Failed to parse breakable target config \"%s\" (malformed KeyValues?).", path);
		delete kv;
		return;
	}

	kv.GetString("targetname", g_TargetName, sizeof(g_TargetName), "");
	delete kv;

	if (g_TargetName[0] == '\0')
	{
		ReportIssue("Config \"%s\" loaded but has no \"targetname\" entry.", path);
	}
	else
	{
		PrintToServer("[ZPS NavBot Breakable Target] Loaded target name \"%s\" from \"%s\".", g_TargetName, path);
	}
}

int CollectTargets(int[] targets)
{
	if (g_TargetName[0] == '\0')
	{
		return 0;
	}

	int count = 0;
	int found = -1;

	while (count < MAX_TARGETS && (found = FindEntityByClassname(found, "func_breakable")) != -1)
	{
		char name[64];
		GetEntPropString(found, Prop_Data, "m_iName", name, sizeof(name));

		if (name[0] != '\0' && StrEqual(name, g_TargetName, false))
		{
			targets[count] = found;
			count++;
		}
	}

	return count;
}

// Nearest target the client can actually see (IsAbleToSeeEntity), not just nearest by distance.
int GetNearestVisibleTarget(Address sensor, int client, const int[] targets, int count, float radius, float &outDistance)
{
	float clientPos[3];
	GetClientAbsOrigin(client, clientPos);

	int nearest = -1;
	float nearestDist = -1.0;

	for (int i = 0; i < count; i++)
	{
		float targetPos[3];
		GetEntPropVector(targets[i], Prop_Send, "m_vecOrigin", targetPos);

		float dist = GetVectorDistance(clientPos, targetPos);

		if (dist > radius)
		{
			continue;
		}

		if (!NavBotSensorInterface.IsAbleToSeeEntity(sensor, targets[i], true))
		{
			continue;
		}

		if (nearestDist < 0.0 || dist < nearestDist)
		{
			nearestDist = dist;
			nearest = targets[i];
		}
	}

	outDistance = nearestDist;
	return nearest;
}

public Action Timer_PollAndApply(Handle timer)
{
	int targets[MAX_TARGETS];
	int count = CollectTargets(targets);

	if (count == 0)
	{
		ReportIssue("No entities matching target name \"%s\" found in the map (destroyed, or config not yet set).", g_TargetName);
		return Plugin_Continue;
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsPlayerAlive(client))
		{
			continue;
		}

		if (GetClientTeam(client) != ZPS_TEAM_SURVIVORS)
		{
			continue;
		}

		NavBot bot = NavBotManager.GetNavBotByIndex(client);

		if (bot == NULL_NAVBOT)
		{
			continue;
		}

		Address sensor = bot.GetSensorInterface();

		if (sensor == Address_Null)
		{
			continue;
		}

		float distance;
		int target = GetNearestVisibleTarget(sensor, client, targets, count, g_hCvarEngageRadius.FloatValue, distance);

		if (target == -1)
		{
			continue;
		}

		NavBotSensorInterface.SetPrimaryThreatOverride(sensor, target);

		if (g_hCvarVerbose.BoolValue)
		{
			PrintToServer("[ZPS NavBot Breakable Target] Set primary threat override (entity %d, dist %.1f) on bot %N.", target, distance, client);
		}
	}

	return Plugin_Continue;
}

void ReportIssue(const char[] fmt, any ...)
{
	char msg[256];
	VFormat(msg, sizeof(msg), fmt, 2);

	char fullMsg[288];
	Format(fullMsg, sizeof(fullMsg), "[ZPS NavBot Breakable Target] %s", msg);

	PrintToServer("%s", fullMsg);

	char logPath[PLATFORM_MAX_PATH];
	char mapName[64];
	GetCurrentMap(mapName, sizeof(mapName));
	BuildPath(Path_SM, logPath, sizeof(logPath), "logs/zps_navbot_breakable_target_%s.log", mapName);
	LogToFileEx(logPath, "%s", fullMsg);
}

public Action Cmd_Status(int client, int args)
{
	if (g_TargetName[0] == '\0')
	{
		ReplyToCommand(client, "[ZPS NavBot Breakable Target] No target name configured for this map.");
		return Plugin_Handled;
	}

	int targets[MAX_TARGETS];
	int count = CollectTargets(targets);

	ReplyToCommand(client, "[ZPS NavBot Breakable Target] Target name \"%s\" -- %d entit%s currently alive.", g_TargetName, count, count == 1 ? "y" : "ies");

	return Plugin_Handled;
}
