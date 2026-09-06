#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "0.1.0"
#define TEAM_SURVIVORS 2

ConVar g_cvEnabled;
ConVar g_cvVersion;

public Plugin myinfo =
{
	name = "ZPS Survivor Callout Suppressor",
	author = "Claude.ai guided by DNA.styx",
	description = "Blocks NavBot native enemy-callout say_team messages from Survivor-team bots",
	version = PLUGIN_VERSION,
	url = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
	g_cvEnabled = CreateConVar("zps_callout_suppress_enabled", "1", "Suppress Survivor-team bot enemy callouts (1=on, 0=off)", FCVAR_PROTECTED);
	g_cvVersion = CreateConVar("zps_callout_suppress_version", PLUGIN_VERSION, "ZPS Callout Suppressor version", FCVAR_NOTIFY|FCVAR_DONTRECORD);

	AddCommandListener(Command_SayTeam, "say_team");

	AutoExecConfig(true, "zps_callout_suppress");
}

public Action Command_SayTeam(int client, const char[] command, int argc)
{
	if (!g_cvEnabled.BoolValue)
	{
		return Plugin_Continue;
	}

	if (client <= 0 || client > MaxClients || !IsFakeClient(client))
	{
		return Plugin_Continue;
	}

	if (GetClientTeam(client) != TEAM_SURVIVORS)
	{
		return Plugin_Continue;
	}

	char args[256];
	GetCmdArgString(args, sizeof(args));

	if (StrContains(args, "spotted at", false) == -1)
	{
		return Plugin_Continue;
	}

	return Plugin_Handled;
}
