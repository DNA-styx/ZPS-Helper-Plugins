#include <sourcemod>
#include <sdktools>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION      "0.9"

#define TEAM_SURVIVOR        2
#define TEAM_ZOMBIE           3

#define CHECK_INTERVAL       2.0    // seconds between eligibility checks
#define LOG_FILE             "logs/zps_bot_panic.log"

ConVar g_cvVersion;
ConVar g_cvEnabled;
ConVar g_cvHealthPct;
ConVar g_cvAmmoThreshold;
ConVar g_cvZombieRadius;
ConVar g_cvCooldown;
ConVar g_cvDebug;

float g_NextPanicAllowed[MAXPLAYERS + 1];
char  g_LogPath[PLATFORM_MAX_PATH];
Handle g_hPanicCall;

public Plugin myinfo =
{
    name        = "ZPS Bot Panic",
    author      = "Claude.ai guided by DNA.styx",
    description = "Makes NavBot survivor bots use the ZPS panic ability in emergencies",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
    g_cvVersion = CreateConVar(
        "zps_bot_panic_version",
        PLUGIN_VERSION,
        "Plugin version.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );

    g_cvEnabled = CreateConVar(
        "zps_bot_panic_enabled",
        "1",
        "Enable bot panic behaviour. 0 = disabled, 1 = enabled.",
        FCVAR_PROTECTED
    );

    g_cvHealthPct = CreateConVar(
        "zps_bot_panic_health_pct",
        "100.0",
        "Health percent at or below which a bot will consider panicking.",
        FCVAR_PROTECTED
    );

    g_cvAmmoThreshold = CreateConVar(
        "zps_bot_panic_ammo_threshold",
        "10",
        "Total carried ammo (clip + reserve, all weapons) at or below which a bot will consider panicking.",
        FCVAR_PROTECTED
    );

    g_cvZombieRadius = CreateConVar(
        "zps_bot_panic_zombie_radius",
        "300.0",
        "Distance (units) within which a zombie counts as an immediate threat.",
        FCVAR_PROTECTED
    );

    g_cvCooldown = CreateConVar(
        "zps_bot_panic_cooldown",
        "20.0",
        "Plugin-side cooldown (seconds) between panic attempts per bot.",
        FCVAR_PROTECTED
    );

    g_cvDebug = CreateConVar(
        "zps_bot_panic_debug",
        "0",
        "Log per-bot eligibility checks to logs/zps_bot_panic.log. 0 = off, 1 = on.",
        FCVAR_PROTECTED
    );

    BuildPath(Path_SM, g_LogPath, sizeof(g_LogPath), LOG_FILE);

    GameData gamedata = new GameData("zps_bot_panic.games");
    if (gamedata == null)
    {
        SetFailState("Could not load gamedata/zps_bot_panic.games.txt");
    }

    StartPrepSDKCall(SDKCall_Player);
    if (!PrepSDKCall_SetFromConf(gamedata, SDKConf_Signature, "CZP_Player::Panic"))
    {
        delete gamedata;
        SetFailState("Failed to locate CZP_Player::Panic signature in gamedata");
    }
    g_hPanicCall = EndPrepSDKCall();
    if (g_hPanicCall == null)
    {
        delete gamedata;
        SetFailState("Failed to create SDKCall for CZP_Player::Panic");
    }

    delete gamedata;

    AutoExecConfig(true, "zps_bot_panic");

    char version[16];
    g_cvVersion.GetString(version, sizeof(version));
    LogMessage("ZPS Bot Panic v%s loaded.", version);
    LogDebug("=== ZPS Bot Panic v%s loaded ===", version);

    CreateTimer(CHECK_INTERVAL, Timer_CheckBots, _, TIMER_REPEAT);
}

void LogDebug(const char[] fmt, any ...)
{
    if (!g_cvDebug.BoolValue)
        return;

    char buffer[256];
    VFormat(buffer, sizeof(buffer), fmt, 2);

    char timestamp[32];
    FormatTime(timestamp, sizeof(timestamp), "%Y-%m-%d %H:%M:%S");

    LogToFileEx(g_LogPath, "[%s] %s", timestamp, buffer);
}

public void OnClientDisconnect(int client)
{
    g_NextPanicAllowed[client] = 0.0;
}

public Action Timer_CheckBots(Handle timer)
{
    if (!g_cvEnabled.BoolValue)
        return Plugin_Continue;

    float now           = GetGameTime();
    float healthPct      = g_cvHealthPct.FloatValue;
    int   ammoThreshold  = g_cvAmmoThreshold.IntValue;
    float zombieRadiusSq = g_cvZombieRadius.FloatValue * g_cvZombieRadius.FloatValue;
    float cooldown       = g_cvCooldown.FloatValue;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client) || !IsPlayerAlive(client))
            continue;

        if (GetClientTeam(client) != TEAM_SURVIVOR)
        {
            g_NextPanicAllowed[client] = 0.0;
            continue;
        }

        char clientName[MAX_NAME_LENGTH];
        GetClientName(client, clientName, sizeof(clientName));

        if (now < g_NextPanicAllowed[client])
        {
            LogDebug("%s: on cooldown (%.1fs remaining)", clientName, g_NextPanicAllowed[client] - now);
            continue;
        }

        int maxHealth = GetEntProp(client, Prop_Data, "m_iMaxHealth");
        float curHealthPct = (maxHealth > 0) ? (float(GetClientHealth(client)) / float(maxHealth)) * 100.0 : 0.0;
        int curAmmo = GetTotalAmmo(client);
        bool zombieClose = IsZombieNearby(client, zombieRadiusSq);

        bool healthOk = curHealthPct <= healthPct;
        bool ammoOk   = curAmmo <= ammoThreshold;

        LogDebug("%s: health=%.1f%% (need<=%.1f%%) ammo=%d (need<=%d) zombieNearby=%s",
            clientName, curHealthPct, healthPct, curAmmo, ammoThreshold, zombieClose ? "yes" : "no");

        if (!healthOk || !ammoOk || !zombieClose)
            continue;

        SDKCall(g_hPanicCall, client);
        g_NextPanicAllowed[client] = now + cooldown;
        LogDebug("%s: PANIC triggered (direct call), next allowed at +%.1fs", clientName, cooldown);
    }

    return Plugin_Continue;
}

