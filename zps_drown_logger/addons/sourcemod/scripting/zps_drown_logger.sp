/**
 * zps_drown_logger.sp
 * Logs bot survivor drowning deaths to the SourceMod log for NavMesh analysis.
 * Output is parsed by the Navbot StuckBot Visualiser web tool.
 *
 * Log format:
 *   [ZPS-Drown] Survivor "BotName" drowned. X.XX Y.YY Z.ZZ
 *
 * Detection criteria:
 *   - player_feed event
 *   - weapon == "worldspawn"
 *   - dmgbits == 16384 (DMG_DROWN)
 *   - attacker == 0 (world kill)
 *   - victim is a fake client (bot)
 *   - victim is on survivor team (team 2)
 */

#include <sourcemod>

#define PLUGIN_VERSION  "1.0.0"
#define DMG_DROWN       16384
#define TEAM_SURVIVOR   2

public Plugin myinfo =
{
    name        = "ZPS Drown Logger",
    author      = "Claude.ai guided by DNA.styx",
    description = "Logs bot survivor drowning deaths for NavMesh analysis.",
    version     = PLUGIN_VERSION,
    url         = "https://github.com/DNA-styx/ZPS-Helper-Plugins"
};

public void OnPluginStart()
{
    CreateConVar("zps_drown_logger_version", PLUGIN_VERSION,
        "ZPS Drown Logger version",
        FCVAR_NOTIFY | FCVAR_DONTRECORD);

    HookEvent("player_feed", Event_PlayerFeed, EventHookMode_Post);
}

public void Event_PlayerFeed(Event event, const char[] name, bool dontBroadcast)
{
    if (!event.GetBool("death"))
        return;

    if (event.GetInt("attacker") != 0)
        return;

    if (event.GetInt("dmgbits") != DMG_DROWN)
        return;

    char weapon[64];
    event.GetString("weapon", weapon, sizeof(weapon));
    if (!StrEqual(weapon, "worldspawn"))
        return;

    int victim = GetClientOfUserId(event.GetInt("userid"));
    if (victim <= 0 || !IsClientInGame(victim))
        return;

    if (!IsFakeClient(victim))
        return;

    if (GetClientTeam(victim) != TEAM_SURVIVOR)
        return;

    float pos[3];
    GetClientAbsOrigin(victim, pos);

    char clientName[MAX_NAME_LENGTH];
    GetClientName(victim, clientName, sizeof(clientName));

    LogMessage("[ZPS-Drown] Survivor \"%s\" drowned. %.2f %.2f %.2f",
        clientName, pos[0], pos[1], pos[2]);
}
