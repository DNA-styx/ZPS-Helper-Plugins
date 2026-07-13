#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <dhooks>
#include <navbot>

#define PLUGIN_VERSION "0.1.12"

ConVar g_hCvarPollInterval;
ConVar g_hCvarVerbose;

#define ZPS_OBJHELPER_CONFIG_FOLDER "zps_objective_helper"

enum struct DoorInfo
{
	char name[64];
	int entRef;
	int areaId;
	int areaCount;
	bool entityResolved;
	bool spawnClosed;
	Handle blockerHandle;  // NavBotNavBlocker, stored generically to keep this struct simple
	bool blockerActive;    // true once we're actively trying to maintain a blocker for this door
	bool blocked;          // last known intended blocked state
	bool inputHooked;      // true once AcceptInput is hooked on this door's entity
	char unblockInput[32]; // input name that means "this door just became passable"
	char blockInput[32];   // input name that means "this door just became impassable again", or "none"
	bool doneMonitoring;   // true once this door will never need checking again (e.g. self-destructs after opening)
}

ArrayList g_hDoors = null;
Handle g_hPollTimer = null;
DynamicHook g_hAcceptInputHook = null;
bool g_bBlockersStarted = false;

public Plugin myinfo =
{
	name = "ZPS Objective Helper",
	author = "Claude.ai guided by DNA.styx",
	description = "Mark navmesh that locked doors touch as blocked for navbot",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	CreateConVar("zps_navbot_doorblocker_version", PLUGIN_VERSION, "ZPS Objective Helper plugin version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_hCvarPollInterval = CreateConVar("zps_navbot_doorblocker_poll_interval", "0.1", "How often (in seconds) to check each managed door's area real blocked state and react if it has gone false.", _, true, 0.05, true, 2.0);
	g_hCvarVerbose = CreateConVar("zps_navbot_doorblocker_verbose", "0", "If 1, logs every blocker (re)creation and every detected Lock/Unlock event. If 0, only logs errors.", _, true, 0.0, true, 1.0);

	AutoExecConfig(true, "zps_navbot_doorblocker");

	RegAdminCmd("sm_zps_doorblocker_status", Cmd_Status, ADMFLAG_ROOT, "Prints status of all managed doors.");
	RegAdminCmd("sm_zps_doorblocker_listdoors", Cmd_ListDoors, ADMFLAG_ROOT, "Lists the doors loaded from this map's zps-objective-helper config.");

	g_hDoors = new ArrayList(sizeof(DoorInfo));

	SetupAcceptInputHook();
}

// Builds the AcceptInput hook definition from SDKTools' own bundled gamedata (sdktools.games),
// which NavBot's own C++ side already reads this exact offset from (confirmed in its source).
// Built manually from the raw offset + CBaseEntity::AcceptInput's standard signature, rather
// than DynamicHook.FromConf(), since the gamedata entry NavBot reads is a plain offset lookup,
// not necessarily a full DHooks "Functions" block.
void SetupAcceptInputHook()
{
	GameData gc = new GameData("sdktools.games");

	if (gc == null)
	{
		LogError("[ZPS Objective Helper] Could not load sdktools.games gamedata. Lock/Unlock detection will not work.");
		return;
	}

	int offset = gc.GetOffset("AcceptInput");
	delete gc;

	if (offset == -1)
	{
		LogError("[ZPS Objective Helper] Could not find \"AcceptInput\" offset in sdktools.games gamedata. Lock/Unlock detection will not work.");
		return;
	}

	g_hAcceptInputHook = new DynamicHook(offset, HookType_Entity, ReturnType_Bool, ThisPointer_CBaseEntity);
	g_hAcceptInputHook.AddParam(HookParamType_CharPtr);     // szInputName
	g_hAcceptInputHook.AddParam(HookParamType_CBaseEntity); // pActivator
	g_hAcceptInputHook.AddParam(HookParamType_CBaseEntity); // pCaller
	g_hAcceptInputHook.AddParam(HookParamType_Object, 20, DHookPass_ByVal | DHookPass_ODTOR | DHookPass_OCTOR | DHookPass_OASSIGNOP);
}

// Hooks a specific door's AcceptInput, if not already hooked. Safe to call repeatedly.
void HookDoorInput(DoorInfo info, int entity)
{
	if (info.inputHooked || g_hAcceptInputHook == null)
	{
		return;
	}

	if (g_hAcceptInputHook.HookEntity(Hook_Pre, entity, Callback_DoorAcceptInput) != INVALID_HOOK_ID)
	{
		info.inputHooked = true;
	}
	else
	{
		ReportIssue("Failed to hook AcceptInput on door \"%s\" (entity %d). Lock/Unlock detection will not work for this door.", info.name, entity);
	}
}

public MRESReturn Callback_DoorAcceptInput(int entity, DHookReturn hReturn, DHookParam hParams)
{
	int idx = FindDoorIndexByEntity(entity);

	if (idx == -1)
	{
		return MRES_Ignored;
	}

	char inputName[64];
	hParams.GetString(1, inputName, sizeof(inputName));

	DoorInfo info;
	g_hDoors.GetArray(idx, info);

	if (info.doneMonitoring)
	{
		return MRES_Ignored;
	}

	if (StrEqual(inputName, info.blockInput, false) && !StrEqual(info.blockInput, "none", false))
	{
		if (g_hCvarVerbose.BoolValue)
		{
			PrintToServer("[ZPS Objective Helper] Detected \"%s\" on door \"%s\" -- (re)blocking.", inputName, info.name);
		}

		BlockDoor(info);
		g_hDoors.SetArray(idx, info);
	}
	else if (StrEqual(inputName, info.unblockInput, false))
	{
		if (g_hCvarVerbose.BoolValue)
		{
			PrintToServer("[ZPS Objective Helper] Detected \"%s\" on door \"%s\" -- removing block.", inputName, info.name);
		}

		UnblockDoor(info);

		if (StrEqual(info.blockInput, "none", false))
		{
			info.doneMonitoring = true;
			ReportIssue("Door \"%s\" unblocked (no re-lock configured) -- no longer monitored.", info.name);
		}

		g_hDoors.SetArray(idx, info);
	}

	return MRES_Ignored;
}

int FindDoorIndexByEntity(int entity)
{
	if (g_hDoors == null)
	{
		return -1;
	}

	int count = g_hDoors.Length;

	for (int i = 0; i < count; i++)
	{
		DoorInfo info;
		g_hDoors.GetArray(i, info);

		if (EntRefToEntIndex(info.entRef) == entity)
		{
			return i;
		}
	}

	return -1;
}

public void OnMapStart()
{
	LoadDoorConfig();

	if (NavBotNavMesh.IsLoaded())
	{
		TryResolveAllDoors();
		StartAllDoorBlockers();
	}
}

public void OnNavBotNavMeshLoaded()
{
	TryResolveAllDoors();
	StartAllDoorBlockers();
}

public void OnNavBotNavMeshDestroyed()
{
	delete g_hPollTimer;
	g_bBlockersStarted = false;

	if (g_hDoors == null)
	{
		return;
	}

	int count = g_hDoors.Length;

	for (int i = 0; i < count; i++)
	{
		DoorInfo info;
		g_hDoors.GetArray(i, info);
		info.entRef = INVALID_ENT_REFERENCE;
		info.areaId = -1;
		info.areaCount = 0;
		info.blockerHandle = null;
		info.blockerActive = false;
		info.blocked = false;
		info.inputHooked = false; // entity hooks are auto-removed by DHooks when the entity is destroyed
		g_hDoors.SetArray(i, info);
	}
}

// Reports a problem loudly (console + chat) rather than only to the SM error log -- and
// also logs it to a dedicated per-map log file, separate from SM's own logs.
void ReportIssue(const char[] fmt, any ...)
{
	char msg[256];
	VFormat(msg, sizeof(msg), fmt, 2);

	char fullMsg[288];
	Format(fullMsg, sizeof(fullMsg), "[ZPS Objective Helper] %s", msg);

	PrintToServer("%s", fullMsg);
	PrintToChatAll("%s", fullMsg);

	char logPath[PLATFORM_MAX_PATH];
	char mapName[64];
	GetCurrentMap(mapName, sizeof(mapName));
	BuildPath(Path_SM, logPath, sizeof(logPath), "logs/zps_objective_helper_%s.log", mapName);
	LogToFileEx(logPath, "%s", fullMsg);
}

void LoadDoorConfig()
{
	g_hDoors.Clear();
	g_bBlockersStarted = false;

	char mapName[64];
	GetCurrentMap(mapName, sizeof(mapName));

	if (strncmp(mapName, "zpo_", 4) != 0)
	{
		ReportIssue("Map \"%s\" does not start with \"zpo_\" -- this plugin only supports ZPS objective maps.", mapName);
		SetFailState("Map \"%s\" does not start with \"zpo_\".", mapName);
		return;
	}

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "configs/%s/%s.cfg", ZPS_OBJHELPER_CONFIG_FOLDER, mapName);

	if (!FileExists(path))
	{
		ReportIssue("No door config found for map \"%s\" at \"%s\".", mapName, path);
		SetFailState("No door config found at \"%s\".", path);
		return;
	}

	KeyValues kv = new KeyValues("ZPSObjectiveHelper");

	if (!kv.ImportFromFile(path))
	{
		ReportIssue("Failed to parse door config \"%s\" (malformed KeyValues?).", path);
		delete kv;
		return;
	}

	if (!kv.JumpToKey("doors"))
	{
		ReportIssue("Door config \"%s\" has no \"doors\" section.", path);
		delete kv;
		return;
	}

	if (kv.GotoFirstSubKey(false))
	{
		do
		{
			char doorName[64];
			kv.GetSectionName(doorName, sizeof(doorName));

			if (doorName[0] != '\0')
			{
				DoorInfo info;
				strcopy(info.name, sizeof(info.name), doorName);
				info.entRef = INVALID_ENT_REFERENCE;
				info.areaId = -1;
				info.areaCount = 0;
				info.entityResolved = false;
				info.blockerHandle = null;
				info.blockerActive = false;
				info.blocked = false;
				info.inputHooked = false;

				char spawnPos[16];
				kv.GetString("SpawnPosition", spawnPos, sizeof(spawnPos), "closed");
				info.spawnClosed = StrEqual(spawnPos, "closed", false);

				kv.GetString("UnblockInput", info.unblockInput, sizeof(info.unblockInput), "Unlock");
				kv.GetString("BlockInput", info.blockInput, sizeof(info.blockInput), "Lock");
				info.doneMonitoring = false;

				g_hDoors.PushArray(info);
			}
		} while (kv.GotoNextKey(false));

		kv.GoBack();
	}

	delete kv;

	if (g_hDoors.Length == 0)
	{
		ReportIssue("Door config \"%s\" loaded but contains no door entries.", path);
	}
	else
	{
		PrintToServer("[ZPS Objective Helper] Loaded %d door(s) from \"%s\".", g_hDoors.Length, path);
	}
}

