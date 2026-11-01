Action Timer_HordeRoundStart(Handle timer)
{
    g_hRoundTimer = null;

    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        return Plugin_Handled;
    }

    int humanSurvivorCount = CountHumanSurvivors();
    int target = 2;

    if (humanSurvivorCount > 1)
    {
        GroupHumanSurvivors();
    }

    KillSurvivorBots();

    g_bRoundStarted = true;

    if (ApplyQuota(1, target) && g_cvDebug.BoolValue)
    {
        LogMessage("[Bot Zombie Horde] Round start. Survivors: %d. Quota target: %d.",
            humanSurvivorCount, target);
    }

    ClampQuotaToCap();

    float freeze = GetFreezeDuration();
    delete g_hFreezeWarningTimer;
    delete g_hWaveDelayTimer;

    if (freeze <= 0.0)
    {
        g_hWaveDelayTimer = CreateTimer(0.1, Timer_HordeWaveBegin, _, TIMER_FLAG_NO_MAPCHANGE);
        return Plugin_Handled;
    }

    if (humanSurvivorCount > 0)
    {
        MessagePlayers("Horde Prepare", RoundToNearest(freeze));
    }

    StartFreezePoll(freeze);

    float warnDelay = freeze - g_cvUnfreezeWarningSeconds.FloatValue;
    if (warnDelay > 0.0)
    {
        g_hFreezeWarningTimer = CreateTimer(warnDelay, Timer_UnfreezeWarning, _, TIMER_FLAG_NO_MAPCHANGE);
    }

    g_hWaveDelayTimer = CreateTimer(freeze, Timer_HordeWaveBegin, _, TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Handled;
}

Action Timer_UnfreezeWarning(Handle timer)
{
    g_hFreezeWarningTimer = null;

    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        return Plugin_Handled;
    }

    MessagePlayers("Horde Unfreeze Warning", RoundToNearest(g_cvUnfreezeWarningSeconds.FloatValue));
    return Plugin_Handled;
}

Action Timer_HordeWaveBegin(Handle timer)
{
    g_hWaveDelayTimer = null;

    if (!g_bMapEnabled || !g_cvEnabled.BoolValue)
    {
        return Plugin_Handled;
    }

    MessagePlayers("Horde Wave Start");

    delete g_hWaveTimer;
    g_hWaveTimer = CreateTimer(g_cvWaveInterval.FloatValue, Timer_HordeWave, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);

    return Plugin_Handled;
}

// ZPS teammates pass through each other, so sharing the anchor's spot is safe.
void GroupHumanSurvivors()
{
    int anchor = 0;
    float origin[3];
    float noVelocity[3];

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
        {
            continue;
        }

        if (GetClientTeam(client) != TEAM_SURVIVOR)
        {
            continue;
        }

        if (anchor == 0)
        {
            anchor = client;
            GetClientAbsOrigin(anchor, origin);
            continue;
        }

        TeleportEntity(client, origin, NULL_VECTOR, noVelocity);

        if (g_cvDebug.BoolValue)
        {
            LogMessage("[Bot Zombie Horde] Moved survivor %d to anchor %d.", client, anchor);
        }
    }
}

void KillSurvivorBots()
{
    int survivorBots[MAXPLAYERS + 1];
    int botCount = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client))
        {
            continue;
        }

        if (GetClientTeam(client) == TEAM_SURVIVOR && IsPlayerAlive(client))
        {
            survivorBots[botCount] = client;
            botCount++;
        }
    }

    // With no human survivors, leave one bot so the round does not end instantly.
    if (CountHumanSurvivors() == 0 && botCount > 0)
    {
        botCount--;
    }

    for (int i = 0; i < botCount; i++)
    {
        ForcePlayerSuicide(survivorBots[i]);
    }

    if (g_cvDebug.BoolValue)
    {
        LogMessage("[Bot Zombie Horde] Killed %d survivor bot(s).", botCount);
    }
}

void KillLateSurvivorBot(int client)
{
    if (!IsFakeClient(client) || !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_SURVIVOR)
    {
        return;
    }

    if (CountHumanSurvivors() == 0 && CountSurvivorBots() <= 1)
    {
        return;
    }

    ForcePlayerSuicide(client);

    if (g_cvDebug.BoolValue)
    {
        LogMessage("[Bot Zombie Horde] Killed late survivor bot %d.", client);
    }
}

int CountSurvivorBots()
{
    int count = 0;

    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client) || !IsPlayerAlive(client))
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
