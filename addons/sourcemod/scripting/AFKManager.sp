#include <sourcemod>
#include <sdktools>
#include <cstrike>

#tryinclude <zombiereloaded>

#pragma semicolon 1
#pragma newdecls required

#define AFK_CHECK_INTERVAL 5.0

bool g_Players_bEnabled[MAXPLAYERS + 1];
bool g_Players_bFlagged[MAXPLAYERS + 1];
int g_Players_iLastAction[MAXPLAYERS + 1];
float g_Players_fEyePosition[MAXPLAYERS + 1][3];
int g_Players_iButtons[MAXPLAYERS + 1];
int g_Players_iSpecMode[MAXPLAYERS + 1];
int g_Players_iSpecTarget[MAXPLAYERS + 1];
int g_Players_iIgnore[MAXPLAYERS + 1];

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

public Plugin myinfo =
{
	name = "Good AFK Manager",
	author = "BotoX",
	description = "A good AFK manager?",
	version = "1.3.0",
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

	CloseHandle(cvar);

	AddCommandListener(Command_Say, "say");
	AddCommandListener(Command_Say, "say_team");
	HookEvent("player_team", Event_PlayerTeamPost, EventHookMode_Post);
	HookEvent("player_spawn", Event_PlayerSpawnPost, EventHookMode_Post);
	HookEvent("player_death", Event_PlayerDeathPost, EventHookMode_Post);
	HookEvent("round_end", Event_RoundEnd, EventHookMode_Pre);

	HookEntityOutput("trigger_teleport", "OnEndTouch", Teleport_OnEndTouch);

	AutoExecConfig(true);
}

public APLRes AskPluginLoad2(Handle myself, bool late, char[] error, int err_max)
{
	CreateNative("GetClientIdleTime", Native_GetClientIdleTime);
	RegPluginLibrary("AFKManager");

	return APLRes_Success;
}

public void OnMapStart()
{
	CreateTimer(AFK_CHECK_INTERVAL, Timer_CheckPlayer, _, TIMER_REPEAT|TIMER_FLAG_NO_MAPCHANGE);

	/* Handle late load */
	for(int i = 1; i <= MaxClients; i++)
	{
		if(IsClientConnected(i))
		{
			OnClientConnected(i);
			if(IsClientInGame(i) && IsClientAuthorized(i))
				OnClientPostAdminCheck(i);
		}
	}
}

public void OnClientConnected(int client)
{
	ResetPlayer(client);
}

public void OnClientPostAdminCheck(int client)
{
	if(!IsFakeClient(client))
		InitializePlayer(client);
}

public void OnClientDisconnect(int client)
{
	ResetPlayer(client);
}

int CheckAdminImmunity(int client)
{
	if(!IsClientAuthorized(client))
		return false;

	AdminId Id = GetUserAdmin(client);
	return GetAdminFlag(Id, Admin_Generic);
}

void ResetPlayer(int client)
{
	g_Players_bEnabled[client] = false;
	g_Players_bFlagged[client] = false;
	g_Players_iLastAction[client] = 0;
	g_Players_fEyePosition[client] = view_as<float>({0.0, 0.0, 0.0});
	g_Players_iButtons[client] = 0;
	g_Players_iIgnore[client] = 0;
}

void InitializePlayer(int client)
{
	if(!(g_iImmunity == 1 && CheckAdminImmunity(client)))
	{
		ResetPlayer(client);
		g_Players_iLastAction[client] = GetTime();
		g_Players_bEnabled[client] = true;
	}
}

public void Event_PlayerTeamPost(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(client > 0 && !IsFakeClient(client))
	{
		if(g_Players_iIgnore[client] & IGNORE_TEAMSWITCH)
			g_Players_iIgnore[client] &= ~IGNORE_TEAMSWITCH;
		else
			g_Players_iLastAction[client] = GetTime();
	}
}

public void Event_PlayerSpawnPost(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(client > 0 && !IsFakeClient(client))
		g_Players_iIgnore[client] |= IGNORE_EYEPOSITION;
}

public void Event_PlayerDeathPost(Handle event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(GetEventInt(event, "userid"));
	if(client > 0 && !IsFakeClient(client))
		g_Players_iIgnore[client] |= IGNORE_OBSERVER;
}

