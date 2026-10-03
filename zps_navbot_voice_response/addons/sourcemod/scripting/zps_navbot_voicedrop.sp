#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>

#if !defined REQUIRE_EXTENSIONS
    #define REQUIRE_EXTENSIONS
#endif
#include <navbot>

#define PLUGIN_VERSION "3.7.0"

#define TEAM_SURVIVOR 2
#define MAX_AMMO_SLOTS 32
#define AMMO_CHECK_DELAY 0.5

GameData g_hGameData;
DynamicDetour g_ddVoiceMenu;
Handle g_hSDKVoiceMenu;
ConVar g_cvCooldown;
ConVar g_cvLog;
char g_szLogFile[PLATFORM_MAX_PATH];
float g_flNextAllowed[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name = "ZPS NavBot Voicedrop",
    author = "Claude.ai guided by DNA.styx",
    description = "A Navbot will drops its weapon or spare ammo when a player uses #VOICE_NEED_WEAPON or NeedAmmo",
    version = PLUGIN_VERSION,
    url = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
    CreateConVar("zps_navbot_voicedrop_version", PLUGIN_VERSION, "ZPS NavBot Voicedrop version", FCVAR_NOTIFY|FCVAR_DONTRECORD);
    g_cvCooldown = CreateConVar("zps_navbot_voicedrop_cooldown", "60.0", "Per-player cooldown in seconds between weapon/ammo requests.", FCVAR_PROTECTED, true, 0.0);
    g_cvLog = CreateConVar("zps_navbot_voicedrop_log", "1", "Log requests and bot ammo before/after values to logs/zps_navbot_voicedrop.log (0 = off, 1 = on).", FCVAR_PROTECTED, true, 0.0, true, 1.0);

    BuildPath(Path_SM, g_szLogFile, sizeof(g_szLogFile), "logs/zps_navbot_voicedrop.log");

    g_hGameData = new GameData("zps_navbot_voicedrop.games");
    if (g_hGameData == null)
        SetFailState("Failed to load gamedata file zps_navbot_voicedrop.games.txt");

    g_ddVoiceMenu = DynamicDetour.FromConf(g_hGameData, "OnPlayerVoiceMenu");
    if (g_ddVoiceMenu == null)
        SetFailState("Failed to setup OnPlayerVoiceMenu detour. Check gamedata.");

    g_ddVoiceMenu.Enable(Hook_Post, Detour_VoiceMenu);

    StartPrepSDKCall(SDKCall_Player);
    PrepSDKCall_SetFromConf(g_hGameData, SDKConf_Signature, "CZP_Player::VoiceMenu");
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
    PrepSDKCall_AddParameter(SDKType_String, SDKPass_Pointer);
    g_hSDKVoiceMenu = EndPrepSDKCall();
    if (g_hSDKVoiceMenu == null)
        SetFailState("Failed to setup SDKCall for CZP_Player::VoiceMenu. Check gamedata.");
}

public void OnMapStart()
{
    // GetGameTime() restarts on each map, so stored cooldown times must be cleared.
    for (int i = 1; i <= MaxClients; i++)
        g_flNextAllowed[i] = 0.0;
}

public void OnClientDisconnect(int client)
{
    g_flNextAllowed[client] = 0.0;
}

public void OnPluginEnd()
{
    if (g_ddVoiceMenu != null)
        g_ddVoiceMenu.Disable(Hook_Post, Detour_VoiceMenu);
}

void VLog(const char[] format, any ...)
{
    if (!g_cvLog.BoolValue)
        return;

    char buffer[1024];
    VFormat(buffer, sizeof(buffer), format, 2);
    LogToFileEx(g_szLogFile, "%s", buffer);
}

public MRESReturn Detour_VoiceMenu(int pThis, DHookParam hParams)
{
    if (pThis < 1 || pThis > MaxClients || !IsClientInGame(pThis) || IsFakeClient(pThis))
        return MRES_Ignored;

    char szInternalText[64];
    hParams.GetString(1, szInternalText, sizeof(szInternalText));

    char szExternalText[256];
    hParams.GetString(2, szExternalText, sizeof(szExternalText));

    bool isWeapon = StrEqual(szExternalText, "#VOICE_NEED_WEAPON", false);
    bool isAmmo = !isWeapon && StrEqual(szInternalText, "NeedAmmo", false);

    if (!isWeapon && !isAmmo)
        return MRES_Ignored;

    if (GetClientTeam(pThis) != TEAM_SURVIVOR || !IsPlayerAlive(pThis))
        return MRES_Ignored;

    if (IsOnCooldown(pThis))
    {
        VLog("%N requested %s - on cooldown for %.0fs, bot declines", pThis, isWeapon ? "weapon" : "ammo", g_flNextAllowed[pThis] - GetGameTime());
        QueueDeclineReply(pThis);
        return MRES_Ignored;
    }

    if (isWeapon)
        DropTargetBotWeapon(pThis);
    else
        DropNearestBotAmmo(pThis, szExternalText);

    return MRES_Ignored;
}

