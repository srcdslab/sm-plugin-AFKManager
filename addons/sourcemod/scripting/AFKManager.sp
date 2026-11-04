#include <sourcemod>
#include <sdktools>
#include <cstrike>
#include <multicolors>
#include <AFKManager>

#undef REQUIRE_PLUGIN
#tryinclude <zombiereloaded>
#tryinclude <entWatch_core>
#tryinclude <EventsManager>
#define REQUIRE_PLUGIN

#pragma semicolon 1
#pragma newdecls required

#define AFK_CHECK_INTERVAL 5.0
#define SPECTATOR_CHECK_INTERVAL 10.0
#define MAP_START_DELAY 45
#define DEFAULT_KICK_TIME 120.0
#define TAG "{green}[AFK]"
#define DETECTION_LOG_FILE "logs/afkmanager_detection.log"

// sm_afk_immunity modes
#define IMMUNITY_COMPLETE 1
#define IMMUNITY_KICK 2
#define IMMUNITY_MOVE 3

// sm_afk_detection modes
#define DETECTION_LEGACY 0  // Legacy detection only
#define DETECTION_OBSERVE 1 // Legacy detection enforces, the new one is computed and compared to it
#define DETECTION_NEW 2     // New detection enforces

// Whether the server receives the players' mouse movement, which the new detection relies on
#define HEALTH_UNKNOWN 0
#define HEALTH_OK 1
#define HEALTH_FAILED 2
#define HEALTH_MIN_SAMPLES 2000
#define HEALTH_MIN_MOUSE_RATIO 0.25

// A disagreement between the two detections, written to the detection log once it ends
#define EPISODE_NONE 0
#define EPISODE_NEW_IDLE 1    // The new detection sees an AFK player that the legacy one sees as active
#define EPISODE_LEGACY_IDLE 2 // The legacy detection sees an AFK player that the new one sees as active

// Activity sources. Keep ACT_CHAT first of the legacy sources: see IsLegacySource()
enum
{
	ACT_MOUSE = 0, // New: physical mouse movement above sm_afk_mouse_threshold
	ACT_KEY,       // New: key pressed, weapon switch or impulse, as sent by the client
	ACT_COMMAND,   // New: command the player sent (jointeam, menuselect, spec_next, ...)
	ACT_CHAT,      // Both: say / say_team
	ACT_ANGLES,    // Legacy: view angles changed
	ACT_BUTTONS,   // Legacy: button state changed
	ACT_OBSERVER,  // Legacy: spectator mode or target changed
	ACT_TEAM,      // Legacy: team changed
	ACT_COUNT
}

char g_sActivityName[][] = { "mouse", "keys", "commands", "chat", "angles", "buttons", "observer", "team" };

// What sm_afk_status shows for each detection
int g_iNewSources[] = { ACT_MOUSE, ACT_KEY, ACT_COMMAND, ACT_CHAT };
int g_iLegacySources[] = { ACT_ANGLES, ACT_BUTTONS, ACT_OBSERVER, ACT_TEAM, ACT_CHAT };

// What the detection log shows: what kept the legacy detection from seeing an AFK player,
// and what kept the new one from seeing an AFK player
int g_iNewIdleReport[] = { ACT_ANGLES, ACT_BUTTONS, ACT_OBSERVER, ACT_TEAM, ACT_KEY, ACT_COMMAND };
int g_iLegacyIdleReport[] = { ACT_MOUSE, ACT_KEY, ACT_COMMAND };

// Client commands that only come from the player
char g_sPlayerCommands[][] = { "jointeam", "joinclass", "spectate", "menuselect", "spec_next", "spec_prev", "spec_mode", "spec_player" };

bool g_bIsAdmin[MAXPLAYERS + 1];
bool g_Players_bEnabled[MAXPLAYERS + 1];
bool g_Players_bFlagged[MAXPLAYERS + 1];
int g_Players_iLastAction[MAXPLAYERS + 1];
float g_Players_fEyePosition[MAXPLAYERS + 1][3];
int g_Players_iButtons[MAXPLAYERS + 1];
int g_Players_iSpecMode[MAXPLAYERS + 1];
int g_Players_iSpecTarget[MAXPLAYERS + 1];
int g_Players_iIgnore[MAXPLAYERS + 1];

// New detection: only input a human produces (see OnPlayerRunCmdPre)
int g_Players_iTrackStart[MAXPLAYERS + 1];
int g_Players_iActivity[MAXPLAYERS + 1][ACT_COUNT]; // GetTime() of the last activity per source, 0 = never
int g_Players_iRawButtons[MAXPLAYERS + 1];
int g_Players_iMouseAmount[MAXPLAYERS + 1];
int g_Players_iMouseWindow[MAXPLAYERS + 1];
bool g_Players_bHasRawAngles[MAXPLAYERS + 1];
float g_Players_fRawAngles[MAXPLAYERS + 1][2];
int g_Players_iViewChanges[MAXPLAYERS + 1];
int g_Players_iViewChangesNoMouse[MAXPLAYERS + 1];

// Comparison between the two detections
int g_Players_iEpisode[MAXPLAYERS + 1];
int g_Players_iEpisodeStart[MAXPLAYERS + 1];
int g_Players_iEpisodeTeam[MAXPLAYERS + 1];
bool g_Players_bEpisodeAlive[MAXPLAYERS + 1];
int g_Players_iEpisodeMaxNew[MAXPLAYERS + 1];
int g_Players_iEpisodeMaxLegacy[MAXPLAYERS + 1];
int g_Players_iSinceStrong[MAXPLAYERS + 1][ACT_COUNT]; // Activity counts since the last mouse movement or chat message
int g_Players_iSinceLegacy[MAXPLAYERS + 1][ACT_COUNT]; // Activity counts since the last legacy activity

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

