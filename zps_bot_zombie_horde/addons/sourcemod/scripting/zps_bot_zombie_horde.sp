/**
 * ZPS Bot Zombie Horde
 * Author: Claude.ai guided by DNA.styx
 * Kills survivor-team bots shortly after round start on configured maps.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION      "0.2.1"

#define TEAM_SURVIVOR       2
#define TEAM_ZOMBIE         3

#define ROUND_START_DELAY   12.0

ConVar g_cvVersion;
ConVar g_cvEnabled;
ConVar g_cvDebug;
ConVar g_cvHordeSkillLevel;
ConVar g_cvDefaultSkillLevel;

Handle g_hRoundTimer;
bool   g_bMapEnabled;

public Plugin myinfo =
{
    name        = "ZPS Bot Zombie Horde",
    author      = "Claude.ai guided by DNA.styx",
    description = "Forces survivor-team bots to zombie team on configured maps",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
    g_cvVersion = CreateConVar(
        "zps_bot_zombie_horde_version", PLUGIN_VERSION,
        "Plugin version.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );

    g_cvEnabled = CreateConVar(
        "zps_bot_zombie_horde_enabled", "1",
        "Enable the bot horde behavior. 0 = disabled, 1 = enabled.",
        FCVAR_PROTECTED, true, 0.0, true, 1.0
    );

    g_cvDebug = CreateConVar(
        "zps_bot_zombie_horde_debug", "0",
        "Log kill counts and spared-bot info per round. 0 = off, 1 = on.",
        FCVAR_PROTECTED, true, 0.0, true, 1.0
    );

    g_cvHordeSkillLevel = CreateConVar(
        "zps_bot_zombie_horde_skill_level", "3",
        "sm_navbot_skill_level value to set on horde-enabled maps.",
        FCVAR_PROTECTED
    );

    g_cvDefaultSkillLevel = CreateConVar(
        "zps_bot_zombie_horde_default_skill_level", "1",
        "sm_navbot_skill_level value to set on non-horde maps.",
        FCVAR_PROTECTED
    );

    AutoExecConfig(true, "zps_bot_zombie_horde");
    g_cvVersion.SetString(PLUGIN_VERSION);

    LoadTranslations("zps_bot_zombie_horde.phrases");

    HookEvent("clientsound", Event_ClientSound);
}

public void OnMapStart()
{
    g_hRoundTimer = null;
    g_bMapEnabled = IsCurrentMapEnabled();
    ApplyNavBotSkillLevel();
}

void ApplyNavBotSkillLevel()
{
    ConVar cvSkill = FindConVar("sm_navbot_skill_level");
    if (cvSkill == null)
    {
        LogError("[Bot Zombie Horde] sm_navbot_skill_level not found, skipping skill level set.");
        return;
    }

    int level = g_bMapEnabled ? g_cvHordeSkillLevel.IntValue : g_cvDefaultSkillLevel.IntValue;
    cvSkill.SetInt(level);
}

void Event_ClientSound(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        return;
    }

    char sound[64];
    event.GetString("sound", sound, sizeof(sound));

    if (StrContains(sound, "Round_Starting", false) == -1)
    {
        return;
    }

    delete g_hRoundTimer;
    g_hRoundTimer = CreateTimer(ROUND_START_DELAY, Timer_HordeBots, _, TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_HordeBots(Handle timer)
{
    g_hRoundTimer = null;

    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        return Plugin_Stop;
    }

    int[] survivorBots = new int[MaxClients + 1];
    int botCount = 0;
    int humanCount = 0;
    int humanSurvivorCount = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client))
        {
            continue;
        }

        if (!IsFakeClient(client))
        {
            humanCount++;
            if (GetClientTeam(client) == TEAM_SURVIVOR)
            {
                humanSurvivorCount++;
            }
            continue;
        }

        if (GetClientTeam(client) == TEAM_SURVIVOR && IsPlayerAlive(client))
        {
            survivorBots[botCount] = client;
            botCount++;
        }
    }

    int sparedBot = -1;
    if (humanSurvivorCount == 0 && botCount > 0)
    {
        sparedBot = survivorBots[botCount - 1];
        botCount--;
    }

    for (int i = 0; i < botCount; i++)
    {
        ForcePlayerSuicide(survivorBots[i]);
    }

    if (g_cvDebug.BoolValue)
    {
        LogMessage("[Bot Zombie Horde] Killed %d survivor bot(s). Spared: %d. Humans: %d (survivor team: %d).",
            botCount, sparedBot, humanCount, humanSurvivorCount);
    }

    if (humanSurvivorCount > 0)
    {
        WarnSurvivors();
    }

    return Plugin_Stop;
}

void WarnSurvivors()
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        if (GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client))
        {
            continue;
        }

        PrintCenterText(client, "%t", "Horde Warning");
    }
}

bool IsCurrentMapEnabled()
{
    char mapName[64];
    GetCurrentMap(mapName, sizeof(mapName));
    GetMapDisplayName(mapName, mapName, sizeof(mapName));

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/zps_bot_zombie_horde/zps_bot_zombie_horde_maps.cfg");

    if (!FileExists(path))
    {
        return false;
    }

    KeyValues kv = new KeyValues("Maps");
    bool imported = kv.ImportFromFile(path);

    bool enabled = false;
    if (imported)
    {
        enabled = kv.GetNum(mapName, 0) != 0;
    }

    delete kv;
    return enabled;
}
