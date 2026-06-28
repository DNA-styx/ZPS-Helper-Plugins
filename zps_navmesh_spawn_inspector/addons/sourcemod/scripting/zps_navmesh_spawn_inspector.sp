#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>

#define PLUGIN_VERSION "1.2.3"
#define TELEPORT_COOLDOWN 0.1

// Filename format: spchecker_<mapname>_YYYY-MM-DD.log
#define SPCHECK_PREFIX     "spchecker_"
#define SPCHECK_PREFIX_LEN 10
#define SPCHECK_SUFFIX_LEN 15  // "_YYYY-MM-DD.log"

ArrayList g_PosCoords;   // float[3] per entry
ArrayList g_PosTypes;    // entity type string per entry
ArrayList g_FileList;    // matching log filenames, sorted desc

int   g_CurrentPos[MAXPLAYERS + 1];
float g_LastTeleport[MAXPLAYERS + 1];
char  g_CurrentMap[64];                   // display name of the current map
char  g_SelectedMap[MAXPLAYERS + 1][64]; // pending changelevel map name

public Plugin myinfo =
{
	name        = "ZPS NavMesh Spawn Inspector",
	author      = "Claude.ai guided by DNA.styx",
	description = "Navigate spawnpoint checker log positions in-game",
	version     = PLUGIN_VERSION,
	url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

// ─── Setup ───────────────────────────────────────────────────────────────────

void UpdateCurrentMap()
{
	char buffer[64];
	GetCurrentMap(buffer, sizeof(buffer));
	if (!GetMapDisplayName(buffer, g_CurrentMap, sizeof(g_CurrentMap)))
		strcopy(g_CurrentMap, sizeof(g_CurrentMap), buffer);
}

public void OnPluginStart()
{
	LoadTranslations("zps_navmesh_spawn_inspector.phrases");

	g_PosCoords = new ArrayList(3);
	g_PosTypes  = new ArrayList(ByteCountToCells(64));
	g_FileList  = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

	UpdateCurrentMap();

	RegAdminCmd("sm_spcheck", Cmd_SpCheck, ADMFLAG_ROOT, "Open NavMesh Spawn Inspector");

	// Show menu to any admin already in-game when plugin is loaded
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i) && (GetUserFlagBits(i) & ADMFLAG_ROOT))
		{
			BuildFileList();
			if (g_FileList.Length > 0)
				ShowFileMenu(i);
			break;
		}
	}
}

public void OnClientPutInServer(int client)
{
	if (IsFakeClient(client))
		return;
	CreateTimer(3.0, Timer_AutoShowMenu, GetClientUserId(client));
}

public Action Timer_AutoShowMenu(Handle timer, int userid)
{
	int client = GetClientOfUserId(userid);
	if (client == 0 || !IsClientInGame(client))
		return Plugin_Stop;
	if (!CheckCommandAccess(client, "sm_spcheck", ADMFLAG_ROOT))
		return Plugin_Stop;

	BuildFileList();
	if (g_FileList.Length > 0)
		ShowFileMenu(client);

	return Plugin_Stop;
}

public void OnPluginEnd()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientInGame(i) && !IsFakeClient(i))
			CancelClientMenu(i);
	}
}

public void OnMapStart()
{
	UpdateCurrentMap();
	g_PosCoords.Clear();
	g_PosTypes.Clear();

	for (int i = 1; i <= MaxClients; i++)
	{
		g_LastTeleport[i] = 0.0;
		if (IsClientInGame(i) && !IsFakeClient(i))
			CancelClientMenu(i);
	}
}

// ─── Command ─────────────────────────────────────────────────────────────────

public Action Cmd_SpCheck(int client, int args)
{
	if (client == 0)
	{
		ReplyToCommand(client, "%T", "ZNSI_InGameOnly", client);
		return Plugin_Handled;
	}

	BuildFileList();

	if (g_FileList.Length == 0)
	{
		ReplyToCommand(client, "%T", "ZNSI_NoLogsFound", client);
		return Plugin_Handled;
	}

	ShowFileMenu(client);
	return Plugin_Handled;
}

// ─── File scanning ───────────────────────────────────────────────────────────

