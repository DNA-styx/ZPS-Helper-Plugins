/**
 * ZPS Bot Zombie Horde
 * Author: Claude.ai guided by DNA.styx
 * Ramps NavBot zombie population over time via sm_navbot_quota_target on configured maps.
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <navbot>

#define PLUGIN_VERSION      "0.14.0"

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
ConVar g_cvNavBotSkillLevel;

Handle g_hRoundTimer;
Handle g_hWaveTimer;
Handle g_hWaveDelayTimer;
Handle g_hFreezeTimer;
Handle g_hFreezeWarningTimer;
bool   g_bMapEnabled;
bool   g_bFrozenThisRound[MAXPLAYERS + 1];
float  g_fFreezeEndTime;

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
        "Seconds zombie bots stand still after round start, letting the quota settle.",
        FCVAR_PROTECTED, true, 1.0
    );

    g_cvUnfreezeWarningSeconds = CreateConVar(
        "zps_bot_zombie_horde_unfreeze_warning_seconds", "10.0",
        "Seconds before unfreeze to show a warning message.",
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
    // Timers flagged TIMER_FLAG_NO_MAPCHANGE are already force-killed by
    // SourceMod before OnMapStart runs, so their handles are dead here.
    // Assign null directly - do not delete/close them, that throws
    // "Handle is invalid" on an already-freed handle.
    g_hRoundTimer = null;
    g_hWaveTimer = null;
    g_hWaveDelayTimer = null;
    g_hFreezeTimer = null;
    g_hFreezeWarningTimer = null;

    // Game time restarts each map, so a stale end time could freeze players.
    g_fFreezeEndTime = 0.0;

    g_bMapEnabled = IsCurrentMapEnabled();
    ApplyNavBotSkillLevel();

    if (!g_bMapEnabled)
    {
        ApplyQuota(g_cvDefaultQuotaFixed.IntValue, g_cvDefaultQuotaTarget.IntValue);
    }
}

public void OnClientPutInServer(int client)
{
    if (!IsFakeClient(client))
    {
        ClampQuotaToCap();
    }
}

public void OnPluginEnd()
{
    // Timers owned by this plugin are closed automatically by SourceMod on
    // unload, and may already be dead here if unload coincides with a map
    // transition (same NO_MAPCHANGE cleanup as OnMapStart) - do not delete
    // them manually, that can hit an already-freed handle.
    ApplyQuota(g_cvDefaultQuotaFixed.IntValue, g_cvDefaultQuotaTarget.IntValue);
}

// Freezes real zombie players during the freeze window by blocking movement
// input. Bots are frozen separately via NavBot WAIT. Ends on its own once
// g_fFreezeEndTime passes, so no restore is needed.
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3])
{
    if (!g_bMapEnabled || GetGameTime() >= g_fFreezeEndTime)
    {
        return Plugin_Continue;
    }

    if (IsFakeClient(client) || !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_ZOMBIE)
    {
        return Plugin_Continue;
    }

    vel[0] = 0.0;
    vel[1] = 0.0;
    vel[2] = 0.0;
    buttons &= ~(IN_JUMP | IN_DUCK | IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
    return Plugin_Changed;
}

// Same-map use only (Event_ClientSound) where timers may genuinely still
// be running and need actual cancellation. Never call this from
// OnMapStart or OnPluginEnd - see the comments there.
void ClearHordeTimers()
{
    delete g_hRoundTimer;
    delete g_hWaveTimer;
    delete g_hWaveDelayTimer;
    delete g_hFreezeTimer;
    delete g_hFreezeWarningTimer;
}

void ApplyNavBotSkillLevel()
{
    int level = g_bMapEnabled ? g_cvHordeSkillLevel.IntValue : g_cvDefaultSkillLevel.IntValue;
    g_cvNavBotSkillLevel.SetInt(level);
}

bool ApplyQuota(int fixedValue, int target)
{
    ConVar cvFixed = FindConVar("sm_navbot_quota_fixed");
    ConVar cvTarget = FindConVar("sm_navbot_quota_target");

    if (cvFixed == null || cvTarget == null)
    {
        LogError("[Bot Zombie Horde] sm_navbot_quota_fixed/target not found, skipping.");
        return false;
    }

    cvFixed.SetInt(fixedValue);
    cvTarget.SetInt(target);
    return true;
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

    // clientsound fires per client, so this can run several times per round.
    // Clearing every timer first keeps the previous round's wave/freeze timers
    // from running alongside the new round's.
    ClearHordeTimers();
    g_hRoundTimer = CreateTimer(ROUND_START_DELAY, Timer_HordeRoundStart, _, TIMER_FLAG_NO_MAPCHANGE);
}

void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
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

// Moves every real survivor to the lowest-index real survivor's position.
// ZPS lets teammates pass through each other, so a shared spot is safe, and
// the anchor's own origin is a valid standing position (not in the ground).
void GroupHumanSurvivors()
{
    int anchor = 0;
    float origin[3];
    float noVelocity[3];

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
        {
            continue;
        }

        if (GetClientTeam(client) != TEAM_SURVIVOR)
        {
            continue;
        }

        if (anchor == 0)
        {
            anchor = client;
            GetClientAbsOrigin(anchor, origin);
            continue;
        }

        TeleportEntity(client, origin, NULL_VECTOR, noVelocity);

        if (g_cvDebug.BoolValue)
        {
            LogMessage("[Bot Zombie Horde] Moved survivor %d to anchor %d.", client, anchor);
        }
    }
}

void KillSurvivorBots()
{
    int survivorBots[MAXPLAYERS + 1];
    int botCount = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client))
        {
            continue;
        }

        if (GetClientTeam(client) == TEAM_SURVIVOR && IsPlayerAlive(client))
        {
            survivorBots[botCount] = client;
            botCount++;
        }
    }

    // With no human survivors, leave one bot so the round does not end instantly.
    if (CountHumanSurvivors() == 0 && botCount > 0)
    {
        botCount--;
    }

    for (int i = 0; i < botCount; i++)
    {
        ForcePlayerSuicide(survivorBots[i]);
    }

    if (g_cvDebug.BoolValue)
    {
        LogMessage("[Bot Zombie Horde] Killed %d survivor bot(s).", botCount);
    }
}

Action Timer_HordeRoundStart(Handle timer)
{
    g_hRoundTimer = null;

    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        return Plugin_Handled;
    }

    int humanSurvivorCount = CountHumanSurvivors();
    int target = 2;

    if (humanSurvivorCount > 1)
    {
        GroupHumanSurvivors();
    }

    KillSurvivorBots();

    if (ApplyQuota(1, target) && g_cvDebug.BoolValue)
    {
        LogMessage("[Bot Zombie Horde] Round start. Survivors: %d. Quota target: %d.",
            humanSurvivorCount, target);
    }

    ClampQuotaToCap();

    if (humanSurvivorCount > 0)
    {
        MessagePlayers("Horde Prepare", RoundToNearest(g_cvFreezeDuration.FloatValue));
    }

    StartFreezePoll();

    float warnDelay = g_cvFreezeDuration.FloatValue - g_cvUnfreezeWarningSeconds.FloatValue;
    delete g_hFreezeWarningTimer;
    if (warnDelay > 0.0)
    {
        g_hFreezeWarningTimer = CreateTimer(warnDelay, Timer_UnfreezeWarning, _, TIMER_FLAG_NO_MAPCHANGE);
    }

    delete g_hWaveDelayTimer;
    g_hWaveDelayTimer = CreateTimer(g_cvFreezeDuration.FloatValue, Timer_HordeWaveBegin, _, TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Handled;
}

Action Timer_UnfreezeWarning(Handle timer)
{
    g_hFreezeWarningTimer = null;

    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        return Plugin_Handled;
    }

    MessagePlayers("Horde Unfreeze Warning", RoundToNearest(g_cvUnfreezeWarningSeconds.FloatValue));
    return Plugin_Handled;
}

Action Timer_HordeWaveBegin(Handle timer)
{
    g_hWaveDelayTimer = null;

    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        return Plugin_Handled;
    }

    MessagePlayers("Horde Wave Start");

    delete g_hWaveTimer;
    g_hWaveTimer = CreateTimer(g_cvWaveInterval.FloatValue, Timer_HordeWave, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Handled;
}

void StartFreezePoll()
{
    if (!LibraryExists("navbot"))
    {
        LogError("[Bot Zombie Horde] NavBot library not available, skipping freeze.");
        return;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        g_bFrozenThisRound[client] = false;
    }

    g_fFreezeEndTime = GetGameTime() + g_cvFreezeDuration.FloatValue;
    FreezeZombieBots(g_cvFreezeDuration.FloatValue);

    delete g_hFreezeTimer;
    g_hFreezeTimer = CreateTimer(FREEZE_POLL_INTERVAL, Timer_FreezePoll, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_FreezePoll(Handle timer)
{
    float remaining = g_fFreezeEndTime - GetGameTime();

    if (remaining <= FREEZE_POLL_INTERVAL)
    {
        g_hFreezeTimer = null;
        return Plugin_Stop;
    }

    FreezeZombieBots(remaining);
    return Plugin_Continue;
}

void FreezeZombieBots(float duration)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client) || g_bFrozenThisRound[client])
        {
            continue;
        }

        if (!NavBotManager.IsNavBot(client))
        {
            continue;
        }

        if (GetClientTeam(client) != TEAM_ZOMBIE || !IsPlayerAlive(client))
        {
            continue;
        }

        NavBot bot = NavBotManager.GetNavBotByIndex(client);
        if (bot.IsNull)
        {
            continue;
        }

        bot.SendPluginCommand(NAVBOT_PLUGINCMD_WAIT, duration);
        g_bFrozenThisRound[client] = true;
    }
}

Action Timer_HordeWave(Handle timer)
{
    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        g_hWaveTimer = null;
        return Plugin_Stop;
    }

    ConVar cvTarget = FindConVar("sm_navbot_quota_target");
    if (cvTarget == null)
    {
        LogError("[Bot Zombie Horde] sm_navbot_quota_target not found, stopping wave timer.");
        g_hWaveTimer = null;
        return Plugin_Stop;
    }

    int humanSurvivorCount = CountHumanSurvivors();
    int oldTarget = cvTarget.IntValue;
    int cap = GetBotCap();

    int newTarget = oldTarget + humanSurvivorCount;
    if (newTarget > cap)
    {
        newTarget = cap;
    }

    if (newTarget != oldTarget)
    {
        cvTarget.SetInt(newTarget);

        if (newTarget > oldTarget)
        {
            MessagePlayers("Horde Wave", newTarget);
        }

        if (g_cvDebug.BoolValue)
        {
            LogMessage("[Bot Zombie Horde] Wave. Survivors: %d. Cap: %d. Quota target: %d -> %d.",
                humanSurvivorCount, cap, oldTarget, newTarget);
        }
    }

    // Keep running at the cap so the target follows players joining and leaving.
    return Plugin_Continue;
}

// Bot slots left once every non-bot client (players, spectators, SourceTV)
// is counted, keeping one slot free for a joining player.
int GetBotCap()
{
    int others = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientConnected(client))
        {
            continue;
        }

        if (IsClientInGame(client) && NavBotManager.IsNavBot(client))
        {
            continue;
        }

        others++;
    }

    int cap = MaxClients - 1 - others;
    return (cap < 0) ? 0 : cap;
}

// Lowers the horde quota target if it no longer fits in the free slots.
void ClampQuotaToCap()
{
    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        return;
    }

    ConVar cvFixed = FindConVar("sm_navbot_quota_fixed");
    ConVar cvTarget = FindConVar("sm_navbot_quota_target");

    // Only fixed mode counts bots alone; leave normal fill mode untouched.
    if (cvFixed == null || cvTarget == null || cvFixed.IntValue != 1)
    {
        return;
    }

    int cap = GetBotCap();
    if (cvTarget.IntValue > cap)
    {
        if (g_cvDebug.BoolValue)
        {
            LogMessage("[Bot Zombie Horde] Player joined. Quota target lowered %d -> %d.",
                cvTarget.IntValue, cap);
        }

        cvTarget.SetInt(cap);
    }
}

int CountHumanSurvivors()
{
    int count = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        if (GetClientTeam(client) == TEAM_SURVIVOR)
        {
            count++;
        }
    }

    return count;
}

void MessagePlayers(const char[] phrase, int value = -1)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        int team = GetClientTeam(client);
        if ((team != TEAM_SURVIVOR && team != TEAM_ZOMBIE) || !IsPlayerAlive(client))
        {
            continue;
        }

        if (value == -1)
        {
            PrintCenterText(client, "%T", phrase, client);
        }
        else
        {
            PrintCenterText(client, "%T", phrase, client, value);
        }
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
