bool ApplyQuota(int fixedValue, int target)
{
    ConVar cvFixed = FindConVar("sm_navbot_quota_fixed");
    ConVar cvTarget = FindConVar("sm_navbot_quota_target");

    if (cvFixed == null || cvTarget == null)
    {
        LogError("[Bot Zombie Horde] sm_navbot_quota_fixed/target not found, skipping.");
        return false;
    }

    cvFixed.SetInt(fixedValue);
    cvTarget.SetInt(target);
    return true;
}

Action Timer_HordeWave(Handle timer)
{
    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        g_hWaveTimer = null;
        return Plugin_Stop;
    }

    ConVar cvTarget = FindConVar("sm_navbot_quota_target");
    if (cvTarget == null)
    {
        LogError("[Bot Zombie Horde] sm_navbot_quota_target not found, stopping wave timer.");
        g_hWaveTimer = null;
        return Plugin_Stop;
    }

    int humanSurvivorCount = CountHumanSurvivors();
    int oldTarget = cvTarget.IntValue;
    int cap = GetZombieCap();

    int newTarget = oldTarget + humanSurvivorCount;
    if (newTarget > cap)
    {
        newTarget = cap;
    }

    if (newTarget != oldTarget)
    {
        cvTarget.SetInt(newTarget);

        if (newTarget > oldTarget)
        {
            MessagePlayers("Horde Wave", newTarget);
        }

        if (g_cvDebug.BoolValue)
        {
            LogMessage("[Bot Zombie Horde] Wave. Survivors: %d. Cap: %d. Quota target: %d -> %d.",
                humanSurvivorCount, cap, oldTarget, newTarget);
        }
    }

    // Keep running at the cap so the target follows players joining and leaving.
    return Plugin_Continue;
}

// Counts players, spectators and SourceTV, and keeps one slot free.
int GetBotCap()
{
    int others = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientConnected(client))
        {
            continue;
        }

        if (IsClientInGame(client) && NavBotManager.IsNavBot(client))
        {
            continue;
        }

        others++;
    }

    int cap = MaxClients - 1 - others;
    return (cap < 0) ? 0 : cap;
}

// Free-slot cap, further limited by zombies per real survivor when set.
// Never below the starting 2, so the round can still run.
int GetZombieCap()
{
    int cap = GetBotCap();
    int perPlayer = GetZombiesPerPlayer();

    if (perPlayer > 0)
    {
        int playerCap = perPlayer * CountHumanSurvivors();
        if (playerCap < 2)
        {
            playerCap = 2;
        }

        if (playerCap < cap)
        {
            cap = playerCap;
        }
    }

    return cap;
}

void ClampQuotaToCap()
{
    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        return;
    }

    ConVar cvFixed = FindConVar("sm_navbot_quota_fixed");
    ConVar cvTarget = FindConVar("sm_navbot_quota_target");

    // Only fixed mode counts bots alone; leave normal fill mode untouched.
    if (cvFixed == null || cvTarget == null || cvFixed.IntValue != 1)
    {
        return;
    }

    int cap = GetZombieCap();
    if (cvTarget.IntValue > cap)
    {
        if (g_cvDebug.BoolValue)
        {
            LogMessage("[Bot Zombie Horde] Quota target lowered %d -> %d.",
                cvTarget.IntValue, cap);
        }

        cvTarget.SetInt(cap);
    }
}