int g_iDetection;
int g_iMouseThreshold;
int g_iKeyOnlyTime;
bool g_bDetectionLog;
int g_iMouseWindowTicks;
int g_iHealth = HEALTH_UNKNOWN;
int g_iHealthSamples;
int g_iHealthMouseSamples;
char g_sDetectionLog[PLATFORM_MAX_PATH];

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
	g_fKickTime = convar.FloatValue;
}
public void Cvar_MoveTime(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_fMoveTime = convar.FloatValue;
}
public void Cvar_WarnTime(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_fWarnTime = convar.FloatValue;
}
public void Cvar_KickMinPlayers(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iKickMinPlayers = convar.IntValue;
}
public void Cvar_MoveMinPlayers(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iMoveMinPlayers = convar.IntValue;
}
public void Cvar_Immunity(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iImmunity = convar.IntValue;
	CheckEveryoneAdminImmunity();
}
public void Cvar_ImmunityItems(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iEntWatch = convar.IntValue;
}
public void Cvar_Detection(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iDetection = convar.IntValue;
	LogToFileEx(g_sDetectionLog, "Detection mode changed from %s to %s", oldValue, newValue);
	OnObservationChanged();
}
public void Cvar_MouseThreshold(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iMouseThreshold = convar.IntValue;
}
public void Cvar_KeyOnlyTime(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iKeyOnlyTime = convar.IntValue;
}
public void Cvar_DetectionLog(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_bDetectionLog = convar.BoolValue;
	OnObservationChanged();
}

public void OnPluginStart()
{
	LoadTranslations("common.phrases");
	LoadTranslations("AFKManager.phrases");

	BuildPath(Path_SM, g_sDetectionLog, sizeof(g_sDetectionLog), DETECTION_LOG_FILE);

	ConVar cvar;
	((cvar = CreateConVar("sm_afk_move_min", "10", "Min players for AFK move"))).AddChangeHook(Cvar_MoveMinPlayers);
	g_iMoveMinPlayers = cvar.IntValue;

	((cvar = CreateConVar("sm_afk_kick_min", "30", "Min players for AFK kick"))).AddChangeHook(Cvar_KickMinPlayers);
	g_iKickMinPlayers = cvar.IntValue;

	((cvar = CreateConVar("sm_afk_move_time", "60.0", "Time in seconds for AFK Move. 0 = DISABLED"))).AddChangeHook(Cvar_MoveTime);
	g_fMoveTime = cvar.FloatValue;

	((cvar = CreateConVar("sm_afk_kick_time", "120.0", "Time in seconds to AFK Kick. 0 = DISABLED"))).AddChangeHook(Cvar_KickTime);
	g_fKickTime = cvar.FloatValue;

	((cvar = CreateConVar("sm_afk_warn_time", "30.0", "Time in seconds remaining before warning"))).AddChangeHook(Cvar_WarnTime);
	g_fWarnTime = cvar.FloatValue;

	((cvar = CreateConVar("sm_afk_immunity", "1", "AFK admins immunity: 0 = DISABLED, 1 = COMPLETE, 2 = KICK, 3 = MOVE", _, true, 0.0, true, 3.0))).AddChangeHook(Cvar_Immunity);
	g_iImmunity = cvar.IntValue;

	((cvar = CreateConVar("sm_afk_immunity_items", "1", "AFK immunity for Items Owner: 0 = DISABLE"))).AddChangeHook(Cvar_ImmunityItems);
	g_iEntWatch = cvar.IntValue;

	((cvar = CreateConVar("sm_afk_max_spectators_full", "10", "Maximum number of spectators allowed when server is full (0 = unlimited)"))).AddChangeHook(Cvar_MaxSpectatorsFull);
	g_iMaxSpectatorsFull = cvar.IntValue;

	((cvar = CreateConVar("sm_afk_detection", "1", "AFK detection: 0 = legacy only, 1 = legacy enforces and the new detection is compared to it (see sm_afk_detection_log), 2 = new detection enforces (legacy until the mouse data is confirmed)", _, true, 0.0, true, 2.0))).AddChangeHook(Cvar_Detection);
	g_iDetection = cvar.IntValue;

	((cvar = CreateConVar("sm_afk_mouse_threshold", "45", "New detection: mouse movement needed within one second to count as activity (45 = about 1 degree of view rotation with m_yaw 0.022)", _, true, 1.0))).AddChangeHook(Cvar_MouseThreshold);
	g_iMouseThreshold = cvar.IntValue;

	((cvar = CreateConVar("sm_afk_key_only_time", "120", "New detection: seconds key presses and commands alone keep a player active without any mouse movement or chat (0 = they never do on their own)", _, true, 0.0))).AddChangeHook(Cvar_KeyOnlyTime);
	g_iKeyOnlyTime = cvar.IntValue;

	((cvar = CreateConVar("sm_afk_detection_log", "1", "Log every disagreement between the legacy and the new detection to " ... DETECTION_LOG_FILE ... " (sm_afk_detection 1 or 2)", _, true, 0.0, true, 1.0))).AddChangeHook(Cvar_DetectionLog);
	g_bDetectionLog = cvar.BoolValue;

	delete cvar;

	// The new detection counts mouse movement over one second
	g_iMouseWindowTicks = RoundToCeil(1.0 / GetTickInterval());

	if (GetFeatureStatus(FeatureType_Capability, FEATURECAP_PLAYERRUNCMD_11PARAMS) != FeatureStatus_Available)
	{
		g_iHealth = HEALTH_FAILED;
		LogError("This server does not give plugins the players' mouse movement: the new AFK detection is disabled and the legacy one stays in use.");
	}

	AddCommandListener(Command_Say, "say");
	AddCommandListener(Command_Say, "say_team");
	for (int i = 0; i < sizeof(g_sPlayerCommands); i++)
		AddCommandListener(Command_PlayerCommand, g_sPlayerCommands[i]);

	RegAdminCmd("sm_afk_status", Command_Status, ADMFLAG_GENERIC, "Shows how the legacy and the new AFK detection see players. Usage: sm_afk_status [#userid|name]");
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
	g_bEntWatch = LibraryExists("entWatch-core");
	VerifyNatives();
}

