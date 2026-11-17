// beam-paint: hold +paint to draw on the map with beams, lasers or decals.
// Standalone copy of the surftimer-gf paint (rc144, master e38414ac).
// The paint itself is in beampaint/paint.sp and saving is in beampaint/db/paint.sp.
// This file is the glue that surftimer-gf provided: forwards, commands, cvars,
// the database connection, chat prefix, SteamIDs and the map name.

#pragma semicolon 1
#pragma newdecls required

#include <sourcemod>
#include <sdktools>
#include <colorvariables>

#define PLUGIN_VERSION "1.0.1"
#define PAINT_DEFAULT_MATERIAL "materials/beampaint/paintbeam.vmt"
#define PAINT_DEFAULT_TEXTURE "materials/beampaint/white.vtf"

public Plugin myinfo =
{
	name = "Beam Paint",
	author = "dPexx",
	description = "Hold +paint to draw with beams, lasers or decals; saved per player and map",
	version = PLUGIN_VERSION,
	url = ""
};

/* ===== what surftimer-gf provided ===== */

Database g_hDb;							// set once the tables exist; null = saving off
char g_szSteamID[MAXPLAYERS + 1][32];	// AuthId_Steam2, same format as surftimer
char g_szMapName[64];					// display name, no workshop path
char g_szChatPrefix[128];
int g_BeamSprite;						// sprites/laserbeam, used by Laser mode and as fallback

ConVar g_hPaintLife;
ConVar g_hPaintBudget;
ConVar g_hPaintMaxSegs;
ConVar g_hPaintLift;
ConVar g_hPaintMinDist;
ConVar g_hPaintMaxDist;
ConVar g_hPaintWidthSmall;
ConVar g_hPaintWidthMedium;
ConVar g_hPaintWidthLarge;
ConVar g_hPaintDebug;
ConVar g_hPaintCatchupDist;
ConVar g_hPaintCatchupDelay;
ConVar g_hPaintCatchupBudget;
ConVar g_hPaintResendFrac;
ConVar g_hPaintTempEnts;
ConVar g_hPaintPvs;
ConVar g_hPaintPvsPeriod;
ConVar g_hPaintPvsMaxCalls;
ConVar g_hPaintMaterial;
ConVar g_hPaintBeamFlags;
ConVar g_hPaintBeamTE;
ConVar g_hPaintFlag;
ConVar g_hPaintEdgeAngle;
ConVar g_hPaintEdgeSnap;
ConVar g_hPaintGrazeAngle;
ConVar g_hPaintBandWidth;
ConVar g_hPaintEdgeSnapAngle;
ConVar g_hChatPrefix;

#include "beampaint/paint.sp"
#include "beampaint/db/paint.sp"
#if defined BEAMPAINT_DEVTEST
	#include "beampaint/devtest_replay.sp"
#endif

// A dev build next to surftimer (which registers the same commands) uses other names.
#if defined BEAMPAINT_DEVTEST
	#define PAINT_CMD(%1) "sm_b" ... %1
	#define PAINT_PLUS "+bpaint"
	#define PAINT_MINUS "-bpaint"
#else
	#define PAINT_CMD(%1) "sm_" ... %1
	#define PAINT_PLUS "+paint"
	#define PAINT_MINUS "-paint"
#endif