// Resolves each configured door's entity and the nav area(s) touching it, and hooks its
// AcceptInput for Lock/Unlock detection. Safe to call repeatedly.
void TryResolveAllDoors()
{
	if (g_hDoors == null || g_hDoors.Length == 0)
	{
		return;
	}

	if (!NavBotNavMesh.IsLoaded())
	{
		return;
	}

	int count = g_hDoors.Length;

	for (int i = 0; i < count; i++)
	{
		DoorInfo info;
		g_hDoors.GetArray(i, info);

		if (info.doneMonitoring)
		{
			continue;
		}

		ResolveDoorAreas(info);
		g_hDoors.SetArray(i, info);
	}
}

void ResolveDoorAreas(DoorInfo info)
{
	int door = ResolveDoorEntity(info);

	if (door == -1)
	{
		ReportIssue("Door \"%s\" (from config) could not be found in the map.", info.name);
		return;
	}

	HookDoorInput(info, door);

	NavBotNavAreaVector areas = NavBotNavMesh.CollectAreasTouchingEntity(door);
	info.areaCount = areas.Size;

	if (areas.Size > 0)
	{
		info.areaId = NavBotNavArea.GetID(areas.At(0));
	}
	else
	{
		info.areaId = -1;
	}

	delete areas;

	if (!info.spawnClosed)
	{
		// Pose isn't guaranteed for this door at this point (spawns open), so an
		// area-touching result here isn't meaningful yet -- not reported as an issue.
		// This door's real check happens via the AcceptInput Lock hook instead.
		return;
	}

	if (info.areaCount == 0)
	{
		ReportIssue("Door \"%s\" found, but touches 0 nav areas. Check nav mesh placement around this door.", info.name);
	}
	else if (info.areaCount > 1)
	{
		ReportIssue("Door \"%s\" touches %d nav areas (expected 1). Using area ID %d; check nav mesh placement around this door.", info.name, info.areaCount, info.areaId);
	}
}

