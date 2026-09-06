/**
 * ZPS Bot Volunteer Zombie v0.11.0
 * Author: Claude.ai guided by DNA.styx
 */

#include <sourcemod>

#pragma semicolon 1
#pragma newdecls required

#define PLUGIN_VERSION   "0.11.0"

#define SELECTION_WINDOW_SECONDS         15.0

ConVar g_cvVersion;
ConVar g_cvMaxPlayers;
ConVar g_cvLogging;
char g_sLogFile[PLATFORM_MAX_PATH];
bool g_bSelectionWindowActive;
int g_iVolunteerOffset;

public Plugin myinfo =
{
    name        = "ZPS Bot Volunteer Zombie",
    author      = "Claude.ai guided by DNA.styx",
    description = "Applies volunteer-for-zombie flag to bots at round start",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
    GameData gd = new GameData("zps_bot_volunteer_zombie");
    if (gd == null)
    {
        SetFailState("Could not load gamedata file zps_bot_volunteer_zombie.games.txt");
    }

    g_iVolunteerOffset = gd.GetOffset("VolunteerForZombie");
    delete gd;

    if (g_iVolunteerOffset == -1)
    {
        SetFailState("VolunteerForZombie offset not found in gamedata - check zps_bot_volunteer_zombie.games.txt");
    }

    g_cvVersion = CreateConVar(
        "zps_bot_volunteer_zombie_version",
        PLUGIN_VERSION,
        "Plugin version.",
        FCVAR_NOTIFY | FCVAR_DONTRECORD
    );
    g_cvVersion.SetString(PLUGIN_VERSION);

    g_cvMaxPlayers = CreateConVar(
        "zps_bot_volunteer_zombie_maxplayers",
        "2",
        "Only flag bots while real player count is at or below this value. 0 = always active regardless of player count.",
        FCVAR_PROTECTED
    );

    g_cvLogging = CreateConVar(
        "zps_bot_volunteer_zombie_logging",
        "0",
        "Enable logging to logs/zps_bot_volunteer_zombie.log. 0 = disabled, 1 = enabled.",
        FCVAR_PROTECTED
    );

    AutoExecConfig(true, "zps_bot_volunteer_zombie");

    BuildPath(Path_SM, g_sLogFile, sizeof(g_sLogFile), "logs/zps_bot_volunteer_zombie.log");

    if (g_cvLogging.BoolValue)
    {
        LogToFileEx(g_sLogFile, "[BotVolunteerZombie] Plugin started, version %s", PLUGIN_VERSION);
    }

    HookEvent("clientsound", Event_ClientSound, EventHookMode_Post);
    HookEvent("player_team", Event_PlayerTeam, EventHookMode_Post);
}

int GetRealPlayerCount()
{
    int count = 0;
    for (int i = 1; i <= MaxClients; i++)
    {
        if (IsClientInGame(i) && !IsFakeClient(i))
        {
            count++;
        }
    }
    return count;
}

bool ShouldBeActiveThisRound(int realPlayerCount)
{
    int maxPlayers = g_cvMaxPlayers.IntValue;
    if (maxPlayers == 0)
    {
        return true;
    }
    return realPlayerCount <= maxPlayers;
}

/**
 * Logs only true initial zombie picks (~15s post-Round_Starting), not
 * mid-round infections, to keep log volume manageable.
 */
public void Event_PlayerTeam(Event event, const char[] name, bool dontBroadcast)
{
    if (!g_cvLogging.BoolValue || !g_bSelectionWindowActive)
    {
        return;
    }

    int oldTeam = event.GetInt("oldteam");
    int newTeam = event.GetInt("team");

    if (!(oldTeam == 2 && newTeam == 3))
    {
        return;
    }

    int userid = event.GetInt("userid");
    int client = GetClientOfUserId(userid);
    if (client == 0)
    {
        return;
    }

    char clientName[MAX_NAME_LENGTH];
    GetClientName(client, clientName, sizeof(clientName));
    bool isFake = IsFakeClient(client);
    int flagValue = GetEntData(client, g_iVolunteerOffset, 1);

    LogToFileEx(g_sLogFile, "[BotVolunteerZombie] SELECTED: %s (userid=%d fake=%b flag=%d)",
        clientName, userid, isFake, flagValue);
}

public void Event_ClientSound(Event event, const char[] name, bool dontBroadcast)
{
    char sound[128];
    event.GetString("sound", sound, sizeof(sound));

    if (StrContains(sound, "Round_Starting", false) != -1)
    {
        int realPlayerCount = GetRealPlayerCount();

        if (!ShouldBeActiveThisRound(realPlayerCount))
        {
            if (g_cvLogging.BoolValue)
            {
                LogToFileEx(g_sLogFile, "[BotVolunteerZombie] Round_Starting - skipped (realPlayerCount=%d > maxplayers=%d)",
                    realPlayerCount, g_cvMaxPlayers.IntValue);
            }
            g_bSelectionWindowActive = false;
            return;
        }

        ApplyToAllBots();

        g_bSelectionWindowActive = true;
        CreateTimer(SELECTION_WINDOW_SECONDS, Timer_CloseSelectionWindow, _, TIMER_FLAG_NO_MAPCHANGE);
    }
}

public Action Timer_CloseSelectionWindow(Handle timer)
{
    g_bSelectionWindowActive = false;
    return Plugin_Stop;
}

void ApplyToAllBots()
{
    int applied = 0;

    for (int i = 1; i <= MaxClients; i++)
    {
        if (!IsClientInGame(i) || !IsFakeClient(i))
        {
            continue;
        }

        SetEntData(i, g_iVolunteerOffset, true, 1);
        applied++;
    }

    if (g_cvLogging.BoolValue)
    {
        LogToFileEx(g_sLogFile, "[BotVolunteerZombie] Round_Starting - flagged %d bot(s)", applied);
    }
}
