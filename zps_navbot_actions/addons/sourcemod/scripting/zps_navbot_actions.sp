/**
 * ZPS NavBot Actions v1.0
 * Adds ambient behaviours to NavBot-controlled bots in Zombie Panic: Source:
 *   - Bots randomly toggle their flashlight (enhancevision, bound to F)
 *   - Zombie-team bots randomly taunt (taunt, bound to Z)
 *
 * Flashlight: on-duration 60-100s, kept under the ~120s in-game battery life.
 * No team filtering on flashlight - affects bots on both teams.
 * Zombie taunt: zombie-team bots only, 30-90s interval per bot.
 *
 * Supersedes: zps_bot_flashlight
 */

#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION      "1.0"

// Flashlight
#define FL_CHECK_INTERVAL   8.0     // seconds between roll attempts
#define FL_TOGGLE_CHANCE    20      // percent chance per bot per check to turn on
#define FL_BATTERY_LIFE     120.0   // confirmed in-game battery life (reference only)
#define FL_MIN_ON           60.0    // minimum on-duration
#define FL_MAX_ON           100.0   // maximum on-duration (20s margin under battery life)

// Zombie taunt
#define ZT_MIN_INTERVAL     30.0    // minimum seconds between taunts per bot
#define ZT_MAX_INTERVAL     90.0    // maximum seconds between taunts per bot

#define TEAM_ZOMBIE         3

ConVar g_cvVersion;
ConVar g_cvFlashlightEnabled;
ConVar g_cvZombieTauntEnabled;

bool  g_FlashlightOn[MAXPLAYERS + 1];
float g_NextTauntTime[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "ZPS NavBot Actions",
    author      = "Claude.ai guided by DNA.styx",
    description = "Ambient flashlight and zombie taunt behaviours for NavBot bots",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
    g_cvVersion = CreateConVar(
        "zps_navbot_actions_version",
        PLUGIN_VERSION,
        "Plugin version.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );

    g_cvFlashlightEnabled = CreateConVar(
        "zps_navbot_actions_flashlight_enabled",
        "1",
        "Enable random flashlight toggling on bots. 0 = disabled, 1 = enabled.",
        FCVAR_PROTECTED
    );

    g_cvZombieTauntEnabled = CreateConVar(
        "zps_navbot_actions_zombie_taunt_enabled",
        "1",
        "Enable random taunts on zombie-team bots. 0 = disabled, 1 = enabled.",
        FCVAR_PROTECTED
    );

    AutoExecConfig(true, "zps_navbot_actions");

    CreateTimer(FL_CHECK_INTERVAL, Timer_CheckBots, _, TIMER_REPEAT);
}

public void OnClientPutInServer(int client)
{
    g_FlashlightOn[client]  = false;
    g_NextTauntTime[client] = GetGameTime() + GetRandomFloat(ZT_MIN_INTERVAL, ZT_MAX_INTERVAL);
}

public void OnClientDisconnect(int client)
{
    g_FlashlightOn[client]  = false;
    g_NextTauntTime[client] = 0.0;
}

public Action Timer_CheckBots(Handle timer)
{
    bool  flashlightEnabled = g_cvFlashlightEnabled.BoolValue;
    bool  tauntEnabled      = g_cvZombieTauntEnabled.BoolValue;
    float now               = GetGameTime();

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client) || !IsPlayerAlive(client))
            continue;

        // Flashlight
        if (flashlightEnabled && !g_FlashlightOn[client])
        {
            if (GetRandomInt(1, 100) <= FL_TOGGLE_CHANCE)
            {
                FakeClientCommand(client, "enhancevision");
                g_FlashlightOn[client] = true;

                DataPack pack = new DataPack();
                pack.WriteCell(GetClientUserId(client));
                CreateTimer(GetRandomFloat(FL_MIN_ON, FL_MAX_ON), Timer_FlashlightOff, pack);
            }
        }

        // Zombie taunt
        if (tauntEnabled && GetClientTeam(client) == TEAM_ZOMBIE)
        {
            // Initialise timer for bots already in-game when plugin loads
            if (g_NextTauntTime[client] == 0.0)
            {
                g_NextTauntTime[client] = now + GetRandomFloat(ZT_MIN_INTERVAL, ZT_MAX_INTERVAL);
            }
            else if (now >= g_NextTauntTime[client])
            {
                FakeClientCommand(client, "taunt");
                g_NextTauntTime[client] = now + GetRandomFloat(ZT_MIN_INTERVAL, ZT_MAX_INTERVAL);
            }
        }
    }

    return Plugin_Continue;
}

public Action Timer_FlashlightOff(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    delete pack;

    int client = GetClientOfUserId(userid);

    if (client == 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
        return Plugin_Stop;

    if (!g_FlashlightOn[client])
        return Plugin_Stop;

    FakeClientCommand(client, "enhancevision");
    g_FlashlightOn[client] = false;

    return Plugin_Stop;
}
