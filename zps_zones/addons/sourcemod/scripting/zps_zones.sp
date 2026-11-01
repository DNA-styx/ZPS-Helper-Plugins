/**
 * ZPS Zones
 *
 * Per-team "god zone" control for Zombie Panic: Source.
 * Players of the zone's team who stay inside a zone are warned with a hint,
 * then slapped for damage at a fixed interval until they leave or die.
 *
 * Clean rewrite inspired by "SM Zones" by Root (based on "Anti Rush" by Peace-Maker).
 *
 * Changelog
 *   0.1.0  Initial ZPS rewrite. Per-team zones, slap damage with grace period,
 *          hint warning, in-game create/edit/delete via !zones menu.
 *   0.2.0  Added "Zones editor" item to the !admin menu (Server Commands).
 *   0.2.1  Zone warning moved from hint text to chat, shown once on entry.
 *          Chat prefix changed to [ZPS Zones].
 */

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#undef REQUIRE_PLUGIN
#include <adminmenu>

#define PLUGIN_VERSION   "0.2.1"

#define TEAM_SURVIVORS   2
#define TEAM_ZOMBIES     3

#define MAX_ZONE_NAME    32
#define CHECK_INTERVAL   0.2
#define DRAW_INTERVAL    1.0
#define MIN_ZONE_HEIGHT  64.0
#define DEFAULT_HEIGHT   128.0
#define WARNING_TEXT     "God zone detected. Leave this area"
#define CHAT_PREFIX      "\x04[ZPS Zones]\x01"

enum struct ZoneData
{
	char  name[MAX_ZONE_NAME];
	float mins[3];
	float maxs[3];
	int   team;
}

