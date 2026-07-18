#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <navbot>

#define PLUGIN_VERSION "0.2.0"

#define ZPS_OBJHELPER_CONFIG_FOLDER "zps_block_closed_doors"

// Source engine TOGGLE_STATE (func_door / func_door_rotating -- m_toggle_state)
#define TS_AT_TOP 0
#define TS_AT_BOTTOM 1
#define TS_GOING_UP 2
#define TS_GOING_DOWN 3

// prop_door_rotating DoorState_t (m_eDoorState) -- from game\server\BasePropDoor.h
#define DOOR_STATE_CLOSED 0
#define DOOR_STATE_OPENING 1
#define DOOR_STATE_OPEN 2
#define DOOR_STATE_CLOSING 3
#define DOOR_STATE_AJAR 4

ConVar g_hCvarPollInterval;
ConVar g_hCvarVerbose;

enum struct DoorInfo
{
	int hammerId;
	char name[64];       // cosmetic only, never used for lookup
	char classname[64];  // required -- drives both entity lookup and state reading
	int entRef;
	bool entityResolved;
	bool everResolved;   // true once this door has been found at least once (distinguishes "never found" from "destroyed")
	int areaId;
	int areaCount;
	Handle blockerHandle; // NavBotNavBlocker, stored generically to keep this struct simple
	bool blockerActive;
	bool blocked;         // last known intended blocked state
	bool doneMonitoring;  // true once this door will never need checking again (destroyed, or lookup permanently failed)
}

ArrayList g_hDoors = null;
Handle g_hPollTimer = null;
bool g_bPollingStarted = false;

public Plugin myinfo =
{
	name = "zps_block_closed_doors",
	author = "Claude.ai guided by DNA.styx",
	description = "Mark navmesh that locked doors touch as blocked for navbot",
	version = PLUGIN_VERSION,
	url = ""
};

//=============================================================================
// Lifecycle
//=============================================================================

public void OnPluginStart()
{
	CreateConVar("zps_block_closed_doors_version", PLUGIN_VERSION, "zps_block_closed_doors plugin version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_hCvarPollInterval = CreateConVar("zps_block_closed_doors_poll_interval", "0.1", "How often (in seconds) to check each managed door's live state and react to changes.", _, true, 0.05, true, 2.0);
	g_hCvarVerbose = CreateConVar("zps_block_closed_doors_verbose", "0", "If 1, logs every blocker (re)creation and every detected block/unblock. If 0, only logs errors.", _, true, 0.0, true, 1.0);

	AutoExecConfig(true, "zps_block_closed_doors");

	RegAdminCmd("sm_zps_block_closed_doors_status", Cmd_Status, ADMFLAG_ROOT, "Prints status of all managed doors.");
	RegAdminCmd("sm_zps_block_closed_doors_listdoors", Cmd_ListDoors, ADMFLAG_ROOT, "Lists the doors loaded from this map's config.");

	g_hDoors = new ArrayList(sizeof(DoorInfo));
}

public void OnMapStart()
{
	LoadDoorConfig();

	if (NavBotNavMesh.IsLoaded())
	{
		TryResolveAllDoors();
		StartPolling();
	}
}

public void OnNavBotNavMeshLoaded()
{
	TryResolveAllDoors();
	StartPolling();
}

public void OnNavBotNavMeshDestroyed()
{
	delete g_hPollTimer;
	g_bPollingStarted = false;

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
		g_hDoors.SetArray(i, info);
	}
}

void ReportIssue(const char[] fmt, any ...)
{
	char msg[256];
	VFormat(msg, sizeof(msg), fmt, 2);

	char fullMsg[288];
	Format(fullMsg, sizeof(fullMsg), "[zps_block_closed_doors] %s", msg);

	PrintToServer("%s", fullMsg);
	PrintToChatAll("%s", fullMsg);

	char logPath[PLATFORM_MAX_PATH];
	char mapName[64];
	GetCurrentMap(mapName, sizeof(mapName));
	BuildPath(Path_SM, logPath, sizeof(logPath), "logs/zps_block_closed_doors_%s.log", mapName);
	LogToFileEx(logPath, "%s", fullMsg);
}

//=============================================================================
// Config loading
//=============================================================================