public void OnLibraryRemoved(const char[] name)
{
	if (strcmp(name, "entWatch-core", false) == 0)
	{
		g_bEntWatch = false;
		VerifyNative_EntWatch();
	}
}

public void OnLibraryAdded(const char[] name)
{
	if (strcmp(name, "entWatch-core", false) == 0)
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
	g_bNative_EntWatch = g_bEntWatch && CanTestFeatures() && GetFeatureStatus(FeatureType_Native, "EW_ClientHasItem") == FeatureStatus_Available;
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

public void OnMapEnd()
{
	CloseAllEpisodes("map end");
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
public void Event_ClientDisconnect(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && client <= MaxClients)
	{
		if (g_Players_iEpisode[client] != EPISODE_NONE)
		{
			char sReason[128], sEnd[160];
			event.GetString("reason", sReason, sizeof(sReason));
			FormatEx(sEnd, sizeof(sEnd), "disconnected (%s)", sReason);
			EndEpisode(client, GetTime(), sEnd);
		}

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
		if (!IsClientInGame(i))
			continue;

		if (IsFakeClient(i))
			continue;

		if (!IsClientAuthorized(i))
			continue;

		RefreshAdminImmunity(i);
	}
}

stock void CheckAdminImmunity(int client)
{
	AdminId Id = GetUserAdmin(client);

	// While an event is loaded only Event Managers count as admins
	g_bIsAdmin[client] = GetAdminFlag(Id, g_bEventLoaded ? Admin_Custom4 : Admin_Generic);
}

// Admins are not tracked at all when they have complete immunity. Event Managers
// have total immunity in all cases while an event is loaded.
stock bool IsTrackingImmune(int client)
{
	return g_bIsAdmin[client] && (g_bEventLoaded || g_iImmunity == IMMUNITY_COMPLETE);
}

stock bool IsMoveImmune(int client)
{
	return g_bIsAdmin[client] && (g_bEventLoaded || g_iImmunity == IMMUNITY_COMPLETE || g_iImmunity == IMMUNITY_MOVE);
}

stock bool IsKickImmune(int client)
{
	return g_bIsAdmin[client] && (g_bEventLoaded || g_iImmunity == IMMUNITY_COMPLETE || g_iImmunity == IMMUNITY_KICK);
}

// sm_afk_kick_time 0 only disables the AFK kick, the spectator and team join
// checks still need a usable delay
stock float GetFallbackKickTime()
{
	return g_fKickTime > 0.0 ? g_fKickTime : DEFAULT_KICK_TIME;
}

stock void StartTracking(int client)
{
	int iNow = GetTime();
	g_Players_iLastAction[client] = iNow;
	g_Players_iTrackStart[client] = iNow;
	g_Players_bEnabled[client] = true;
	CreateTimer(GetFallbackKickTime(), Timer_CheckPlayerHasJoinTeam, GetClientUserId(client), TIMER_FLAG_NO_MAPCHANGE);
}

// Re-evaluate the admin status of a connected client and start or stop tracking
// it accordingly (admin cache rebuild, event start/stop, sm_afk_immunity change)
stock void RefreshAdminImmunity(int client)
{
	CheckAdminImmunity(client);

	bool bTracked = !IsTrackingImmune(client);
	if (bTracked && !g_Players_bEnabled[client])
		StartTracking(client);
	else if (!bTracked)
	{
		EndEpisode(client, GetTime(), "no longer tracked (admin immunity)");
		g_Players_bEnabled[client] = false;
	}

	// A pending kick flag must not outlive kick immunity
	if (IsKickImmune(client))
		g_Players_bFlagged[client] = false;
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

	g_Players_iTrackStart[client] = 0;
	g_Players_iRawButtons[client] = 0;
	g_Players_iMouseAmount[client] = 0;
	g_Players_iMouseWindow[client] = 0;
	g_Players_bHasRawAngles[client] = false;
	g_Players_iViewChanges[client] = 0;
	g_Players_iViewChangesNoMouse[client] = 0;
	g_Players_iEpisode[client] = EPISODE_NONE;
	for (int i = 0; i < ACT_COUNT; i++)
	{
		g_Players_iActivity[client][i] = 0;
		g_Players_iSinceStrong[client][i] = 0;
		g_Players_iSinceLegacy[client][i] = 0;
	}
}

void InitializePlayer(int client)
{
	// Reset first: ResetPlayer clears g_bIsAdmin, which the immunity modes rely on
	ResetPlayer(client);
	CheckAdminImmunity(client);

	if (IsTrackingImmune(client))
		return;

	StartTracking(client);
}

public void Event_PlayerTeamPost(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && !IsFakeClient(client))
	{
		if (g_Players_iIgnore[client] & IGNORE_TEAMSWITCH)
			g_Players_iIgnore[client] &= ~IGNORE_TEAMSWITCH;
		else
			RecordActivity(client, ACT_TEAM);

		UpdatePlayerCounts();
	}
}

public void Event_PlayerSpawnPost(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && !IsFakeClient(client))
		g_Players_iIgnore[client] |= IGNORE_EYEPOSITION;
}

public void Event_PlayerDeathPost(Event event, const char[] name, bool dontBroadcast)
{
	int client = GetClientOfUserId(event.GetInt("userid"));
	if (client > 0 && !IsFakeClient(client))
		g_Players_iIgnore[client] |= IGNORE_OBSERVER;
}

public void Event_RoundEnd(Event event, const char[] name, bool dontBroadcast)
{
	for (int client = 1; client <= MaxClients; client++)
	{
		if (g_Players_bEnabled[client])
			g_Players_iIgnore[client] |= IGNORE_TEAMSWITCH;
	}
}

public Action Command_Say(int client, const char[] Command, int Args)
{
	if (client > 0 && client <= MaxClients)
		RecordActivity(client, ACT_CHAT);

	return Plugin_Continue;
}

