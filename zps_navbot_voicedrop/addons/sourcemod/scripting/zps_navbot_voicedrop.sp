#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#if !defined REQUIRE_EXTENSIONS
    #define REQUIRE_EXTENSIONS
#endif
#include <navbot>

#define PLUGIN_VERSION "2.3.0"

#define TEAM_SURVIVOR 2

GameData g_hGameData;
DynamicDetour g_ddVoiceMenu;

public Plugin myinfo =
{
    name = "ZPS Bot Drop Weapon",
    author = "Claude.ai guided by DNA.styx",
    description = "The survivor bot a player is aiming at (or nearest if not aiming at one) drops its weapon on #VOICE_NEED_WEAPON",
    version = PLUGIN_VERSION,
    url = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
    CreateConVar("zps_bot_drop_weapon_version", PLUGIN_VERSION, "ZPS Bot Drop Weapon version", FCVAR_NOTIFY|FCVAR_DONTRECORD);

    g_hGameData = new GameData("zps_bot_drop_weapon.games");
    if (g_hGameData == null)
        SetFailState("Failed to load gamedata file zps_bot_drop_weapon.games.txt");

    g_ddVoiceMenu = DynamicDetour.FromConf(g_hGameData, "OnPlayerVoiceMenu");
    if (g_ddVoiceMenu == null)
        SetFailState("Failed to setup OnPlayerVoiceMenu detour. Check gamedata.");

    g_ddVoiceMenu.Enable(Hook_Post, Detour_VoiceMenu);
}

public void OnPluginEnd()
{
    if (g_ddVoiceMenu != null)
        g_ddVoiceMenu.Disable(Hook_Post, Detour_VoiceMenu);
}

public MRESReturn Detour_VoiceMenu(int pThis, DHookParam hParams)
{
    if (pThis < 1 || pThis > MaxClients || !IsClientInGame(pThis) || IsFakeClient(pThis))
        return MRES_Ignored;

    char szExternalText[64];
    hParams.GetString(2, szExternalText, sizeof(szExternalText));

    if (StrEqual(szExternalText, "#VOICE_NEED_WEAPON", false))
    {
        DropTargetBotWeapon(pThis);
    }

    return MRES_Ignored;
}

void DropTargetBotWeapon(int caller)
{
    char callerName[MAX_NAME_LENGTH];
    GetClientName(caller, callerName, sizeof(callerName));

    int target = FindTargetBot(caller);
    if (target == -1)
    {
        LogMessage("#VOICE_NEED_WEAPON triggered by %s - no survivor bot found", callerName);
        return;
    }

    NavBot bot = NavBotManager.GetNavBotByIndex(target);
    if (bot == NULL_NAVBOT)
    {
        LogMessage("#VOICE_NEED_WEAPON triggered by %s - target bot has no NavBot instance", callerName);
        return;
    }

    bot.DelayedFakeClientCommand("dropweapon");
    CreateTimer(0.5, Timer_SelectBestWeapon, GetClientUserId(target), TIMER_FLAG_NO_MAPCHANGE);

    char botName[MAX_NAME_LENGTH];
    GetClientName(target, botName, sizeof(botName));

    PrintToChat(caller, "%s has dropped you a weapon.", botName);
    LogMessage("#VOICE_NEED_WEAPON triggered by %s - targeted bot %s queued dropweapon", callerName, botName);
}

int FindTargetBot(int caller)
{
    float eyePos[3], eyeAng[3];
    GetClientEyePosition(caller, eyePos);
    GetClientEyeAngles(caller, eyeAng);

    TR_TraceRayFilter(eyePos, eyeAng, MASK_SHOT, RayType_Infinite, TraceFilter_IgnoreSelf, caller);

    if (TR_DidHit())
    {
        int hitEntity = TR_GetEntityIndex();
        if (hitEntity >= 1 && hitEntity <= MaxClients
            && IsClientInGame(hitEntity) && IsFakeClient(hitEntity)
            && GetClientTeam(hitEntity) == TEAM_SURVIVOR)
        {
            return hitEntity;
        }
    }

    float callerOrigin[3];
    GetClientAbsOrigin(caller, callerOrigin);

    int nearest = -1;
    float nearestDistSqr = -1.0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsFakeClient(i))
            continue;

        if (GetClientTeam(i) != TEAM_SURVIVOR)
            continue;

        float botOrigin[3];
        GetClientAbsOrigin(i, botOrigin);
        float distSqr = GetVectorDistance(callerOrigin, botOrigin, true);

        if (nearest == -1 || distSqr < nearestDistSqr)
        {
            nearest = i;
            nearestDistSqr = distSqr;
        }
    }

    return nearest;
}

public bool TraceFilter_IgnoreSelf(int entity, int contentsMask, any data)
{
    return entity != data;
}

public Action Timer_SelectBestWeapon(Handle timer, any data)
{
    int client = GetClientOfUserId(data);
    if (client == 0 || !IsClientInGame(client) || !IsFakeClient(client))
        return Plugin_Stop;

    NavBot bot = NavBotManager.GetNavBotByIndex(client);
    if (bot == NULL_NAVBOT)
        return Plugin_Stop;

    Address ptr = bot.GetInventoryInterface();
    NavBotInventoryInterface.SelectBestWeapon(ptr);

    return Plugin_Stop;
}
