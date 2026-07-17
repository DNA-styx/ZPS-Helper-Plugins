/**
 * zps_navbot_objectives.sp
 * Directs NavBot bots through map-defined objectives via ordered per-team
 * command sequences.
 * Config: configs/zps_navbot_objectives/<map>.cfg
 * Author: Claude.ai guided by DNA.styx
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdktools_entoutput>
#include <navbot>

#define PLUGIN_VERSION "0.4.5"
#define CFG_SCHEMA_VERSION 3

#define TEAM_SURVIVOR 2
#define TEAM_ZOMBIE   3

#define MAX_OBJECTIVES            8
#define MAX_TARGETS_PER_OBJECTIVE 6
#define MAX_COMMANDS_PER_TASK     4

#define ORIGIN_TOLERANCE 16.0

enum struct TargetData
{
    char  sName[64];
    char  sType[32];
    float fOrigin[3];
    char  sCompletedOutput[32];
    int   iEntity;
    bool  bCompleted;
}

enum struct CommandStep
{
    int   cmdType;
    float fParam;
}

enum struct TeamTaskData
{
    bool        bConfigured;
    int         iCommandCount;
    CommandStep commands[MAX_COMMANDS_PER_TASK];
}

enum struct ObjectiveData
{
    char          sName[64];
    int           iTargetCount;
    TargetData    targets[MAX_TARGETS_PER_OBJECTIVE];
    TeamTaskData  survivorTask;
    TeamTaskData  zombieTask;
}

ObjectiveData g_Objectives[MAX_OBJECTIVES];
int           g_iObjectiveCount = 0;
int           g_iCurrentObjective = -1;

ConVar g_cvEnabled;
ConVar g_cvPollInterval;
ConVar g_cvRoundStartDelay;

bool   g_bConfigLoaded = false;
bool   g_bPollingAllowed = false;
Handle g_hRoundStartTimer = null;

int   g_iBotObjective[MAXPLAYERS + 1];
bool  g_bBotZombie[MAXPLAYERS + 1];
int   g_iBotCommandIndex[MAXPLAYERS + 1];
int   g_iBotTargetIndex[MAXPLAYERS + 1];
float g_fBotCommandStart[MAXPLAYERS + 1];
bool  g_bBotDone[MAXPLAYERS + 1];

public Plugin myinfo =
{
    name        = "ZPS NavBot Objectives",
    author      = "Claude.ai guided by DNA.styx",
    description = "Directs NavBot bots through map-defined objectives.",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
    CreateConVar("zps_navbot_objectives_version", PLUGIN_VERSION, "ZPS NavBot Objectives plugin version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
    g_cvEnabled         = CreateConVar("zps_navbot_objectives_enabled", "1", "Enable/disable objective processing.", FCVAR_PROTECTED);
    g_cvPollInterval    = CreateConVar("zps_navbot_objectives_poll_interval", "1.0", "Seconds between polls.", FCVAR_PROTECTED);
    g_cvRoundStartDelay = CreateConVar("zps_navbot_objectives_round_start_delay", "10.0", "Seconds after Round_Starting before polling begins.", FCVAR_PROTECTED);

    HookEvent("clientsound", Event_ClientSound);
}

void ZpoMsg(const char[] format, any ...)
{
    char sMsg[256];
    VFormat(sMsg, sizeof(sMsg), format, 2);
    PrintToChatAll("[ZPO] %s", sMsg);
}

public void Event_ClientSound(Event event, const char[] name, bool dontBroadcast)
{
    char sSound[64];
    event.GetString("sound", sSound, sizeof(sSound));
    if (StrContains(sSound, "Round_Starting", false) == -1)
        return;

    if (g_hRoundStartTimer != null)
    {
        KillTimer(g_hRoundStartTimer);
        g_hRoundStartTimer = null;
    }

    if (g_bConfigLoaded)
        ResetObjectiveProgress();

    g_bPollingAllowed = false;
    g_hRoundStartTimer = CreateTimer(g_cvRoundStartDelay.FloatValue, Timer_RoundStartDelay, _, TIMER_FLAG_NO_MAPCHANGE);
}

void ResetObjectiveProgress()
{
    g_iCurrentObjective = (g_iObjectiveCount > 0) ? 0 : -1;

    for (int o = 0; o < g_iObjectiveCount; o++)
    {
        for (int t = 0; t < g_Objectives[o].iTargetCount; t++)
            g_Objectives[o].targets[t].bCompleted = false;
    }

    for (int client = 0; client <= MAXPLAYERS; client++)
    {
        g_iBotObjective[client] = -1;
        g_bBotDone[client] = false;
    }

    ZpoMsg("Objective progress reset for new round.");
}

public Action Timer_RoundStartDelay(Handle timer)
{
    g_hRoundStartTimer = null;
    g_bPollingAllowed = true;
    ZpoMsg("Polling enabled.");
    return Plugin_Stop;
}

public void OnMapStart()
{
    g_bConfigLoaded = false;
    g_bPollingAllowed = false;
    g_hRoundStartTimer = null;
    g_iObjectiveCount = 0;
    g_iCurrentObjective = -1;

    for (int client = 0; client <= MAXPLAYERS; client++)
    {
        g_iBotObjective[client] = -1;
        g_bBotDone[client] = false;
    }

    if (!LoadConfig())
        return;

    g_bConfigLoaded = true;
    g_iCurrentObjective = 0;
    HookAllTargetOutputs();

    CreateTimer(g_cvPollInterval.FloatValue, Timer_PollObjective, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

bool LoadConfig()
{
    char sMap[PLATFORM_MAX_PATH];
    GetCurrentMap(sMap, sizeof(sMap));

    char sPath[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, sPath, sizeof(sPath), "configs/zps_navbot_objectives/%s.cfg", sMap);

    if (!FileExists(sPath))
        return false;

    KeyValues kv = new KeyValues("zps_navbot_objectives");
    if (!kv.ImportFromFile(sPath))
    {
        ZpoMsg("Failed to parse %s.cfg.", sMap);
        delete kv;
        return false;
    }

    if (kv.GetNum("version", -1) != CFG_SCHEMA_VERSION)
    {
        ZpoMsg("%s.cfg schema version mismatch - expected %d.", sMap, CFG_SCHEMA_VERSION);
        delete kv;
        return false;
    }

    if (kv.GotoFirstSubKey(true))
    {
        do
        {
            char sSectionName[32];
            kv.GetSectionName(sSectionName, sizeof(sSectionName));
            if (!StrEqual(sSectionName, "objective") || g_iObjectiveCount >= MAX_OBJECTIVES)
                continue;

            ParseObjective(kv, g_iObjectiveCount);
            g_iObjectiveCount++;

        } while (kv.GotoNextKey(true));
    }

    delete kv;

    int missing = 0;
    for (int o = 0; o < g_iObjectiveCount; o++)
    {
        for (int t = 0; t < g_Objectives[o].iTargetCount; t++)
        {
            int entity = ResolveTargetEntity(
                g_Objectives[o].targets[t].sName,
                g_Objectives[o].targets[t].sType,
                g_Objectives[o].targets[t].fOrigin,
                ORIGIN_TOLERANCE);

            if (entity == -1)
            {
                ZpoMsg("Objective %d target %d ('%s') not found.", o + 1, t + 1, g_Objectives[o].targets[t].sName);
                missing++;
                continue;
            }

            g_Objectives[o].targets[t].iEntity = entity;
            ZpoMsg("Objective %d target %d ('%s') resolved to entity %d.", o + 1, t + 1, g_Objectives[o].targets[t].sName, entity);
        }
    }

    if (missing > 0)
    {
        ZpoMsg("%s.cfg load failed: %d target(s) not found.", sMap, missing);
        return false;
    }

    ZpoMsg("%s.cfg loaded: %d objective(s).", sMap, g_iObjectiveCount);
    return true;
}

void ParseObjective(KeyValues kv, int objIdx)
{
    kv.GetString("name", g_Objectives[objIdx].sName, 64, "");
    if (g_Objectives[objIdx].sName[0] == '\0')
        Format(g_Objectives[objIdx].sName, 64, "Objective %d", objIdx + 1);

    // Reset before re-parsing - otherwise a second map load appends after
    // stale data instead of overwriting from index 0.
    g_Objectives[objIdx].iTargetCount = 0;
    g_Objectives[objIdx].survivorTask.bConfigured = false;
    g_Objectives[objIdx].survivorTask.iCommandCount = 0;
    g_Objectives[objIdx].zombieTask.bConfigured = false;
    g_Objectives[objIdx].zombieTask.iCommandCount = 0;

    if (!kv.GotoFirstSubKey(true))
        return;

    do
    {
        char sSectionName[32];
        kv.GetSectionName(sSectionName, sizeof(sSectionName));

        if (StrEqual(sSectionName, "target") && g_Objectives[objIdx].iTargetCount < MAX_TARGETS_PER_OBJECTIVE)
        {
            int t = g_Objectives[objIdx].iTargetCount;
            kv.GetString("name", g_Objectives[objIdx].targets[t].sName, 64, "");
            kv.GetString("type", g_Objectives[objIdx].targets[t].sType, 32, "");
            kv.GetString("completed", g_Objectives[objIdx].targets[t].sCompletedOutput, 32, "");

            char sOrigin[64];
            kv.GetString("origin", sOrigin, sizeof(sOrigin), "0 0 0");
            ParseOriginString(sOrigin, g_Objectives[objIdx].targets[t].fOrigin);

            g_Objectives[objIdx].targets[t].iEntity = -1;
            g_Objectives[objIdx].targets[t].bCompleted = false;
            g_Objectives[objIdx].iTargetCount++;
        }
        else if (StrEqual(sSectionName, "survivor_tasks"))
        {
            ParseTeamTask(kv, objIdx, false);
        }
        else if (StrEqual(sSectionName, "zombie_tasks"))
        {
            ParseTeamTask(kv, objIdx, true);
        }

    } while (kv.GotoNextKey(true));
    kv.GoBack();
}

void ParseTeamTask(KeyValues kv, int objIdx, bool bZombie)
{
    if (!KvEnterFirstChildNamed(kv, "task"))
        return;

    if (kv.GotoFirstSubKey(true))
    {
        int iCmdCount = 0;
        do
        {
            char sCmdSection[32];
            kv.GetSectionName(sCmdSection, sizeof(sCmdSection));
            if (!StrEqual(sCmdSection, "command") || iCmdCount >= MAX_COMMANDS_PER_TASK)
                continue;

            char sType[32];
            kv.GetString("type", sType, sizeof(sType), "");
            int cmdType = CommandTypeFromString(sType);
            float fParam = kv.GetFloat("duration", 0.0);

            if (bZombie)
            {
                g_Objectives[objIdx].zombieTask.commands[iCmdCount].cmdType = cmdType;
                g_Objectives[objIdx].zombieTask.commands[iCmdCount].fParam = fParam;
            }
            else
            {
                g_Objectives[objIdx].survivorTask.commands[iCmdCount].cmdType = cmdType;
                g_Objectives[objIdx].survivorTask.commands[iCmdCount].fParam = fParam;
            }

            iCmdCount++;

        } while (kv.GotoNextKey(true));
        kv.GoBack();

        if (bZombie)
        {
            g_Objectives[objIdx].zombieTask.iCommandCount = iCmdCount;
            g_Objectives[objIdx].zombieTask.bConfigured = (iCmdCount > 0);
        }
        else
        {
            g_Objectives[objIdx].survivorTask.iCommandCount = iCmdCount;
            g_Objectives[objIdx].survivorTask.bConfigured = (iCmdCount > 0);
        }
    }

    kv.GoBack();
}

// Cursor left one level deeper on success (caller must GoBack). On failure
// the cursor is already restored - no GoBack needed.
bool KvEnterFirstChildNamed(KeyValues kv, const char[] name)
{
    if (!kv.GotoFirstSubKey(true))
        return false;

    do
    {
        char sSection[32];
        kv.GetSectionName(sSection, sizeof(sSection));
        if (StrEqual(sSection, name))
            return true;
    } while (kv.GotoNextKey(true));

    kv.GoBack();
    return false;
}

int CommandTypeFromString(const char[] sType)
{
    if (StrEqual(sType, "MOVE_TO", false))          return view_as<int>(NAVBOT_PLUGINCMD_MOVE_TO);
    if (StrEqual(sType, "WAIT", false))              return view_as<int>(NAVBOT_PLUGINCMD_WAIT);
    if (StrEqual(sType, "PATROL", false))            return view_as<int>(NAVBOT_PLUGINCMD_PATROL);
    if (StrEqual(sType, "SEEK_AND_DESTROY", false))  return view_as<int>(NAVBOT_PLUGINCMD_SEEK_AND_DESTROY);
    return -1;
}

void CommandTypeToString(int cmdType, char[] sOut, int size)
{
    if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_MOVE_TO))               strcopy(sOut, size, "MOVE_TO");
    else if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_WAIT))             strcopy(sOut, size, "WAIT");
    else if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_PATROL))           strcopy(sOut, size, "PATROL");
    else if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_SEEK_AND_DESTROY)) strcopy(sOut, size, "SEEK_AND_DESTROY");
    else                                                                 strcopy(sOut, size, "UNKNOWN");
}

void ParseOriginString(const char[] sOrigin, float fOut[3])
{
    char sParts[3][32];
    ExplodeString(sOrigin, " ", sParts, 3, 32);
    fOut[0] = StringToFloat(sParts[0]);
    fOut[1] = StringToFloat(sParts[1]);
    fOut[2] = StringToFloat(sParts[2]);
}

int ResolveTargetEntity(const char[] sName, const char[] sType, const float fOrigin[3], float flTolerance)
{
    int best = -1;
    float bestDist = 999999.0;
    int entity = -1;

    while ((entity = FindEntityByClassname(entity, sType)) != -1)
    {
        char sEntName[64];
        GetEntPropString(entity, Prop_Data, "m_iName", sEntName, sizeof(sEntName));
        if (!StrEqual(sEntName, sName, false))
            continue;

        float fEntOrigin[3];
        GetEntPropVector(entity, Prop_Send, "m_vecOrigin", fEntOrigin);
        float dist = GetVectorDistance(fOrigin, fEntOrigin);
        if (dist <= flTolerance && dist < bestDist)
        {
            bestDist = dist;
            best = entity;
        }
    }

    return best;
}

void HookAllTargetOutputs()
{
    char sHookedPairs[MAX_OBJECTIVES * MAX_TARGETS_PER_OBJECTIVE][64];
    int  iHookedCount = 0;

    for (int o = 0; o < g_iObjectiveCount; o++)
    {
        for (int t = 0; t < g_Objectives[o].iTargetCount; t++)
        {
            char sPair[64];
            Format(sPair, sizeof(sPair), "%s:%s", g_Objectives[o].targets[t].sType, g_Objectives[o].targets[t].sCompletedOutput);

            bool bAlreadyHooked = false;
            for (int i = 0; i < iHookedCount; i++)
            {
                if (StrEqual(sHookedPairs[i], sPair))
                {
                    bAlreadyHooked = true;
                    break;
                }
            }

            if (!bAlreadyHooked)
            {
                HookEntityOutput(g_Objectives[o].targets[t].sType, g_Objectives[o].targets[t].sCompletedOutput, Callback_TargetCompleted);
                strcopy(sHookedPairs[iHookedCount], 64, sPair);
                iHookedCount++;
            }
        }
    }
}

public void Callback_TargetCompleted(const char[] output, int caller, int activator, float delay)
{
    for (int o = 0; o < g_iObjectiveCount; o++)
    {
        for (int t = 0; t < g_Objectives[o].iTargetCount; t++)
        {
            if (g_Objectives[o].targets[t].iEntity != caller)
                continue;

            g_Objectives[o].targets[t].bCompleted = true;
            ZpoMsg("Objective %d target %d complete (%s).", o + 1, t + 1, output);

            if (o == g_iCurrentObjective)
                CheckObjectiveComplete(o);

            return;
        }
    }

    // Diagnostic: fired but matched no known target - shows whether the
    // native event happened at all, and against what entity index.
    ZpoMsg("Output '%s' fired by entity %d - no matching target.", output, caller);
}

void CheckObjectiveComplete(int objIdx)
{
    for (int t = 0; t < g_Objectives[objIdx].iTargetCount; t++)
    {
        if (!g_Objectives[objIdx].targets[t].bCompleted)
            return;
    }

    ZpoMsg("Objective %d complete.", objIdx + 1);

    g_iCurrentObjective++;
    if (g_iCurrentObjective >= g_iObjectiveCount)
    {
        ZpoMsg("All objectives complete.");
        g_iCurrentObjective = -1;
    }

    // No force-release here - every plugin command task rejects new commands
    // while running, so a bot mid-command releases itself naturally once its
    // own command actually finishes (see UpdateTrackedBots).
}

public Action Timer_PollObjective(Handle timer)
{
    if (!g_bConfigLoaded || !g_cvEnabled.BoolValue || !g_bPollingAllowed || g_iCurrentObjective == -1)
        return Plugin_Continue;

    int iTrackedClients[MAXPLAYERS + 1];
    int iTrackedCount = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client) || !IsPlayerAlive(client))
        {
            g_iBotObjective[client] = -1;
            continue;
        }

        int team = GetClientTeam(client);
        bool bZombie;
        if (team == TEAM_SURVIVOR)
            bZombie = false;
        else if (team == TEAM_ZOMBIE)
            bZombie = true;
        else
            continue;

        if (g_iBotObjective[client] != -1 && g_bBotZombie[client] != bZombie)
            g_iBotObjective[client] = -1;

        // Only release a bot tracked for a stale objective once its own
        // command has actually finished - never mid-command.
        if (g_iBotObjective[client] != -1 && g_iBotObjective[client] != g_iCurrentObjective && g_bBotDone[client])
        {
            g_iBotObjective[client] = -1;
            g_bBotDone[client] = false;
        }

        if (g_iBotObjective[client] == -1)
            EnterTask(client, bZombie);

        if (g_iBotObjective[client] != -1 && !g_bBotDone[client])
            iTrackedClients[iTrackedCount++] = client;
    }

    UpdateTrackedBots(iTrackedClients, iTrackedCount);

    return Plugin_Continue;
}

void EnterTask(int client, bool bZombie)
{
    int objIdx = g_iCurrentObjective;

    bool bConfigured = bZombie ? g_Objectives[objIdx].zombieTask.bConfigured : g_Objectives[objIdx].survivorTask.bConfigured;
    if (!bConfigured)
        return;

    int targetIdx = NearestIncompleteTarget(objIdx, client);
    if (targetIdx == -1)
        return;

    g_iBotObjective[client] = objIdx;
    g_bBotZombie[client] = bZombie;
    g_iBotTargetIndex[client] = targetIdx;
    g_bBotDone[client] = false;

    IssueCommand(client, objIdx, bZombie, 0);
}

void IssueCommand(int client, int objIdx, bool bZombie, int cmdIndex)
{
    int cmdType  = bZombie ? g_Objectives[objIdx].zombieTask.commands[cmdIndex].cmdType  : g_Objectives[objIdx].survivorTask.commands[cmdIndex].cmdType;
    float fParam = bZombie ? g_Objectives[objIdx].zombieTask.commands[cmdIndex].fParam   : g_Objectives[objIdx].survivorTask.commands[cmdIndex].fParam;
    int targetIdx = g_iBotTargetIndex[client];

    NavBot bot = view_as<NavBot>(client);

    if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_MOVE_TO))
    {
        // Scripted rather than SendPluginCommand - plain MOVE_TO never
        // self-terminates, and every plugin command task rejects new
        // commands while running, so a bot on plain MOVE_TO could never
        // receive anything else. This self-cancels via ScriptedMoveTo.
        bot.SendScriptedPluginCommand(ScriptedMoveTo);
    }
    else if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_WAIT))
    {
        bot.SendPluginCommand(NAVBOT_PLUGINCMD_WAIT, fParam);
    }
    else if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_PATROL))
    {
        bot.SendPluginCommand(NAVBOT_PLUGINCMD_PATROL);
    }
    else if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_SEEK_AND_DESTROY))
    {
        bot.SendPluginCommand(NAVBOT_PLUGINCMD_SEEK_AND_DESTROY, g_Objectives[objIdx].targets[targetIdx].iEntity);
    }

    g_iBotCommandIndex[client] = cmdIndex;
    g_fBotCommandStart[client] = GetGameTime();

    char sCmdType[24];
    CommandTypeToString(cmdType, sCmdType, sizeof(sCmdType));

    ZpoMsg("%s: %N - Objective: %s - Command: %s",
        bZombie ? "Zombie" : "Survivor", client, g_Objectives[objIdx].sName, sCmdType);
}

public Action ScriptedMoveTo(NavBot bot, float moveGoal[3], NavBotRouteType routeType)
{
    int client = bot.Index;

    if (g_iBotObjective[client] == -1)
        return Plugin_Stop;

    int objIdx = g_iBotObjective[client];
    int targetIdx = g_iBotTargetIndex[client];

    if (g_Objectives[objIdx].targets[targetIdx].bCompleted)
        return Plugin_Stop;

    float fOrigin[3];
    GetClientAbsOrigin(client, fOrigin);

    if (GetVectorDistance(fOrigin, g_Objectives[objIdx].targets[targetIdx].fOrigin) <= 0.0)
        return Plugin_Stop;

    moveGoal[0] = g_Objectives[objIdx].targets[targetIdx].fOrigin[0];
    moveGoal[1] = g_Objectives[objIdx].targets[targetIdx].fOrigin[1];
    moveGoal[2] = g_Objectives[objIdx].targets[targetIdx].fOrigin[2];

    // Plugin_Continue is a trap here - NavBot's C++ side invalidates
    // navigation and skips the goal entirely for that specific value.
    // Plugin_Handled is what actually drives movement.
    return Plugin_Handled;
}

void UpdateTrackedBots(const int[] iClients, int iCount)
{
    for (int i = 0; i < iCount; i++)
    {
        int client = iClients[i];
        int objIdx = g_iBotObjective[client];
        bool bZombie = g_bBotZombie[client];
        int cmdIndex = g_iBotCommandIndex[client];
        int targetIdx = g_iBotTargetIndex[client];

        int cmdType = bZombie ? g_Objectives[objIdx].zombieTask.commands[cmdIndex].cmdType : g_Objectives[objIdx].survivorTask.commands[cmdIndex].cmdType;
        bool bIsMoveTo = (cmdType == view_as<int>(NAVBOT_PLUGINCMD_MOVE_TO));

        if (g_Objectives[objIdx].targets[targetIdx].bCompleted)
        {
            if (bIsMoveTo)
                ScheduleAdvance(client, objIdx, bZombie, cmdIndex);
            else
                AdvanceBot(client, objIdx, bZombie, cmdIndex);
            continue;
        }

        if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_WAIT))
        {
            float fParam = bZombie ? g_Objectives[objIdx].zombieTask.commands[cmdIndex].fParam : g_Objectives[objIdx].survivorTask.commands[cmdIndex].fParam;
            if ((GetGameTime() - g_fBotCommandStart[client]) < fParam)
                continue;

            AdvanceBot(client, objIdx, bZombie, cmdIndex);
        }
        else if (bIsMoveTo)
        {
            float fOrigin[3];
            GetClientAbsOrigin(client, fOrigin);
            if (GetVectorDistance(fOrigin, g_Objectives[objIdx].targets[targetIdx].fOrigin) > 0.0)
                continue;

            ScheduleAdvance(client, objIdx, bZombie, cmdIndex);
        }
    }
}

// Short delay before dispatching the next command after MOVE_TO - gives
// NavBot's own scripted-task resolution time to actually finish first.
// Dispatching too early would hit the same "reject while running" issue
// MOVE_TO itself was built to avoid.
void ScheduleAdvance(int client, int objIdx, bool bZombie, int cmdIndex)
{
    DataPack pack = new DataPack();
    pack.WriteCell(GetClientUserId(client));
    pack.WriteCell(objIdx);
    pack.WriteCell(bZombie);
    pack.WriteCell(cmdIndex);
    CreateTimer(0.5, Timer_DelayedAdvance, pack);
}

public Action Timer_DelayedAdvance(Handle timer, DataPack pack)
{
    pack.Reset();
    int userid = pack.ReadCell();
    int objIdx = pack.ReadCell();
    bool bZombie = pack.ReadCell();
    int cmdIndex = pack.ReadCell();

    int client = GetClientOfUserId(userid);
    if (client == 0 || !IsClientInGame(client) || !IsPlayerAlive(client))
        return Plugin_Stop;

    if (g_iBotObjective[client] != objIdx || g_iBotCommandIndex[client] != cmdIndex || g_bBotZombie[client] != bZombie)
        return Plugin_Stop;

    AdvanceBot(client, objIdx, bZombie, cmdIndex);
    return Plugin_Stop;
}

void AdvanceBot(int client, int objIdx, bool bZombie, int cmdIndex)
{
    int iCmdCount = bZombie ? g_Objectives[objIdx].zombieTask.iCommandCount : g_Objectives[objIdx].survivorTask.iCommandCount;
    int nextIndex = cmdIndex + 1;

    if (nextIndex >= iCmdCount)
    {
        g_bBotDone[client] = true;
        return;
    }

    IssueCommand(client, objIdx, bZombie, nextIndex);
}

int NearestIncompleteTarget(int objIdx, int client)
{
    float fClientOrigin[3];
    GetClientAbsOrigin(client, fClientOrigin);

    int best = -1;
    float bestDist = 999999.0;

    for (int t = 0; t < g_Objectives[objIdx].iTargetCount; t++)
    {
        if (g_Objectives[objIdx].targets[t].bCompleted)
            continue;

        float dist = GetVectorDistance(fClientOrigin, g_Objectives[objIdx].targets[t].fOrigin);
        if (dist < bestDist)
        {
            bestDist = dist;
            best = t;
        }
    }

    return best;
}