public Plugin myinfo =
{
	name        = "ZPS Zones",
	author      = "Claude.ai guided by DNA.styx",
	description = "Per-team god zone punishment for Zombie Panic: Source",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

ArrayList g_Zones;
TopMenu   g_hTopMenu;

ConVar g_cvEnable;
ConVar g_cvDamage;
ConVar g_cvInterval;
ConVar g_cvGrace;
ConVar g_cvSlapSound;

char g_sMap[PLATFORM_MAX_PATH];
char g_sConfigPath[PLATFORM_MAX_PATH];

int g_iBeamSprite = -1;
int g_iHaloSprite = -1;

int g_iColorSurvivors[4] = { 0,   128, 255, 255 };
int g_iColorZombies[4]   = { 255, 0,   0,   255 };
int g_iColorDraft[4]     = { 255, 255, 0,   255 };

int g_iBoxEdges[12][2] =
{
	{ 0, 1 }, { 2, 3 }, { 4, 5 }, { 6, 7 },
	{ 0, 2 }, { 1, 3 }, { 4, 6 }, { 5, 7 },
	{ 0, 4 }, { 1, 5 }, { 2, 6 }, { 3, 7 }
};

// Editor state
bool  g_bEditing[MAXPLAYERS + 1];
bool  g_bFromAdminMenu[MAXPLAYERS + 1];
bool  g_bDraftHas1[MAXPLAYERS + 1];
bool  g_bDraftHas2[MAXPLAYERS + 1];
float g_fDraftP1[MAXPLAYERS + 1][3];
float g_fDraftP2[MAXPLAYERS + 1][3];
int   g_iDraftTeam[MAXPLAYERS + 1];
int   g_iEditZone[MAXPLAYERS + 1];
int   g_iEditCorner[MAXPLAYERS + 1];
float g_fEditStep[MAXPLAYERS + 1];

// Punishment state
bool  g_bInZone[MAXPLAYERS + 1];
float g_fNextSlap[MAXPLAYERS + 1];

// ====[ SETUP ]=============================================================

public void OnPluginStart()
{
	CreateConVar("zps_zones_version", PLUGIN_VERSION, "ZPS Zones version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	g_cvEnable    = CreateConVar("zps_zones_enable",     "1",    "Enable zone punishment. 0 = off, 1 = on.", FCVAR_PROTECTED, true, 0.0, true, 1.0);
	g_cvDamage    = CreateConVar("zps_zones_damage",     "10",   "HP removed per slap.", FCVAR_PROTECTED, true, 1.0);
	g_cvInterval  = CreateConVar("zps_zones_interval",   "1.0",  "Seconds between slaps while inside a zone.", FCVAR_PROTECTED, true, 0.2);
	g_cvGrace     = CreateConVar("zps_zones_grace",      "3.0",  "Seconds inside a zone before the first slap.", FCVAR_PROTECTED, true, 0.0);
	g_cvSlapSound = CreateConVar("zps_zones_slap_sound", "1",    "Play slap sound. 0 = off, 1 = on.", FCVAR_PROTECTED, true, 0.0, true, 1.0);

	AutoExecConfig(true, "zps_zones");

	RegAdminCmd("sm_zones", Command_Zones, ADMFLAG_CONFIG, "Open the ZPS zones editor.");

	g_Zones = new ArrayList(sizeof(ZoneData));

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "data/zps_zones");
	if (!DirExists(path))
	{
		CreateDirectory(path, FPERM_U_READ | FPERM_U_WRITE | FPERM_U_EXEC | FPERM_G_READ | FPERM_G_EXEC | FPERM_O_READ | FPERM_O_EXEC);
	}

	for (int client = 1; client <= MaxClients; client++)
	{
		ResetClient(client);
	}

	CreateTimer(CHECK_INTERVAL, Timer_Check, _, TIMER_REPEAT);
	CreateTimer(DRAW_INTERVAL,  Timer_Draw,  _, TIMER_REPEAT);

	TopMenu topmenu;
	if (LibraryExists("adminmenu") && ((topmenu = GetAdminTopMenu()) != null))
	{
		OnAdminMenuReady(topmenu);
	}
}

public void OnLibraryRemoved(const char[] name)
{
	if (StrEqual(name, "adminmenu"))
	{
		g_hTopMenu = null;
	}
}

public void OnAdminMenuReady(Handle aTopMenu)
{
	TopMenu topmenu = TopMenu.FromHandle(aTopMenu);
	if (topmenu == g_hTopMenu)
	{
		return;
	}

	g_hTopMenu = topmenu;

	TopMenuObject serverCommands = g_hTopMenu.FindCategory(ADMINMENU_SERVERCOMMANDS);
	if (serverCommands != INVALID_TOPMENUOBJECT)
	{
		g_hTopMenu.AddItem("sm_zones", AdminMenu_Zones, serverCommands, "sm_zones", ADMFLAG_CONFIG);
	}
}

public void AdminMenu_Zones(TopMenu topmenu, TopMenuAction action, TopMenuObject object_id, int client, char[] buffer, int maxlength)
{
	if (action == TopMenuAction_DisplayOption)
	{
		Format(buffer, maxlength, "Zones editor");
	}
	else if (action == TopMenuAction_SelectOption)
	{
		g_bEditing[client]       = true;
		g_bFromAdminMenu[client] = true;
		ShowMainMenu(client);
	}
}

public void OnMapStart()
{
	PrecacheBeams();

	GetCurrentMap(g_sMap, sizeof(g_sMap));
	BuildPath(Path_SM, g_sConfigPath, sizeof(g_sConfigPath), "data/zps_zones/%s.cfg", g_sMap);

	LoadZones();

	for (int client = 1; client <= MaxClients; client++)
	{
		ResetClient(client);
	}
}

public void OnClientPutInServer(int client)
{
	ResetClient(client);
}

public void OnClientDisconnect(int client)
{
	ResetClient(client);
}

void ResetClient(int client)
{
	g_bEditing[client]    = false;
	g_bFromAdminMenu[client] = false;
	g_bInZone[client]     = false;
	g_fNextSlap[client]   = 0.0;
	g_iEditZone[client]   = -1;
	g_iEditCorner[client] = 0;
	g_fEditStep[client]   = 8.0;
	ResetDraft(client);
}

void ResetDraft(int client)
{
	g_bDraftHas1[client] = false;
	g_bDraftHas2[client] = false;
	g_iDraftTeam[client] = TEAM_SURVIVORS;
}

void PrecacheBeams()
{
	g_iBeamSprite = -1;
	g_iHaloSprite = -1;

	GameData gd = new GameData("funcommands.games");
	if (gd != null)
	{
		char buffer[PLATFORM_MAX_PATH];
		if (gd.GetKeyValue("SpriteBeam", buffer, sizeof(buffer)) && buffer[0])
		{
			g_iBeamSprite = PrecacheModel(buffer);
		}
		if (gd.GetKeyValue("SpriteHalo", buffer, sizeof(buffer)) && buffer[0])
		{
			g_iHaloSprite = PrecacheModel(buffer);
		}
		delete gd;
	}

	if (g_iBeamSprite <= 0)
	{
		g_iBeamSprite = PrecacheModel("materials/sprites/laser.vmt");
	}
	if (g_iHaloSprite <= 0)
	{
		g_iHaloSprite = PrecacheModel("materials/sprites/halo01.vmt");
	}
}

// ====[ CONFIG ]============================================================

void LoadZones()
{
	g_Zones.Clear();

	if (!FileExists(g_sConfigPath))
	{
		return;
	}

	KeyValues kv = new KeyValues("Zones");
	if (!kv.ImportFromFile(g_sConfigPath))
	{
		LogError("Failed to read zone config: %s", g_sConfigPath);
		delete kv;
		return;
	}

	if (kv.GotoFirstSubKey())
	{
		do
		{
			ZoneData zone;
			kv.GetString("name", zone.name, sizeof(zone.name));
			kv.GetVector("mins", zone.mins);
			kv.GetVector("maxs", zone.maxs);
			zone.team = kv.GetNum("team", TEAM_SURVIVORS);

			if (zone.team != TEAM_SURVIVORS && zone.team != TEAM_ZOMBIES)
			{
				zone.team = TEAM_SURVIVORS;
			}

			g_Zones.PushArray(zone);
		}
		while (kv.GotoNextKey());
	}

	delete kv;
}

bool SaveZones()
{
	KeyValues kv = new KeyValues("Zones");
	char key[8];
	ZoneData zone;

	for (int i = 0; i < g_Zones.Length; i++)
	{
		g_Zones.GetArray(i, zone);
		IntToString(i, key, sizeof(key));

		kv.JumpToKey(key, true);
		kv.SetString("name", zone.name);
		kv.SetVector("mins", zone.mins);
		kv.SetVector("maxs", zone.maxs);
		kv.SetNum("team", zone.team);
		kv.GoBack();
	}

	kv.Rewind();
	bool ok = kv.ExportToFile(g_sConfigPath);
	delete kv;

	if (!ok)
	{
		LogError("Failed to write zone config: %s", g_sConfigPath);
	}
	return ok;
}

// ====[ PUNISHMENT ]========================================================

public Action Timer_Check(Handle timer)
{
	if (!g_cvEnable.BoolValue || g_Zones.Length == 0)
	{
		return Plugin_Continue;
	}

	float now = GetGameTime();
	float origin[3];

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !IsPlayerAlive(client) || g_bEditing[client])
		{
			g_bInZone[client] = false;
			continue;
		}

		int team = GetClientTeam(client);
		if (team != TEAM_SURVIVORS && team != TEAM_ZOMBIES)
		{
			g_bInZone[client] = false;
			continue;
		}

		GetClientAbsOrigin(client, origin);
		if (!IsInTeamZone(origin, team))
		{
			g_bInZone[client] = false;
			continue;
		}

		if (!g_bInZone[client])
		{
			g_bInZone[client]   = true;
			g_fNextSlap[client] = now + g_cvGrace.FloatValue;
			PrintToChat(client, "%s %s", CHAT_PREFIX, WARNING_TEXT);
		}

		if (now >= g_fNextSlap[client])
		{
			SlapPlayer(client, g_cvDamage.IntValue, g_cvSlapSound.BoolValue);
			g_fNextSlap[client] = now + g_cvInterval.FloatValue;
		}
	}

	return Plugin_Continue;
}