// Resolves (and caches) the door's entity index. Updates info.entRef/entityResolved.
int ResolveDoorEntity(DoorInfo info)
{
	int door = EntRefToEntIndex(info.entRef);

	if (door == -1 || door == INVALID_ENT_REFERENCE)
	{
		door = FindEntityByTargetname(info.name);

		if (door == -1)
		{
			info.entityResolved = false;
			info.entRef = INVALID_ENT_REFERENCE;
			return -1;
		}

		info.entRef = EntIndexToEntRef(door);
	}

	info.entityResolved = true;
	return door;
}

int FindEntityByTargetname(const char[] targetname)
{
	int entity = -1;

	while ((entity = FindEntityByClassname(entity, "*")) != -1)
	{
		char name[64];
		GetEntPropString(entity, Prop_Data, "m_iName", name, sizeof(name));

		if (name[0] != '\0' && StrEqual(name, targetname, false))
		{
			return entity;
		}
	}

	return -1;
}

void StartAllDoorBlockers()
{
	if (g_hDoors == null || g_bBlockersStarted)
	{
		return;
	}

	g_bBlockersStarted = true;

	int count = g_hDoors.Length;

	for (int i = 0; i < count; i++)
	{
		DoorInfo info;
		g_hDoors.GetArray(i, info);

		if (info.spawnClosed && !info.doneMonitoring)
		{
			BlockDoor(info);
			g_hDoors.SetArray(i, info);
		}
	}

	delete g_hPollTimer;
	g_hPollTimer = CreateTimer(g_hCvarPollInterval.FloatValue, Timer_PollAndReact, _, TIMER_REPEAT);
}