public void Event_RoundEnd(Handle event, const char[] name, bool dontBroadcast)
{
	for(int client = 1; client <= MaxClients; client++)
	{
		if(g_Players_bEnabled[client])
			g_Players_iIgnore[client] |= IGNORE_TEAMSWITCH;
	}
}

public Action Command_Say(int client, const char[] Command, int Args)
{
	g_Players_iLastAction[client] = GetTime();

	return Plugin_Continue;
}

public Action OnPlayerRunCmd(int client, int &iButtons, int &iImpulse, float fVel[3], float fAngles[3], int &iWeapon)
{
	if(!IsClientInGame(client))
		return Plugin_Continue;
		
	if(IsClientObserver(client))
	{
		int iSpecMode = g_Players_iSpecMode[client];
		int iSpecTarget = g_Players_iSpecTarget[client];

		g_Players_iSpecMode[client] = GetEntProp(client, Prop_Send, "m_iObserverMode");
		g_Players_iSpecTarget[client] = GetEntPropEnt(client, Prop_Send, "m_hObserverTarget");

		if(g_Players_iSpecMode[client] == 1) // OBS_MODE_DEATHCAM
			g_Players_iIgnore[client] |= IGNORE_OBSERVER;

		if(iSpecTarget && g_Players_iSpecTarget[client] != iSpecTarget)
		{
			if(iSpecTarget == -1 || g_Players_iSpecTarget[client] == -1 ||
				!IsClientInGame(iSpecTarget) || !IsPlayerAlive(iSpecTarget))
				g_Players_iIgnore[client] |= IGNORE_OBSERVER;
		}

		if((iSpecMode && g_Players_iSpecMode[client] != iSpecMode) || (iSpecTarget && g_Players_iSpecTarget[client] != iSpecTarget))
		{
			if(g_Players_iIgnore[client] & IGNORE_OBSERVER)
				g_Players_iIgnore[client] &= ~IGNORE_OBSERVER;
			else
				g_Players_iLastAction[client] = GetTime();
		}
	}

	if(((g_Players_fEyePosition[client][0] != fAngles[0]) ||
		(g_Players_fEyePosition[client][1] != fAngles[1]) ||
		(g_Players_fEyePosition[client][2] != fAngles[2])) &&
		(!IsClientObserver(client) ||
		g_Players_iSpecMode[client] != 4)) // OBS_MODE_IN_EYE
	{
		if(!((iButtons & IN_LEFT) || (iButtons & IN_RIGHT)))
		{
			if(g_Players_iIgnore[client] & IGNORE_EYEPOSITION)
				g_Players_iIgnore[client] &= ~IGNORE_EYEPOSITION;
			else
				g_Players_iLastAction[client] = GetTime();
		}

		g_Players_fEyePosition[client] = fAngles;
	}

	if(g_Players_iButtons[client] != iButtons)
	{
		g_Players_iLastAction[client] = GetTime();
		g_Players_iButtons[client] = iButtons;
	}

	return Plugin_Continue;
}

