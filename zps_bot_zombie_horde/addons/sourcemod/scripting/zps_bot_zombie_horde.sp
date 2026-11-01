/**
 * ZPS Bot Zombie Horde
 * Author: Claude.ai guided by DNA.styx
 * Ramps NavBot zombie population over time via sm_navbot_quota_target on configured maps.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdkhooks>
#include <navbot>

#define PLUGIN_VERSION      "0.17.0"

#define TEAM_SURVIVOR       2
#define TEAM_ZOMBIE         3

#define ROUND_START_DELAY   12.0
#define FREEZE_POLL_INTERVAL 1.0

ConVar g_cvVersion;
ConVar g_cvEnabled;
ConVar g_cvDebug;
ConVar g_cvHordeSkillLevel;
ConVar g_cvDefaultSkillLevel;
ConVar g_cvWaveInterval;
ConVar g_cvDefaultQuotaFixed;
ConVar g_cvDefaultQuotaTarget;
ConVar g_cvFreezeDuration;
ConVar g_cvUnfreezeWarningSeconds;
ConVar g_cvBotHoldDuration;
ConVar g_cvZombiesPerPlayer;
ConVar g_cvNavBotSkillLevel;

Handle g_hRoundTimer;
Handle g_hWaveTimer;
Handle g_hWaveDelayTimer;
Handle g_hFreezeTimer;
Handle g_hFreezeWarningTimer;
Handle g_hBotHoldTimer;
bool   g_bMapEnabled;
bool   g_bRoundStarted;
bool   g_bFrozenThisRound[MAXPLAYERS + 1];
float  g_fFreezeEndTime;
bool   g_bHeld[MAXPLAYERS + 1];
float  g_fBotHoldEndTime;

// Per-map overrides from the map config; -1 = use the cvar.
float  g_fMapFreezeDuration = -1.0;
int    g_iMapZombiesPerPlayer = -1;

#include "zps_bot_zombie_horde/util.sp"
#include "zps_bot_zombie_horde/quota.sp"
#include "zps_bot_zombie_horde/freeze.sp"
#include "zps_bot_zombie_horde/roundstart.sp"

public Plugin myinfo =
{
    name        = "ZPS Bot Zombie Horde",
    author      = "Claude.ai guided by DNA.styx",
    description = "Ramps NavBot zombie population over time on configured maps",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
    if (late)
    {
        if (!LibraryExists("navbot"))
        {
            strcopy(error, err_max, "NavBot extension not running!");
            return APLRes_SilentFailure;
        }
    }

    return APLRes_Success;
}

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
        "Log wave target changes. 0 = off, 1 = on.",
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

    g_cvWaveInterval = CreateConVar(
        "zps_bot_zombie_horde_wave_interval", "60.0",
        "Seconds between zombie waves.",
        FCVAR_PROTECTED, true, 1.0
    );

    g_cvDefaultQuotaFixed = CreateConVar(
        "zps_bot_zombie_horde_default_quota_fixed", "0",
        "sm_navbot_quota_fixed value to restore on non-horde maps.",
        FCVAR_PROTECTED, true, 0.0, true, 1.0
    );

    g_cvDefaultQuotaTarget = CreateConVar(
        "zps_bot_zombie_horde_default_quota_target", "-1",
        "sm_navbot_quota_target value to restore on non-horde maps.",
        FCVAR_PROTECTED
    );

    g_cvFreezeDuration = CreateConVar(
        "zps_bot_zombie_horde_freeze_duration", "30.0",
        "Seconds zombies stand still after round start. 0 = no freeze.",
        FCVAR_PROTECTED, true, 0.0
    );

    g_cvUnfreezeWarningSeconds = CreateConVar(
        "zps_bot_zombie_horde_unfreeze_warning_seconds", "10.0",
        "Seconds before unfreeze to show a warning message.",
        FCVAR_PROTECTED, true, 0.0
    );

    g_cvBotHoldDuration = CreateConVar(
        "zps_bot_zombie_horde_bot_hold_duration", "60.0",
        "Seconds survivor bots stand still from map start and each round start. 0 = off.",
        FCVAR_PROTECTED, true, 0.0
    );

    g_cvZombiesPerPlayer = CreateConVar(
        "zps_bot_zombie_horde_zombies_per_player", "0",
        "Most zombie bots per real survivor. 0 = fill to free slots.",
        FCVAR_PROTECTED, true, 0.0
    );

    AutoExecConfig(true, "zps_bot_zombie_horde");
    g_cvVersion.SetString(PLUGIN_VERSION);

    LoadTranslations("zps_bot_zombie_horde.phrases");

    g_cvNavBotSkillLevel = FindConVar("sm_navbot_skill_level");

    HookEvent("clientsound", Event_ClientSound);
    HookEvent("player_team", Event_PlayerTeam);
}

public void OnMapStart()
{
    // NO_MAPCHANGE timers are already freed here: null them, never delete.
    g_hRoundTimer = null;
    g_hWaveTimer = null;
    g_hWaveDelayTimer = null;
    g_hFreezeTimer = null;
    g_hFreezeWarningTimer = null;
    g_hBotHoldTimer = null;

    // Game time restarts each map; a stale end time would freeze players.
    g_fFreezeEndTime = 0.0;
    g_bRoundStarted = false;

    g_bMapEnabled = LoadMapSettings();
    ApplyNavBotSkillLevel();

    if (!g_bMapEnabled)
    {
        ApplyQuota(g_cvDefaultQuotaFixed.IntValue, g_cvDefaultQuotaTarget.IntValue);
    }

    StartBotHold();
}

public void OnClientPutInServer(int client)
{
    if (IsFakeClient(client))
    {
        SDKHook(client, SDKHook_SpawnPost, OnBotSpawnPost);
        return;
    }

    ClampQuotaToCap();
}

public void OnPluginEnd()
{
    // SourceMod frees plugin timers on unload; deleting here can hit freed handles.
    ApplyQuota(g_cvDefaultQuotaFixed.IntValue, g_cvDefaultQuotaTarget.IntValue);
}

// Same-map use only. Never call from OnMapStart or OnPluginEnd.
void ClearHordeTimers()
{
    delete g_hRoundTimer;
    delete g_hWaveTimer;
    delete g_hWaveDelayTimer;
    delete g_hFreezeTimer;
    delete g_hFreezeWarningTimer;
}

void Event_ClientSound(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        return;
    }

    char sound[64];
    event.GetString("sound", sound, sizeof(sound));

    // Covers Round_End.Human, Round_End.Zombie and Round_End.Stalemate.
    if (StrContains(sound, "Round_End", false) != -1)
    {
        g_bRoundStarted = false;
        return;
    }

    if (StrContains(sound, "Round_Starting", false) == -1)
    {
        return;
    }

    // Fires once per client; clear the previous round's timers before restarting.
    g_bRoundStarted = false;
    ClearHordeTimers();
    StartBotHold();
    g_hRoundTimer = CreateTimer(ROUND_START_DELAY, Timer_HordeRoundStart, _, TIMER_FLAG_NO_MAPCHANGE);
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bMapEnabled || !g_cvEnabled.BoolValue || !g_bRoundStarted)
    {
        return;
    }

    int client = GetClientOfUserId(event.GetInt("userid"));
    if (client <= 0 || !IsClientInGame(client) || IsFakeClient(client))
    {
        return;
    }

    if (event.GetInt("team") != TEAM_SURVIVOR)
    {
        return;
    }

    KillSurvivorBots();
}

void OnBotSpawnPost(int client)
{
    if (!g_bMapEnabled || !g_cvEnabled.BoolValue || !g_bRoundStarted)
    {
        return;
    }

    // One frame later, so the spawn's team has applied.
    RequestFrame(Frame_CheckLateBot, GetClientUserId(client));
}

void Frame_CheckLateBot(int userid)
{
    int client = GetClientOfUserId(userid);
    if (client <= 0 || !IsClientInGame(client))
    {
        return;
    }

    KillLateSurvivorBot(client);
}
