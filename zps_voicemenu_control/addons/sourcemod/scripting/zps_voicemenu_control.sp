#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>
#include <basecomm>

#define PLUGIN_VERSION "0.1.0"

GameData g_hGameData;
DynamicDetour g_ddVoiceMenu;

ConVar g_cvBlockEnable;
ConVar g_cvCooldown;
ConVar g_cvLogBlock;
ConVar g_cvLogCooldown;

char g_szBlockLog[PLATFORM_MAX_PATH];
char g_szCooldownLog[PLATFORM_MAX_PATH];

float g_flNextAllowed[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "ZPS VoiceMenu Control",
    author = "Claude.ai guided by DNA.styx",
    description = "Blocks voice menu commands for gagged/muted players and applies a shared voice menu cooldown",
    version = PLUGIN_VERSION,
    url = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
    CreateConVar("zps_voicemenu_control_version", PLUGIN_VERSION, "ZPS VoiceMenu Control version", FCVAR_NOTIFY|FCVAR_DONTRECORD);
    g_cvBlockEnable = CreateConVar("sm_vmc_block_enable", "1", "Block voice menu for gagged or muted players (0 = off, 1 = on).", FCVAR_PROTECTED, true, 0.0, true, 1.0);
    g_cvCooldown = CreateConVar("sm_vmc_cooldown", "5.0", "Shared cooldown in seconds between voice menu commands (0 = off).", FCVAR_PROTECTED, true, 0.0);
    g_cvLogBlock = CreateConVar("sm_vmc_log_block", "1", "Log gag/mute blocks to logs/zps_voicemenu_control_block.log (0 = off, 1 = on).", FCVAR_PROTECTED, true, 0.0, true, 1.0);
    g_cvLogCooldown = CreateConVar("sm_vmc_log_cooldown", "1", "Log cooldown blocks to logs/zps_voicemenu_control_cooldown.log (0 = off, 1 = on).", FCVAR_PROTECTED, true, 0.0, true, 1.0);

    BuildPath(Path_SM, g_szBlockLog, sizeof(g_szBlockLog), "logs/zps_voicemenu_control_block.log");
    BuildPath(Path_SM, g_szCooldownLog, sizeof(g_szCooldownLog), "logs/zps_voicemenu_control_cooldown.log");

    g_hGameData = new GameData("zps_voicemenu_control.games");
    if (g_hGameData == null)
        SetFailState("Failed to load gamedata file zps_voicemenu_control.games.txt");

    g_ddVoiceMenu = DynamicDetour.FromConf(g_hGameData, "OnPlayerVoiceMenu");
    if (g_ddVoiceMenu == null)
        SetFailState("Failed to setup OnPlayerVoiceMenu detour. Check gamedata.");

    g_ddVoiceMenu.Enable(Hook_Pre, Detour_VoiceMenuPre);
}

public void OnPluginEnd()
{
    if (g_ddVoiceMenu != null)
        g_ddVoiceMenu.Disable(Hook_Pre, Detour_VoiceMenuPre);
}

public void OnMapStart()
{
    // GetGameTime() restarts each map.
    for (int i = 1; i <= MaxClients; i++)
        g_flNextAllowed[i] = 0.0;
}

public void OnClientDisconnect(int client)
{
    g_flNextAllowed[client] = 0.0;
}

public MRESReturn Detour_VoiceMenuPre(int pThis, DHookParam hParams)
{
    // Bots are exempt: voicedrop issues bot replies through this function via SDKCall.
    if (pThis < 1 || pThis > MaxClients || !IsClientInGame(pThis) || IsFakeClient(pThis))
        return MRES_Ignored;

    if (CheckCommandAccess(pThis, "sm_vmc_immunity", ADMFLAG_GENERIC, true))
        return MRES_Ignored;

    char szInternal[64];
    hParams.GetString(1, szInternal, sizeof(szInternal));

    if (g_cvBlockEnable.BoolValue)
    {
        bool gagged = BaseComm_IsClientGagged(pThis);
        bool muted = BaseComm_IsClientMuted(pThis);

        if (gagged || muted)
        {
            if (g_cvLogBlock.BoolValue)
                LogToFileEx(g_szBlockLog, "Blocked %L voice command \"%s\" (gagged=%d muted=%d)", pThis, szInternal, gagged, muted);
            return MRES_Supercede;
        }
    }

    float cooldown = g_cvCooldown.FloatValue;
    if (cooldown > 0.0)
    {
        float now = GetGameTime();
        if (now < g_flNextAllowed[pThis])
        {
            if (g_cvLogCooldown.BoolValue)
                LogToFileEx(g_szCooldownLog, "Cooldown %L voice command \"%s\" (%.1fs left)", pThis, szInternal, g_flNextAllowed[pThis] - now);
            return MRES_Supercede;
        }

        g_flNextAllowed[pThis] = now + cooldown;
    }

    return MRES_Ignored;
}
