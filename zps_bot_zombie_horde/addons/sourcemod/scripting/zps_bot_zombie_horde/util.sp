// A map entry is either "map" "1" or a block of keys overriding the cvars.
bool LoadMapSettings()
{
    g_fMapFreezeDuration = -1.0;
    g_iMapZombiesPerPlayer = -1;

    char mapName[64];
    GetCurrentMap(mapName, sizeof(mapName));
    GetMapDisplayName(mapName, mapName, sizeof(mapName));

    char path[PLATFORM_MAX_PATH];
    BuildPath(Path_SM, path, sizeof(path), "configs/zps_bot_zombie_horde/zps_bot_zombie_horde_maps.cfg");

    if (!FileExists(path))
    {
        return false;
    }

    KeyValues kv = new KeyValues("Maps");
    bool enabled = false;

    if (kv.ImportFromFile(path) && kv.JumpToKey(mapName))
    {
        if (kv.GotoFirstSubKey(false))
        {
            kv.GoBack();
            enabled = true;
            g_fMapFreezeDuration = kv.GetFloat("freeze", -1.0);
            g_iMapZombiesPerPlayer = kv.GetNum("zombies_per_player", -1);
        }
        else
        {
            enabled = kv.GetNum(NULL_STRING, 0) != 0;
        }
    }

    delete kv;
    return enabled;
}

float GetFreezeDuration()
{
    return (g_fMapFreezeDuration >= 0.0) ? g_fMapFreezeDuration : g_cvFreezeDuration.FloatValue;
}

int GetZombiesPerPlayer()
{
    return (g_iMapZombiesPerPlayer >= 0) ? g_iMapZombiesPerPlayer : g_cvZombiesPerPlayer.IntValue;
}

void ApplyNavBotSkillLevel()
{
    int level = g_bMapEnabled ? g_cvHordeSkillLevel.IntValue : g_cvDefaultSkillLevel.IntValue;
    g_cvNavBotSkillLevel.SetInt(level);
}

int CountHumanSurvivors()
{
    int count = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        if (GetClientTeam(client) == TEAM_SURVIVOR)
        {
            count++;
        }
    }

    return count;
}

void MessagePlayers(const char[] phrase, int value = -1)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client))
        {
            continue;
        }

        int team = GetClientTeam(client);
        if ((team != TEAM_SURVIVOR && team != TEAM_ZOMBIE) || !IsPlayerAlive(client))
        {
            continue;
        }

        if (value == -1)
        {
            PrintCenterText(client, "%T", phrase, client);
        }
        else
        {
            PrintCenterText(client, "%T", phrase, client, value);
        }
    }
}
