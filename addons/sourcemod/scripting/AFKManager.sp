#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <multicolors>
#include <AFKManager>

#undef REQUIRE_PLUGIN
#tryinclude <zombiereloaded>
#tryinclude <EntWatch>
#tryinclude <EventsManager>
#define REQUIRE_PLUGIN

#pragma semicolon 1
#pragma newdecls required

#define AFK_CHECK_INTERVAL 5.0
#define SPECTATOR_CHECK_INTERVAL 10.0
#define MAP_START_DELAY 45
#define TAG "{green}[AFK]"

bool g_bIsAdmin[MAXPLAYERS + 1];
bool g_Players_bEnabled[MAXPLAYERS + 1];
bool g_Players_bFlagged[MAXPLAYERS + 1];
int g_Players_iLastAction[MAXPLAYERS + 1];
float g_Players_fEyePosition[MAXPLAYERS + 1][3];
int g_Players_iButtons[MAXPLAYERS + 1];
int g_Players_iSpecMode[MAXPLAYERS + 1];
int g_Players_iSpecTarget[MAXPLAYERS + 1];
int g_Players_iIgnore[MAXPLAYERS + 1];
int g_iConnectedPlayers = 0;
int g_iSpectatorCount = 0;
int g_iMapStartTime = 0;

enum
{
	IGNORE_EYEPOSITION = 1,
	IGNORE_TEAMSWITCH = 2,
	IGNORE_OBSERVER = 4
}

float g_fKickTime;
float g_fMoveTime;
float g_fWarnTime;
int g_iKickMinPlayers;
int g_iMoveMinPlayers;
int g_iImmunity;

bool g_bEntWatch = false;
bool g_bNative_EntWatch = false;
bool g_bEventLoaded;
int g_iEntWatch;

int g_iMaxSpectatorsFull;

public Plugin myinfo =
{
	name = "Good AFK Manager",
	author = "BotoX, .Rushaway, maxime1907",
	description = "A good AFK manager?",
	version = AFKManager_VERSION,
	url = ""
};

public void Cvar_KickTime(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_fKickTime = GetConVarFloat(convar);
}
public void Cvar_MoveTime(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_fMoveTime = GetConVarFloat(convar);
}
public void Cvar_WarnTime(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_fWarnTime = GetConVarFloat(convar);
}
public void Cvar_KickMinPlayers(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iKickMinPlayers = GetConVarInt(convar);
}
public void Cvar_MoveMinPlayers(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iMoveMinPlayers = GetConVarInt(convar);
}
public void Cvar_Immunity(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iImmunity = GetConVarInt(convar);
	CheckEveryoneAdminImmunity();
}
public void Cvar_ImmunityItems(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iEntWatch = GetConVarInt(convar);
}

public void OnPluginStart()
{
	ConVar cvar;
	HookConVarChange((cvar = CreateConVar("sm_afk_move_min", "10", "Min players for AFK move")), Cvar_MoveMinPlayers);
	g_iMoveMinPlayers = GetConVarInt(cvar);

	HookConVarChange((cvar = CreateConVar("sm_afk_kick_min", "30", "Min players for AFK kick")), Cvar_KickMinPlayers);
	g_iKickMinPlayers = GetConVarInt(cvar);

	HookConVarChange((cvar = CreateConVar("sm_afk_move_time", "60.0", "Time in seconds for AFK Move. 0 = DISABLED")), Cvar_MoveTime);
	g_fMoveTime = GetConVarFloat(cvar);

	HookConVarChange((cvar = CreateConVar("sm_afk_kick_time", "120.0", "Time in seconds to AFK Kick. 0 = DISABLED")), Cvar_KickTime);
	g_fKickTime = GetConVarFloat(cvar);

	HookConVarChange((cvar = CreateConVar("sm_afk_warn_time", "30.0", "Time in seconds remaining before warning")), Cvar_WarnTime);
	g_fWarnTime = GetConVarFloat(cvar);

	HookConVarChange((cvar = CreateConVar("sm_afk_immunity", "1", "AFK admins immunity: 0 = DISABLED, 1 = COMPLETE, 2 = KICK, 3 = MOVE")), Cvar_Immunity);
	g_iImmunity = GetConVarInt(cvar);

	HookConVarChange((cvar = CreateConVar("sm_afk_immunity_items", "1", "AFK immunity for Items Owner: 0 = DISABLE")), Cvar_ImmunityItems);
	g_iEntWatch = GetConVarInt(cvar);

	HookConVarChange((cvar = CreateConVar("sm_afk_max_spectators_full", "10", "Maximum number of spectators allowed when server is full (0 = unlimited)")), Cvar_MaxSpectatorsFull);
	g_iMaxSpectatorsFull = GetConVarInt(cvar);

	CloseHandle(cvar);

	AddCommandListener(Command_Say, "say");
	AddCommandListener(Command_Say, "say_team");
	HookEvent("player_team", Event_PlayerTeamPost, EventHookMode_Post);
	HookEvent("player_spawn", Event_PlayerSpawnPost, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeathPost, EventHookMode_Post);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);
	HookEvent("player_disconnect", Event_ClientDisconnect, EventHookMode_Pre);

	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);

	AutoExecConfig(true);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("GetClientIdleTime", Native_GetClientIdleTime);
	RegPluginLibrary("AFKManager");

	return APLRes_Success;
}

