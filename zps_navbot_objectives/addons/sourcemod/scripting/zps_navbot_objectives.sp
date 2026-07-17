/**
 * zps_navbot_objectives.sp
 * Directs NavBot bots through map-defined objectives via ordered per-team
 * command sequences (task chaining). No radius/tolerance on MOVE_TO arrival -
 * direct distance check, confirmed reliable via live testing.
 * Config: configs/zps_navbot_objectives/<map>.cfg
 * Author: Claude.ai guided by DNA.styx
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <sdktools_entoutput>
#include <navbot>

#define PLUGIN_VERSION "0.3.3"
#define CFG_SCHEMA_VERSION 3

#define TEAM_SURVIVOR 2
#define TEAM_ZOMBIE   3

#define MAX_OBJECTIVES            8
#define MAX_TARGETS_PER_OBJECTIVE 6
#define MAX_COMMANDS_PER_TASK     4

#define ORIGIN_TOLERANCE 16.0 // entity resolution only - matching name+type+origin to the live entity

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
    int   cmdType; // NavBotPluginCommandTypes int, or -1 if invalid
    float fParam;  // WAIT duration only, unused for other types
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
int           g_iCurrentObjective = -1; // -1 = not started / all complete

ConVar g_cvEnabled;
ConVar g_cvPollInterval;
ConVar g_cvRoundStartDelay;

bool   g_bConfigLoaded = false;
bool   g_bPollingAllowed = false;
bool   g_bGateLogged = false;
Handle g_hRoundStartTimer = null;

// Per-bot state
int   g_iBotObjective[MAXPLAYERS + 1];     // -1 = untracked
bool  g_bBotZombie[MAXPLAYERS + 1];
int   g_iBotCommandIndex[MAXPLAYERS + 1];  // position within the team's command sequence
int   g_iBotTargetIndex[MAXPLAYERS + 1];   // sticky target, resolved once at task entry
float g_fBotCommandStart[MAXPLAYERS + 1];  // for WAIT timing
bool  g_bBotDone[MAXPLAYERS + 1];          // finished the whole sequence, stays parked

ArrayList g_hValidationReport = null;      // queued validation lines, flushed at round start

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

// Chat only, always on, [ZPO] prefix - used for every message this plugin sends.
void ZpoMsg(const char[] format, any ...)
{
    char sMsg[256];
    VFormat(sMsg, sizeof(sMsg), format, 2);
    PrintToChatAll("[ZPO] %s", sMsg);
}

// Queues a validation report line instead of printing immediately - map-load-time
// messages are otherwise likely to be missed if no player is connected yet.
// Flushed once polling is allowed (round start).
void QueueValidationMsg(const char[] format, any ...)
{
    char sMsg[256];
    VFormat(sMsg, sizeof(sMsg), format, 2);
    g_hValidationReport.PushString(sMsg);
}

void FlushValidationReport()
{
    if (g_hValidationReport == null)
        return;

    char sMsg[256];
    for (int i = 0; i < g_hValidationReport.Length; i++)
    {
        g_hValidationReport.GetString(i, sMsg, sizeof(sMsg));
        ZpoMsg("%s", sMsg);
    }

    delete g_hValidationReport;
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

    // Round restarts on the same map don't go through OnMapStart, so objective
    // progress must be reset here too.
    if (g_bConfigLoaded)
        ResetObjectiveProgress();

    g_bPollingAllowed = false;
    g_hRoundStartTimer = CreateTimer(g_cvRoundStartDelay.FloatValue, Timer_RoundStartDelay, _, TIMER_FLAG_NO_MAPCHANGE);

    ZpoMsg("Round_Starting detected, delay=%.1f", g_cvRoundStartDelay.FloatValue);
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
    g_bGateLogged = false;

    ZpoMsg("Polling enabled.");
    FlushValidationReport();

    return Plugin_Stop;
}

public void OnMapStart()
{
    g_bConfigLoaded = false;
    g_bPollingAllowed = false;
    g_bGateLogged = false;
    g_hRoundStartTimer = null;
    g_iObjectiveCount = 0;
    g_iCurrentObjective = -1;

    for (int client = 0; client <= MAXPLAYERS; client++)
    {
        g_iBotObjective[client] = -1;
        g_bBotDone[client] = false;
    }

    if (g_hValidationReport != null)
        delete g_hValidationReport;
    g_hValidationReport = new ArrayList(ByteCountToCells(256));

    if (!LoadAndValidateConfig())
        return;

    g_bConfigLoaded = true;
    g_iCurrentObjective = 0;
    HookAllTargetOutputs();

    CreateTimer(g_cvPollInterval.FloatValue, Timer_PollObjective, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

// ---------------------------------------------------------------------------
// Config loading and validation
// ---------------------------------------------------------------------------

bool LoadAndValidateConfig()
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
        QueueValidationMsg("Failed to parse %s.cfg - check syntax.", sMap);
        delete kv;
        return false;
    }

    int iCfgVersion = kv.GetNum("version", -1);
    if (iCfgVersion != CFG_SCHEMA_VERSION)
    {
        QueueValidationMsg("%s.cfg schema version %d does not match expected %d - refusing to load.",
            sMap, iCfgVersion, CFG_SCHEMA_VERSION);
        delete kv;
        return false;
    }

    int iProblems = 0;

    if (!kv.GotoFirstSubKey(true))
    {
        QueueValidationMsg("%s.cfg has no objectives.", sMap);
        delete kv;
        return false;
    }

    do
    {
        char sSectionName[32];
        kv.GetSectionName(sSectionName, sizeof(sSectionName));
        if (!StrEqual(sSectionName, "objective") || g_iObjectiveCount >= MAX_OBJECTIVES)
            continue;

        ParseObjective(kv, g_iObjectiveCount, iProblems);
        g_iObjectiveCount++;

    } while (kv.GotoNextKey(true));

    delete kv;

    // Resolve and validate every target across every objective.
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
                QueueValidationMsg("Objective %d target %d ('%s' near %.1f,%.1f,%.1f) not found.",
                    o + 1, t + 1, g_Objectives[o].targets[t].sName,
                    g_Objectives[o].targets[t].fOrigin[0], g_Objectives[o].targets[t].fOrigin[1], g_Objectives[o].targets[t].fOrigin[2]);
                iProblems++;
                continue;
            }

            g_Objectives[o].targets[t].iEntity = entity;
        }

        if (!g_Objectives[o].survivorTask.bConfigured && !g_Objectives[o].zombieTask.bConfigured)
        {
            QueueValidationMsg("Objective %d has no survivor or zombie task configured.", o + 1);
            iProblems++;
        }
    }

    if (iProblems > 0)
    {
        QueueValidationMsg("%s.cfg load FAILED: %d problem(s) found. Bots will use default AI until fixed.", sMap, iProblems);
        return false;
    }

    QueueValidationMsg("%s.cfg loaded OK (schema v%d): %d objective(s).", sMap, CFG_SCHEMA_VERSION, g_iObjectiveCount);
    return true;
}

void ParseObjective(KeyValues kv, int objIdx, int &iProblems)
{
    kv.GetString("name", g_Objectives[objIdx].sName, 64, "");
    if (g_Objectives[objIdx].sName[0] == '\0')
        Format(g_Objectives[objIdx].sName, 64, "Objective %d", objIdx + 1);

    // Reset before re-parsing - without this, a second map load (without a full
    // plugin reload) appends after stale data from the previous load instead of
    // overwriting from index 0.
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

            if (g_Objectives[objIdx].targets[t].sName[0] == '\0' || g_Objectives[objIdx].targets[t].sType[0] == '\0'
                || g_Objectives[objIdx].targets[t].sCompletedOutput[0] == '\0')
            {
                QueueValidationMsg("Objective %d target %d missing name/type/completed field.", objIdx + 1, t + 1);
                iProblems++;
            }

            g_Objectives[objIdx].iTargetCount++;
        }
        else if (StrEqual(sSectionName, "survivor_tasks"))
        {
            ParseTeamTask(kv, objIdx, false, iProblems);
        }
        else if (StrEqual(sSectionName, "zombie_tasks"))
        {
            ParseTeamTask(kv, objIdx, true, iProblems);
        }

    } while (kv.GotoNextKey(true));
    kv.GoBack();
}

// Reads the first "task" under this team's task container, then every direct
// "command" child under it, in order - the full sequence for that team.
void ParseTeamTask(KeyValues kv, int objIdx, bool bZombie, int &iProblems)
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

            if (cmdType == -1)
            {
                QueueValidationMsg("Objective %d: unrecognized/unsupported command type '%s'.", objIdx + 1, sType);
                iProblems++;
            }

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
        kv.GoBack(); // leave "command" level, back to "task" level

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

        if (iCmdCount == 0)
        {
            QueueValidationMsg("Objective %d: task has no command.", objIdx + 1);
            iProblems++;
        }
    }

    kv.GoBack(); // leave "task" level, back to survivor_tasks/zombie_tasks level
}

// Enters the first direct child section named `name`, cursor left one level
// deeper on success (caller must GoBack). On failure the cursor is already
// restored to the caller's original position - no GoBack needed.
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
    if (StrEqual(sType, "MOVE_TO", false))             return view_as<int>(NAVBOT_PLUGINCMD_MOVE_TO);
    if (StrEqual(sType, "WAIT", false))                 return view_as<int>(NAVBOT_PLUGINCMD_WAIT);
    if (StrEqual(sType, "PATROL", false))               return view_as<int>(NAVBOT_PLUGINCMD_PATROL);
    if (StrEqual(sType, "SEEK_AND_DESTROY", false))     return view_as<int>(NAVBOT_PLUGINCMD_SEEK_AND_DESTROY);
    return -1;
}

void CommandTypeToString(int cmdType, char[] sOut, int size)
{
    if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_MOVE_TO))              strcopy(sOut, size, "MOVE_TO");
    else if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_WAIT))            strcopy(sOut, size, "WAIT");
    else if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_PATROL))          strcopy(sOut, size, "PATROL");
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

// Re-resolves a target's entity index if it's gone stale since map load - some
// map scripts kill/respawn entities mid-round (confirmed: this map's AngelScript
// touches PCP-Breakable when Destroy PCP activates), which would otherwise leave
// us holding a dead index and throwing "NULL entity" on the next native call.
// HookEntityOutput is classname-wide, not entity-index-specific, so a
// newly-resolved entity is automatically covered by the existing hook already -
// no re-hook needed here.
void EnsureTargetEntityValid(int objIdx, int targetIdx)
{
    int entity = g_Objectives[objIdx].targets[targetIdx].iEntity;
    if (entity != -1 && IsValidEntity(entity))
        return;

    int resolved = ResolveTargetEntity(
        g_Objectives[objIdx].targets[targetIdx].sName,
        g_Objectives[objIdx].targets[targetIdx].sType,
        g_Objectives[objIdx].targets[targetIdx].fOrigin,
        ORIGIN_TOLERANCE);

    if (resolved != -1)
    {
        g_Objectives[objIdx].targets[targetIdx].iEntity = resolved;
        ZpoMsg("Objective %d target %d re-resolved (entity was stale, now %d).", objIdx + 1, targetIdx + 1, resolved);
    }
    else
    {
        ZpoMsg("Objective %d target %d entity is stale and could not be re-resolved.", objIdx + 1, targetIdx + 1);
    }
}

// ---------------------------------------------------------------------------
// Output hooks for target completion
// ---------------------------------------------------------------------------

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
}

void CheckObjectiveComplete(int objIdx)
{
    for (int t = 0; t < g_Objectives[objIdx].iTargetCount; t++)
    {
        if (!g_Objectives[objIdx].targets[t].bCompleted)
            return;
    }

    ZpoMsg("Objective %d complete.", objIdx + 1);

    // Release everyone so the next poll dispatches fresh against the new objective.
    for (int client = 0; client <= MAXPLAYERS; client++)
    {
        g_iBotObjective[client] = -1;
        g_bBotDone[client] = false;
    }

    g_iCurrentObjective++;
    if (g_iCurrentObjective >= g_iObjectiveCount)
    {
        ZpoMsg("All objectives complete.");
        g_iCurrentObjective = -1;
    }
}

// ---------------------------------------------------------------------------
// Poll loop
// ---------------------------------------------------------------------------

public Action Timer_PollObjective(Handle timer)
{
    if (!g_bConfigLoaded || !g_cvEnabled.BoolValue || !g_bPollingAllowed || g_iCurrentObjective == -1)
    {
        if (!g_bGateLogged)
        {
            ZpoMsg("Poll gate blocked: configLoaded=%d enabled=%d pollingAllowed=%d currentObjective=%d",
                g_bConfigLoaded, g_cvEnabled.BoolValue, g_bPollingAllowed, g_iCurrentObjective);
            g_bGateLogged = true;
        }
        return Plugin_Continue;
    }

    int iTrackedClients[MAXPLAYERS + 1];
    int iTrackedCount = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client) || !IsPlayerAlive(client))
        {
            // Covers death/disconnect, and doubles as "reissue on respawn" - a bot
            // that comes back (new zombie, converted survivor) is untracked again
            // and gets dispatched fresh the next tick it's seen alive.
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

        // Team changed since last tracked (e.g. survivor died and infected) -
        // release so it's picked up fresh for its new team's task.
        if (g_iBotObjective[client] != -1 && g_bBotZombie[client] != bZombie)
            g_iBotObjective[client] = -1;

        if (g_iBotObjective[client] == -1)
            EnterTask(client, bZombie);

        if (g_iBotObjective[client] != -1 && !g_bBotDone[client])
            iTrackedClients[iTrackedCount++] = client;
    }

    UpdateTrackedBots(iTrackedClients, iTrackedCount);

    return Plugin_Continue;
}

// Dispatches a bot into command index 0 of its team's sequence for the
// current objective, resolving its sticky target for the first time.
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

// Issues the command at cmdIndex in the bot's team sequence and records it as
// the bot's current step.
void IssueCommand(int client, int objIdx, bool bZombie, int cmdIndex)
{
    int cmdType  = bZombie ? g_Objectives[objIdx].zombieTask.commands[cmdIndex].cmdType  : g_Objectives[objIdx].survivorTask.commands[cmdIndex].cmdType;
    float fParam = bZombie ? g_Objectives[objIdx].zombieTask.commands[cmdIndex].fParam   : g_Objectives[objIdx].survivorTask.commands[cmdIndex].fParam;
    int targetIdx = g_iBotTargetIndex[client];

    NavBot bot = view_as<NavBot>(client);

    if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_MOVE_TO))
    {
        // Origin taken directly from the .cfg, not re-queried from the live
        // entity - decouples movement from entity resolution.
        bot.SendPluginCommand(NAVBOT_PLUGINCMD_MOVE_TO, g_Objectives[objIdx].targets[targetIdx].fOrigin);
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
        // Previous entity-reference theory retracted - disproven by BreakObstacle
        // using the identical pawnutils::ReadEntity() function with a raw index,
        // confirmed working live. Simplified to the bare minimum: no intervening
        // native calls between reading the value and dispatching it, matching the
        // ROAM corruption pattern found earlier tonight (a native call sitting
        // between value and dispatch corrupted the argument there too).
        int iEntity = g_Objectives[objIdx].targets[targetIdx].iEntity;
        bot.SendPluginCommand(NAVBOT_PLUGINCMD_SEEK_AND_DESTROY, iEntity);
    }

    g_iBotCommandIndex[client] = cmdIndex;
    g_fBotCommandStart[client] = GetGameTime();

    char sCmdType[24];
    CommandTypeToString(cmdType, sCmdType, sizeof(sCmdType));

    ZpoMsg("%s: %N - Objective: %s - Command: %s",
        bZombie ? "Zombie" : "Survivor", client, g_Objectives[objIdx].sName, sCmdType);
}

// Universal exit: if the bot's assigned target is complete, its current
// command is done regardless of type - this is what lets SEEK_AND_DESTROY and
// PATROL advance at all, since we have no other way to detect their
// completion, and it's the same OnBreak/OnTrigger signal either way, just
// arriving through Callback_TargetCompleted instead of a command-specific
// check. Command-specific checks (arrival, duration) still exist alongside
// this - they're what makes MOVE_TO progress to SEEK_AND_DESTROY in the first
// place, since nothing attacks the target until that command begins.
void UpdateTrackedBots(const int[] iClients, int iCount)
{
    for (int i = 0; i < iCount; i++)
    {
        int client = iClients[i];
        int objIdx = g_iBotObjective[client];
        bool bZombie = g_bBotZombie[client];
        int cmdIndex = g_iBotCommandIndex[client];
        int targetIdx = g_iBotTargetIndex[client];

        if (g_Objectives[objIdx].targets[targetIdx].bCompleted)
        {
            AdvanceBot(client, objIdx, bZombie, cmdIndex);
            continue;
        }

        int cmdType = bZombie ? g_Objectives[objIdx].zombieTask.commands[cmdIndex].cmdType : g_Objectives[objIdx].survivorTask.commands[cmdIndex].cmdType;

        if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_MOVE_TO))
        {
            float fOrigin[3];
            GetClientAbsOrigin(client, fOrigin);

            // No tolerance - direct distance check, confirmed reliable via live
            // testing (NavBot appears to snap the bot onto the goal on arrival).
            if (GetVectorDistance(fOrigin, g_Objectives[objIdx].targets[targetIdx].fOrigin) > 0.0)
                continue;

            AdvanceBot(client, objIdx, bZombie, cmdIndex);
        }
        else if (cmdType == view_as<int>(NAVBOT_PLUGINCMD_WAIT))
        {
            float fParam = bZombie ? g_Objectives[objIdx].zombieTask.commands[cmdIndex].fParam : g_Objectives[objIdx].survivorTask.commands[cmdIndex].fParam;
            if ((GetGameTime() - g_fBotCommandStart[client]) < fParam)
                continue;

            AdvanceBot(client, objIdx, bZombie, cmdIndex);
        }
        // PATROL / SEEK_AND_DESTROY: no command-specific completion signal -
        // only advance via the target-complete check above.
    }
}

void AdvanceBot(int client, int objIdx, bool bZombie, int cmdIndex)
{
    int iCmdCount = bZombie ? g_Objectives[objIdx].zombieTask.iCommandCount : g_Objectives[objIdx].survivorTask.iCommandCount;
    int nextIndex = cmdIndex + 1;

    if (nextIndex >= iCmdCount)
    {
        g_bBotDone[client] = true; // sequence complete for this bot - stay parked
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
