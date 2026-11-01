#include <sourcemod>
#include <sdktools>
#include <navbot>

#pragma newdecls required
#pragma semicolon 1

#define PLUGIN_VERSION "0.1.2"

public Plugin myinfo =
{
	name = "ZPS NavBot Unstuck",
	author = "Claude.ai guided by DNA.styx",
	description = "Makes stuck zombie NavBots crouch and/or jump to get past props.",
	version = PLUGIN_VERSION,
	url = "https://github.com/DNA-styx/navbot-plugins"
};

enum ZPSTeam
{
	ZPS_TEAM_UNASSIGNED = 0,
	ZPS_TEAM_SPECTATOR,
	ZPS_TEAM_SURVIVORS,
	ZPS_TEAM_ZOMBIES,

	MAX_ZPS_TEAMS
};

ConVar cvar_enabled = null;
ConVar cvar_crouch_count = null;
ConVar cvar_jump_count = null;
ConVar cvar_alternate_count = null;
ConVar cvar_crouch_duration = null;
ConVar cvar_debug = null;
char g_logfile[PLATFORM_MAX_PATH];

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	char gamefolder[16];
	GetGameFolderName(gamefolder, sizeof(gamefolder));

	if (strcmp(gamefolder, "zps") == 0)
	{
		return APLRes_Success;
	}

	strcopy(error, err_max, "This plugin is for Zombie Panic! Source only!");
	return APLRes_SilentFailure;
}

public void OnPluginStart()
{
	CreateConVar("sm_navbot_zunstuck_version", PLUGIN_VERSION, "Plugin version.", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	cvar_enabled = CreateConVar("sm_navbot_zunstuck_enabled", "1", "Enables/Disables the plugin.", _, true, 0.0, true, 1.0);
	cvar_crouch_count = CreateConVar("sm_navbot_zunstuck_crouch_count", "3", "Consecutive stuck events before the bot crouches. 0 disables this stage.", _, true, 0.0, true, 60.0);
	cvar_jump_count = CreateConVar("sm_navbot_zunstuck_jump_count", "6", "Consecutive stuck events before the bot also jumps while crouched. 0 disables this stage.", _, true, 0.0, true, 60.0);
	cvar_alternate_count = CreateConVar("sm_navbot_zunstuck_alternate_count", "10", "Consecutive stuck events before the bot alternates between crouch jumping and standing jumping. 0 disables this stage.", _, true, 0.0, true, 60.0);
	cvar_crouch_duration = CreateConVar("sm_navbot_zunstuck_crouch_duration", "1.5", "How long in seconds each stuck event keeps the crouch button held. Stuck events happen once per second.", _, true, 0.25, true, 5.0);
	cvar_debug = CreateConVar("sm_navbot_zunstuck_debug", "0", "Logs the action taken for each stuck event.", _, true, 0.0, true, 1.0);

	BuildPath(Path_SM, g_logfile, sizeof(g_logfile), "logs/zps_navbot_unstuck.log");

	AutoExecConfig(true, "zps_navbot_unstuck");
}

/*
* Stuck events fire once per second and the count is consecutive events.
* NavBot's own unstuck routine runs before this forward, so any crouch jump it
* started is already pressed by the time this function adjusts the buttons.
*/
public void OnNavBotStuck(NavBot bot, int count)
{
	if (!cvar_enabled.BoolValue)
	{
		return;
	}

	if (!bot.IsAlive || bot.TeamNum != view_as<int>(ZPS_TEAM_ZOMBIES))
	{
		return;
	}

	int crouchAt = cvar_crouch_count.IntValue;
	int jumpAt = cvar_jump_count.IntValue;
	int alternateAt = cvar_alternate_count.IntValue;
	bool crouch = false;
	bool jump = false;

	if (alternateAt > 0 && count >= alternateAt)
	{
		// Even steps crouch jump, odd steps stand jump.
		crouch = ((count - alternateAt) % 2) == 0;
		jump = true;
	}
	else
	{
		if (crouchAt > 0 && count >= crouchAt)
		{
			crouch = true;
		}

		if (crouch && jumpAt > 0 && count >= jumpAt)
		{
			jump = true;
		}
	}

	if (!crouch && !jump)
	{
		return;
	}

	Address controller = bot.GetPlayerControllerInterface();

	if (controller == Address_Null)
	{
		return;
	}

	if (crouch)
	{
		NavBotPlayerControllerInterface.PressButtonByID(controller, NAVBOT_BUTTON_CROUCH, cvar_crouch_duration.FloatValue);
	}
	else
	{
		NavBotPlayerControllerInterface.ReleaseButtonByID(controller, NAVBOT_BUTTON_CROUCH);
	}

	if (jump)
	{
		// Negative duration taps the button.
		NavBotPlayerControllerInterface.PressButtonByID(controller, NAVBOT_BUTTON_JUMP, -1.0);
	}

	if (cvar_debug.BoolValue)
	{
		LogToFile(g_logfile, "Zombie \"%L\" stuck event %i: crouch=%s jump=%s", bot.Index, count, crouch ? "yes" : "no", jump ? "yes" : "no");
	}
}