bool IsInTeamZone(const float origin[3], int team)
{
	ZoneData zone;
	for (int i = 0; i < g_Zones.Length; i++)
	{
		g_Zones.GetArray(i, zone);
		if (zone.team != team)
		{
			continue;
		}

		if (origin[0] >= zone.mins[0] && origin[0] <= zone.maxs[0]
		 && origin[1] >= zone.mins[1] && origin[1] <= zone.maxs[1]
		 && origin[2] >= zone.mins[2] - 2.0 && origin[2] <= zone.maxs[2])
		{
			return true;
		}
	}
	return false;
}

// ====[ DRAWING ]===========================================================

public Action Timer_Draw(Handle timer)
{
	ZoneData zone;
	float mins[3], maxs[3];

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || !g_bEditing[client])
		{
			continue;
		}

		for (int i = 0; i < g_Zones.Length; i++)
		{
			g_Zones.GetArray(i, zone);
			DrawBox(client, zone.mins, zone.maxs, zone.team == TEAM_ZOMBIES ? g_iColorZombies : g_iColorSurvivors);
		}

		if (g_bDraftHas1[client] && g_bDraftHas2[client])
		{
			NormaliseBox(g_fDraftP1[client], g_fDraftP2[client], mins, maxs);
			DrawBox(client, mins, maxs, g_iColorDraft);
		}
		else if (g_bDraftHas1[client])
		{
			for (int axis = 0; axis < 3; axis++)
			{
				mins[axis] = g_fDraftP1[client][axis] - 8.0;
				maxs[axis] = g_fDraftP1[client][axis] + 8.0;
			}
			DrawBox(client, mins, maxs, g_iColorDraft);
		}
	}

	return Plugin_Continue;
}

