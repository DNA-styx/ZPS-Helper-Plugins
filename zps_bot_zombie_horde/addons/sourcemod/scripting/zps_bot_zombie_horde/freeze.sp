void StartFreezePoll(float duration)
{
    if (!LibraryExists("navbot"))
    {
        LogError("[Bot Zombie Horde] NavBot library not available, skipping freeze.");
        return;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        g_bFrozenThisRound[client] = false;
    }

    g_fFreezeEndTime = GetGameTime() + duration;
    FreezeZombieBots(duration);

    delete g_hFreezeTimer;
    g_hFreezeTimer = CreateTimer(FREEZE_POLL_INTERVAL, Timer_FreezePoll, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_FreezePoll(Handle timer)
{
    float remaining = g_fFreezeEndTime - GetGameTime();

    if (remaining <= FREEZE_POLL_INTERVAL)
    {
        g_hFreezeTimer = null;
        return Plugin_Stop;
    }

    FreezeZombieBots(remaining);
    return Plugin_Continue;
}

void FreezeZombieBots(float duration)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client) || g_bFrozenThisRound[client])
        {
            continue;
        }

        if (!NavBotManager.IsNavBot(client))
        {
            continue;
        }

        if (GetClientTeam(client) != TEAM_ZOMBIE || !IsPlayerAlive(client))
        {
            continue;
        }

        NavBot bot = NavBotManager.GetNavBotByIndex(client);
        if (bot.IsNull)
        {
            continue;
        }

        bot.SendPluginCommand(NAVBOT_PLUGINCMD_WAIT, duration);
        g_bFrozenThisRound[client] = true;
    }
}

// Real zombie players only (bots use NavBot WAIT). No restore needed.
public Action OnPlayerRunCmd(int client, int &buttons, int &impulse, float vel[3], float angles[3])
{
    if (!g_bMapEnabled || GetGameTime() >= g_fFreezeEndTime)
    {
        return Plugin_Continue;
    }

    if (IsFakeClient(client) || !IsPlayerAlive(client) || GetClientTeam(client) != TEAM_ZOMBIE)
    {
        return Plugin_Continue;
    }

    vel[0] = 0.0;
    vel[1] = 0.0;
    vel[2] = 0.0;
    buttons &= ~(IN_JUMP | IN_DUCK | IN_FORWARD | IN_BACK | IN_MOVELEFT | IN_MOVERIGHT);
    return Plugin_Changed;
}

// Holds survivor bots still at map start and each round start, so they
// don't break things before the round-start pass kills them.
void StartBotHold()
{
    if (!g_bMapEnabled || !g_cvEnabled.BoolValue || !LibraryExists("navbot"))
    {
        return;
    }

    float duration = g_cvBotHoldDuration.FloatValue;
    if (duration <= 0.0)
    {
        return;
    }

    for (int client = 1; client <= MaxClients; client++)
    {
        g_bHeld[client] = false;
    }

    g_fBotHoldEndTime = GetGameTime() + duration;
    HoldSurvivorBots(duration);

    delete g_hBotHoldTimer;
    g_hBotHoldTimer = CreateTimer(FREEZE_POLL_INTERVAL, Timer_BotHold, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

Action Timer_BotHold(Handle timer)
{
    float remaining = g_fBotHoldEndTime - GetGameTime();

    if (remaining <= FREEZE_POLL_INTERVAL)
    {
        g_hBotHoldTimer = null;
        return Plugin_Stop;
    }

    HoldSurvivorBots(remaining);
    return Plugin_Continue;
}

void HoldSurvivorBots(float duration)
{
    for (int client = 1; client <= MaxClients; client++)
    {
        if (!IsClientInGame(client) || !IsFakeClient(client) || g_bHeld[client])
        {
            continue;
        }

        if (!NavBotManager.IsNavBot(client))
        {
            continue;
        }

        if (GetClientTeam(client) != TEAM_SURVIVOR || !IsPlayerAlive(client))
        {
            continue;
        }

        NavBot bot = NavBotManager.GetNavBotByIndex(client);
        if (bot.IsNull)
        {
            continue;
        }

        bot.SendPluginCommand(NAVBOT_PLUGINCMD_WAIT, duration);
        g_bHeld[client] = true;
    }
}
