# Copilot Instructions for AFK Manager Plugin

## Repository Overview

This repository contains **AFKManager**, a sophisticated SourceMod plugin for managing AFK (Away From Keyboard) players on Source engine game servers. The plugin intelligently detects inactive players using multiple methods and provides configurable actions like moving to spectator or kicking players to maintain server performance and player engagement.

### Key Features
- Multi-method AFK detection (eye movement, button input, spectator mode changes)
- Configurable kick/move timers with warning system
- Admin immunity system with granular controls
- Full server spectator management with priority kicking
- Integration with popular plugins (EntWatch, ZombieReloaded, EventsManager)
- Translation support via MultiColors
- Native API for other plugins to query idle time

## Technical Environment

- **Language**: SourcePawn (Source engine scripting language)
- **Platform**: SourceMod 1.11+ (latest stable release)
- **Build System**: SourceKnight (Docker-based SourceMod compiler)
- **CI/CD**: GitHub Actions with automated builds and releases

## Project Structure

```
addons/sourcemod/
├── scripting/
│   ├── AFKManager.sp           # Main plugin source (~750 lines)
│   └── include/
│       └── AFKManager.inc      # Native function definitions and API
├── plugins/                    # Compiled output (gitignored)
└── [other standard SM dirs]    # configs/, translations/, etc.

.github/
├── workflows/ci.yml            # Build and release automation
└── dependabot.yml             # Dependency updates

sourceknight.yaml               # Build configuration and dependencies
```

## Build System

### SourceKnight Configuration
The project uses SourceKnight for building, which provides:
- Automated dependency management
- Docker-based compilation environment
- Consistent builds across platforms

### Dependencies (from sourceknight.yaml)
- **sourcemod**: Core SourceMod framework (v1.11.0-git6934)
- **zombiereloaded**: Zombie:Reloaded integration (optional)
- **multicolors**: Chat color formatting
- **EntWatch**: Special item holder integration (optional)

### Build Commands
```bash
# Using GitHub Action (recommended)
# The CI automatically builds on push/PR using maxime1907/action-sourceknight@v1

# Local build (if sourceknight is installed)
sourceknight build

# Manual compilation (if SourceMod compiler is available)
spcomp -i addons/sourcemod/scripting/include addons/sourcemod/scripting/AFKManager.sp
```

### Build Outputs
- Compiled plugin: `.sourceknight/package/addons/sourcemod/plugins/AFKManager.smx`
- Package structure mirrors standard SourceMod installation

## Code Architecture

### Core Detection System
The AFK detection system uses multiple methods in `OnPlayerRunCmd`:

1. **Eye Position Tracking**: Monitors view angle changes
2. **Button Input**: Detects any button presses/releases
3. **Spectator Behavior**: Tracks spectator mode and target changes
4. **Chat Activity**: Monitors say/say_team commands

### Key Global Variables
```sourcepawn
bool g_Players_bEnabled[MAXPLAYERS + 1];    // Player tracking status
bool g_Players_bFlagged[MAXPLAYERS + 1];    // Kick-flagged status
int g_Players_iLastAction[MAXPLAYERS + 1];  // Last activity timestamp
float g_Players_fEyePosition[MAXPLAYERS + 1][3]; // Eye angle tracking
int g_Players_iIgnore[MAXPLAYERS + 1];      // Ignore flags for special situations
```

### Ignore Flags System
Uses bitwise flags to handle special cases:
- `IGNORE_EYEPOSITION`: Skip eye movement checks (after spawn/teleport)
- `IGNORE_TEAMSWITCH`: Skip team change detection (during automated moves)
- `IGNORE_OBSERVER`: Skip spectator checks (during death/forced spectate)

### Timer System
- `Timer_CheckPlayer`: Main AFK checking (5-second interval)
- `Timer_CheckSpectators`: Spectator management (10-second interval)
- `Timer_CheckFullServer`: Full server warnings (5-second interval)

## Configuration System

### ConVars (Auto-generated config)
```sourcepawn
sm_afk_move_time "60.0"         // Time before moving to spectator
sm_afk_kick_time "120.0"        // Time before kick-flagging
sm_afk_warn_time "30.0"         // Warning time before action
sm_afk_move_min "10"            // Minimum players for moves
sm_afk_kick_min "30"            // Minimum players for kicks
sm_afk_immunity "1"             // Admin immunity level
sm_afk_immunity_items "1"       // Item holder immunity
sm_afk_max_spectators_full "10" // Max spectators when full
```