void DrawBox(int client, const float mins[3], const float maxs[3], const int color[4])
{
	float corners[8][3];
	for (int i = 0; i < 8; i++)
	{
		corners[i][0] = (i & 1) ? maxs[0] : mins[0];
		corners[i][1] = (i & 2) ? maxs[1] : mins[1];
		corners[i][2] = (i & 4) ? maxs[2] : mins[2];
	}

	for (int e = 0; e < 12; e++)
	{
		TE_SetupBeamPoints(corners[g_iBoxEdges[e][0]], corners[g_iBoxEdges[e][1]], g_iBeamSprite, g_iHaloSprite,
			0, 0, DRAW_INTERVAL + 0.1, 2.0, 2.0, 1, 0.0, color, 0);
		TE_SendToClient(client);
	}
}

void NormaliseBox(const float p1[3], const float p2[3], float mins[3], float maxs[3])
{
	for (int axis = 0; axis < 3; axis++)
	{
		mins[axis] = p1[axis] < p2[axis] ? p1[axis] : p2[axis];
		maxs[axis] = p1[axis] > p2[axis] ? p1[axis] : p2[axis];
	}

	if (maxs[2] - mins[2] < MIN_ZONE_HEIGHT)
	{
		maxs[2] = mins[2] + DEFAULT_HEIGHT;
	}
}

// ====[ COMMAND ]===========================================================

public Action Command_Zones(int client, int args)
{
	if (client == 0 || !IsClientInGame(client))
	{
		ReplyToCommand(client, "[Zones] This command is in-game only.");
		return Plugin_Handled;
	}

	g_bEditing[client]       = true;
	g_bFromAdminMenu[client] = false;
	ShowMainMenu(client);
	return Plugin_Handled;
}

void HandleCancel(int client, int reason)
{
	if (reason == MenuCancel_Exit || reason == MenuCancel_Disconnected || reason == MenuCancel_Timeout)
	{
		g_bEditing[client] = false;
		ResetDraft(client);
	}
}

void GetTeamLabel(int team, char[] buffer, int maxlen)
{
	strcopy(buffer, maxlen, team == TEAM_ZOMBIES ? "Zombies" : "Survivors");
}

// ====[ MAIN MENU ]=========================================================