public Action Command_PlayerCommand(int client, const char[] Command, int Args)
{
	if (client > 0 && client <= MaxClients)
		RecordActivity(client, ACT_COMMAND);

	return Plugin_Continue;
}

// Chat and the legacy sources reset the legacy idle timer
stock bool IsLegacySource(int iSource)
{
	return iSource >= ACT_CHAT;
}

// Mouse movement and chat are the only activities that keep a player active on their own
// in the new detection, key presses and commands only for sm_afk_key_only_time
stock bool IsStrongSource(int iSource)
{
	return iSource == ACT_MOUSE || iSource == ACT_CHAT;
}

stock void ClearCounts(int[] iCounts)
{
	for (int i = 0; i < ACT_COUNT; i++)
		iCounts[i] = 0;
}

void RecordActivity(int client, int iSource)
{
	int iNow = GetTime();
	g_Players_iActivity[client][iSource] = iNow;

	// The counts of an open disagreement are kept until it is logged
	if (IsStrongSource(iSource) && g_Players_iEpisode[client] != EPISODE_NEW_IDLE)
		ClearCounts(g_Players_iSinceStrong[client]);
	if (IsLegacySource(iSource) && g_Players_iEpisode[client] != EPISODE_LEGACY_IDLE)
		ClearCounts(g_Players_iSinceLegacy[client]);

	g_Players_iSinceStrong[client][iSource]++;
	g_Players_iSinceLegacy[client][iSource]++;

	if (IsLegacySource(iSource))
		g_Players_iLastAction[client] = iNow;
}

stock int IntAbs(int iValue)
{
	return iValue < 0 ? -iValue : iValue;
}

stock int IntMax(int a, int b)
{
	return a > b ? a : b;
}

// New detection: reads the input exactly as the client sent it, before any plugin changes it
public void OnPlayerRunCmdPre(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	if (!g_Players_bEnabled[client])
		return;

	// Physical mouse movement. The client fills it from the mouse only: a view turned by the server
	// (teleport, spectating in first person), +left/+right, a menu with a cursor or the game
	// in the background all leave it at 0. Movement is summed over one second against
	// sm_afk_mouse_threshold so that sensor noise does not count.
	int iMouse = IntAbs(mouse[0]) + IntAbs(mouse[1]);
	if (iMouse > 0)
	{
		int iTick = GetGameTickCount();
		// The tick count starts over on map change
		if (iTick < g_Players_iMouseWindow[client] || iTick - g_Players_iMouseWindow[client] >= g_iMouseWindowTicks)
		{
			g_Players_iMouseWindow[client] = iTick;
			g_Players_iMouseAmount[client] = 0;
		}

		g_Players_iMouseAmount[client] += iMouse;
		if (g_Players_iMouseAmount[client] >= g_iMouseThreshold)
		{
			g_Players_iMouseWindow[client] = iTick;
			g_Players_iMouseAmount[client] = 0;
			RecordActivity(client, ACT_MOUSE);
		}
	}

	// Only a key going down counts: a key held down, or something resting on it, never does
	int iPressed = buttons & ~g_Players_iRawButtons[client];
	g_Players_iRawButtons[client] = buttons;
	if (iPressed || impulse || weapon)
		RecordActivity(client, ACT_KEY);

	// How often the view of a living player turns without the mouse: confirms that the server
	// receives the mouse movement at all, and shows players who would not be seen (controller)
	if (IsPlayerAlive(client) && !(buttons & (IN_LEFT|IN_RIGHT)))
	{
		if (g_Players_bHasRawAngles[client] && (angles[0] != g_Players_fRawAngles[client][0] || angles[1] != g_Players_fRawAngles[client][1]))
		{
			g_Players_iViewChanges[client]++;
			if (iMouse == 0)
				g_Players_iViewChangesNoMouse[client]++;

			SampleMouseHealth(iMouse > 0);
		}
	}

	g_Players_fRawAngles[client][0] = angles[0];
	g_Players_fRawAngles[client][1] = angles[1];
	g_Players_bHasRawAngles[client] = true;
}

// The new detection is only trusted once the server is seen receiving mouse movement
void SampleMouseHealth(bool bMouse)
{
	if (g_iHealth != HEALTH_UNKNOWN)
		return;

	g_iHealthSamples++;
	if (bMouse)
		g_iHealthMouseSamples++;

	if (g_iHealthSamples < HEALTH_MIN_SAMPLES)
		return;

	float fRatio = float(g_iHealthMouseSamples) / float(g_iHealthSamples);
	if (fRatio >= HEALTH_MIN_MOUSE_RATIO)
	{
		g_iHealth = HEALTH_OK;
		LogToFileEx(g_sDetectionLog, "New detection ready: mouse movement received for %.0f%% of %d view changes", fRatio * 100.0, g_iHealthSamples);
	}
	else
	{
		g_iHealth = HEALTH_FAILED;
		LogError("Mouse movement received for only %.0f%% of %d view changes: the new AFK detection is disabled and the legacy one stays in use.", fRatio * 100.0, g_iHealthSamples);
		LogToFileEx(g_sDetectionLog, "New detection disabled: mouse movement received for only %.0f%% of %d view changes", fRatio * 100.0, g_iHealthSamples);
	}
}

stock int GetLegacyIdleTime(int client, int iNow)
{
	return iNow - g_Players_iLastAction[client];
}

// Key presses and commands alone keep a player active for sm_afk_key_only_time at most:
// a macro pressing a key now and then only delays the AFK by that much
stock int GetNewIdleTime(int client, int iNow)
{
	int iLastStrong = IntMax(g_Players_iTrackStart[client], IntMax(g_Players_iActivity[client][ACT_MOUSE], g_Players_iActivity[client][ACT_CHAT]));
	int iLastAny = IntMax(iLastStrong, IntMax(g_Players_iActivity[client][ACT_KEY], g_Players_iActivity[client][ACT_COMMAND]));

	return IntMax(iNow - iLastAny, iNow - iLastStrong - g_iKeyOnlyTime);
}