public void OnPluginStart()
{
	CreateConVar("sm_beampaint_version", PLUGIN_VERSION, "Beam Paint version", FCVAR_NOTIFY | FCVAR_DONTRECORD);
	g_hPaintFlag = CreateConVar("sm_beampaint_flag", "", "Admin flag(s) needed to paint, e.g. \"o\" or \"b\"; empty = everyone. Override name: beampaint", FCVAR_NOTIFY);
	g_hChatPrefix = CreateConVar("sm_beampaint_prefix", "{lime}[Paint]{default}", "Chat prefix, with {colour} tags", FCVAR_NOTIFY);
	g_hPaintLife = CreateConVar("sm_beampaint_life", "5.0", "Paint beam life in seconds; every segment is re-sent once per life", FCVAR_NOTIFY, true, 0.5, true, 25.0);
	g_hPaintBudget = CreateConVar("sm_beampaint_budget", "16", "Max paint beams re-sent per server tick, all painters together (0 = no re-send)", FCVAR_NOTIFY, true, 0.0, true, 64.0);
	g_hPaintMaxSegs = CreateConVar("sm_beampaint_max_segments", "1024", "Max paint segments per player (about 10 per second of painting); the oldest go first", FCVAR_NOTIFY, true, 1.0, true, 2048.0);
	g_hPaintLift = CreateConVar("sm_beampaint_lift", "1.0", "Units a paint point is lifted off the surface it hit", FCVAR_NOTIFY, true, 0.0, true, 16.0);
	g_hPaintMinDist = CreateConVar("sm_beampaint_min_dist", "2.0", "Min distance between paint samples", FCVAR_NOTIFY, true, 0.0);
	g_hPaintMaxDist = CreateConVar("sm_beampaint_max_dist", "256.0", "Above this distance between samples a new paint stroke starts instead of joining", FCVAR_NOTIFY, true, 1.0);
	g_hPaintWidthSmall = CreateConVar("sm_beampaint_width_small", "4.0", "Paint beam width, small", FCVAR_NOTIFY, true, 0.1, true, 64.0);
	g_hPaintWidthMedium = CreateConVar("sm_beampaint_width_medium", "12.0", "Paint beam width, medium", FCVAR_NOTIFY, true, 0.1, true, 64.0);
	g_hPaintWidthLarge = CreateConVar("sm_beampaint_width_large", "30.0", "Paint beam width, large", FCVAR_NOTIFY, true, 0.1, true, 64.0);
	g_hPaintDebug = CreateConVar("sm_beampaint_debug", "0", "Paint debug to logs/beampaint_debug.log: 1 = once a second, segments and late re-sends (beam gaps); 2 = also what the aim trace hits while painting", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	g_hPaintCatchupDist = CreateConVar("sm_beampaint_catchup_dist", "512", "Distance a player must move within one tick (a teleport) for all paint to be re-sent to them straight away; 0 = off", FCVAR_NOTIFY, true, 0.0);
	g_hPaintCatchupDelay = CreateConVar("sm_beampaint_catchup_delay", "0", "Seconds to wait after a teleport before paint catch-up; 0 starts on the next tick", FCVAR_NOTIFY, true, 0.0, true, 2.0);
	g_hPaintCatchupBudget = CreateConVar("sm_beampaint_catchup_budget", "240", "Max extra paint temp entities per tick for catch-ups, on top of sm_beampaint_budget; also limited by sv_multiplayer_maxtempentities", FCVAR_NOTIFY, true, 0.0, true, 240.0);
	// ConVars survive a plugin reload with their old bounds; CreateConVar alone keeps max 64.
	g_hPaintCatchupBudget.SetBounds(ConVarBound_Upper, true, 240.0);
	g_hPaintResendFrac = CreateConVar("sm_beampaint_resend_frac", "0.85", "Re-send each paint beam after this fraction of its life; 0.5 keeps two copies alive (covers a lost send, double the client FPS cost), 0.85 about 1.18 (copies = 1 / fraction)", FCVAR_NOTIFY, true, 0.5, true, 0.95);
	g_hPaintTempEnts = CreateConVar("sm_beampaint_tempents", "256", "Sets the engine's hidden sv_multiplayer_maxtempentities (temp entities per player per tick, stock 32) on each map and when changed; 256 lets a teleport's paint arrive in one tick. 0 = leave the engine value alone", FCVAR_NOTIFY, true, 0.0, true, 1024.0);
	g_hPaintTempEnts.AddChangeHook(Paint_OnTempEntsChanged);
	g_hPaintPvs = CreateConVar("sm_beampaint_pvs", "1", "1 = send paint beams only to players whose PVS has them, and send a beam the moment it enters a player's PVS (clients drop beams outside their PVS); 0 = old behaviour", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hPaintPvsPeriod = CreateConVar("sm_beampaint_pvs_period", "0.1", "sm_beampaint_pvs: seconds to check every paint segment against every player's PVS once", FCVAR_NOTIFY, true, 0.02, true, 2.0);
	g_hPaintPvsMaxCalls = CreateConVar("sm_beampaint_pvs_max_calls", "192", "sm_beampaint_pvs: max engine PVS tests per tick; more paint then makes the check cycle longer instead of the tick heavier", FCVAR_NOTIFY, true, 8.0, true, 4096.0);
	g_hPaintMaterial = CreateConVar("sm_beampaint_material", PAINT_DEFAULT_MATERIAL, "Paint beam material path; takes effect on the next map", FCVAR_NOTIFY);
	g_hPaintBeamFlags = CreateConVar("sm_beampaint_beam_flags", "0", "Paint beam flags test value; ignored by CS:GO BeamPoints rendering", FCVAR_NOTIFY, true, 0.0, true, 65535.0);
	g_hPaintBeamTE = CreateConVar("sm_beampaint_beam_te", "1", "Beams: 1 = BeamEntPoint temp entity (not culled by solid behind flat ramps), 0 = old BeamPoints", FCVAR_NOTIFY, true, 0.0, true, 1.0);
	g_hPaintEdgeAngle = CreateConVar("sm_beampaint_edge_angle", "20.0", "Two samples on faces whose normals differ by more than this (degrees) snap the stroke to the edge between them (ramp spines); 0 = off", FCVAR_NOTIFY, true, 0.0, true, 179.0);
	g_hPaintEdgeSnap = CreateConVar("sm_beampaint_edge_snap", "8.0", "Aim within this many units of an edge snaps to it; 0 = off", FCVAR_NOTIFY, true, 0.0, true, 64.0);
	g_hPaintGrazeAngle = CreateConVar("sm_beampaint_graze_angle", "4.0", "Skip samples where the aim meets the surface at less than this many degrees (they jump along it); 0 = off", FCVAR_NOTIFY, true, 0.0, true, 45.0);
	g_hPaintEdgeSnapAngle = CreateConVar("sm_beampaint_edge_snap_angle", "1.5", "Aim within this many degrees of an edge (as seen by the painter) also snaps to it, for spines painted from far away; 0 = units only", FCVAR_NOTIFY, true, 0.0, true, 10.0);
	g_hPaintBandWidth = CreateConVar("sm_beampaint_band_width", "4.0", "Beam/Laser strokes wider than this are drawn as flat bands of thin beams lying on the surface, each at most this wide (up to 8 per segment; they count against the budgets); 0 = one wide camera-facing beam", FCVAR_NOTIFY, true, 0.0, true, 32.0);
	AutoExecConfig(true, "beampaint");

	g_hChatPrefix.AddChangeHook(OnPrefixChanged);
	g_hChatPrefix.GetString(g_szChatPrefix, sizeof(g_szChatPrefix));

	RegConsoleCmd(PAINT_PLUS, Command_PaintStart, "[paint] hold to paint");
	RegConsoleCmd(PAINT_MINUS, Command_PaintStop, "[paint] stops painting");
	RegConsoleCmd(PAINT_CMD("paint"), Command_Paint, "[paint] paint menu: mode, colour, size, view, save");
	RegConsoleCmd(PAINT_CMD("paintcolour"), Command_PaintColour, "[paint] [r g b | #RRGGBB | random] - sets your paint colour, no args opens the colour menu");
	RegConsoleCmd(PAINT_CMD("paintcolor"), Command_PaintColour, "[paint] [r g b | #RRGGBB | random] - sets your paint colour, no args opens the colour menu");
	RegConsoleCmd(PAINT_CMD("paintsize"), Command_PaintSize, "[paint] [1-3] - sets your paint size, no args cycles it");
	RegConsoleCmd(PAINT_CMD("paintview"), Command_PaintView, "[paint] toggles seeing everyone's paint or only your own");
	RegConsoleCmd(PAINT_CMD("paintsave"), Command_PaintSave, "[paint] saves your paint for this map");
	RegConsoleCmd(PAINT_CMD("paintautosave"), Command_PaintAutosave, "[paint] toggles saving your paint automatically");
	RegConsoleCmd(PAINT_CMD("paintclear"), Command_PaintClear, "[paint] removes your paint from the map (not your saved copy)");
	RegConsoleCmd(PAINT_CMD("paintdelete"), Command_PaintDelete, "[paint] deletes your saved paint for this map");

	Paint_OnPluginStart();
#if defined BEAMPAINT_DEVTEST
	Paint_RecOnPluginStart();
#endif

	// Late load: players already here never get OnClientAuthorized again.
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientConnected(client) && !IsFakeClient(client) && IsClientAuthorized(client))
			GetClientAuthId(client, AuthId_Steam2, g_szSteamID[client], sizeof(g_szSteamID[]));
	}

	db_connect();
}