void BuildFileList()
{
	g_FileList.Clear();

	char logDir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, logDir, sizeof(logDir), "logs");

	DirectoryListing dir = OpenDirectory(logDir);
	if (dir == null)
		return;

	// Collect all spchecker_*.log files
	ArrayList allFiles = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	char filename[PLATFORM_MAX_PATH];
	FileType ft;

	while (dir.GetNext(filename, sizeof(filename), ft))
	{
		if (ft != FileType_File)
			continue;
		if (strncmp(filename, SPCHECK_PREFIX, SPCHECK_PREFIX_LEN, false) != 0)
			continue;
		int len = strlen(filename);
		if (len < 4 || strcmp(filename[len - 4], ".log", false) != 0)
			continue;
		allFiles.PushString(filename);
	}

	delete dir;

	// Sort descending — first occurrence of each map name = most recent file
	allFiles.Sort(Sort_Descending, Sort_String);

	// Pick most recent file per unique map name
	StringMap seen = new StringMap();
	char mapName[64];

	for (int i = 0; i < allFiles.Length; i++)
	{
		allFiles.GetString(i, filename, sizeof(filename));

		int len = strlen(filename);
		int mapLen = len - SPCHECK_PREFIX_LEN - SPCHECK_SUFFIX_LEN;
		if (mapLen <= 0)
			continue;

		strcopy(mapName, mapLen + 1 < sizeof(mapName) ? mapLen + 1 : sizeof(mapName), filename[SPCHECK_PREFIX_LEN]);

		int dummy;
		if (seen.GetValue(mapName, dummy))
			continue;

		seen.SetValue(mapName, 1);
		g_FileList.PushString(filename);
	}

	delete seen;
	delete allFiles;
}

// ─── File parsing ─────────────────────────────────────────────────────────────

bool LoadFile(const char[] filename)
{
	g_PosCoords.Clear();
	g_PosTypes.Clear();

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "logs/%s", filename);

	File f = OpenFile(path, "r");
	if (f == null)
		return false;

	char line[512];
	while (f.ReadLine(line, sizeof(line)))
	{
		// Format: ... nearby! <entitytype> "setpos X Y Z"
		int nearbyIdx = StrContains(line, "nearby! ");
		if (nearbyIdx < 0)
			continue;

		char rest[256];
		strcopy(rest, sizeof(rest), line[nearbyIdx + 8]);
		TrimString(rest);

		// Split entity type from setpos string
		int spaceIdx = StrContains(rest, " ");
		if (spaceIdx < 0)
			continue;

		char entityType[64];
		strcopy(entityType, sizeof(entityType), rest);
		entityType[spaceIdx] = '\0';

		if (strcmp(entityType, "info_player_commons", false) == 0
			|| strcmp(entityType, "info_player_observer", false) == 0)
			continue;

		int setposIdx = StrContains(rest, "setpos ");
		if (setposIdx < 0)
			continue;

		char coords[128];
		strcopy(coords, sizeof(coords), rest[setposIdx + 7]);

		// Strip trailing quote and whitespace
		int coordLen = strlen(coords);
		while (coordLen > 0 && (coords[coordLen - 1] == '"' || coords[coordLen - 1] == '\n'
			|| coords[coordLen - 1] == '\r' || coords[coordLen - 1] == ' '))
			coords[--coordLen] = '\0';

		char parts[3][32];
		if (ExplodeString(coords, " ", parts, 3, 32) < 3)
			continue;

		float pos[3];
		pos[0] = StringToFloat(parts[0]);
		pos[1] = StringToFloat(parts[1]);
		pos[2] = StringToFloat(parts[2]);

		g_PosCoords.PushArray(pos, 3);
		g_PosTypes.PushString(entityType);
	}

	delete f;
	return g_PosCoords.Length > 0;
}

// ─── File selection menu ─────────────────────────────────────────────────────

