#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

ConVar g_cvarEnabled;
ConVar g_cvarConnect;
ConVar g_cvarDebug;

#define PLUGIN_VERSION "1.0.2"
public Plugin myinfo = 
{
	name = "zps_tidychat",
	author = "Claude.ai guided by DNA.styx",
	description = "Custom chat/console message filter built for Zombie Panic: Source.",
	version = PLUGIN_VERSION,
	url = "",
};

public void OnPluginStart()
{
	CreateConVar("zps_tidychat_version", PLUGIN_VERSION, "zps_tidychat Version", FCVAR_SPONLY|FCVAR_REPLICATED|FCVAR_NOTIFY);

	g_cvarEnabled = CreateConVar("zps_tidychat_on", "1", "0/1 On/off");
	g_cvarConnect = CreateConVar("zps_tidychat_connect", "0", "0/1 Tidy connect messages");
	g_cvarDebug = CreateConVar("zps_tidychat_debug", "1", "0/1 Log blocked messages to the SourceMod log");

	AutoExecConfig(true, "zps_tidychat");

	// Step 1 of incremental build: player_connect only.
	HookEvent("player_connect", Event_PlayerConnect, EventHookMode_Pre);
}

public Action Event_PlayerConnect(Event event, const char[] name, bool dontBroadcast)
{
	if(g_cvarEnabled.BoolValue && g_cvarConnect.BoolValue)
	{
		event.BroadcastDisabled = true;

		if(g_cvarDebug.BoolValue)
		{
			char playerName[64];
			event.GetString("name", playerName, sizeof(playerName));
			LogMessage("Blocked event \"player_connect\" for player \"%s\"", playerName);
		}
	}

	return Plugin_Continue;
}