### Immunity Levels
- `0`: No immunity
- `1`: Complete immunity (default)
- `2`: Immunity from kicks only
- `3`: Immunity from moves only

## Plugin Integrations

### EntWatch Integration
```sourcepawn
#if defined _EntWatch_include
if (g_bNative_EntWatch && g_iEntWatch > 0 && EntWatch_HasSpecialItem(client))
    continue; // Skip AFK action for item holders
#endif
```

### ZombieReloaded Integration
Handles infection/cure events to prevent false AFK detections during gameplay mechanics.

### EventsManager Integration
Provides enhanced admin immunity during events with `Admin_Custom4` flag checking.

## Code Style Guidelines

### Naming Conventions
- **Global variables**: Prefix with `g_` (e.g., `g_fKickTime`)
- **Player arrays**: Use `g_Players_` prefix (e.g., `g_Players_bEnabled`)
- **Functions**: PascalCase (e.g., `CheckAdminImmunity`)
- **Local variables**: camelCase (e.g., `iCurrentTime`)

### Memory Management
- Use `delete` for Handle cleanup (no null checks needed)
- Avoid `.Clear()` on StringMap/ArrayList (memory leaks)
- Always create new instances after deletion

### Best Practices Specific to This Plugin
- Always use asynchronous SQL operations (if database features are added)
- Handle late loading in `OnMapStart()`
- Update player counts after team changes
- Use ignore flags for temporary state changes
- Implement proper cleanup in event handlers

## Native API

### Public Functions
```sourcepawn
/**
 * Gets the idle time of a client in seconds
 * @param client        Client index
 * @return             Number of seconds client has been idle, 0 if not being tracked, -1 on error
 */
native int GetClientIdleTime(int client);
```

### Usage Example
```sourcepawn
#include <AFKManager>

// Check if player has been idle for more than 30 seconds
if (GetClientIdleTime(client) > 30)
{
    // Handle idle player
}
```

## Testing and Development

### Development Setup
1. Clone repository with dependencies
2. Use SourceKnight for building (via CI or local setup)
3. Test on development server with various scenarios

### Key Test Scenarios
- AFK detection accuracy across different game modes
- Admin immunity behavior at different levels
- Full server spectator management
- Plugin integration compatibility
- Edge cases (map changes, late loading, rapid team switches)

### Debug Commands
The plugin includes built-in monitoring via console variables and can be extended with debug commands for development.

## Common Development Patterns

### Event Handling Pattern
```sourcepawn
public void Event_PlayerTeamPost(Handle event, const char[] name, bool dontBroadcast)
{
    int client = GetClientOfUserId(GetEventInt(event, "userid"));
    if (client > 0 && !IsFakeClient(client))
    {
        // Handle ignore flags to prevent false positives
        if (g_Players_iIgnore[client] & IGNORE_TEAMSWITCH)
            g_Players_iIgnore[client] &= ~IGNORE_TEAMSWITCH;
        else
            g_Players_iLastAction[client] = GetTime();
    }
}
```

### Safe Player Iteration
```sourcepawn
for (int client = 1; client <= MaxClients; client++)
{
    if (!IsClientInGame(client) || IsFakeClient(client))
        continue;
        
    if (!g_Players_bEnabled[client])
        continue;
        
    // Safe to process player
}
```

### Timer Cleanup Pattern
```sourcepawn
public Action Timer_Function(Handle timer, any data)
{
    // Always return Plugin_Continue for repeating timers
    // Return Plugin_Stop for one-time timers
    return Plugin_Continue;
}
```

## Performance Considerations

- **Frequency**: Main checks run every 5 seconds (balance between responsiveness and performance)
- **Early Returns**: Multiple early returns in player iteration to minimize processing
- **Conditional Processing**: Different logic paths based on server population
- **Ignore Flags**: Prevent unnecessary calculations during state transitions
- **Efficient Comparisons**: Use integer timestamps over float calculations where possible

## Release and Versioning

- **Versioning**: Semantic versioning in `AFKManager.inc` (`MAJOR.MINOR.PATCH`)
- **Releases**: Automated via GitHub Actions on tag push
- **Artifacts**: Packaged as `.tar.gz` with proper SourceMod directory structure

## Integration Notes for AI Agents

When modifying this plugin:
1. Always test AFK detection accuracy after changes
2. Verify admin immunity still works correctly
3. Check plugin integration compatibility
4. Ensure proper cleanup in all code paths
5. Test edge cases like late loading and map changes
6. Follow the existing ignore flag patterns for new features
7. Maintain the timer intervals unless performance requires changes
8. Keep the native API backward compatible