int GetTotalAmmo(int client)
{
    int totalAmmo = 0;
    int seenAmmoType[32];
    int seenCount = 0;

    for (int slot = 0; slot < 5; slot++)
    {
        int weapon = GetPlayerWeaponSlot(client, slot);
        if (weapon == -1 || !IsValidEntity(weapon))
            continue;

        // Clip ammo (always specific to this weapon instance)
        int clip = GetEntProp(weapon, Prop_Data, "m_iClip1");
        if (clip > 0)
            totalAmmo += clip;

        // Reserve ammo (shared per ammo type - only count each type once)
        int ammoType = GetEntProp(weapon, Prop_Send, "m_iPrimaryAmmoType");
        if (ammoType < 0)
            continue;

        bool alreadySeen = false;
        for (int i = 0; i < seenCount; i++)
        {
            if (seenAmmoType[i] == ammoType)
            {
                alreadySeen = true;
                break;
            }
        }

        if (alreadySeen)
            continue;

        if (seenCount < sizeof(seenAmmoType))
        {
            seenAmmoType[seenCount] = ammoType;
            seenCount++;
        }

        totalAmmo += GetEntProp(client, Prop_Send, "m_iAmmo", _, ammoType);
    }

    return totalAmmo;
}

bool IsZombieNearby(int client, float radiusSq)
{
    float clientPos[3];
    GetClientAbsOrigin(client, clientPos);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsPlayerAlive(i))
            continue;

        if (GetClientTeam(i) != TEAM_ZOMBIE)
            continue;

        float zombiePos[3];
        GetClientAbsOrigin(i, zombiePos);

        if (GetVectorDistance(clientPos, zombiePos, true) <= radiusSq)
            return true;
    }

    return false;
}