stock bool UseNewDetection()
{
	return g_iDetection == DETECTION_NEW && g_iHealth == HEALTH_OK;
}

// Idle time used to warn, move and kick
stock int GetIdleTime(int client, int iNow)
{
	return UseNewDetection() ? GetNewIdleTime(client, iNow) : GetLegacyIdleTime(client, iNow);
}

public Action OnPlayerRunCmd(int client, int &iButtons, int &iImpulse, float fAngles[3])
{
	if (!IsClientInGame(client))
		return Plugin_Continue;

	if (!g_Players_bEnabled[client])
		return Plugin_Continue;

	bool bIsObserver = IsClientObserver(client);

	if (bIsObserver)
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
				RecordActivity(client, ACT_OBSERVER);
		}
	}

	if (((g_Players_fEyePosition[client][0] != fAngles[0]) || (g_Players_fEyePosition[client][1] != fAngles[1]) || (g_Players_fEyePosition[client][2] != fAngles[2]))
		&& (!bIsObserver || g_Players_iSpecMode[client] != 4)) // OBS_MODE_IN_EYE
	{
		if (!((iButtons & IN_LEFT) || (iButtons & IN_RIGHT)))
		{
			if (g_Players_iIgnore[client] & IGNORE_EYEPOSITION)
				g_Players_iIgnore[client] &= ~IGNORE_EYEPOSITION;
			else
				RecordActivity(client, ACT_ANGLES);
		}

		g_Players_fEyePosition[client] = fAngles;
	}

	if (g_Players_iButtons[client] != iButtons)
	{
		int iChangedButtons = g_Players_iButtons[client] ^ iButtons;

		// Ignore duck-only toggles: a common AFK-bypass macro (e.g. "bind mwheelup +duck")
		// spams +duck/-duck to keep the button state changing without any real input.
		// Any other button changing alongside it (attack, use, movement, ...) still counts.
		if (iChangedButtons != IN_DUCK)
			RecordActivity(client, ACT_BUTTONS);

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

public void ZR_OnClientInfected(int client, int attacker, bool motherInfect, bool respawnOverride, bool respawn)
{
	g_Players_iIgnore[client] |= IGNORE_TEAMSWITCH;
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

	// The player may have been promoted since the timer was created
	if (!g_Players_bEnabled[client] || IsMoveImmune(client))
		return Plugin_Stop;

	if (client && GetClientTeam(client) == CS_TEAM_NONE)
		ChangeClientTeam(client, CS_TEAM_SPECTATOR);

	return Plugin_Continue;
}

// Gathers flagged players who have crossed the kick threshold, sorted from most to least idle.
// Used to replace an O(n) rescan of every client per kick with a single O(n) pass.
int GatherKickCandidates(int iCurrentTime, int candidates[MAXPLAYERS + 1], int candidateTimes[MAXPLAYERS + 1])
{
	int iCandidateCount = 0;

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!g_Players_bEnabled[client] || !g_Players_bFlagged[client] || IsKickImmune(client))
			continue;

		int IdleTime = GetIdleTime(client, iCurrentTime);
		if (IdleTime < g_fKickTime)
			continue;

		int iPos = iCandidateCount;
		while (iPos > 0 && candidateTimes[iPos - 1] < IdleTime)
		{
			candidates[iPos] = candidates[iPos - 1];
			candidateTimes[iPos] = candidateTimes[iPos - 1];
			iPos--;
		}
		candidates[iPos] = client;
		candidateTimes[iPos] = IdleTime;
		iCandidateCount++;
	}

	return iCandidateCount;
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

	int iCurrentTime = GetTime();

	// Compared whatever the player count, the comparison does not act on anyone
	ObserveDetection(iCurrentTime);

	bool bMovePlayers = (iTotalPlayers >= g_iMoveMinPlayers && g_fMoveTime > 0.0);
	bool bKickPlayers = (iTotalPlayers >= g_iKickMinPlayers && g_fKickTime > 0.0);

	// If server is full, disable kick for spectators
	if (iTotalPlayers >= MaxClients && g_iMaxSpectatorsFull > 0)
		bKickPlayers = false;

	if (!bMovePlayers && !bKickPlayers)
		return Plugin_Continue;

	for (client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client))
			continue;

		if (!g_Players_bEnabled[client])
			continue;

		int IdleTime = GetIdleTime(client, iCurrentTime);

	#if defined _entWatch_included
		if (g_bNative_EntWatch && g_iEntWatch > 0 && EW_ClientHasItem(client))
			continue;
	#endif

		int iTeamNum = GetClientTeam(client);

		if (g_Players_bFlagged[client] && (g_fKickTime - IdleTime) > 0.0)
		{
			PrintCenterText(client, "%t", "AFK Welcome Back");
			CPrintToChat(client, "%s {default}%t", TAG, "AFK Unflagged");
			g_Players_bFlagged[client] = false;
		}

		if (bMovePlayers && iTeamNum > CS_TEAM_SPECTATOR && !IsMoveImmune(client))
		{
			float iTimeleft = g_fMoveTime - IdleTime;
			if (iTimeleft > 0.0)
			{
				if (iTimeleft <= g_fWarnTime)
				{
					PrintCenterText(client, "%t", "AFK Move Warning", RoundToFloor(iTimeleft));
					CPrintToChat(client, "%s {default}%t", TAG, "AFK Move Warning", RoundToFloor(iTimeleft));
				}
			}
			else
			{
				CPrintToChatAll("%s %t", TAG, "AFK Moved To Spectate", client);
				ForcePlayerSuicide(client);
				g_Players_iIgnore[client] |= IGNORE_TEAMSWITCH;
				ChangeClientTeam(client, CS_TEAM_SPECTATOR);
			}
		}
		else if (g_fKickTime > 0.0 && !IsKickImmune(client))
		{
			float iTimeleft = g_fKickTime - IdleTime;
			if (iTimeleft > 0.0)
			{
				if (iTimeleft <= g_fWarnTime)
				{
					PrintCenterText(client, "%t", "AFK Kick Warning", RoundToFloor(iTimeleft));
					CPrintToChat(client, "%s {default}%t", TAG, "AFK Kick Warning", RoundToFloor(iTimeleft));
				}
			}
			else
			{
				if (!g_Players_bFlagged[client])
				{
					CPrintToChat(client, "%s {default}%t", TAG, "AFK Kick Flagged");
					g_Players_bFlagged[client] = true;
				}
				int FlaggedPlayers = 0;
				int Position = 1;
				for (int client_ = 1; client_ <= MaxClients; client_++)
				{
					if (!g_Players_bFlagged[client_])
						continue;

					FlaggedPlayers++;
					int IdleTime_ = GetIdleTime(client_, iCurrentTime);

					if (IdleTime_ > IdleTime)
						Position++;
				}
				PrintCenterText(client, "%t", "AFK Kick Flagged Position", Position, FlaggedPlayers);
			}
		}
	}

	if (bKickPlayers)
	{
		int candidates[MAXPLAYERS + 1];
		int candidateTimes[MAXPLAYERS + 1];
		int iCandidateCount = GatherKickCandidates(iCurrentTime, candidates, candidateTimes);

		for (int i = 0; i < iCandidateCount && bKickPlayers; i++)
		{
			int InactivePlayer = candidates[i];
			int InactivePlayerTime = candidateTimes[i];

			g_Players_bFlagged[InactivePlayer] = false;
			CPrintToChatAll("%s %t", TAG, "AFK Kicked", InactivePlayer, InactivePlayerTime);
			KickClient(InactivePlayer, "[AFK] %t", "AFK Kick Reason", InactivePlayerTime);
			iTotalPlayers--;

			bKickPlayers = (iTotalPlayers >= g_iKickMinPlayers && g_fKickTime > 0.0);
		}
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

	return GetIdleTime(client, GetTime());
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

	// Event Managers are back to the regular admin immunity
	CheckEveryoneAdminImmunity();
}
#endif