public void OnAllPluginsLoaded()
{
	g_bEntWatch = LibraryExists("EntWatch");
	VerifyNatives();
}

public void OnLibraryRemoved(const char[] name)
{
	if (strcmp(name, "EntWatch", false) == 0)
	{
		g_bEntWatch = false;
		VerifyNative_EntWatch();
	}
}

public void OnLibraryAdded(const char[] name)
{
	if (strcmp(name, "EntWatch", false) == 0)
	{
		g_bEntWatch = true;
		VerifyNative_EntWatch();
	}
}

stock void VerifyNatives()
{
	VerifyNative_EntWatch();
}

stock void VerifyNative_EntWatch()
{
	g_bNative_EntWatch = g_bEntWatch && CanTestFeatures() && GetFeatureStatus(FeatureType_Native, "EntWatch_HasSpecialItem") == FeatureStatus_Available;
}

public void OnMapStart()
{
	g_iMapStartTime = GetTime();
	CreateTimer(AFK_CHECK_INTERVAL, Timer_CheckPlayer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(SPECTATOR_CHECK_INTERVAL, Timer_CheckSpectators, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);
	CreateTimer(AFK_CHECK_INTERVAL, Timer_CheckFullServer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);

	/* Handle late load */
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			OnClientConnected(i);
			if (IsClientInGame(i) && IsClientAuthorized(i))
				OnClientPostAdminCheck(i);
		}
	}
}

public void OnClientConnected(int client)
{
	ResetPlayer(client);
	UpdatePlayerCounts();
}

public void OnClientPostAdminCheck(int client)
{
	if (!IsFakeClient(client))
		InitializePlayer(client);
}

// We do that with Hook to prevent get this functions run during map change
public void Event_ClientDisconnect(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0 && client <= MaxClients)
	{
		ResetPlayer(client);
		UpdatePlayerCounts();
	}
}

public void OnRebuildAdminCache(AdminCachePart part)
{
	// Only do something if admins/groups are being rebuild
	if (part == AdminCache_Overrides)
		return;

	CheckEveryoneAdminImmunity();
}

stock void CheckEveryoneAdminImmunity()
{
	for (int i = 1; i <= MaxClients; i++)
	{
		if (!IsClientConnected(i))
			continue;

		if (IsFakeClient(i))
			continue;
		
		if (!IsClientAuthorized(i))
			continue;

		if (g_Players_bEnabled[i])
			continue;

		CheckAdminImmunity(i);
	}
}

stock void CheckAdminImmunity(int client)
{
	AdminId Id = GetUserAdmin(client);

	if (!g_bEventLoaded)
		g_bIsAdmin[client] = GetAdminFlag(Id, Admin_Generic);
	else
	{
		g_bIsAdmin[client] = GetAdminFlag(Id, Admin_Custom4);

		// Event is loaded and Event Manager have total immunity in all cases
		if (g_bIsAdmin[client])
			g_Players_bEnabled[client] = false;
	}
}