void BlockDoor(DoorInfo info)
{
	if (info.blockerHandle != null && IsValidHandle(info.blockerHandle))
	{
		delete info.blockerHandle;
	}
	info.blockerHandle = null;

	int door = ResolveDoorEntity(info);

	if (door == -1)
	{
		ReportIssue("Could not (re)create blocker for door \"%s\": entity not found.", info.name);
		info.blockerActive = false;
		return;
	}

	HookDoorInput(info, door);

	info.blockerHandle = new NavBotNavBlocker(InitDoorBlockerCB, UpdateDoorBlockerCB, info.name);
	info.blockerActive = true;
}

// Removes an active blocker for one door (called when its Unlock input is detected).
void UnblockDoor(DoorInfo info)
{
	if (info.blockerHandle != null && IsValidHandle(info.blockerHandle))
	{
		delete info.blockerHandle;
	}
	info.blockerHandle = null;
	info.blockerActive = false;
	info.blocked = false;
}

int FindDoorIndexByBlockerHandle(Handle h)
{
	if (g_hDoors == null)
	{
		return -1;
	}

	int count = g_hDoors.Length;

	for (int i = 0; i < count; i++)
	{
		DoorInfo info;
		g_hDoors.GetArray(i, info);

		if (info.blockerHandle == h)
		{
			return i;
		}
	}

	return -1;
}