public Action Teleport_OnEndTouch(const char[] output, int caller, int activator, float delay)
{
	if(activator < 1 || activator > MaxClients)
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

public Action Timer_CheckPlayer(Handle Timer, any Data)
{
	int client;
	int Clients = 0;

	for(client = 1; client <= MaxClients; client++)
	{
		if(IsClientInGame(client) && !IsFakeClient(client))
			Clients++;
	}

	bool bMovePlayers = (Clients >= g_iMoveMinPlayers && g_fMoveTime > 0.0);
	bool bKickPlayers = (Clients >= g_iKickMinPlayers && g_fKickTime > 0.0);

	if(!bMovePlayers && !bKickPlayers)
		return Plugin_Continue;

	for(client = 1; client <= MaxClients; client++)
	{
		if(!g_Players_bEnabled[client] || !IsClientInGame(client))
			continue;

		int iTeamNum = GetClientTeam(client);

		int IdleTime = GetTime() - g_Players_iLastAction[client];

		if(g_Players_bFlagged[client] && (g_fKickTime - IdleTime) > 0.0)
		{
			PrintCenterText(client, "Welcome back!");
			PrintToChat(client, "\x04[AFK]\x01 You have been un-flagged for being inactive.");
			g_Players_bFlagged[client] = false;
		}

		if(bMovePlayers && iTeamNum > CS_TEAM_SPECTATOR && (!g_iImmunity || g_iImmunity == 2 || !CheckAdminImmunity(client)))
		{
			float iTimeleft = g_fMoveTime - IdleTime;
			if(iTimeleft > 0.0)
			{
				if(iTimeleft <= g_fWarnTime)
				{
					PrintCenterText(client, "Warning: If you do not move in %d seconds, you will be moved to spectate.", RoundToFloor(iTimeleft));
					PrintToChat(client, "\x04[AFK]\x01 Warning: If you do not move in %d seconds, you will be moved to spectate.", RoundToFloor(iTimeleft));
				}
			}
			else
			{
				PrintToChatAll("\x04[AFK] \x03%N\x01 was moved to spectate for being AFK too long.", client);
				ForcePlayerSuicide(client);
				g_Players_iIgnore[client] |= IGNORE_TEAMSWITCH;
				ChangeClientTeam(client, CS_TEAM_SPECTATOR);
			}
		}
		else if(g_fKickTime > 0.0 && (!g_iImmunity || g_iImmunity == 3 || !CheckAdminImmunity(client)))
		{
			float iTimeleft = g_fKickTime - IdleTime;
			if(iTimeleft > 0.0)
			{
				if(iTimeleft <= g_fWarnTime)
				{
					PrintCenterText(client, "Warning: If you do not move in %d seconds, you will be kick-flagged for being inactive.", RoundToFloor(iTimeleft));
					PrintToChat(client, "\x04[AFK]\x01 Warning: If you do not move in %d seconds, you will be kick-flagged for being inactive.", RoundToFloor(iTimeleft));
				}
			}
			else
			{
				if(!g_Players_bFlagged[client])
				{
					PrintToChat(client, "\x04[AFK]\x01 You have been kick-flagged for being inactive.");
					g_Players_bFlagged[client] = true;
				}
				int FlaggedPlayers = 0;
				int Position = 1;
				for(int client_ = 1; client_ <= MaxClients; client_++)
				{
					if(!g_Players_bFlagged[client_])
						continue;

					FlaggedPlayers++;
					int IdleTime_ = GetTime() - g_Players_iLastAction[client_];

					if(IdleTime_ > IdleTime)
						Position++;
				}
				PrintCenterText(client, "You have been kick-flagged for being inactive. [%d/%d]", Position, FlaggedPlayers);
			}
		}
	}

	while(bKickPlayers)
	{
		int InactivePlayer = -1;
		int InactivePlayerTime = 0;

		for(client = 1; client <= MaxClients; client++)
		{
			if(!g_Players_bEnabled[client] || !g_Players_bFlagged[client])
				continue;

			int IdleTime = GetTime() - g_Players_iLastAction[client];
			if(IdleTime >= g_fKickTime && IdleTime > InactivePlayerTime)
			{
				InactivePlayer = client;
				InactivePlayerTime = IdleTime;
			}
		}

		if(InactivePlayer == -1)
			break;
		else
		{
			PrintToChatAll("\x04[AFK] \x03%N\x01 was kicked for being AFK too long. (%d seconds)", InactivePlayer, InactivePlayerTime);
			KickClient(InactivePlayer, "[AFK] You were kicked for being AFK too long. (%d seconds)", InactivePlayerTime);
			Clients--;
			g_Players_bFlagged[InactivePlayer] = false;
		}

		bKickPlayers = (Clients >= g_iKickMinPlayers && g_fKickTime > 0.0);
	}

	return Plugin_Continue;
}

public int Native_GetClientIdleTime(Handle plugin, int numParams)
{
	int client = GetNativeCell(1);

	if(client > MaxClients || client <= 0)
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Client is not valid.");
		return -1;
	}

	if(!IsClientInGame(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Client is not in-game.");
		return -1;
	}

	if(IsFakeClient(client))
	{
		ThrowNativeError(SP_ERROR_NATIVE, "Client is fake-client.");
		return -1;
	}

	if(!g_Players_bEnabled[client])
		return 0;

	return GetTime() - g_Players_iLastAction[client];
}