void ResetPlayer(int client)
{
	g_bIsAdmin[client] = false;
	g_Players_bEnabled[client] = false;
	g_Players_bFlagged[client] = false;
	g_Players_iLastAction[client] = 0;
	g_Players_fEyePosition[client] = view_as<float>({0.0, 0.0, 0.0});
	g_Players_iButtons[client] = 0;
	g_Players_iIgnore[client] = 0;
}

void InitializePlayer(int client)
{
	CheckAdminImmunity(client);

	if (g_bIsAdmin[client] && g_iImmunity == 1)
		return;

	ResetPlayer(client);
	g_Players_iLastAction[client] = GetTime();
	g_Players_bEnabled[client] = true;
	CreateTimer(g_fKickTime, Timer_CheckPlayerHasJoinTeam, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

public void Event_PlayerTeamPost(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0 && !IsFakeClient(client))
	{
		if (g_Players_iIgnore[client] & IGNORE_TEAMSWITCH)
			g_Players_iIgnore[client] &= ~IGNORE_TEAMSWITCH;
		else
			g_Players_iLastAction[client] = GetTime();
		
		UpdatePlayerCounts();
	}
}

public void Event_PlayerSpawnPost(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0 && !IsFakeClient(client))
		g_Players_iIgnore[client] |= IGNORE_EYEPOSITION;
}

public void Event_PlayerDeathPost(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if (client > 0 && !IsFakeClient(client))
		g_Players_iIgnore[client] |= IGNORE_OBSERVER;
}

public void Event_RoundEnd(Handle event, const char[] name, bool dontBroadcast)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (g_Players_bEnabled[client])
			g_Players_iIgnore[client] |= IGNORE_TEAMSWITCH;
	}
}

public Action Command_Say(int client, const char[] Command, int Args)
{
	g_Players_iLastAction[client] = GetTime();

	return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &iButtons, int &iImpulse, float fAngles[3])
{
	if (!IsClientInGame(client))
		return Plugin_Continue;

	if (!g_Players_bEnabled[client])
		return Plugin_Continue;
		
	if (IsClientObserver(client))
	{
		int iSpecMode = g_Players_iSpecMode[client];
		int iSpecTarget = g_Players_iSpecTarget[client];

		g_Players_iSpecMode[client] = GetEntProp(client, Prop_Send, "m_iObserverMode");
		g_Players_iSpecTarget[client] = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");

		if (g_Players_iSpecMode[client] == 1) // OBS_MODE_DEATHCAM
			g_Players_iIgnore[client] |= IGNORE_OBSERVER;

		if (iSpecTarget && g_Players_iSpecTarget[client] != iSpecTarget)
		{
			if (iSpecTarget == -1 || g_Players_iSpecTarget[client] == -1 ||
				!IsClientInGame(iSpecTarget) || !IsPlayerAlive(iSpecTarget))
				g_Players_iIgnore[client] |= IGNORE_OBSERVER;
		}

		if ((iSpecMode && g_Players_iSpecMode[client] != iSpecMode) || (iSpecTarget && g_Players_iSpecTarget[client] != iSpecTarget))
		{
			if (g_Players_iIgnore[client] & IGNORE_OBSERVER)
				g_Players_iIgnore[client] &= ~IGNORE_OBSERVER;
			else
				g_Players_iLastAction[client] = GetTime();
		}
	}

	if (((g_Players_fEyePosition[client][0] != fAngles[0]) || (g_Players_fEyePosition[client][1] != fAngles[1]) || (g_Players_fEyePosition[client][2] != fAngles[2]))
		&& (!IsClientObserver(client) || g_Players_iSpecMode[client] != 4)) // OBS_MODE_IN_EYE
	{
		if (!((iButtons & IN_LEFT) || (iButtons & IN_RIGHT)))
		{
			if (g_Players_iIgnore[client] & IGNORE_EYEPOSITION)
				g_Players_iIgnore[client] &= ~IGNORE_EYEPOSITION;
			else
				g_Players_iLastAction[client] = GetTime();
		}

		g_Players_fEyePosition[client] = fAngles;
	}

	if (g_Players_iButtons[client] != iButtons)
	{
		g_Players_iLastAction[client] = GetTime();
		g_Players_iButtons[client] = iButtons;
	}

	return Plugin_Continue;
}