void LoadDoorConfig()
{
	g_hDoors.Clear();
	g_bPollingStarted = false;

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
			char hammerIdStr[16];
			kv.GetSectionName(hammerIdStr, sizeof(hammerIdStr));

			int hammerId = StringToInt(hammerIdStr);

			if (hammerId <= 0)
			{
				ReportIssue("Door config \"%s\" has an invalid Hammer ID key \"%s\" -- skipping.", path, hammerIdStr);
				continue;
			}

			DoorInfo info;
			info.hammerId = hammerId;
			kv.GetString("Name", info.name, sizeof(info.name), hammerIdStr);
			kv.GetString("Classname", info.classname, sizeof(info.classname), "");
			info.entRef = INVALID_ENT_REFERENCE;
			info.entityResolved = false;
			info.everResolved = false;
			info.areaId = -1;
			info.areaCount = 0;
			info.blockerHandle = null;
			info.blockerActive = false;
			info.blocked = false;
			info.doneMonitoring = false;

			if (info.classname[0] == '\0')
			{
				ReportIssue("Door \"%s\" (hammerid %d) has no Classname configured -- skipping.", info.name, info.hammerId);
				continue;
			}

			g_hDoors.PushArray(info);
		} while (kv.GotoNextKey(false));

		kv.GoBack();
	}

	delete kv;

	if (g_hDoors.Length == 0)
	{
		ReportIssue("Door config \"%s\" loaded but contains no usable door entries.", path);
	}
	else
	{
		PrintToServer("[zps_block_closed_doors] Loaded %d door(s) from \"%s\".", g_hDoors.Length, path);
	}
}

//=============================================================================
// Entity / area resolution
//=============================================================================

// Finds an entity by its compile-time-unique Hammer ID, narrowed by classname.
// Unlike targetname, Hammer IDs are guaranteed unique even when multiple doors
// share the same mapper-assigned name.
int FindEntityOfHammerID(const char[] classname, int hammerid)
{
	int entity = INVALID_ENT_REFERENCE;

	while ((entity = FindEntityByClassname(entity, classname)) != INVALID_ENT_REFERENCE)
	{
		int id = GetEntProp(entity, Prop_Data, "m_iHammerID");

		if (id == hammerid)
		{
			return entity;
		}
	}

	return INVALID_ENT_REFERENCE;
}

// Reads the door's actual live state rather than inferring it from any event.
// prop_door_rotating (and prop_door* variants) use m_eDoorState.
// func_door / func_door_rotating (and func_door* variants) use m_toggle_state.
bool IsDoorPassable(int entity, const char[] classname)
{
	if (strncmp(classname, "prop_door", 9) == 0)
	{
		int doorstate = GetEntProp(entity, Prop_Data, "m_eDoorState");
		return (doorstate == DOOR_STATE_OPEN || doorstate == DOOR_STATE_OPENING);
	}

	if (strncmp(classname, "func_door", 9) == 0)
	{
		int togglestate = GetEntProp(entity, Prop_Data, "m_toggle_state");
		return (togglestate == TS_AT_TOP || togglestate == TS_GOING_UP);
	}

	return false; // unrecognized classname -- default to "blocked" (safer than assuming passable)
}

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
		ReportIssue("Door \"%s\" (hammerid %d, classname \"%s\") could not be found in the map.", info.name, info.hammerId, info.classname);
		return;
	}

	if (strncmp(info.classname, "prop_door", 9) != 0 && strncmp(info.classname, "func_door", 9) != 0)
	{
		ReportIssue("Door \"%s\" (hammerid %d) has unrecognized classname \"%s\" -- cannot determine its state.", info.name, info.hammerId, info.classname);
	}

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

	// Only trust a 0-area result as a real mesh-placement problem if the door is
	// actually closed right now -- otherwise its pose isn't guaranteed and the
	// result is meaningless (this is checked live, not assumed from config).
	if (IsDoorPassable(door, info.classname))
	{
		return;
	}

	if (info.areaCount == 0)
	{
		ReportIssue("Door \"%s\" (hammerid %d) is closed but touches 0 nav areas. Check nav mesh placement around this door.", info.name, info.hammerId);
	}
	else if (info.areaCount > 1)
	{
		ReportIssue("Door \"%s\" (hammerid %d) touches %d nav areas (expected 1). Using area ID %d; check nav mesh placement around this door.", info.name, info.hammerId, info.areaCount, info.areaId);
	}
}

int ResolveDoorEntity(DoorInfo info)
{
	int door = EntRefToEntIndex(info.entRef);

	if (door == -1 || door == INVALID_ENT_REFERENCE)
	{
		door = FindEntityOfHammerID(info.classname, info.hammerId);

		if (door == -1)
		{
			info.entityResolved = false;
			info.entRef = INVALID_ENT_REFERENCE;
			return -1;
		}

		info.entRef = EntIndexToEntRef(door);
	}

	info.entityResolved = true;
	info.everResolved = true;
	return door;
}

//=============================================================================
// Blocking core
//=============================================================================

