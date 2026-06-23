#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>

#define PLUGIN_VERSION  "1.5.8"

ConVar  g_cvEnabled;
ConVar  g_cvMinMapAge;

// ─── Plugin Info ──────────────────────────────────────────────────────────────

public Plugin myinfo =
{
    name        = "[SM] First Player Restart",
    author      = "Claude.ai guided by DNA.styx",
    description = "Reloads the map when the first real player joins a bot-only server",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

// ─── Lifecycle ────────────────────────────────────────────────────────────────

public void OnPluginStart()
{
    CreateConVar(
        "sm_firstplayer_restart_version", PLUGIN_VERSION,
        "Plugin version.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_cvEnabled = CreateConVar(
        "sm_firstplayer_restart_enabled", "1",
        "Enable first-player map reload. 0 = disabled.",
        FCVAR_NOTIFY);

    g_cvMinMapAge = CreateConVar(
        "sm_firstplayer_restart_minage", "60.0",
        "Minimum map age in seconds before a reload is triggered. Prevents restarts on fresh map loads.",
        FCVAR_NOTIFY);

    AutoExecConfig(true, "sm_firstplayer_restart");
}

// ─── Client Join ─────────────────────────────────────────────────────────────

public void OnClientPutInServer(int client)
{
    if (!g_cvEnabled.BoolValue)
        return;

    if (IsFakeClient(client))
        return;

    // Loop prevention — map age resets to near zero after restart.
    float mapAge = GetGameTime();
    if (mapAge < g_cvMinMapAge.FloatValue)
        return;

    // Confirm no other real players are already in-game
    for (int i = 1; i <= MaxClients; i++)
    {
        if (i == client)
            continue;
        if (IsClientInGame(i) && !IsFakeClient(i))
            return;
    }

    char currentMap[PLATFORM_MAX_PATH];
    GetCurrentMap(currentMap, sizeof(currentMap));
    LogMessage("[First Player Restart] Triggered by client %d. Map age %.1fs. Issuing changelevel %s.", client, mapAge, currentMap);
    ServerCommand("changelevel %s", currentMap);
}