public Action Teleport_OnEndTouch(const char[] output, int caller, int activator, float delay)
{
	if (activator < 1 || activator > MaxClients)
		return Plugin_Continue;

	g_Players_iIgnore[activator] |= IGNORE_EYEPOSITION;

	return Plugin_Continue;
}

public Action ZR_OnClientInfect(int &client, int &attacker, bool &motherInfect, bool &respawnOverride, bool &respawn)
{
	g_Players_iIgnore[client] |= IGNORE_TEAMSWITCH;
	return Plugin_Continue;
}

public Action ZR_OnClientHuman(int &client, bool &respawn, bool &protect)
{
	g_Players_iIgnore[client] |= IGNORE_TEAMSWITCH;
	return Plugin_Continue;
}

public Action Timer_CheckPlayerHasJoinTeam(Handle Timer, any userid)
{
	int client = GetClientOfUserId(userid);

	if (!client)
		return Plugin_Stop;

	if (client && GetClientTeam(client) == CS_TEAM_NONE)
		ChangeClientTeam(client, CS_TEAM_SPECTATOR);

	return Plugin_Continue;
}

public Action Timer_CheckPlayer(Handle Timer, any Data)
{
	int client;
	int iTotalPlayers = 0;

	for (client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client))
			iTotalPlayers++;
	}

	bool bMovePlayers = (iTotalPlayers >= g_iMoveMinPlayers && g_fMoveTime > 0.0);
	bool bKickPlayers = (iTotalPlayers >= g_iKickMinPlayers && g_fKickTime > 0.0);

	// If server is full, disable kick for spectators
	if (iTotalPlayers >= MaxClients && g_iMaxSpectatorsFull > 0)
		bKickPlayers = false;

	if (!bMovePlayers && !bKickPlayers)
		return Plugin_Continue;

	int iCurrentTime = GetTime();

	for (client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client))
			continue;

		if (!g_Players_bEnabled[client])
			continue;

		int IdleTime = iCurrentTime - g_Players_iLastAction[client];

	#if defined _EntWatch_include
		if (g_bNative_EntWatch && g_iEntWatch > 0 && EntWatch_HasSpecialItem(client))
			continue;
	#endif

		int iTeamNum = GetClientTeam(client);

		if (g_Players_bFlagged[client] && (g_fKickTime - IdleTime) > 0.0)
		{
			PrintCenterText(client, "Welcome back!");
			CPrintToChat(client, "%s {default}You have been un-flagged for being inactive.", TAG);
			g_Players_bFlagged[client] = false;
		}

		if (bMovePlayers && iTeamNum > CS_TEAM_SPECTATOR && (!g_iImmunity || g_iImmunity == 2 && !g_bIsAdmin[client]))
		{
			float iTimeleft = g_fMoveTime - IdleTime;
			if (iTimeleft > 0.0)
			{
				if (iTimeleft <= g_fWarnTime)
				{
					PrintCenterText(client, "Warning: If you do not move in %d seconds, you will be moved to spectate.", RoundToFloor(iTimeleft));
					CPrintToChat(client, "%s {default}Warning: If you do not move in %d seconds, you will be moved to spectate.", TAG, RoundToFloor(iTimeleft));
				}
			}
			else
			{
				CPrintToChatAll("%s {lightgreen}%N {default}was moved to spectate for being AFK too long.", TAG, client);
				ForcePlayerSuicide(client);
				g_Players_iIgnore[client] |= IGNORE_TEAMSWITCH;
				ChangeClientTeam(client, CS_TEAM_SPECTATOR);
			}
		}
		else if (g_fKickTime > 0.0 && (!g_iImmunity || g_iImmunity == 3 && !g_bIsAdmin[client]))
		{
			float iTimeleft = g_fKickTime - IdleTime;
			if (iTimeleft > 0.0)
			{
				if (iTimeleft <= g_fWarnTime)
				{
					PrintCenterText(client, "Warning: If you do not move in %d seconds, you will be kick-flagged for being inactive.", RoundToFloor(iTimeleft));
					CPrintToChat(client, "%s {default}Warning: If you do not move in %d seconds, you will be kick-flagged for being inactive.", TAG, RoundToFloor(iTimeleft));
				}
			}
			else
			{
				if (!g_Players_bFlagged[client])
				{
					CPrintToChat(client, "%s {default}You have been kick-flagged for being inactive.", TAG);
					g_Players_bFlagged[client] = true;
				}
				int FlaggedPlayers = 0;
				int Position = 1;
				for (int client_ = 1; client_ <= MaxClients; client_++)
				{
					if (!g_Players_bFlagged[client_])
						continue;

					FlaggedPlayers++;
					int IdleTime_ = iCurrentTime - g_Players_iLastAction[client_];

					if (IdleTime_ > IdleTime)
						Position++;
				}
				PrintCenterText(client, "You have been kick-flagged for being inactive. [%d/%d]", Position, FlaggedPlayers);
			}
		}
	}

	while (bKickPlayers)
	{
		int InactivePlayer = -1;
		int InactivePlayerTime = 0;

		for (client = 1; client <= MaxClients; client++)
		{
			if (!g_Players_bEnabled[client] || !g_Players_bFlagged[client])
				continue;

			int IdleTime = iCurrentTime - g_Players_iLastAction[client];
			if (IdleTime >= g_fKickTime && IdleTime > InactivePlayerTime)
			{
				InactivePlayer = client;
				InactivePlayerTime = IdleTime;
			}
		}

		if (InactivePlayer == -1)
			break;
		else
		{
			g_Players_bFlagged[InactivePlayer] = false;
			CPrintToChatAll("%s {lightgreen}%N {default}was kicked for being AFK too long. (%d seconds)", TAG, InactivePlayer, InactivePlayerTime);
			KickClient(InactivePlayer, "[AFK] You were kicked for being AFK too long. (%d seconds)", InactivePlayerTime);
			iTotalPlayers--;
		}

		bKickPlayers = (iTotalPlayers >= g_iKickMinPlayers && g_fKickTime > 0.0);
	}

	return Plugin_Continue;
}