public void Cvar_MaxSpectatorsFull(ConVar convar, const char[] oldValue, const char[] newValue)
{
	g_iMaxSpectatorsFull = convar.IntValue;
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
				CPrintToChat(i, "%s {fullred}%t", TAG, "AFK Server Full");
				CPrintToChat(i, "%s {fullred}%t", TAG, "AFK Spectators Will Be Kicked");
			}
		}
	}

	return Plugin_Continue;
}

public Action Timer_CheckSpectators(Handle Timer, any Data)
{
	float fSpectatorKickTime = GetFallbackKickTime();
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
			if (IsKickImmune(i))
				continue;

			int idleTime = GetIdleTime(i, iCurrentTime);
			
			// Only consider spectators who have been inactive longer than sm_afk_kick_time
			if (idleTime >= (fSpectatorKickTime / 2) && idleTime > mostInactiveTime)
			{
				mostInactive = i;
				mostInactiveTime = idleTime;
			}
		}

		if (mostInactive != -1)
		{
			// Kick the most inactive spectator
			g_Players_bFlagged[mostInactive] = false;
			CPrintToChatAll("%s %t", TAG, "AFK Kicked For Room", mostInactive, mostInactiveTime);
			KickClient(mostInactive, "[AFK] %t", "AFK Kick For Room Reason", mostInactiveTime);
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
	int candidates[MAXPLAYERS + 1];
	int candidateTimes[MAXPLAYERS + 1];
	int iCandidateCount = GatherKickCandidates(iCurrentTime, candidates, candidateTimes);

	for (int i = 0; i < iCandidateCount && bKickPlayers; i++)
	{
		int InactivePlayer = candidates[i];
		int InactivePlayerTime = candidateTimes[i];

		g_Players_bFlagged[InactivePlayer] = false;
		CPrintToChatAll("%s %t", TAG, "AFK Kicked", InactivePlayer, InactivePlayerTime);
		KickClient(InactivePlayer, "[AFK] %t", "AFK Kick Reason", InactivePlayerTime);

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
		if (!IsClientConnected(i))
			continue;

		g_iConnectedPlayers++;
		if (!IsClientInGame(i))
			continue;

		if (GetClientTeam(i) != CS_TEAM_SPECTATOR)
			continue;

		g_iSpectatorCount++;
	}
}

/*
 * Comparison between the legacy and the new detection.
 * Every disagreement is written to the detection log when it ends, with what kept
 * the other detection from seeing the player as AFK.
 */

stock bool IsObserving()
{
	return g_iDetection != DETECTION_LEGACY && g_bDetectionLog && g_iHealth == HEALTH_OK;
}

// Idle time from which a player counts as AFK in the comparison: the first action the plugin takes
stock int GetObservationThreshold()
{
	return RoundToFloor(g_fMoveTime > 0.0 ? g_fMoveTime : GetFallbackKickTime());
}

void OnObservationChanged()
{
	if (!IsObserving())
		CloseAllEpisodes("comparison stopped");
}