void ShowMainMenu(int client)
{
	Menu menu = new Menu(MenuHandler_Main);
	menu.SetTitle("ZPS Zones - %s\nZones on map: %d\n ", g_sMap, g_Zones.Length);
	menu.AddItem("add",  "Add zone");
	menu.AddItem("edit", "Edit zones", g_Zones.Length > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.ExitBackButton = g_bFromAdminMenu[client];
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Main(Menu menu, MenuAction action, int client, int item)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[8];
			menu.GetItem(item, info, sizeof(info));

			if (StrEqual(info, "add"))
			{
				ResetDraft(client);
				ShowAddMenu(client);
			}
			else
			{
				ShowZoneListMenu(client);
			}
		}
		case MenuAction_Cancel:
		{
			if (item == MenuCancel_ExitBack && g_hTopMenu != null)
			{
				g_bEditing[client]       = false;
				g_bFromAdminMenu[client] = false;
				ResetDraft(client);
				g_hTopMenu.Display(client, TopMenuPosition_LastCategory);
			}
			else
			{
				HandleCancel(client, item);
			}
		}
		case MenuAction_End: delete menu;
	}
	return 0;
}

// ====[ ADD ZONE ]==========================================================

void ShowAddMenu(int client)
{
	char teamLabel[16], buffer[48];
	GetTeamLabel(g_iDraftTeam[client], teamLabel, sizeof(teamLabel));

	Menu menu = new Menu(MenuHandler_Add);
	menu.SetTitle("Add zone\nPoint 1: %s\nPoint 2: %s\n ",
		g_bDraftHas1[client] ? "set" : "not set",
		g_bDraftHas2[client] ? "set" : "not set");

	menu.AddItem("p1", "Set point 1 (my position)");
	menu.AddItem("p2", "Set point 2 (my position)");

	Format(buffer, sizeof(buffer), "Team: %s", teamLabel);
	menu.AddItem("team", buffer);

	menu.AddItem("save", "Save zone", (g_bDraftHas1[client] && g_bDraftHas2[client]) ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Add(Menu menu, MenuAction action, int client, int item)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[8];
			menu.GetItem(item, info, sizeof(info));

			if (StrEqual(info, "p1"))
			{
				GetClientAbsOrigin(client, g_fDraftP1[client]);
				g_bDraftHas1[client] = true;
				PrintToChat(client, "%s Point 1 set.", CHAT_PREFIX);
			}
			else if (StrEqual(info, "p2"))
			{
				GetClientAbsOrigin(client, g_fDraftP2[client]);
				g_bDraftHas2[client] = true;
				PrintToChat(client, "%s Point 2 set.", CHAT_PREFIX);
			}
			else if (StrEqual(info, "team"))
			{
				g_iDraftTeam[client] = (g_iDraftTeam[client] == TEAM_SURVIVORS) ? TEAM_ZOMBIES : TEAM_SURVIVORS;
			}
			else if (StrEqual(info, "save"))
			{
				ZoneData zone;
				GetNextZoneName(zone.name, sizeof(zone.name));
				NormaliseBox(g_fDraftP1[client], g_fDraftP2[client], zone.mins, zone.maxs);
				zone.team = g_iDraftTeam[client];

				g_Zones.PushArray(zone);

				if (SaveZones())
				{
					PrintToChat(client, "%s Zone \x04%s\x01 saved.", CHAT_PREFIX, zone.name);
				}
				else
				{
					PrintToChat(client, "%s Zone \x04%s\x01 created but the config could not be written. Check the error log.", CHAT_PREFIX, zone.name);
				}

				ResetDraft(client);
				ShowMainMenu(client);
				return 0;
			}

			ShowAddMenu(client);
		}
		case MenuAction_Cancel:
		{
			if (item == MenuCancel_ExitBack)
			{
				ResetDraft(client);
				ShowMainMenu(client);
			}
			else
			{
				HandleCancel(client, item);
			}
		}
		case MenuAction_End: delete menu;
	}
	return 0;
}