public bool InitDoorBlockerCB(NavBotNavBlocker blocker)
{
	int idx = FindDoorIndexByBlockerHandle(view_as<Handle>(blocker));

	if (idx == -1)
	{
		LogError("[ZPS Objective Helper] InitDoorBlockerCB: could not match blocker Handle to a configured door.");
		return false;
	}

	DoorInfo info;
	g_hDoors.GetArray(idx, info);

	int door = EntRefToEntIndex(info.entRef);

	if (door == -1 || door == INVALID_ENT_REFERENCE)
	{
		LogError("[ZPS Objective Helper] InitDoorBlockerCB: door entity reference invalid for \"%s\".", info.name);
		g_hDoors.SetArray(idx, info);
		return false;
	}

	NavBotNavAreaVector areas = NavBotNavMesh.CollectAreasTouchingEntity(door);
	info.areaCount = areas.Size;

	if (areas.Size > 0)
	{
		info.areaId = NavBotNavArea.GetID(areas.At(0));
	}

	blocker.AddAreas(areas);
	delete areas;

	blocker.UpdateBlockedStatus(NAVBOT_NAV_TEAM_ANY, true);
	info.blocked = true;

	g_hDoors.SetArray(idx, info);

	if (g_hCvarVerbose.BoolValue)
	{
		PrintToServer("[ZPS Objective Helper] Blocker (re)created for door \"%s\": %d area(s), area ID=%d, blocked=true.", info.name, info.areaCount, info.areaId);
	}

	return true;
}

public bool UpdateDoorBlockerCB(NavBotNavBlocker blocker)
{
	return true;
}

public Action Timer_PollAndReact(Handle timer)
{
	if (g_hDoors == null)
	{
		return Plugin_Continue;
	}

	int count = g_hDoors.Length;

	for (int i = 0; i < count; i++)
	{
		DoorInfo info;
		g_hDoors.GetArray(i, info);

		if (info.doneMonitoring || !info.blockerActive || info.areaId == -1)
		{
			continue;
		}

		Address area = NavBotNavMesh.GetNavAreaByID(info.areaId);

		if (area == Address_Null)
		{
			// Area no longer resolves -- force a fresh lookup for this door.
			BlockDoor(info);
			g_hDoors.SetArray(i, info);
			continue;
		}

		if (!NavBotNavArea.IsBlocked(area, NAVBOT_NAV_TEAM_ANY))
		{
			BlockDoor(info);
			g_hDoors.SetArray(i, info);
		}
	}

	return Plugin_Continue;
}

public Action Cmd_Status(int client, int args)
{
	if (g_hDoors == null || g_hDoors.Length == 0)
	{
		ReplyToCommand(client, "[ZPS Objective Helper] No doors loaded.");
		return Plugin_Handled;
	}

	int count = g_hDoors.Length;
	ReplyToCommand(client, "[ZPS Objective Helper] %d door(s):", count);

	for (int i = 0; i < count; i++)
	{
		DoorInfo info;
		g_hDoors.GetArray(i, info);

		ReplyToCommand(client, "  [%d] %s -- managed: %s, blocked: %s, area ID: %d, hooked: %s, unblock on: %s, block on: %s, done: %s", i, info.name, info.blockerActive ? "yes" : "no", info.blocked ? "yes" : "no", info.areaId, info.inputHooked ? "yes" : "no", info.unblockInput, info.blockInput, info.doneMonitoring ? "yes" : "no");
	}

	return Plugin_Handled;
}

public Action Cmd_ListDoors(int client, int args)
{
	if (g_hDoors == null)
	{
		ReplyToCommand(client, "[ZPS Objective Helper] Door list not initialized.");
		return Plugin_Handled;
	}

	int count = g_hDoors.Length;

	ReplyToCommand(client, "[ZPS Objective Helper] %d door(s) loaded from config:", count);

	for (int i = 0; i < count; i++)
	{
		DoorInfo info;
		g_hDoors.GetArray(i, info);

		ReplyToCommand(client, "  [%d] %s -- entity: %s, areas touching: %d, area ID: %d, spawn position: %s", i, info.name, info.entityResolved ? "found" : "NOT FOUND", info.areaCount, info.areaId, info.spawnClosed ? "closed" : "open");
	}

	return Plugin_Handled;
}