public void OnPrefixChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	strcopy(g_szChatPrefix, sizeof(g_szChatPrefix), newValue);
}

public void OnMapStart()
{
	char map[PLATFORM_MAX_PATH];
	GetCurrentMap(map, sizeof(map));
	if (!GetMapDisplayName(map, g_szMapName, sizeof(g_szMapName)))
		strcopy(g_szMapName, sizeof(g_szMapName), map);

	g_BeamSprite = PrecacheModel("materials/sprites/laserbeam.vmt", true);
	Paint_OnMapStart();
	CreateTimer(0.1, Timer_PaintSample, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
}

public void OnConfigsExecuted()
{
	Paint_PrecacheMaterial();
	Paint_ApplyTempEnts();
}

public void OnMapEnd()
{
#if defined BEAMPAINT_DEVTEST
	Paint_RecOnMapEnd();
#endif
	Paint_OnMapEnd();
}

public Action Timer_PaintSample(Handle timer)
{
	Paint_Sample();
	return Plugin_Continue;
}

public void OnGameFrame()
{
	Paint_Scheduler();
}

public void OnClientPutInServer(int client)
{
	Paint_OnClientPutInServer(client);
}

public void OnClientAuthorized(int client, const char[] auth)
{
	if (IsFakeClient(client))
		return;
	if (!GetClientAuthId(client, AuthId_Steam2, g_szSteamID[client], sizeof(g_szSteamID[])))
		g_szSteamID[client][0] = '\0';
}

public void OnClientPostAdminCheck(int client)
{
	Paint_OnClientPostAdminCheck(client);
}

public void OnClientDisconnect(int client)
{
#if defined BEAMPAINT_DEVTEST
	Paint_RecStop(client);
#endif
	Paint_OnClientDisconnect(client);
	g_szSteamID[client][0] = '\0';
}

/* ===== helpers surftimer-gf provided ===== */

stock bool IsValidClient(int client)
{
	return client >= 1 && client <= MaxClients && IsClientConnected(client) && IsClientInGame(client);
}

stock void EscapeQueryString(const char[] input, char[] output, int maxlen)
{
	if (g_hDb == null || !g_hDb.Escape(input, output, maxlen))
		output[0] = '\0';
}

// A query can finish after its player has left and someone else has taken the slot.
// Pass ClientToRef(client) as the query data and turn it back with ClientFromRef in
// the callback: you get 0 if that player is gone, never the newcomer.
stock int ClientToRef(int client)
{
	if (client < 1 || client > MaxClients || !IsClientConnected(client))
		return 0;
	return GetClientUserId(client);
}

stock int ClientFromRef(int ref)
{
	return ref == 0 ? 0 : GetClientOfUserId(ref);
}

// Logs a failed query (null result set) under the callback's name; true means the caller should return
stock bool SqlFailed(DBResultSet hndl, const char[] error, const char[] szCallback)
{
	if (hndl != null)
		return false;
	LogError("[beampaint] SQL Error (%s): %s", szCallback, error);
	return true;
}