public int Native_GetClientIdleTime(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);

	if (client > MaxClients || client <= 0)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Client is not valid.");
		return -1;
	}

	if (!IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Client is not in-game.");
		return -1;
	}

	if (IsFakeClient(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Client is fake-client.");
		return -1;
	}

	if (!g_Players_bEnabled[client])
		return 0;

	return GetTime() - g_Players_iLastAction[client];
}

#if defined _EventsManager_included
public void Events_OnEventPreStarted()
{
	g_bEventLoaded = true;
}

public void Events_OnPromotingAdmins()
{
	// Verify Admins who get promoted to Event Manager
	CheckEveryoneAdminImmunity();
}

public void Events_OnEventStopped()
{
	g_bEventLoaded = false;
}
#endif

public void Cvar_MaxSpectatorsFull(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iMaxSpectatorsFull = GetConVarInt(convar);
}

public Action Timer_CheckFullServer(Handle Timer, any Data)
{
	// Check for too many spectators when server is full
	bool bFullServerMode = g_iConnectedPlayers >= MaxClients;

	// If server is full and we have too many spectators, warn players
	if (bFullServerMode && g_iMaxSpectatorsFull > 0 && g_iSpectatorCount > g_iMaxSpectatorsFull)
	{
		// Warn all spectators
		for (int i = 1; i <= MaxClients; i++)
		{
			if (IsClientInGame(i) && !IsFakeClient(i) && GetClientTeam(i) == CS_TEAM_SPECTATOR && !IsClientSourceTV(i))
			{
				CPrintToChat(i, "%s {fullred}Server is full! Join a team now to stay in the game!", TAG);
				CPrintToChat(i, "%s {fullred}Inactive spectators will be kicked to make room for active players.", TAG);
			}
		}
	}

	return Plugin_Continue;
}