void ShowFileMenu(int client)
{
	Menu menu = new Menu(MenuHandler_File);

	char title[64];
	Format(title, sizeof(title), "%T", "ZNSI_MenuTitle", client);
	menu.SetTitle(title);
	menu.ExitButton = true;

	char filename[PLATFORM_MAX_PATH];
	char mapName[64];
	char date[6];
	char display[96];

	// If current map has no log entry, add a disabled placeholder first
	if (g_CurrentMap[0] != '\0')
	{
		bool found = false;
		for (int i = 0; i < g_FileList.Length && !found; i++)
		{
			g_FileList.GetString(i, filename, sizeof(filename));
			int fLen = strlen(filename);
			int fMapLen = fLen - SPCHECK_PREFIX_LEN - SPCHECK_SUFFIX_LEN;
			if (fMapLen > 0)
			{
				strcopy(mapName, fMapLen + 1 < sizeof(mapName) ? fMapLen + 1 : sizeof(mapName), filename[SPCHECK_PREFIX_LEN]);
				if (strcmp(mapName, g_CurrentMap, false) == 0)
					found = true;
			}
		}

		if (!found)
		{
			Format(display, sizeof(display), "%T", "ZNSI_MapNoLog", client, g_CurrentMap);
			menu.AddItem("", display, ITEMDRAW_DISABLED);
		}
	}

	for (int i = 0; i < g_FileList.Length; i++)
	{
		g_FileList.GetString(i, filename, sizeof(filename));

		int len = strlen(filename);
		int mapLen = len - SPCHECK_PREFIX_LEN - SPCHECK_SUFFIX_LEN;

		if (mapLen > 0)
		{
			strcopy(mapName, mapLen + 1 < sizeof(mapName) ? mapLen + 1 : sizeof(mapName), filename[SPCHECK_PREFIX_LEN]);
			strcopy(date, sizeof(date), filename[len - 9]); // MM-DD (skip YYYY-)

			bool isCurrent = (strcmp(mapName, g_CurrentMap, false) == 0);

			if (isCurrent)
				Format(display, sizeof(display), "%T", "ZNSI_MapCurrentEntry", client, mapName, date);
			else
				Format(display, sizeof(display), "%T", "ZNSI_MapEntry", client, mapName, date);
		}
		else
		{
			strcopy(display, sizeof(display), filename);
		}

		menu.AddItem(filename, display);
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_File(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char filename[PLATFORM_MAX_PATH];
		menu.GetItem(param2, filename, sizeof(filename));

		// Extract map name to check against current map
		int len = strlen(filename);
		int mapLen = len - SPCHECK_PREFIX_LEN - SPCHECK_SUFFIX_LEN;
		char mapName[64];
		if (mapLen > 0)
		{
			int safeLen = mapLen + 1 < sizeof(mapName) ? mapLen + 1 : sizeof(mapName);
			strcopy(mapName, safeLen, filename[SPCHECK_PREFIX_LEN]);
		}
		else
			strcopy(mapName, sizeof(mapName), filename);

		if (strcmp(mapName, g_CurrentMap, false) != 0)
		{
			strcopy(g_SelectedMap[param1], sizeof(g_SelectedMap[]), mapName);
			ShowConfirmMenu(param1, mapName);
			return 0;
		}

		if (!LoadFile(filename))
		{
			ShowDeleteMenu(param1, filename);
			return 0;
		}

		g_CurrentPos[param1] = -1;
		ShowNavMenu(param1);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

// ─── Delete log confirmation menu ────────────────────────────────────────────

// ─── Delete log confirmation menu ────────────────────────────────────────────

// Deletes all spchecker_<mapName>_*.log files. Returns count of deleted files.
int DeleteMapLogs(const char[] mapName)
{
	char prefix[128];
	Format(prefix, sizeof(prefix), "%s%s_", SPCHECK_PREFIX, mapName);
	int prefixLen = strlen(prefix);

	char logDir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, logDir, sizeof(logDir), "logs");

	DirectoryListing dir = OpenDirectory(logDir);
	if (dir == null)
		return 0;

	int deleted = 0;
	char filename[PLATFORM_MAX_PATH];
	char path[PLATFORM_MAX_PATH];
	FileType ft;

	while (dir.GetNext(filename, sizeof(filename), ft))
	{
		if (ft != FileType_File)
			continue;
		if (strncmp(filename, prefix, prefixLen, false) != 0)
			continue;
		int len = strlen(filename);
		if (len < 4 || strcmp(filename[len - 4], ".log", false) != 0)
			continue;

		BuildPath(Path_SM, path, sizeof(path), "logs/%s", filename);
		if (DeleteFile(path))
			deleted++;
	}

	delete dir;
	return deleted;
}

void ShowDeleteMenu(int client, const char[] filename)
{
	// Extract map name to use as item value — allows deleting all dated logs for this map
	int len = strlen(filename);
	int mapLen = len - SPCHECK_PREFIX_LEN - SPCHECK_SUFFIX_LEN;
	char mapName[64];
	if (mapLen > 0)
	{
		int safeLen = mapLen + 1 < sizeof(mapName) ? mapLen + 1 : sizeof(mapName);
		strcopy(mapName, safeLen, filename[SPCHECK_PREFIX_LEN]);
	}
	else
		strcopy(mapName, sizeof(mapName), filename);

	Menu menu = new Menu(MenuHandler_Delete);

	char title[128];
	Format(title, sizeof(title), "%T", "ZNSI_AllNavmesh", client);
	menu.SetTitle(title);
	menu.ExitButton = true;

	char yes[64], no[64];
	Format(yes, sizeof(yes), "%T", "ZNSI_DeleteYes", client);
	Format(no,  sizeof(no),  "%T", "ZNSI_DeleteNo",  client);
	menu.AddItem(mapName, yes); // map name stored as item value for multi-file deletion
	menu.AddItem("", no);

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Delete(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char mapName[64];
		menu.GetItem(param2, mapName, sizeof(mapName));

		if (strlen(mapName) > 0)
		{
			int count = DeleteMapLogs(mapName);
			if (count > 0)
				PrintToChat(param1, "%T", "ZNSI_DeleteSuccess", param1, count);
			else
				PrintToChat(param1, "%T", "ZNSI_DeleteFailed", param1);

			BuildFileList();
		}

		ShowFileMenu(param1);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

// ─── Map change confirmation menu ────────────────────────────────────────────

void ShowConfirmMenu(int client, const char[] mapName)
{
	Menu menu = new Menu(MenuHandler_Confirm);

	char title[128];
	Format(title, sizeof(title), "%T", "ZNSI_ConfirmTitle", client, mapName);
	menu.SetTitle(title);
	menu.ExitButton = true;

	char yes[64], no[64];
	Format(yes, sizeof(yes), "%T", "ZNSI_ConfirmYes", client);
	Format(no,  sizeof(no),  "%T", "ZNSI_ConfirmNo",  client);
	menu.AddItem("yes", yes);
	menu.AddItem("no",  no);

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Confirm(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char item[8];
		menu.GetItem(param2, item, sizeof(item));

		if (strcmp(item, "yes") == 0)
		{
			ServerCommand("changelevel %s", g_SelectedMap[param1]);
		}
		else
		{
			ShowFileMenu(param1);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

// ─── Navigation menu ─────────────────────────────────────────────────────────

void ShowNavMenu(int client)
{
	int total = g_PosCoords.Length;
	if (total == 0)
	{
		PrintToChat(client, "%T", "ZNSI_NoPositions", client);
		return;
	}

	int idx = g_CurrentPos[client];

	Menu menu = new Menu(MenuHandler_Nav);
	char title[192];

	if (idx < 0)
	{
		Format(title, sizeof(title), "%T", "ZNSI_NavTitleBegin", client, total);
	}
	else
	{
		float pos[3];
		g_PosCoords.GetArray(idx, pos, 3);

		char entityType[64];
		g_PosTypes.GetString(idx, entityType, sizeof(entityType));

		char coords[64];
		Format(coords, sizeof(coords), "%.2f %.2f %.2f", pos[0], pos[1], pos[2]);
		Format(title, sizeof(title), "%T", "ZNSI_NavTitle", client, idx + 1, total, entityType, coords);
	}

	menu.SetTitle(title);
	menu.ExitButton = true;

	char prev[32], next[32], back[48];
	Format(prev, sizeof(prev), "%T", "ZNSI_Previous", client);
	Format(next, sizeof(next), "%T", "ZNSI_Next",     client);
	Format(back, sizeof(back), "%T", "ZNSI_BackToList", client);

	menu.AddItem("prev", prev, idx > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("next", next, idx < total - 1 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED);
	menu.AddItem("files", back);

	menu.Display(client, MENU_TIME_FOREVER);
}

public int MenuHandler_Nav(Menu menu, MenuAction action, int param1, int param2)
{
	if (action == MenuAction_Select)
	{
		char item[16];
		menu.GetItem(param2, item, sizeof(item));

		if (strcmp(item, "prev") == 0)
		{
			if (GetGameTime() - g_LastTeleport[param1] >= TELEPORT_COOLDOWN)
			{
				if (g_CurrentPos[param1] > 0)
					g_CurrentPos[param1]--;

				float pos[3];
				g_PosCoords.GetArray(g_CurrentPos[param1], pos, 3);
				TeleportEntity(param1, pos, NULL_VECTOR, NULL_VECTOR);
				g_LastTeleport[param1] = GetGameTime();
			}
			ShowNavMenu(param1);
		}
		else if (strcmp(item, "next") == 0)
		{
			if (GetGameTime() - g_LastTeleport[param1] >= TELEPORT_COOLDOWN)
			{
				if (g_CurrentPos[param1] < g_PosCoords.Length - 1)
					g_CurrentPos[param1]++;

				float pos[3];
				g_PosCoords.GetArray(g_CurrentPos[param1], pos, 3);
				TeleportEntity(param1, pos, NULL_VECTOR, NULL_VECTOR);
				g_LastTeleport[param1] = GetGameTime();
			}
			ShowNavMenu(param1);
		}
		else if (strcmp(item, "files") == 0)
		{
			ShowFileMenu(param1);
		}
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}
