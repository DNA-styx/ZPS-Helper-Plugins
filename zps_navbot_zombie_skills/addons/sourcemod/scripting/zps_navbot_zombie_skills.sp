#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <navbot>

#define PLUGIN_VERSION "0.8.0"
#define TEAM_SURVIVOR 2
#define TEAM_ZOMBIE   3

ConVar g_hSpotSuitPowerMin;
ConVar g_hCheckInterval;
ConVar g_hSkillCooldown;

char g_sLogPath[PLATFORM_MAX_PATH];
float g_flNextSkillAttempt[MAXPLAYERS + 1];

public Plugin myinfo =
{
	name = "ZPS NavBot Carrier Skills",
	author = "Claude.ai guided by DNA.styx",
	description = "Activates the Carrier zombie Spot skill for NavBot-controlled carriers",
	version = PLUGIN_VERSION,
	url = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
	CreateConVar("sm_zps_navbot_carrier_skills_version", PLUGIN_VERSION, "ZPS NavBot Carrier Skills version", FCVAR_NOTIFY | FCVAR_DONTRECORD);

	// 35% confirmed engine requirement (player_data/carrier_spot_required_fom).
	g_hSpotSuitPowerMin = CreateConVar("sm_zps_navbot_carrier_spot_suitpower_min", "35.0", "Minimum Feed-O-Meter to attempt Spot", FCVAR_PROTECTED);
	g_hCheckInterval    = CreateConVar("sm_zps_navbot_carrier_spot_interval", "2.0", "Seconds between carrier eligibility checks", FCVAR_PROTECTED);
	g_hSkillCooldown    = CreateConVar("sm_zps_navbot_carrier_skill_cooldown", "30.0", "Seconds between Spot attempts", FCVAR_PROTECTED);

	AutoExecConfig(true, "zps_navbot_carrier_skills");
	BuildPath(Path_SM, g_sLogPath, sizeof(g_sLogPath), "logs/zps_navbot_carrier_skills.log");


	HookEvent("clientsound_player", Event_ClientSoundPlayer);
}

public void OnMapStart()
{
	for (int i = 0; i <= MaxClients; i++)
		g_flNextSkillAttempt[i] = 0.0;

	CreateTimer(g_hCheckInterval.FloatValue, Timer_CheckCarriers, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public Action Timer_CheckCarriers(Handle timer)
{
	float now      = GetGameTime();
	float spotMin  = g_hSpotSuitPowerMin.FloatValue;
	float cooldown = g_hSkillCooldown.FloatValue;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsFakeClient(i) || !IsPlayerAlive(i))
			continue;

		if (GetClientTeam(i) != TEAM_ZOMBIE || !IsCarrierByWeapon(i))
			continue;

		if (now < g_flNextSkillAttempt[i])
			continue;

		// 35% is the confirmed engine minimum for Spot.
		float suitPower = GetEntPropFloat(i, Prop_Send, "m_flSuitPower");
		if (suitPower < spotMin)
			continue;

		NavBot bot = view_as<NavBot>(i);
		Address controller = bot.GetPlayerControllerInterface();
		if (controller == Address_Null)
			continue;

		int target = FindVisibleSurvivor(i, bot);
		if (target == -1)
			continue;

		LogToFileEx(g_sLogPath, "%L attempting Spot on %L (m_flSuitPower=%.1f)", i, target, suitPower);
		NavBotPlayerControllerInterface.AimAtEntity(controller, target, LOOK_USE, 1.0, "Carrier Spot target");
		NavBotPlayerControllerInterface.PressButtonByID(controller, NAVBOT_BUTTON_USE, 0.2);

		g_flNextSkillAttempt[i] = now + cooldown;
	}

	return Plugin_Continue;
}

// Carrier detection via active weapon
bool IsCarrierByWeapon(int client)
{
	int weapon = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	if (weapon == -1 || !IsValidEntity(weapon))
		return false;

	char classname[32];
	GetEntityClassname(weapon, classname, sizeof(classname));
	return StrEqual(classname, "weapon_carrierarms");
}

// Nearest survivor the bot can actually see. No range cutoff - DoCarrierSpot() enforces its
// own fixed hull check server-side and no-ops if out of range.
int FindVisibleSurvivor(int carrier, NavBot bot)
{
	Address sensor = bot.GetSensorInterface();
	if (sensor == Address_Null)
		return -1;

	float carrierPos[3];
	GetClientAbsOrigin(carrier, carrierPos);

	int best = -1;
	float bestDist = 0.0;

	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientInGame(i) || !IsPlayerAlive(i) || GetClientTeam(i) != TEAM_SURVIVOR)
			continue;

		if (!NavBotSensorInterface.IsAbleToSeeEntity(sensor, i, true))
			continue;

		float pos[3];
		GetClientAbsOrigin(i, pos);
		float dist = GetVectorDistance(carrierPos, pos, true); // squared - avoids sqrt

		if (best == -1 || dist < bestDist)
		{
			bestDist = dist;
			best = i;
		}
	}

	return best;
}

public void Event_ClientSoundPlayer(Event event, const char[] name, bool dontBroadcast)
{
	char sound[64];
	event.GetString("sound", sound, sizeof(sound));

	// Cheap reject: this event fires for every player sound, very few are carrier sounds.
	if (StrContains(sound, "Carrier", false) == -1)
		return;

	// Roar detection retained deliberately: the plugin no longer triggers Roar, so any
	// CONFIRMED Roar line here comes from a human carrier - which validates that the hook
	// can see Roar at all, the outstanding test from the failed bot Roar work.
	bool isSpot = (StrContains(sound, "Carrier_Action.Spotted", false) != -1);
	bool isRoar = (StrContains(sound, "Carrier.Roar", false) != -1 || StrContains(sound, "Carrier_Action.Roar", false) != -1);

	if (!isSpot && !isRoar)
		return;

	int client = event.GetInt("entindex"); // raw client index, not a userid
	if (client < 1 || client > MaxClients || !IsClientInGame(client))
		return;

	LogToFileEx(g_sLogPath, "CONFIRMED: %L triggered %s (sound=%s)", client, isSpot ? "Spot" : "Roar", sound);
}