void ObserveDetection(int iNow)
{
	if (!IsObserving())
		return;

	int iThreshold = GetObservationThreshold();

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!g_Players_bEnabled[client] || !IsClientInGame(client))
			continue;

		int iNew = GetNewIdleTime(client, iNow);
		int iLegacy = GetLegacyIdleTime(client, iNow);

		// A disagreement lasts until the detection that sees the player as AFK sees activity
		switch (g_Players_iEpisode[client])
		{
			case EPISODE_NONE:
			{
				if (iNew >= iThreshold && iLegacy < iThreshold)
					StartEpisode(client, EPISODE_NEW_IDLE, iNow);
				else if (iLegacy >= iThreshold && iNew < iThreshold)
					StartEpisode(client, EPISODE_LEGACY_IDLE, iNow);
			}
			case EPISODE_NEW_IDLE:
			{
				if (iNew < iThreshold)
					EndEpisode(client, iNow, "the new detection saw activity");
			}
			case EPISODE_LEGACY_IDLE:
			{
				if (iLegacy < iThreshold)
					EndEpisode(client, iNow, "the legacy detection saw activity");
			}
		}

		if (g_Players_iEpisode[client] != EPISODE_NONE)
		{
			g_Players_iEpisodeMaxNew[client] = IntMax(g_Players_iEpisodeMaxNew[client], iNew);
			g_Players_iEpisodeMaxLegacy[client] = IntMax(g_Players_iEpisodeMaxLegacy[client], iLegacy);
		}
	}
}

void StartEpisode(int client, int iEpisode, int iNow)
{
	g_Players_iEpisode[client] = iEpisode;
	g_Players_iEpisodeStart[client] = iNow;
	g_Players_iEpisodeTeam[client] = GetClientTeam(client);
	g_Players_bEpisodeAlive[client] = IsPlayerAlive(client);
	g_Players_iEpisodeMaxNew[client] = 0;
	g_Players_iEpisodeMaxLegacy[client] = 0;
}

void EndEpisode(int client, int iNow, const char[] sEnd)
{
	int iEpisode = g_Players_iEpisode[client];
	if (iEpisode == EPISODE_NONE)
		return;

	g_Players_iEpisode[client] = EPISODE_NONE;

	char sStart[16], sTeam[8], sCounts[256];
	FormatTime(sStart, sizeof(sStart), "%H:%M:%S", g_Players_iEpisodeStart[client]);
	GetTeamLabel(g_Players_iEpisodeTeam[client], sTeam, sizeof(sTeam));

	if (iEpisode == EPISODE_NEW_IDLE)
	{
		FormatCounts(sCounts, sizeof(sCounts), g_Players_iSinceStrong[client], g_iNewIdleReport, sizeof(g_iNewIdleReport));
		ClearCounts(g_Players_iSinceStrong[client]);
	}
	else
	{
		FormatCounts(sCounts, sizeof(sCounts), g_Players_iSinceLegacy[client], g_iLegacyIdleReport, sizeof(g_iLegacyIdleReport));
		ClearCounts(g_Players_iSinceLegacy[client]);
	}

	LogToFileEx(g_sDetectionLog, "%s %L | %s %s at %s, lasted %ds | idle max: new %ds, legacy %ds (threshold %ds) | %s: %s | view turned without mouse: %d of %d | end: %s",
		iEpisode == EPISODE_NEW_IDLE ? "[new: AFK, legacy: active]" : "[legacy: AFK, new: active]",
		client, sTeam, g_Players_bEpisodeAlive[client] ? "alive" : "dead", sStart, iNow - g_Players_iEpisodeStart[client],
		g_Players_iEpisodeMaxNew[client], g_Players_iEpisodeMaxLegacy[client], GetObservationThreshold(),
		iEpisode == EPISODE_NEW_IDLE ? "since last mouse/chat" : "since last legacy activity", sCounts,
		g_Players_iViewChangesNoMouse[client], g_Players_iViewChanges[client], sEnd);
}

void CloseAllEpisodes(const char[] sEnd)
{
	int iNow = GetTime();
	for (int client = 1; client <= MaxClients; client++)
	{
		if (g_Players_iEpisode[client] == EPISODE_NONE)
			continue;

		if (IsClientConnected(client))
			EndEpisode(client, iNow, sEnd);
		else
			g_Players_iEpisode[client] = EPISODE_NONE;
	}
}

void FormatCounts(char[] sBuffer, int iMaxLen, const int[] iCounts, const int[] iSources, int iSourceCount)
{
	sBuffer[0] = '\0';
	for (int i = 0; i < iSourceCount; i++)
		Format(sBuffer, iMaxLen, "%s%s%s=%d", sBuffer, i ? " " : "", g_sActivityName[iSources[i]], iCounts[iSources[i]]);
}

void FormatLastActivities(char[] sBuffer, int iMaxLen, int client, int iNow, const int[] iSources, int iSourceCount)
{
	sBuffer[0] = '\0';
	for (int i = 0; i < iSourceCount; i++)
	{
		int iTime = g_Players_iActivity[client][iSources[i]];
		if (iTime > 0)
			Format(sBuffer, iMaxLen, "%s%s%s %ds ago", sBuffer, i ? ", " : "", g_sActivityName[iSources[i]], iNow - iTime);
		else
			Format(sBuffer, iMaxLen, "%s%s%s never", sBuffer, i ? ", " : "", g_sActivityName[iSources[i]]);
	}
}

stock void GetTeamLabel(int iTeam, char[] sBuffer, int iMaxLen)
{
	switch (iTeam)
	{
		case CS_TEAM_T: strcopy(sBuffer, iMaxLen, "T");
		case CS_TEAM_CT: strcopy(sBuffer, iMaxLen, "CT");
		case CS_TEAM_SPECTATOR: strcopy(sBuffer, iMaxLen, "spec");
		default: strcopy(sBuffer, iMaxLen, "none");
	}
}

/*
 * sm_afk_status [target]: how both detections see the players, to check a player live
 */

