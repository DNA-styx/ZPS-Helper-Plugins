#pragma semicolon 1
#include <sourcemod>

#pragma newdecls required

#define PLUGIN_VERSION "1.3.0"
#define VOTE_YES "Yes"
#define VOTE_NO "No"
#define SKILL_COUNT 4

char g_sSkillNames[SKILL_COUNT][12] = { "Easy", "Normal", "Hard", "Expert" };

ConVar g_hCvarVersion;
ConVar g_hCvarCooldown;
ConVar g_hCvarPercent;
ConVar g_hCvarRestoreTarget;

int g_iLastVoteTime = 0;
bool g_bEnableMode = false;
int g_iRequestedSkill = 0;

public Plugin myinfo =
{
	name = "NavBot Vote",
	author = "Claude.ai guided by DNA.styx",
	description = "Allows players to vote to disable/re-enable NavBot bots or change the bot skill level",
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

	RegConsoleCmd("sm_navbot_vote", Command_VoteBots, "Opens the NavBot vote menu (bot count / skill level).");

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
		ShowTopMenu(client);
	}

	return Plugin_Continue;
}

public Action Command_VoteBots(int client, int args)
{
	ShowTopMenu(client);
	return Plugin_Handled;
}

void ShowTopMenu(int client)
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

	bool botsDisabled = hQuotaTarget.IntValue <= -1;

	Menu hTopMenu = new Menu(Handler_TopMenu);
	hTopMenu.SetTitle("NavBot Vote");
	hTopMenu.AddItem("botcount", botsDisabled ? "Add Bots" : "Remove Bots");
	hTopMenu.AddItem("skill", "Change Skill");
	hTopMenu.ExitButton = true;

	hTopMenu.Display(client, 15);
}

public int Handler_TopMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[16];
			menu.GetItem(param2, info, sizeof(info));

			if (StrEqual(info, "botcount"))
			{
				TryStartBotCountVote(param1);
			}
			else if (StrEqual(info, "skill"))
			{
				ShowSkillMenu(param1);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}

void ShowSkillMenu(int client)
{
	if (IsVoteInProgress())
	{
		PrintToChat(client, "[SM] A vote is already in progress.");
		return;
	}

	ConVar hSkillLevel = FindConVar("sm_navbot_skill_level");
	if (hSkillLevel == null)
	{
		PrintToChat(client, "[SM] sm_navbot_skill_level not found. Is NavBot loaded?");
		return;
	}

	int currentSkill = hSkillLevel.IntValue;

	Menu hSkillMenu = new Menu(Handler_SkillMenu);
	hSkillMenu.SetTitle("Change Bot Skill");

	for (int i = 0; i < SKILL_COUNT; i++)
	{
		char info[4];
		IntToString(i, info, sizeof(info));

		if (i == currentSkill)
		{
			char display[32];
			Format(display, sizeof(display), "%s (current)", g_sSkillNames[i]);
			hSkillMenu.AddItem(info, display, ITEMDRAW_DISABLED);
		}
		else
		{
			hSkillMenu.AddItem(info, g_sSkillNames[i]);
		}
	}

	hSkillMenu.ExitButton = true;
	hSkillMenu.Display(client, 15);
}

public int Handler_SkillMenu(Menu menu, MenuAction action, int param1, int param2)
{
	switch (action)
	{
		case MenuAction_Select:
		{
			char info[4];
			menu.GetItem(param2, info, sizeof(info));
			int requestedSkill = StringToInt(info);
			TryStartSkillVote(param1, requestedSkill);
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}

void TryStartSkillVote(int client, int requestedSkill)
{
	if (IsVoteInProgress())
	{
		PrintToChat(client, "[SM] A vote is already in progress.");
		return;
	}

	if (requestedSkill < 0 || requestedSkill >= SKILL_COUNT)
	{
		return;
	}

	ConVar hSkillLevel = FindConVar("sm_navbot_skill_level");
	if (hSkillLevel == null)
	{
		PrintToChat(client, "[SM] sm_navbot_skill_level not found. Is NavBot loaded?");
		return;
	}

	int currentSkill = hSkillLevel.IntValue;

	int cooldown = RoundToNearest(g_hCvarCooldown.FloatValue);
	int timeLeft = (g_iLastVoteTime + cooldown) - GetTime();
	if (g_iLastVoteTime != 0 && timeLeft > 0)
	{
		PrintToChat(client, "[SM] Vote to change bot skill is on cooldown for %d more second(s).", timeLeft);
		return;
	}

	g_iLastVoteTime = GetTime();
	g_iRequestedSkill = requestedSkill;

	char currentName[12];
	strcopy(currentName, sizeof(currentName), (currentSkill >= 0 && currentSkill < SKILL_COUNT) ? g_sSkillNames[currentSkill] : "Unknown");

	char voteTitle[64];
	Format(voteTitle, sizeof(voteTitle), "Change bot skill from %s to %s?", currentName, g_sSkillNames[requestedSkill]);

	Menu hVoteMenu = new Menu(Handler_SkillVoteMenu, MENU_ACTIONS_ALL);
	hVoteMenu.SetTitle(voteTitle);
	hVoteMenu.AddItem(VOTE_YES, "Yes");
	hVoteMenu.AddItem(VOTE_NO, "No");
	hVoteMenu.ExitButton = false;

	LogAction(client, -1, "\"%L\" initiated a vote to change bot skill from %s to %s.", client, currentName, g_sSkillNames[requestedSkill]);
	char name[MAX_NAME_LENGTH];
	GetClientName(client, name, sizeof(name));
	ShowActivity2(client, "[SM] ", "%s initiated a vote to change bot skill to %s.", name, g_sSkillNames[requestedSkill]);

	hVoteMenu.DisplayVoteToAll(20);
}

public int Handler_SkillVoteMenu(Menu menu, MenuAction action, int param1, int param2)
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

			char requestedName[12];
			strcopy(requestedName, sizeof(requestedName), (g_iRequestedSkill >= 0 && g_iRequestedSkill < SKILL_COUNT) ? g_sSkillNames[g_iRequestedSkill] : "Unknown");

			if (StrEqual(item, VOTE_YES) && percent >= limit)
			{
				ConVar hSkillLevel = FindConVar("sm_navbot_skill_level");
				if (hSkillLevel != null)
				{
					hSkillLevel.SetInt(g_iRequestedSkill);
				}

				ServerCommand("sm_navbot_reload_difficulty_profiles");

				PrintToChatAll("[SM] Vote passed. Bot skill changed to %s. (%d%% of %d votes)", requestedName, RoundToNearest(100.0 * percent), totalVotes);
				LogAction(-1, -1, "Vote to change bot skill passed. sm_navbot_skill_level set to %d (%s), sm_navbot_reload_difficulty_profiles issued. (%d%% of %d votes)", g_iRequestedSkill, requestedName, RoundToNearest(100.0 * percent), totalVotes);
			}
			else
			{
				PrintToChatAll("[SM] Vote failed. %d%% required, received %d%% of %d votes.", RoundToNearest(100.0 * limit), RoundToNearest(100.0 * percent), totalVotes);
				LogAction(-1, -1, "Vote to change bot skill to %s failed. %d%% required, received %d%% of %d votes.", requestedName, RoundToNearest(100.0 * limit), RoundToNearest(100.0 * percent), totalVotes);
			}
		}
		case MenuAction_End:
		{
			delete menu;
		}
	}

	return 0;
}

void TryStartBotCountVote(int client)
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