void StartPolling()
{
	if (g_hDoors == null || g_bPollingStarted)
	{
		return;
	}

	g_bPollingStarted = true;

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
		info.blockerActive = false;
		return;
	}

	info.blockerHandle = new NavBotNavBlocker(InitDoorBlockerCB, UpdateDoorBlockerCB, info.name);
	info.blockerActive = true;
}

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
		LogError("[zps_block_closed_doors] InitDoorBlockerCB: could not match blocker Handle to a configured door.");
		return false;
	}

	DoorInfo info;
	g_hDoors.GetArray(idx, info);

	int door = EntRefToEntIndex(info.entRef);

	if (door == -1 || door == INVALID_ENT_REFERENCE)
	{
		LogError("[zps_block_closed_doors] InitDoorBlockerCB: door entity reference invalid for \"%s\".", info.name);
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
		PrintToServer("[zps_block_closed_doors] Blocker (re)created for door \"%s\" (hammerid %d): %d area(s), area ID=%d, blocked=true.", info.name, info.hammerId, info.areaCount, info.areaId);
	}

	return true;
}

public bool UpdateDoorBlockerCB(NavBotNavBlocker blocker)
{
	return true;
}

// Single unified loop: reads each door's live state, decides whether it should be
// blocked or unblocked right now, and acts on any change -- including a door being
// destroyed (treated as a permanent, terminal unblock) and NavBot's own blocker
// self-invalidation (recreated if still supposed to be blocked but no longer is).
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

		if (info.doneMonitoring)
		{
			continue;
		}

		int entity = ResolveDoorEntity(info);

		if (entity == -1)
		{
			if (info.everResolved)
			{
				UnblockDoor(info);
				info.doneMonitoring = true;
				ReportIssue("Door \"%s\" (hammerid %d) no longer exists -- treating as permanently unblocked.", info.name, info.hammerId);
			}
			else
			{
				// Never found, even after the initial diagnostic pass already reported it.
				// Stop retrying every tick rather than spamming.
				info.doneMonitoring = true;
			}

			g_hDoors.SetArray(i, info);
			continue;
		}

		bool passable = IsDoorPassable(entity, info.classname);

		if (passable)
		{
			if (info.blocked)
			{
				UnblockDoor(info);

				if (g_hCvarVerbose.BoolValue)
				{
					PrintToServer("[zps_block_closed_doors] Door \"%s\" (hammerid %d) is now passable -- unblocking.", info.name, info.hammerId);
				}
			}
		}
		else
		{
			bool needsBlock = !info.blockerActive;

			if (!needsBlock && info.areaId != -1)
			{
				Address area = NavBotNavMesh.GetNavAreaByID(info.areaId);

				if (area == Address_Null || !NavBotNavArea.IsBlocked(area, NAVBOT_NAV_TEAM_ANY))
				{
					needsBlock = true;
				}
			}

			if (needsBlock)
			{
				BlockDoor(info);
			}
		}

		g_hDoors.SetArray(i, info);
	}

	return Plugin_Continue;
}

//=============================================================================
// Commands
//=============================================================================

public Action Cmd_Status(int client, int args)
{
	if (g_hDoors == null || g_hDoors.Length == 0)
	{
		ReplyToCommand(client, "[zps_block_closed_doors] No doors loaded.");
		return Plugin_Handled;
	}

	int count = g_hDoors.Length;
	ReplyToCommand(client, "[zps_block_closed_doors] %d door(s):", count);

	for (int i = 0; i < count; i++)
	{
		DoorInfo info;
		g_hDoors.GetArray(i, info);

		ReplyToCommand(client, "  [%d] %s (hammerid %d) -- managed: %s, blocked: %s, area ID: %d, done: %s", i, info.name, info.hammerId, info.blockerActive ? "yes" : "no", info.blocked ? "yes" : "no", info.areaId, info.doneMonitoring ? "yes" : "no");
	}

	return Plugin_Handled;
}

public Action Cmd_ListDoors(int client, int args)
{
	if (g_hDoors == null)
	{
		ReplyToCommand(client, "[zps_block_closed_doors] Door list not initialized.");
		return Plugin_Handled;
	}

	int count = g_hDoors.Length;

	ReplyToCommand(client, "[zps_block_closed_doors] %d door(s) loaded from config:", count);

	for (int i = 0; i < count; i++)
	{
		DoorInfo info;
		g_hDoors.GetArray(i, info);

		ReplyToCommand(client, "  [%d] %s (hammerid %d, %s) -- entity: %s, areas touching: %d, area ID: %d", i, info.name, info.hammerId, info.classname, info.entityResolved ? "found" : "NOT FOUND", info.areaCount, info.areaId);
	}

	return Plugin_Handled;
}
