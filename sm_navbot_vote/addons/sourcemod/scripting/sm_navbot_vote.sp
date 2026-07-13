#pragma semicolon 1
#include <sourcemod>

#pragma newdecls required

#define PLUGIN_VERSION "1.2.0"
#define VOTE_YES "Yes"
#define VOTE_NO "No"

ConVar g_hCvarVersion;
ConVar g_hCvarCooldown;
ConVar g_hCvarPercent;
ConVar g_hCvarRestoreTarget;

int g_iLastVoteTime = 0;
bool g_bEnableMode = false;

public Plugin myinfo =
{
	name = "NavBot Vote",
	author = "Claude.ai guided by DNA.styx",
	description = "Allows players to vote to disable or re-enable the NavBot quota system and remove/add active bots",
	version = PLUGIN_VERSION,
	url = ""
};

public void OnPluginStart()
{
	g_hCvarVersion = CreateConVar("sm_navbot_vote_version", PLUGIN_VERSION, "NavBot Vote plugin version.", FCVAR_NOTIFY|FCVAR_DONTRECORD);
	#pragma unused g_hCvarVersion
	g_hCvarCooldown = CreateConVar("sm_navbot_vote_cooldown", "300.0", "Cooldown in seconds between vote attempts.", FCVAR_PROTECTED, true, 0.0);
	g_hCvarPercent = CreateConVar("sm_navbot_vote_percent", "0.60", "Fraction of Yes votes required to pass (0.05 - 1.0).", FCVAR_PROTECTED, true, 0.05, true, 1.0);
	g_hCvarRestoreTarget = CreateConVar("sm_navbot_vote_restore_target", "10", "sm_navbot_quota_target value to restore when a vote re-enables bots.", FCVAR_PROTECTED, true, 0.0);

	AutoExecConfig(true, "sm_navbot_vote");

	RegConsoleCmd("sm_navbot_vote", Command_VoteBots, "Starts a vote to disable or re-enable NavBot bots.");

	AddCommandListener(Listener_Say, "say");
	AddCommandListener(Listener_Say, "say_team");
}

public Action Listener_Say(int client, const char[] command, int args)
{
	if (client == 0 || args < 1)
	{
		return Plugin_Continue;
	}

	char text[256];
	GetCmdArgString(text, sizeof(text));
	StripQuotes(text);
	TrimString(text);

	if (StrEqual(text, "!bots", false))
	{
		TryStartVote(client);
	}

	return Plugin_Continue;
}

public Action Command_VoteBots(int client, int args)
{
	TryStartVote(client);
	return Plugin_Handled;
}

void TryStartVote(int client)
{
	if (IsVoteInProgress())
	{
		PrintToChat(client, "[SM] A vote is already in progress.");
		return;
	}

	ConVar hQuotaTarget = FindConVar("sm_navbot_quota_target");
	if (hQuotaTarget == null)
	{
		PrintToChat(client, "[SM] sm_navbot_quota_target not found. Is NavBot loaded?");
		return;
	}

	if (hQuotaTarget.IntValue <= -1)
	{
		g_bEnableMode = true;
	}
	else
	{
		g_bEnableMode = false;
	}

	int cooldown = RoundToNearest(g_hCvarCooldown.FloatValue);
	int timeLeft = (g_iLastVoteTime + cooldown) - GetTime();
	if (g_iLastVoteTime != 0 && timeLeft > 0)
	{
		PrintToChat(client, "[SM] Vote to change bots is on cooldown for %d more second(s).", timeLeft);
		return;
	}

	g_iLastVoteTime = GetTime();

	Menu hVoteMenu = new Menu(Handler_VoteBotsMenu, MENU_ACTIONS_ALL);
	hVoteMenu.SetTitle(g_bEnableMode ? "Add bots back?" : "Disable bots?");
	hVoteMenu.AddItem(VOTE_YES, "Yes");
	hVoteMenu.AddItem(VOTE_NO, "No");
	hVoteMenu.ExitButton = false;

	LogAction(client, -1, "\"%L\" initiated a vote to %s bots.", client, g_bEnableMode ? "add" : "disable");
	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	ShowActivity2(client, "[SM] ", "%s initiated a vote to %s bots.", name, g_bEnableMode ? "add" : "disable");

	hVoteMenu.DisplayVoteToAll(20);
}

public int Handler_VoteBotsMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_VoteEnd:
		{
			char item[16];
			int votes, totalVotes;
			GetMenuVoteInfo(param2, votes, totalVotes);
			menu.GetItem(param1, item, sizeof(item));

			float percent = totalVotes > 0 ? (float(votes) / float(totalVotes)) : 0.0;
			float limit = g_hCvarPercent.FloatValue;

			if (StrEqual(item, VOTE_YES) && percent >= limit)
			{
				ConVar hQuotaTarget = FindConVar("sm_navbot_quota_target");

				if (g_bEnableMode)
				{
					int restoreTarget = g_hCvarRestoreTarget.IntValue;
					if (hQuotaTarget != null)
					{
						hQuotaTarget.SetInt(restoreTarget);
					}

					PrintToChatAll("[SM] Vote passed. Bots re-enabled (target: %d). (%d%% of %d votes)", restoreTarget, RoundToNearest(100.0 * percent), totalVotes);
					LogAction(-1, -1, "Vote to add bots passed. sm_navbot_quota_target set to %d. (%d%% of %d votes)", restoreTarget, RoundToNearest(100.0 * percent), totalVotes);
				}
				else
				{
					if (hQuotaTarget != null)
					{
						hQuotaTarget.SetInt(-1);
					}

					ServerCommand("sm_kick @bots \"Bots disabled by vote\"");

					PrintToChatAll("[SM] Vote passed. Bots disabled and removed. (%d%% of %d votes)", RoundToNearest(100.0 * percent), totalVotes);
					LogAction(-1, -1, "Vote to disable bots passed. sm_navbot_quota_target set to -1, sm_kick @bots issued. (%d%% of %d votes)", RoundToNearest(100.0 * percent), totalVotes);
				}
			}
			else
			{
				PrintToChatAll("[SM] Vote failed. %d%% required, received %d%% of %d votes.", RoundToNearest(100.0 * limit), RoundToNearest(100.0 * percent), totalVotes);
				LogAction(-1, -1, "Vote to %s bots failed. %d%% required, received %d%% of %d votes.", g_bEnableMode ? "add" : "disable", RoundToNearest(100.0 * limit), RoundToNearest(100.0 * percent), totalVotes);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}
