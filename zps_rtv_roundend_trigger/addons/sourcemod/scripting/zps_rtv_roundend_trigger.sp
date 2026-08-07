#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <nextmap>

#define PLUGIN_VERSION "0.2.8"

public Plugin myinfo =
{
    name        = "ZPS RTV Round End Trigger",
    author      = "Claude.ai guided by DNA.styx",
    description = "Does a RTV end of round map change.",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

ConVar g_hNextMap;
ConVar g_hRtvChangeTime;
ConVar g_hDelay;
ConVar g_hDebug;
bool g_bRtvPending = false;
bool g_bVoteConfirmed = false;
char g_sConfirmedMap[PLATFORM_MAX_PATH];
char g_sLogPath[PLATFORM_MAX_PATH];

public void OnPluginStart()
{
    CreateConVar("zps_rtv_roundend_trigger_version", PLUGIN_VERSION, "ZPS RTV Round End Trigger version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);

    g_hDelay = CreateConVar("zps_rtv_roundend_trigger_delay", "10.0", "Delay in seconds before forcing the map change.", FCVAR_PROTECTED, true, 0.0);

    g_hDebug = CreateConVar("zps_rtv_roundend_trigger_debug", "0", "Log detection-stage detail.", FCVAR_PROTECTED, true, 0.0, true, 1.0);

    AutoExecConfig(true, "zps_rtv_roundend_trigger");

    BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/zps_rtv_roundend_trigger.log");

    AddCommandListener(Command_RTVConsole, "sm_rtv");
    AddCommandListener(Command_Say, "say");
    AddCommandListener(Command_Say, "say_team");

    HookEvent("clientsound", Event_ClientSound);

    g_hRtvChangeTime = FindConVar("sm_rtv_changetime");

    g_hNextMap = FindConVar("sm_nextmap");
    if (g_hNextMap != null)
    {
        HookConVarChange(g_hNextMap, OnNextMapChanged);
    }
    else
    {
        if (g_hDebug.BoolValue)
        {
            LogToFile(g_sLogPath, "sm_nextmap convar not found at plugin start - nextmap.smx may not be loaded yet.");
        }
    }
}

public void OnMapStart()
{
    g_bRtvPending = false;
    g_bVoteConfirmed = false;
    g_sConfirmedMap[0] = '\0';
}

public void OnMapEnd()
{
    g_bRtvPending = false;
    g_bVoteConfirmed = false;
    g_sConfirmedMap[0] = '\0';
}

bool IsRtvRoundEndMode()
{
    return (g_hRtvChangeTime != null && g_hRtvChangeTime.IntValue == 1);
}

public Action Command_RTVConsole(int client, const char[] command, int args)
{
    if (!IsRtvRoundEndMode())
    {
        return Plugin_Continue;
    }

    g_bRtvPending = true;
    if (g_hDebug.BoolValue)
    {
        LogToFile(g_sLogPath, "RTV attempt detected via sm_rtv console command.");
    }
    return Plugin_Continue;
}

public Action Command_Say(int client, const char[] command, int args)
{
    if (client <= 0 || !IsClientInGame(client))
    {
        return Plugin_Continue;
    }

    char text[192];
    GetCmdArgString(text, sizeof(text));

    int len = strlen(text);
    if (len >= 2 && text[0] == '"' && text[len - 1] == '"')
    {
        text[len - 1] = '\0';
        strcopy(text, sizeof(text), text[1]);
    }

    if ((StrEqual(text, "rtv", false) || StrEqual(text, "rockthevote", false)) && IsRtvRoundEndMode())
    {
        g_bRtvPending = true;
        if (g_hDebug.BoolValue)
        {
            LogToFile(g_sLogPath, "RTV attempt detected via chat trigger.");
        }
    }

    return Plugin_Continue;
}

public void OnNextMapChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
    if (!g_bRtvPending)
    {
        return;
    }

    strcopy(g_sConfirmedMap, sizeof(g_sConfirmedMap), newValue);
    g_bVoteConfirmed = true;
    if (g_hDebug.BoolValue)
    {
        LogToFile(g_sLogPath, "sm_nextmap changed to \"%s\" while an RTV attempt was pending - treating as vote confirmation.", newValue);
    }
}

public void Event_ClientSound(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_bRtvPending)
    {
        return;
    }

    char sound[64];
    event.GetString("sound", sound, sizeof(sound));

    if (StrContains(sound, "Round_End.Human", false) == -1
        && StrContains(sound, "Round_End.Zombie", false) == -1
        && StrContains(sound, "Round_End.Stalemate", false) == -1)
    {
        return;
    }

    if (!g_bVoteConfirmed)
    {
        if (g_hDebug.BoolValue)
        {
            LogToFile(g_sLogPath, "RTV was attempted, but no confirmed sm_nextmap change found at round end (sound: \"%s\"). Clearing pending flag.", sound);
        }
        g_bRtvPending = false;
        g_bVoteConfirmed = false;
        g_sConfirmedMap[0] = '\0';
        return;
    }

    if (g_hDebug.BoolValue)
    {
        LogToFile(g_sLogPath, "RTV vote confirmed passed. Round-end sound: \"%s\". Target map: \"%s\". Queuing map change in %.1f seconds.", sound, g_sConfirmedMap, g_hDelay.FloatValue);
    }

    PrintToChatAll("[SM] RTV map change to %s", g_sConfirmedMap);

    DataPack pack;
    CreateDataTimer(g_hDelay.FloatValue, Timer_ForceMapChange, pack, TIMER_FLAG_NO_MAPCHANGE);
    pack.WriteString(g_sConfirmedMap);
    pack.Reset();

    g_bRtvPending = false;
    g_bVoteConfirmed = false;
    g_sConfirmedMap[0] = '\0';
}

public Action Timer_ForceMapChange(Handle timer, DataPack pack)
{
    pack.Reset();
    char map[PLATFORM_MAX_PATH];
    pack.ReadString(map, sizeof(map));

    if (g_hDebug.BoolValue)
    {
        LogToFile(g_sLogPath, "Forcing map change to \"%s\" (RTV, RoundEnd).", map);
    }
    ForceChangeLevel(map, "RTV (RoundEnd)");

    return Plugin_Stop;
}