public Action Command_Status(int client, int args)
{
	if (GetCmdReplySource() == SM_REPLY_TO_CHAT)
		ReplyToCommand(client, "[AFK] %t", "See console for output");

	int iNow = GetTime();
	int iThreshold = GetObservationThreshold();
	PrintStatusHeader(client, iThreshold);

	if (args < 1)
	{
		PrintStatusList(client, iNow, iThreshold);
		return Plugin_Handled;
	}

	char sTarget[MAX_TARGET_LENGTH], sTargetName[MAX_TARGET_LENGTH];
	GetCmdArg(1, sTarget, sizeof(sTarget));

	int iTargets[MAXPLAYERS];
	bool bTnIsMl;
	int iCount = ProcessTargetString(sTarget, client, iTargets, sizeof(iTargets), COMMAND_FILTER_NO_BOTS|COMMAND_FILTER_NO_IMMUNITY, sTargetName, sizeof(sTargetName), bTnIsMl);
	if (iCount <= 0)
	{
		ReplyToTargetError(client, iCount);
		return Plugin_Handled;
	}

	for (int i = 0; i < iCount; i++)
		PrintPlayerStatus(client, iTargets[i], iNow);

	return Plugin_Handled;
}

void PrintStatusHeader(int client, int iThreshold)
{
	switch (g_iDetection)
	{
		case DETECTION_LEGACY: PrintToConsole(client, "[AFK] Mode 0: legacy detection only");
		case DETECTION_OBSERVE: PrintToConsole(client, "[AFK] Mode 1: legacy detection acts, the new one is compared to it");
		case DETECTION_NEW: PrintToConsole(client, "[AFK] Mode 2: new detection acts%s", UseNewDetection() ? "" : " (legacy until the mouse data is confirmed)");
	}

	if (g_iHealth == HEALTH_OK)
		PrintToConsole(client, "[AFK] New detection ready: mouse movement received for %.0f%% of %d view changes", float(g_iHealthMouseSamples) * 100.0 / float(g_iHealthSamples), g_iHealthSamples);
	else if (g_iHealth == HEALTH_UNKNOWN)
		PrintToConsole(client, "[AFK] New detection waiting for data: %d of %d view changes seen", g_iHealthSamples, HEALTH_MIN_SAMPLES);
	else
		PrintToConsole(client, "[AFK] New detection disabled: the server does not receive the players' mouse movement");

	PrintToConsole(client, "[AFK] Comparison threshold %ds, mouse threshold %d per second, keys alone %ds", iThreshold, g_iMouseThreshold, g_iKeyOnlyTime);
}

void PrintStatusList(int client, int iNow, int iThreshold)
{
	int iClients[MAXPLAYERS + 1];
	int iSortIdle[MAXPLAYERS + 1];
	int iCount = 0;

	// Most idle first, whichever detection sees it
	for (int target = 1; target <= MaxClients; target++)
	{
		if (!IsClientInGame(target) || IsFakeClient(target))
			continue;

		int iIdle = g_Players_bEnabled[target] ? IntMax(GetNewIdleTime(target, iNow), GetLegacyIdleTime(target, iNow)) : -1;

		int iPos = iCount;
		while (iPos > 0 && iSortIdle[iPos - 1] < iIdle)
		{
			iClients[iPos] = iClients[iPos - 1];
			iSortIdle[iPos] = iSortIdle[iPos - 1];
			iPos--;
		}
		iClients[iPos] = target;
		iSortIdle[iPos] = iIdle;
		iCount++;
	}

	PrintToConsole(client, "  %-24s %-5s %-6s %7s %7s", "Player", "Team", "State", "Legacy", "New");

	for (int i = 0; i < iCount; i++)
	{
		int target = iClients[i];

		char sName[25], sTeam[8];
		GetClientName(target, sName, sizeof(sName));
		GetTeamLabel(GetClientTeam(target), sTeam, sizeof(sTeam));
		char sState[8];
		strcopy(sState, sizeof(sState), IsPlayerAlive(target) ? "alive" : "dead");

		if (!g_Players_bEnabled[target])
		{
			PrintToConsole(client, "  %-24s %-5s %-6s %7s %7s  not tracked", sName, sTeam, sState, "-", "-");
			continue;
		}

		int iNew = GetNewIdleTime(target, iNow);
		int iLegacy = GetLegacyIdleTime(target, iNow);

		char sNote[48];
		if (iNew >= iThreshold && iLegacy < iThreshold)
			strcopy(sNote, sizeof(sNote), "<- AFK for the new detection only");
		else if (iLegacy >= iThreshold && iNew < iThreshold)
			strcopy(sNote, sizeof(sNote), "<- AFK for the legacy detection only");

		PrintToConsole(client, "  %-24s %-5s %-6s %6ds %6ds  %s", sName, sTeam, sState, iLegacy, iNew, sNote);
	}
}

void PrintPlayerStatus(int client, int target, int iNow)
{
	char sTeam[8];
	GetTeamLabel(GetClientTeam(target), sTeam, sizeof(sTeam));
	PrintToConsole(client, "[AFK] %N (#%d) - %s, %s", target, GetClientUserId(target), sTeam, IsPlayerAlive(target) ? "alive" : "dead");

	if (!g_Players_bEnabled[target])
	{
		PrintToConsole(client, "  Not tracked (admin immunity, or not fully connected yet).");
		return;
	}

	PrintToConsole(client, "  Idle: legacy %ds, new %ds. Used to act: %s detection.", GetLegacyIdleTime(target, iNow), GetNewIdleTime(target, iNow), UseNewDetection() ? "new" : "legacy");

	char sLine[256];
	FormatLastActivities(sLine, sizeof(sLine), target, iNow, g_iNewSources, sizeof(g_iNewSources));
	PrintToConsole(client, "  New detection - %s", sLine);
	FormatLastActivities(sLine, sizeof(sLine), target, iNow, g_iLegacySources, sizeof(g_iLegacySources));
	PrintToConsole(client, "  Legacy detection - %s", sLine);
	PrintToConsole(client, "  View turned without mouse while alive: %d of %d times", g_Players_iViewChangesNoMouse[target], g_Players_iViewChanges[target]);

	if (g_Players_iEpisode[target] != EPISODE_NONE)
		PrintToConsole(client, "  The detections disagree for %ds: AFK for the %s detection only.", iNow - g_Players_iEpisodeStart[target], g_Players_iEpisode[target] == EPISODE_NEW_IDLE ? "new" : "legacy");
}