bool IsOnCooldown(int caller)
{
    return GetGameTime() < g_flNextAllowed[caller];
}

void StartCooldown(int caller)
{
    g_flNextAllowed[caller] = GetGameTime() + g_cvCooldown.FloatValue;
}

void QueueDeclineReply(int caller)
{
    int target = FindNearestSurvivorBot(caller);
    if (target == -1)
        return;

    // Deferred: calling VoiceMenu from inside the VoiceMenu detour crashes the server.
    RequestFrame(Frame_PlayDeclineVoice, GetClientUserId(target));
}

public void Frame_PlayDeclineVoice(any data)
{
    int bot = GetClientOfUserId(data);
    if (bot == 0 || !IsClientInGame(bot) || !IsFakeClient(bot) || !IsPlayerAlive(bot))
        return;

    SDKCall(g_hSDKVoiceMenu, bot, "Decline", "#VOICE_DISAGREE");
}

void DropTargetBotWeapon(int caller)
{
    int target = FindTargetBot(caller);
    if (target == -1)
    {
        VLog("%N requested weapon - no survivor bot found", caller);
        return;
    }

    NavBot bot;
    char botName[MAX_NAME_LENGTH];
    if (!ResolveBot(target, bot, botName, sizeof(botName)))
    {
        VLog("%N requested weapon - target bot has no NavBot instance", caller);
        return;
    }

    bot.DelayedFakeClientCommand("dropweapon");
    CreateTimer(0.5, Timer_SelectBestWeapon, GetClientUserId(target), TIMER_FLAG_NO_MAPCHANGE);
    StartCooldown(caller);

    PrintToChat(caller, "\x05[NAV]\x01 %s has dropped you a weapon.", botName);
    VLog("%N requested weapon - bot %s queued dropweapon", caller, botName);
}

void DropNearestBotAmmo(int caller, const char[] voiceText)
{
    int botIds[MAXPLAYERS + 1];
    int slotCounts[MAXPLAYERS + 1];
    int before[MAXPLAYERS + 1][MAX_AMMO_SLOTS];
    int count = 0;

    char ammoText[512];

    int wantedMask = ParseRequestedAmmoTypes(voiceText);
    VLog("%N requested ammo - types mask %d - voice text: %s", caller, wantedMask, voiceText);

    // Prefer the nearest bot carrying an ammo type the player asked for.
    // If the voice text names no known type, fall back to the nearest bot.
    int nearest = (wantedMask != 0) ? FindNearestBotWithAmmo(caller, wantedMask) : FindNearestSurvivorBot(caller);

    for (int i = 1; i <= MaxClients; i++)
    {
        if (i != nearest)
            continue;

        NavBot bot;
        char botName[MAX_NAME_LENGTH];
        if (!ResolveBot(i, bot, botName, sizeof(botName)))
            continue;

        int slots = ReadAmmo(i, before[count]);
        FormatAmmo(before[count], slots, ammoText, sizeof(ammoText));

        bot.DelayedFakeClientCommand("dropammo");
        VLog("  %s - queued dropammo. before:%s", botName, ammoText);

        botIds[count] = GetClientUserId(i);
        slotCounts[count] = slots;
        count++;
    }

    if (count == 0)
    {
        VLog("%N requested ammo - no live survivor bot carrying the requested ammo, bot declines", caller);
        QueueDeclineReply(caller);
        return;
    }

    // Start the cooldown now so repeat requests during the check window are declined.
    // It is cleared again if the check finds nothing was dropped.
    StartCooldown(caller);

    DataPack pack;
    CreateDataTimer(AMMO_CHECK_DELAY, Timer_CheckAmmoDrop, pack, TIMER_FLAG_NO_MAPCHANGE);
    pack.WriteCell(GetClientUserId(caller));
    pack.WriteCell(count);

    for (int n = 0; n < count; n++)
    {
        pack.WriteCell(botIds[n]);
        pack.WriteCell(slotCounts[n]);
        for (int t = 0; t < slotCounts[n]; t++)
            pack.WriteCell(before[n][t]);
    }
}