void GetNextZoneName(char[] buffer, int maxlen)
{
	ZoneData zone;
	for (int n = 1; ; n++)
	{
		Format(buffer, maxlen, "zone_%d", n);

		bool taken = false;
		for (int i = 0; i < g_Zones.Length; i++)
		{
			g_Zones.GetArray(i, zone);
			if (StrEqual(zone.name, buffer, false))
			{
				taken = true;
				break;
			}
		}

		if (!taken)
		{
			return;
		}
	}
}

// ====[ ZONE LIST ]=========================================================

void ShowZoneListMenu(int client)
{
	if (g_Zones.Length == 0)
	{
		ShowMainMenu(client);
		return;
	}

	Menu menu = new Menu(MenuHandler_ZoneList);
	menu.SetTitle("Edit zones\n ");

	ZoneData zone;
	char info[8], label[64], teamLabel[16];

	for (int i = 0; i < g_Zones.Length; i++)
	{
		g_Zones.GetArray(i, zone);
		GetTeamLabel(zone.team, teamLabel, sizeof(teamLabel));
		IntToString(i, info, sizeof(info));
		Format(label, sizeof(label), "%s (%s)", zone.name, teamLabel);
		menu.AddItem(info, label);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_ZoneList(Menu menu, MenuAction action, int client, int item)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[8];
			menu.GetItem(item, info, sizeof(info));
			g_iEditZone[client] = StringToInt(info);
			ShowZoneMenu(client);
		}
		case MenuAction_Cancel:
		{
			if (item == MenuCancel_ExitBack)
			{
				ShowMainMenu(client);
			}
			else
			{
				HandleCancel(client, item);
			}
		}
		case MenuAction_End: delete menu;
	}
	return 0;
}

bool IsEditZoneValid(int client)
{
	return g_iEditZone[client] >= 0 && g_iEditZone[client] < g_Zones.Length;
}

// ====[ ZONE OPTIONS ]======================================================

void ShowZoneMenu(int client)
{
	if (!IsEditZoneValid(client))
	{
		ShowZoneListMenu(client);
		return;
	}

	ZoneData zone;
	g_Zones.GetArray(g_iEditZone[client], zone);

	char teamLabel[16], buffer[48];
	GetTeamLabel(zone.team, teamLabel, sizeof(teamLabel));

	Menu menu = new Menu(MenuHandler_Zone);
	menu.SetTitle("Zone: %s\n ", zone.name);

	menu.AddItem("tele", "Teleport to zone");

	Format(buffer, sizeof(buffer), "Team: %s", teamLabel);
	menu.AddItem("team", buffer);

	menu.AddItem("c1",  "Adjust min corner");
	menu.AddItem("c2",  "Adjust max corner");
	menu.AddItem("del", "Delete zone");

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Zone(Menu menu, MenuAction action, int client, int item)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			if (!IsEditZoneValid(client))
			{
				ShowZoneListMenu(client);
				return 0;
			}

			char info[8];
			menu.GetItem(item, info, sizeof(info));

			ZoneData zone;
			g_Zones.GetArray(g_iEditZone[client], zone);

			if (StrEqual(info, "tele"))
			{
				float pos[3], zero[3];
				pos[0] = (zone.mins[0] + zone.maxs[0]) / 2.0;
				pos[1] = (zone.mins[1] + zone.maxs[1]) / 2.0;
				pos[2] = zone.mins[2] + 8.0;
				TeleportEntity(client, pos, NULL_VECTOR, zero);
			}
			else if (StrEqual(info, "team"))
			{
				zone.team = (zone.team == TEAM_SURVIVORS) ? TEAM_ZOMBIES : TEAM_SURVIVORS;
				g_Zones.SetArray(g_iEditZone[client], zone);
				SaveZones();
			}
			else if (StrEqual(info, "c1") || StrEqual(info, "c2"))
			{
				g_iEditCorner[client] = StrEqual(info, "c1") ? 1 : 2;
				ShowAdjustMenu(client);
				return 0;
			}
			else if (StrEqual(info, "del"))
			{
				ShowDeleteMenu(client);
				return 0;
			}

			ShowZoneMenu(client);
		}
		case MenuAction_Cancel:
		{
			if (item == MenuCancel_ExitBack)
			{
				ShowZoneListMenu(client);
			}
			else
			{
				HandleCancel(client, item);
			}
		}
		case MenuAction_End: delete menu;
	}
	return 0;
}

