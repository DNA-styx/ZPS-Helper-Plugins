#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION "2.0.1"

#define TEAM_SURVIVORS 2

bool g_bLastAliveActive = false;
int g_iPrevShowActivity = -1;

ConVar g_hShowActivity;

public Plugin myinfo =
{
    name = "[ZPS] Beacon Last Bot",
    author = "Claude.ai guided by DNA.styx",
    description = "Beacons the last Survivor bot.",
    version = PLUGIN_VERSION,
    url = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
    CreateConVar("zps_beacon_lastbot_version", PLUGIN_VERSION, "ZPS Beacon Last Bot plugin version", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    g_hShowActivity = FindConVar("sm_show_activity");

    HookEvent("clientsound", Event_ClientSound, EventHookMode_Post);

    CreateTimer(15.0, Timer_CheckLastPlayer, _, TIMER_REPEAT);
}

public void Event_ClientSound(Event event, const char[] name, bool dontBroadcast)
{
    char sSound[64];
    event.GetString("sound", sSound, sizeof(sSound));

    if (StrContains(sSound, "Round_Starting", false) != -1)
    {
        g_bLastAliveActive = false;
    }
}

public Action Timer_CheckLastPlayer(Handle timer)
{
    int aliveCount = 0;
    int aliveClient = -1;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && IsPlayerAlive(i) && GetClientTeam(i) == TEAM_SURVIVORS)
        {
            aliveCount++;
            aliveClient = i;
        }
    }

    bool shouldBeActive = (aliveCount == 1 && aliveClient != -1 && IsFakeClient(aliveClient));

    if (shouldBeActive && !g_bLastAliveActive)
    {
        g_bLastAliveActive = true;

        int userid = GetClientUserId(aliveClient);

        PrintToChatAll("\x05[NAV]\x01 Last bot beaconed");

        ToggleBeaconQuiet(userid);
    }
    else if (!shouldBeActive && g_bLastAliveActive)
    {
        g_bLastAliveActive = false;
    }

    return Plugin_Continue;
}

void ToggleBeaconQuiet(int userid)
{
    g_iPrevShowActivity = (g_hShowActivity != null) ? g_hShowActivity.IntValue : -1;

    if (g_hShowActivity != null)
    {
        g_hShowActivity.IntValue = 0;
    }

    ServerCommand("sm_beacon #%d", userid);

    CreateTimer(0.1, Timer_RestoreShowActivity);
}

public Action Timer_RestoreShowActivity(Handle timer)
{
    if (g_hShowActivity != null && g_iPrevShowActivity != -1)
    {
        g_hShowActivity.IntValue = g_iPrevShowActivity;
    }

    return Plugin_Stop;
}
