#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION "0.6"
#define FIRE_LOOP      "ambient/fire/fire_small_loop2.wav"
#define MAX_ENTS       2048

ConVar g_cvDebug;
char   g_sLogFile[PLATFORM_MAX_PATH];
int    g_iFlameRef[MAX_ENTS];      // entity reference of tracked entityflame
int    g_iFlameChannel[MAX_ENTS];  // channel the loop was started on

public Plugin myinfo =
{
	name        = "ZPS Fire Loop Fix",
	author      = "Claude.ai guided by DNA.styx",
	description = "Stops fire_small_loop2 on entityflame when the burning player dies",
	version     = PLUGIN_VERSION,
	url         = ""
};

public void OnPluginStart()
{
	CreateConVar("sm_fireloopfix_version", PLUGIN_VERSION, "ZPS Fire Loop Fix version",
		FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_cvDebug = CreateConVar("sm_fireloopfix_debug", "0",
		"Log flame tracking and stops to logs/zps_fireloopfix.log (0 = off, 1 = on)",
		FCVAR_PROTECTED, true, 0.0, true, 1.0);

	BuildPath(Path_SM, g_sLogFile, sizeof(g_sLogFile), "logs/zps_fireloopfix.log");
	AddNormalSoundHook(Hook_NormalSound);
	HookEvent("player_feed", Event_PlayerFeed);
	ResetTracking();
}

public void OnMapStart()
{
	ResetTracking();
}

void ResetTracking()
{
	for (int i = 0; i < MAX_ENTS; i++)
	{
		g_iFlameRef[i] = INVALID_ENT_REFERENCE;
		g_iFlameChannel[i] = 0;
	}
}

void DebugLog(const char[] format, any ...)
{
	if (!g_cvDebug.BoolValue)
	{
		return;
	}
	char buffer[256];
	VFormat(buffer, sizeof(buffer), format, 2);
	LogToFileEx(g_sLogFile, "%s", buffer);
}

bool IsFlameEntity(int entity)
{
	if (entity <= MaxClients || entity >= MAX_ENTS || !IsValidEntity(entity))
	{
		return false;
	}
	char classname[32];
	GetEntityClassname(entity, classname, sizeof(classname));
	return StrEqual(classname, "entityflame");
}

public Action Hook_NormalSound(int clients[MAXPLAYERS], int &numClients,
	char sample[PLATFORM_MAX_PATH], int &entity, int &channel, float &volume,
	int &level, int &pitch, int &flags, char soundEntry[PLATFORM_MAX_PATH], int &seed)
{
	if (flags != 0 || StrContains(sample, FIRE_LOOP, false) == -1 || !IsFlameEntity(entity))
	{
		return Plugin_Continue;
	}

	g_iFlameRef[entity] = EntIndexToEntRef(entity);
	g_iFlameChannel[entity] = channel;

	int attached = -1;
	if (HasEntProp(entity, Prop_Data, "m_hEntAttached"))
	{
		attached = GetEntPropEnt(entity, Prop_Data, "m_hEntAttached");
	}

	DebugLog("[track] flame=%d chan=%d attached=%d", entity, channel, attached);
	return Plugin_Continue;
}

void StopFlameLoop(int flame, const char[] reason)
{
	StopSound(flame, g_iFlameChannel[flame], FIRE_LOOP);
	DebugLog("[stop] flame=%d chan=%d reason=%s", flame, g_iFlameChannel[flame], reason);
	g_iFlameRef[flame] = INVALID_ENT_REFERENCE;
}

public void Event_PlayerFeed(Event event, const char[] name, bool dontBroadcast)
{
	if (!event.GetBool("death"))
	{
		return;
	}

	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client <= 0)
	{
		return;
	}

	for (int i = MaxClients + 1; i < MAX_ENTS; i++)
	{
		if (g_iFlameRef[i] == INVALID_ENT_REFERENCE)
		{
			continue;
		}
		int flame = EntRefToEntIndex(g_iFlameRef[i]);
		if (flame == INVALID_ENT_REFERENCE)
		{
			g_iFlameRef[i] = INVALID_ENT_REFERENCE;
			continue;
		}
		if (HasEntProp(flame, Prop_Data, "m_hEntAttached")
			&& GetEntPropEnt(flame, Prop_Data, "m_hEntAttached") == client)
		{
			StopFlameLoop(flame, "owner_death");
		}
	}
}

public void OnEntityDestroyed(int entity)
{
	if (entity <= MaxClients || entity >= MAX_ENTS)
	{
		return;
	}
	if (g_iFlameRef[entity] != INVALID_ENT_REFERENCE
		&& EntRefToEntIndex(g_iFlameRef[entity]) == entity)
	{
		StopFlameLoop(entity, "destroyed");
	}
}