// ====[ ADJUST CORNER ]=====================================================

void ShowAdjustMenu(int client)
{
	if (!IsEditZoneValid(client))
	{
		ShowZoneListMenu(client);
		return;
	}

	ZoneData zone;
	g_Zones.GetArray(g_iEditZone[client], zone);

	Menu menu = new Menu(MenuHandler_Adjust);
	menu.SetTitle("Zone: %s\nAdjust %s corner\nStep: %.0f units\n ",
		zone.name, g_iEditCorner[client] == 1 ? "min" : "max", g_fEditStep[client]);

	menu.AddItem("+0",   "+X");
	menu.AddItem("-0",   "-X");
	menu.AddItem("+1",   "+Y");
	menu.AddItem("-1",   "-Y");
	menu.AddItem("+2",   "+Z");
	menu.AddItem("-2",   "-Z");
	menu.AddItem("step", "Change step");
	menu.AddItem("back", "Back");

	menu.Pagination = MENU_NO_PAGINATION;
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Adjust(Menu menu, MenuAction action, int client, int item)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			if (!IsEditZoneValid(client))
			{
				ShowZoneListMenu(client);
				return 0;
			}

			char info[8];
			menu.GetItem(item, info, sizeof(info));

			if (StrEqual(info, "back"))
			{
				ShowZoneMenu(client);
				return 0;
			}

			if (StrEqual(info, "step"))
			{
				if      (g_fEditStep[client] < 8.0)  g_fEditStep[client] = 8.0;
				else if (g_fEditStep[client] < 32.0) g_fEditStep[client] = 32.0;
				else if (g_fEditStep[client] < 64.0) g_fEditStep[client] = 64.0;
				else                                 g_fEditStep[client] = 1.0;
			}
			else
			{
				int   axis  = info[1] - '0';
				float delta = (info[0] == '+') ? g_fEditStep[client] : -g_fEditStep[client];

				ZoneData zone;
				g_Zones.GetArray(g_iEditZone[client], zone);

				if (g_iEditCorner[client] == 1)
				{
					zone.mins[axis] += delta;
				}
				else
				{
					zone.maxs[axis] += delta;
				}

				if (zone.mins[axis] > zone.maxs[axis])
				{
					float temp      = zone.mins[axis];
					zone.mins[axis] = zone.maxs[axis];
					zone.maxs[axis] = temp;
				}

				g_Zones.SetArray(g_iEditZone[client], zone);
				SaveZones();
			}

			ShowAdjustMenu(client);
		}
		case MenuAction_Cancel: HandleCancel(client, item);
		case MenuAction_End:    delete menu;
	}
	return 0;
}

// ====[ DELETE ]============================================================

void ShowDeleteMenu(int client)
{
	if (!IsEditZoneValid(client))
	{
		ShowZoneListMenu(client);
		return;
	}

	ZoneData zone;
	g_Zones.GetArray(g_iEditZone[client], zone);

	Menu menu = new Menu(MenuHandler_Delete);
	menu.SetTitle("Delete zone %s?\n ", zone.name);
	menu.AddItem("yes", "Confirm delete");
	menu.AddItem("no",  "Cancel");
	menu.ExitButton = false;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Delete(Menu menu, MenuAction action, int client, int item)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[8];
			menu.GetItem(item, info, sizeof(info));

			if (StrEqual(info, "yes") && IsEditZoneValid(client))
			{
				ZoneData zone;
				g_Zones.GetArray(g_iEditZone[client], zone);
				g_Zones.Erase(g_iEditZone[client]);
				g_iEditZone[client] = -1;
				SaveZones();

				PrintToChat(client, "%s Zone \x04%s\x01 deleted.", CHAT_PREFIX, zone.name);
				ShowZoneListMenu(client);
			}
			else
			{
				ShowZoneMenu(client);
			}
		}
		case MenuAction_Cancel: HandleCancel(client, item);
		case MenuAction_End:    delete menu;
	}
	return 0;
}