public Action Timer_CheckAmmoDrop(Handle timer, DataPack pack)
{
    pack.Reset();
    int caller = GetClientOfUserId(pack.ReadCell());
    int count = pack.ReadCell();

    int before[MAX_AMMO_SLOTS];
    int after[MAX_AMMO_SLOTS];
    char beforeText[512], afterText[512];
    int dropped = 0;

    for (int n = 0; n < count; n++)
    {
        int bot = GetClientOfUserId(pack.ReadCell());
        int slots = pack.ReadCell();
        for (int t = 0; t < slots; t++)
            before[t] = pack.ReadCell();

        if (bot == 0 || !IsClientInGame(bot))
        {
            VLog("  check: bot left the game before the check");
            continue;
        }

        ReadAmmo(bot, after);
        FormatAmmo(before, slots, beforeText, sizeof(beforeText));
        FormatAmmo(after, slots, afterText, sizeof(afterText));

        bool decreased = false;
        for (int t = 0; t < slots; t++)
        {
            if (after[t] < before[t])
            {
                decreased = true;
                break;
            }
        }

        if (decreased)
            dropped++;

        VLog("  check: %N %s. before:%s after:%s", bot, decreased ? "DROPPED" : "no change", beforeText, afterText);
    }

    if (caller == 0 || !IsClientInGame(caller))
    {
        VLog("ammo check done - %d of %d bot(s) dropped, caller left the game", dropped, count);
        return Plugin_Stop;
    }

    if (dropped > 0)
    {
        PrintToChat(caller, "\x05[NAV]\x01 %d bot(s) dropped you some ammo.", dropped);
        VLog("ammo check done for %N - %d of %d bot(s) dropped", caller, dropped, count);
    }
    else
    {
        g_flNextAllowed[caller] = 0.0;
        QueueDeclineReply(caller);
        VLog("ammo check done for %N - 0 of %d bot(s) dropped, cooldown cleared, bot declines", caller, count);
    }

    return Plugin_Stop;
}

// Reads the bot's reserve ammo per ammo type from the m_iAmmo netprop array
// (the same property NavBot's GetAmmoOfIndex reads). Returns the number of slots read.
int ReadAmmo(int client, int[] ammo)
{
    int slots = GetEntPropArraySize(client, Prop_Send, "m_iAmmo");
    if (slots > MAX_AMMO_SLOTS)
        slots = MAX_AMMO_SLOTS;

    for (int t = 0; t < slots; t++)
        ammo[t] = GetEntProp(client, Prop_Send, "m_iAmmo", _, t);

    return slots;
}

void FormatAmmo(const int[] ammo, int slots, char[] buffer, int size)
{
    buffer[0] = '\0';
    for (int t = 0; t < slots; t++)
    {
        if (ammo[t] != 0)
            Format(buffer, size, "%s [%d]=%d", buffer, t, ammo[t]);
    }

    if (buffer[0] == '\0')
        strcopy(buffer, size, " none");
}

// Ammo type indexes follow ZPSUTIL: pistol 1, revolver 2, shotgun 3, rifle 4, barricade 5.
// Token names come from server_srv.so strings; MAG = revolver and BARR = barricade are assumed.
int ParseRequestedAmmoTypes(const char[] text)
{
    int mask = 0;
    if (StrContains(text, "VO_NEED_PISTOL") != -1)  mask |= (1 << 1);
    if (StrContains(text, "VO_NEED_MAG") != -1)     mask |= (1 << 2);
    if (StrContains(text, "VO_NEED_SHOTGUN") != -1) mask |= (1 << 3);
    if (StrContains(text, "VO_NEED_RIFLE") != -1)   mask |= (1 << 4);
    if (StrContains(text, "VO_NEED_BARR") != -1)    mask |= (1 << 5);
    return mask;
}

bool BotHasWantedAmmo(int bot, int wantedMask)
{
    for (int t = 1; t <= 5; t++)
    {
        if ((wantedMask & (1 << t)) && GetEntProp(bot, Prop_Send, "m_iAmmo", _, t) > 0)
            return true;
    }
    return false;
}

int FindNearestBotWithAmmo(int caller, int wantedMask)
{
    float callerOrigin[3];
    GetClientAbsOrigin(caller, callerOrigin);

    int nearest = -1;
    float nearestDistSqr = -1.0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsLiveSurvivorBot(i) || !BotHasWantedAmmo(i, wantedMask))
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

bool ResolveBot(int target, NavBot &bot, char[] botName, int size)
{
    bot = NavBotManager.GetNavBotByIndex(target);
    if (bot == NULL_NAVBOT)
        return false;

    GetClientName(target, botName, size);
    return true;
}

bool IsLiveSurvivorBot(int client)
{
    return IsClientInGame(client) && IsFakeClient(client)
        && IsPlayerAlive(client) && GetClientTeam(client) == TEAM_SURVIVOR;
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
        if (hitEntity >= 1 && hitEntity <= MaxClients && IsLiveSurvivorBot(hitEntity))
            return hitEntity;
    }

    return FindNearestSurvivorBot(caller);
}

int FindNearestSurvivorBot(int caller)
{
    float callerOrigin[3];
    GetClientAbsOrigin(caller, callerOrigin);

    int nearest = -1;
    float nearestDistSqr = -1.0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsLiveSurvivorBot(i))
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

    NavBot bot;
    char botName[MAX_NAME_LENGTH];
    if (!ResolveBot(client, bot, botName, sizeof(botName)))
        return Plugin_Stop;

    Address ptr = bot.GetInventoryInterface();
    NavBotInventoryInterface.RequestUpdate(ptr);
    NavBotInventoryInterface.SelectBestWeapon(ptr);

    return Plugin_Stop;
}
