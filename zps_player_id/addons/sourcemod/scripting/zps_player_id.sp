#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.0.5"

// ZPS team constants
#define TEAM_SURVIVOR 2
#define TEAM_ZOMBIE   3

ConVar g_cvEnabled;
ConVar g_cvDisplay;
ConVar g_cvBots;

public Plugin myinfo =
{
    name        = "[ZPS] Player ID",
    author      = "Claude.ai guided by DNA.styx",
    description = "Shows opposite-team player names when aimed at",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
    g_cvEnabled = CreateConVar(
        "zps_playerid_enabled", "1",
        "Enable Player ID display. 1=on, 0=off",
        FCVAR_NONE, true, 0.0, true, 1.0
    );
    g_cvDisplay = CreateConVar(
        "zps_playerid_display", "1",
        "Display method: 1=PrintHintText, 2=PrintCenterText",
        FCVAR_NONE, true, 1.0, true, 2.0
    );

    g_cvBots = CreateConVar(
        "zps_playerid_show_bots", "1",
        "Allow bots to be identified by players. 1=on, 0=off",
        FCVAR_NONE, true, 0.0, true, 1.0
    );

    AutoExecConfig(true, "zps_player_id");
    LoadTranslations("zps_player_id.phrases");

    CreateTimer(0.2, Timer_CheckAimTarget, _, TIMER_REPEAT);
}

public Action Timer_CheckAimTarget(Handle timer)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;

    int displayMode = g_cvDisplay.IntValue;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsPlayerAlive(client) || IsFakeClient(client))
            continue;

        int myTeam = GetClientTeam(client);
        if (myTeam != TEAM_SURVIVOR && myTeam != TEAM_ZOMBIE)
            continue;

        // only_clients=true: returns clients only; -1=no target, -2=unsupported
        int target = GetClientAimTarget(client, true);

        if (target < 1 || target > MaxClients)
            continue;

        if (!IsClientInGame(target) || !IsPlayerAlive(target))
            continue;

        // Skip bots unless enabled
        if (IsFakeClient(target) && !g_cvBots.BoolValue)
            continue;

        int targetTeam = GetClientTeam(target);

        // Must be opposite team and a valid ZPS team
        if (targetTeam == myTeam)
            continue;
        if (targetTeam != TEAM_SURVIVOR && targetTeam != TEAM_ZOMBIE)
            continue;

        char targetName[MAX_NAME_LENGTH];
        GetClientName(target, targetName, sizeof(targetName));

        if (displayMode == 2)
            PrintCenterText(client, "%t %s", "PlayerID Prefix", targetName);
        else
            PrintHintText(client, "%t %s", "PlayerID Prefix", targetName);
    }

    return Plugin_Continue;
}
