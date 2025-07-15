#if defined _AFKManager_Included
#endinput
#endif
#define _AFKManager_Included

#define AFKManager_V_MAJOR   "1"
#define AFKManager_V_MINOR   "4"
#define AFKManager_V_PATCH   "1"

#define AFKManager_VERSION   AFKManager_V_MAJOR..."."...AFKManager_V_MINOR..."."...AFKManager_V_PATCH

/**
 * Gets the idle time of a client in seconds
 *
 * @param client        Client index
 * @return             Number of seconds client has been idle, 0 if not being tracked, -1 on error
 * @error              If client is invalid, not in game, or is a bot
 */
native int GetClientIdleTime(int client);

public SharedPlugin __pl_AFKManager =
{
	name = "AFKManager",
	file = "AFKManager.smx",
#if defined REQUIRE_PLUGIN
	required = 1,
#else
	required = 0,
#endif
};

#if !defined REQUIRE_PLUGIN
public void __pl_AFKManager_SetNTVOptional()
{
	MarkNativeAsOptional("GetClientIdleTime");
}
#endif
