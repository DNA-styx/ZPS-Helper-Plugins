/**
 * ZPS Bot Flashlight v1.3
 * Randomly toggles the flashlight (enhancevision, bound to F) on
 * NavBot-controlled bots. On-duration 60-100s, kept under the ~120s
 * in-game battery life. No team filtering - affects bots on both teams.
 */

#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

public Plugin myinfo =
{
    name = "ZPS Bot Flashlight",
    author = "Claude.ai guided by DNA.styx",
    description = "Randomly toggles flashlight on NavBot-controlled bots",
    version = "1.3",
    url = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

#define CHECK_INTERVAL    8.0    // seconds between roll attempts, global timer
#define TOGGLE_CHANCE     20     // percent chance per bot per check to turn on
#define BATTERY_LIFE      120.0  // seconds, confirmed in-game flashlight battery life
#define MIN_ON_DURATION   60.0   // seconds, minimum flashlight-on time
#define MAX_ON_DURATION   100.0  // seconds, maximum flashlight-on time (20s margin under battery life)

bool g_FlashlightOn[MAXPLAYERS + 1];

public void OnPluginStart()
{
    CreateTimer(CHECK_INTERVAL, Timer_CheckBots, _, TIMER_REPEAT);
}

public void OnClientPutInServer(int client)
{
    g_FlashlightOn[client] = false;
}

public void OnClientDisconnect(int client)
{
    g_FlashlightOn[client] = false;
}

public Action Timer_CheckBots(Handle timer)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client) || !IsPlayerAlive(client))
        {
            continue;
        }

        if (g_FlashlightOn[client])
        {
            continue;
        }

        if (GetRandomInt(1, 100) > TOGGLE_CHANCE)
        {
            continue;
        }

        FakeClientCommand(client, "enhancevision");
        g_FlashlightOn[client] = true;

        float onDuration = GetRandomFloat(MIN_ON_DURATION, MAX_ON_DURATION);

        DataPack pack = new DataPack();
        pack.WriteCell(GetClientUserId(client));
        CreateTimer(onDuration, Timer_TurnOff, pack);
    }

    return Plugin_Continue;
}

public Action Timer_TurnOff(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);

    if (client == 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
    {
        return Plugin_Stop;
    }

    if (!g_FlashlightOn[client])
    {
        return Plugin_Stop;
    }

    FakeClientCommand(client, "enhancevision");
    g_FlashlightOn[client] = false;

    return Plugin_Stop;
}