public Action Timer_CheckSpectators(Handle Timer, any Data)
{
	if (g_fKickTime <= 0.0)
		g_fKickTime = 120.0;

	int iCurrentTime = GetTime();

	// Check for too many spectators when server is full
	bool bFullServerMode = g_iConnectedPlayers >= MaxClients;

	// If server is full and we have too many spectators, handle that first
	if (bFullServerMode && g_iMaxSpectatorsFull > 0 && g_iSpectatorCount > g_iMaxSpectatorsFull)
	{
		// Find the most inactive spectator to kick
		int mostInactive = -1;
		int mostInactiveTime = 0;

		for (int i = 1; i <= MaxClients; i++)
		{
			if (!IsClientInGame(i) || IsFakeClient(i) || GetClientTeam(i) != CS_TEAM_SPECTATOR)
				continue;

			// Skip SourceTV
			if (IsClientSourceTV(i))
				continue;

			// Skip if player has immunity
			if (g_bIsAdmin[i] && (g_iImmunity == 1 || g_iImmunity == 2))
				continue;

			int idleTime = iCurrentTime - g_Players_iLastAction[i];
			
			// Only consider spectators who have been inactive longer than sm_afk_kick_time
			if (idleTime >= (g_fKickTime / 2) && idleTime > mostInactiveTime)
			{
				mostInactive = i;
				mostInactiveTime = idleTime;
			}
		}

		if (mostInactive != -1)
		{
			// Kick the most inactive spectator
			g_Players_bFlagged[mostInactive] = false;
			CPrintToChatAll("%s {lightgreen}%N {default}was kicked to make room for active players (inactive for %d seconds).", TAG, mostInactive, mostInactiveTime);
			KickClient(mostInactive, "[AFK] You were kicked to make room for active players (inactive for %d seconds).", mostInactiveTime);
			return Plugin_Continue;
		}
	}

	// Continue with normal AFK kick logic
	bool bKickPlayers = (g_iConnectedPlayers >= g_iKickMinPlayers && g_fKickTime > 0.0);

	// If server is full, disable kick for spectators
	if (g_iConnectedPlayers >= MaxClients && g_iMaxSpectatorsFull > 0)
		bKickPlayers = false;

	if (!bKickPlayers)
		return Plugin_Continue;

	// Check for AFK players to kick
	while (bKickPlayers)
	{
		int InactivePlayer = -1;
		int InactivePlayerTime = 0;

		for (int client = 1; client <= MaxClients; client++)
		{
			if (!g_Players_bEnabled[client] || !g_Players_bFlagged[client])
				continue;

			int IdleTime = iCurrentTime - g_Players_iLastAction[client];
			if (IdleTime >= g_fKickTime && IdleTime > InactivePlayerTime)
			{
				InactivePlayer = client;
				InactivePlayerTime = IdleTime;
			}
		}

		if (InactivePlayer == -1)
			break;
		else
		{
			g_Players_bFlagged[InactivePlayer] = false;
			CPrintToChatAll("%s {lightgreen}%N {default}was kicked for being AFK too long. (%d seconds)", TAG, InactivePlayer, InactivePlayerTime);
			KickClient(InactivePlayer, "[AFK] You were kicked for being AFK too long. (%d seconds)", InactivePlayerTime);
		}

		bKickPlayers = (g_iConnectedPlayers >= g_iKickMinPlayers && g_fKickTime > 0.0);
	}

	return Plugin_Continue;
}

void UpdatePlayerCounts()
{
	// Don't update counts during the first 45 seconds after map start
	if (GetTime() - g_iMapStartTime < MAP_START_DELAY)
		return;

	g_iConnectedPlayers = 0;
	g_iSpectatorCount = 0;
	
	for (int i = 1; i <= MaxClients; i++)
	{
		if (IsClientConnected(i))
		{
			g_iConnectedPlayers++;
			if (IsClientInGame(i) && GetClientTeam(i) == CS_TEAM_SPECTATOR)
				g_iSpectatorCount++;
		}
	}
}
