// Paint: Beam (default), Laser and saved Decal modes. Hold +paint to draw.
// Beam strokes are chains of beam temp
// entities drawn in free space between aim points, so static-prop surfaces (surf_whiteout
// ramps) can be painted, which the old decal paint plugin (paint.smx) could not do.
//
// Beams expire on the client, so every segment is re-sent once per sm_beampaint_life by
// Paint_Scheduler (OnGameFrame), at most sm_beampaint_budget temp entities per tick for all
// painters together. Each player sees their own paint, plus everyone else's unless they
// chose "only mine". Saving per player and map, and the settings: db/paint.sp.
//
// The client drops a temporary beam whose box is outside its PVS when it arrives. With
// sm_beampaint_pvs (default) beams go only to players whose PVS has them, and a beam is sent
// to a player the moment it enters their PVS (Paint_PvsScan, then Paint_CatchupSend). With
// sm_beampaint_pvs 0, a player who moves more than sm_beampaint_catchup_dist in one tick
// gets a catch-up pass after sm_beampaint_catchup_delay: every segment they see is re-sent to
// them alone, up to sm_beampaint_catchup_budget beams a tick on top of the round-robin's.

#define PAINT_SIZES 3
#define PAINT_VIEW_ALL 0
#define PAINT_VIEW_OWN 1
#define PAINT_ROWS_PER_INSERT 24	// rows now carry a normal; keeps the 8192-byte insert buffer clear
#define PAINT_MODE_BEAM 0
#define PAINT_MODE_LASER 1
#define PAINT_MODE_DECAL 2
#define PAINT_MODES 3
#define PAINT_SEEN_WORDS ((MAXPLAYERS + 32) / 32)

enum struct PaintSegment
{
	float start[3];
	float end[3];
	int color[4];
	float width;
	float normal[3];		// surface normal: drawn as a flat band of thin beams on it; zero = one plain beam
	int mode;
	int size;                       // decal material size, independent of beam width cvars
	int decalSeen[PAINT_SEEN_WORDS]; // recipients already sent this persistent decal this map
	int pvsIn[PAINT_SEEN_WORDS];	// sm_beampaint_pvs: viewers whose PVS has this row now (Paint_PvsScan)
	int alive[PAINT_SEEN_WORDS];	// viewers that got a send of it while it was in their PVS, beam not expired
	bool saved;			// in the owner's saved copy: loaded from it, or part of a save that succeeded
	int saveGen;		// save that included this segment, 0 = none; it becomes saved when that save succeeds
	float lastSend;		// GetGameTime() of the last send, 0.0 = not sent yet
}

ArrayList g_hPaintSegs[MAXPLAYERS + 1];		// PaintSegment, per owner, oldest first
int g_iPaintCursor[MAXPLAYERS + 1];			// next segment the scheduler re-sends
float g_fPaintDebt[MAXPLAYERS + 1];			// re-sends owed (fraction carried between ticks)
bool g_bPainting[MAXPLAYERS + 1];
bool g_bPaintHasLast[MAXPLAYERS + 1];		// false: the next sample starts a new stroke
float g_fPaintLast[MAXPLAYERS + 1][3];
float g_fPaintLastPointNormal[MAXPLAYERS + 1][3];	// surface normal at g_fPaintLast (bisector on an edge)
int g_iPaintStroke[MAXPLAYERS + 1][3];		// colour of the stroke being drawn

// Settings (beampaint_options)
int g_iPaintColor[MAXPLAYERS + 1][3];
bool g_bPaintRandom[MAXPLAYERS + 1];
int g_iPaintSize[MAXPLAYERS + 1];
int g_iPaintMode[MAXPLAYERS + 1];
int g_iPaintView[MAXPLAYERS + 1];
bool g_bPaintAutosave[MAXPLAYERS + 1];
bool g_bPaintOptionsLoaded[MAXPLAYERS + 1]; // wait for visibility before sending irreversible decals
bool g_bPaintOptsChanged[MAXPLAYERS + 1];	// changed before the settings query came back: ignore its result

bool g_bPaintDirty[MAXPLAYERS + 1];			// changed since the last save or load
bool g_bPaintCapWarned[MAXPLAYERS + 1];		// told the painter the cap is deleting old paint
int g_iPaintSaveGen[MAXPLAYERS + 1];		// last save started for this player, see PaintSegment.saveGen
int g_iPaintMapSerial;						// bumped every map; stale load callbacks are dropped
char g_szPaintMap[64];						// kept after OnMapEnd clears g_szMapName, for disconnect saves
int g_iPaintBeam;
int g_iPaintDecal[14][PAINT_SIZES];
bool g_bPaintDecalsReady;
char g_szPaintModeNames[][] = { "Beam", "Laser (black is invisible)", "Decal" };
// Same order as g_iPaintPresets.
char g_szPaintDecalNames[][] = { "white", "black", "red", "orange", "yellow", "green", "darkgreen", "cyan", "lightblue", "blue", "purple", "pink", "lightpink", "brown" };
char g_szPaintDecalSuffix[][] = { "", "_med", "_large" };
int g_iPaintNextOwner;

// Most cursor steps per owner per tick (overdue rows can be sent without debt).
#define PAINT_OWNER_STEPS_PER_TICK 32

// Catch-up pass (per viewer): the client refuses temporary beams that are outside its PVS
// when they arrive, so after a teleport the paint at the new place is missing until the
// round-robin comes round again. A pass re-sends every segment that viewer sees, to them only.
// (The delay was a fixed 0.3 s, checked every 100 ms; now sm_beampaint_catchup_delay, checked every tick.)
float g_fPaintCatchAt[MAXPLAYERS + 1];		// game time the pass may start, 0.0 = none pending
float g_fPaintCatchTrigger[MAXPLAYERS + 1];	// debug: game time the pass was triggered
int g_iPaintCatchOwner[MAXPLAYERS + 1];		// 1-based owner offset from viewer; their own rows go first
int g_iPaintCatchIndex[MAXPLAYERS + 1];		// segment index in that owner's list
int g_iPaintCatchSent[MAXPLAYERS + 1];		// debug: beams sent by the current pass
float g_fPaintViewPos[MAXPLAYERS + 1][3];	// position at the last sample
bool g_bPaintViewPosSet[MAXPLAYERS + 1];
int g_iPaintNextViewer;
ConVar g_hPaintTempEntLimit;			// engine's per-client temp-entity snapshot ceiling

// PVS-entry send (sm_beampaint_pvs). The client drops a temporary beam whose box is outside its
// PVS when it arrives (view_beams.cpp CullBeam -> IsBoxVisible) and never retries it. So the
// server tracks per row and viewer whether the row is in the viewer's PVS (pvsIn, from
// GetClientsInRange in Paint_PvsScan) and whether the viewer has a live copy (alive). A row
// with pvsIn && !alive is sent to that viewer at once by the catch-up pass ("entry"), and
// round-robin sends go only to viewers whose PVS has the row.
bool g_bPaintEntryDirty[MAXPLAYERS + 1];	// some row is pvsIn && !alive for this viewer: run a pass
bool g_bPaintCatchEntry[MAXPLAYERS + 1];	// the running pass was started for entry sends
float g_fPaintEntryAt[MAXPLAYERS + 1];		// no entry pass before this game time (after a teleport)
int g_iPaintScanOwner = 1;					// scan cursor over all owners' rows
int g_iPaintScanIndex;
float g_fPaintScanCycleStart;
float g_fPaintScanCycle;					// debug: last full cycle, seconds
int g_iPaintScanCallsPeak;					// debug: most engine calls in one tick since the last report
float g_fPaintScanCostSum;					// debug: GetEngineTime() spent scanning since the last report
float g_fPaintScanCostPeak;
int g_iPaintScanTicks;
bool g_bPaintScanFull;						// a teleport: check every row this tick, without the call cap

char g_szPaintSizeNames[PAINT_SIZES][] = { "Small", "Medium", "Large" };

char g_szPaintPresetNames[][] = { "White", "Black", "Red", "Orange", "Yellow", "Green", "Dark Green", "Cyan", "Light Blue", "Blue", "Purple", "Pink", "Light Pink", "Brown" };
int g_iPaintPresets[][3] = {
	{255, 255, 255}, {0, 0, 0}, {255, 0, 0}, {255, 128, 0}, {255, 255, 0}, {0, 255, 0}, {0, 128, 0},
	{0, 255, 255}, {100, 180, 255}, {0, 0, 255}, {160, 0, 255}, {255, 0, 255}, {255, 150, 200}, {130, 80, 30}
};

// Edge snapping and band fit: needs the globals above, and the code below needs its globals.
#include "beampaint/paint_edge.sp"

/* ===== lifecycle ===== */

void Paint_OnPluginStart()
{
	g_hPaintTempEntLimit = FindConVar("sv_multiplayer_maxtempentities");
	for (int i = 0; i <= MAXPLAYERS; i++)
	{
		g_hPaintSegs[i] = new ArrayList(sizeof(PaintSegment));
		Paint_ResetClient(i);
	}
}

// sm_beampaint_tempents: sv_multiplayer_maxtempentities is a development-only cvar, so a
// cfg or the console cannot set it; the plugin can. 0 leaves the engine value alone.
void Paint_ApplyTempEnts()
{
	int want = g_hPaintTempEnts.IntValue;
	if (want <= 0 || g_hPaintTempEntLimit == null || g_hPaintTempEntLimit.IntValue == want)
		return;
	g_hPaintTempEntLimit.IntValue = want;
	LogMessage("[beampaint] sv_multiplayer_maxtempentities set to %d (sm_beampaint_tempents)", want);
}

public void Paint_OnTempEntsChanged(ConVar convar, const char[] oldValue, const char[] newValue)
{
	Paint_ApplyTempEnts();
}

void Paint_ResetClient(int client)
{
	g_hPaintSegs[client].Clear();
	g_iPaintCursor[client] = 0;
	g_fPaintDebt[client] = 0.0;
	g_bPainting[client] = false;
	g_bPaintHasLast[client] = false;
	for (int i = 0; i < 3; i++)
		g_iPaintColor[client][i] = 255;
	g_bPaintRandom[client] = true;
	g_iPaintSize[client] = 0;
	g_iPaintMode[client] = PAINT_MODE_BEAM;
	g_iPaintView[client] = PAINT_VIEW_ALL;
	g_bPaintAutosave[client] = false;
	g_bPaintOptsChanged[client] = false;
	g_bPaintOptionsLoaded[client] = false;
	g_bPaintDirty[client] = false;
	g_bPaintCapWarned[client] = false;
	Paint_CatchupReset(client);
	// A new occupant of this slot must receive the remaining owners' decals again.
	PaintSegment seg;
	for (int owner = 1; owner <= MAXPLAYERS; owner++)
	{
		if (g_hPaintSegs[owner] == null)
			continue;
		for (int i = 0; i < g_hPaintSegs[owner].Length; i++)
		{
			g_hPaintSegs[owner].GetArray(i, seg);
			seg.decalSeen[client / 32] &= ~(1 << (client % 32));
			seg.pvsIn[client / 32] &= ~(1 << (client % 32));
			seg.alive[client / 32] &= ~(1 << (client % 32));
			g_hPaintSegs[owner].SetArray(i, seg);
		}
	}
}

void Paint_CatchupReset(int client)
{
	g_fPaintCatchAt[client] = 0.0;
	g_iPaintCatchOwner[client] = 1;
	g_iPaintCatchIndex[client] = 0;
	g_iPaintCatchSent[client] = 0;
	g_bPaintViewPosSet[client] = false;
	g_bPaintEntryDirty[client] = false;
	g_bPaintCatchEntry[client] = false;
	g_fPaintEntryAt[client] = 0.0;
}

// OnMapStart, after g_BeamSprite (the fallback) is precached and g_szMapName is set.
void Paint_OnMapStart()
{
	g_iPaintMapSerial++;
	strcopy(g_szPaintMap, sizeof(g_szPaintMap), g_szMapName);

	for (int i = 0; i <= MAXPLAYERS; i++)
	{
		g_hPaintSegs[i].Clear();
		g_iPaintCursor[i] = 0;
		g_fPaintDebt[i] = 0.0;
		g_bPainting[i] = false;
		g_bPaintHasLast[i] = false;
		g_bPaintDirty[i] = false;
		g_bPaintCapWarned[i] = false;
		Paint_CatchupReset(i);
	}

	// Fallback until OnConfigsExecuted precaches the configured material.
	g_iPaintBeam = g_BeamSprite;

	Paint_PrecacheDecals();

	// Plugin loaded late: nobody gets OnClientPostAdminCheck for players already in game.
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client) && IsClientAuthorized(client))
			Paint_LoadClient(client);
	}
}

// OnConfigsExecuted: beampaint.cfg runs after OnMapStart, so reading sm_beampaint_material
// in OnMapStart missed the configured value on the first map after a server start.
void Paint_PrecacheMaterial()
{
	char material[PLATFORM_MAX_PATH];
	g_hPaintMaterial.GetString(material, sizeof(material));
	int beam = 0;
	if (FileExists(material, true))
	{
		// Stock VPK materials need no download; only advertise loose files.
		if (FileExists(material, false))
		{
			AddFileToDownloadsTable(material);
			// The bundled material's own texture (not every game has sprites/white).
			if (StrEqual(material, PAINT_DEFAULT_MATERIAL, false) && FileExists(PAINT_DEFAULT_TEXTURE, false))
				AddFileToDownloadsTable(PAINT_DEFAULT_TEXTURE);
		}
		beam = PrecacheModel(material, true);
	}
	if (beam <= 0)
	{
		LogError("[beampaint] Paint material '%s' is missing or failed to precache; paint uses sprites/laserbeam instead.", material);
		beam = g_BeamSprite;
	}
	g_iPaintBeam = beam;
}

// Only loose files need downloads; never advertise a file the server cannot serve.
void Paint_PrecacheDecals()
{
	g_bPaintDecalsReady = true;
	char material[PLATFORM_MAX_PATH], path[PLATFORM_MAX_PATH];
	for (int colour = 0; colour < sizeof(g_szPaintDecalNames); colour++)
	{
		Format(path, sizeof(path), "materials/decals/beampaint/%s.vtf", g_szPaintDecalNames[colour]);
		if (FileExists(path, false))
			AddFileToDownloadsTable(path);
		if (!FileExists(path, true))
			g_bPaintDecalsReady = false;
		for (int size = 0; size < PAINT_SIZES; size++)
		{
			Format(material, sizeof(material), "decals/beampaint/%s%s.vmt", g_szPaintDecalNames[colour], g_szPaintDecalSuffix[size]);
			Format(path, sizeof(path), "materials/%s", material);
			g_iPaintDecal[colour][size] = 0;
			if (FileExists(path, true))
			{
				if (FileExists(path, false))
					AddFileToDownloadsTable(path);
				g_iPaintDecal[colour][size] = PrecacheDecal(material, true);
			}
			if (g_iPaintDecal[colour][size] <= 0)
				g_bPaintDecalsReady = false;
		}
	}
	if (!g_bPaintDecalsReady)
		LogError("[beampaint] Paint decal materials missing or failed to precache; Decal mode disabled for this map.");
}

void Paint_OnMapEnd()
{
	for (int client = 1; client <= MaxClients; client++)
	{
		g_bPainting[client] = false;
		if (IsClientInGame(client) && !IsFakeClient(client) && g_bPaintAutosave[client] && g_bPaintDirty[client])
			db_savePaint(client, false);
	}
}

void Paint_OnClientPutInServer(int client)
{
	Paint_ResetClient(client);
}

void Paint_OnClientPostAdminCheck(int client)
{
	if (IsFakeClient(client))
		return;
	Paint_LoadClient(client);
}

void Paint_OnClientDisconnect(int client)
{
	if (IsClientConnected(client) && !IsFakeClient(client) && g_bPaintAutosave[client] && g_bPaintDirty[client])
		db_savePaint(client, false);
	Paint_ResetClient(client);
}

void Paint_LoadClient(int client)
{
	if (g_hDb == null)
	{
		// No database (yet): the defaults count as loaded, or decals would wait for ever.
		// If the database connects later, SQLTxn_PaintTablesSuccess loads everyone again.
		g_bPaintOptionsLoaded[client] = true;
		return;
	}
	db_selectPaintOptions(client);
	if (Paint_HasAccess(client))
		db_selectPaintSegments(client);
}

// sm_beampaint_flag: empty = everyone, else those flags (override name "beampaint").
bool Paint_HasAccess(int client)
{
	char flags[32];
	g_hPaintFlag.GetString(flags, sizeof(flags));
	TrimString(flags);
	if (flags[0] == '\0')
		return true;
	return CheckCommandAccess(client, "beampaint", ReadFlagString(flags), true);
}

// For every paint command except !paintview, which stays open to everyone
bool Paint_CheckAccess(int client)
{
	if (client == 0)
	{
		ReplyToCommand(client, "[beampaint] Paint commands are in-game only.");
		return false;
	}
	if (!Paint_HasAccess(client))
	{
		CPrintToChat(client, "%s You do not have access to this command.", g_szChatPrefix);
		return false;
	}
	return true;
}

/* ===== painting ===== */

public bool Paint_TraceFilter(int entity, int contentsMask)
{
	return entity == 0 || entity > MaxClients;
}

// Timer_PaintSample, every 0.1 s
void Paint_Sample()
{
	float eye[3], ang[3];
	float lift = g_hPaintLift.FloatValue;
	float minDist = g_hPaintMinDist.FloatValue;
	float maxDist = g_hPaintMaxDist.FloatValue;

	Paint_DebugReport();

	for (int client = 1; client <= MaxClients; client++)
	{
		if (!g_bPainting[client])
			continue;

		if (!IsClientInGame(client) || IsFakeClient(client) || !IsPlayerAlive(client))
		{
			g_bPaintHasLast[client] = false;
#if defined BEAMPAINT_DEVTEST
			Paint_RecEvent(client, "R");
#endif
			continue;
		}

		if (g_iPaintMode[client] == PAINT_MODE_DECAL && !g_bPaintDecalsReady)
		{
			g_bPainting[client] = false;
#if defined BEAMPAINT_DEVTEST
			Paint_RecEvent(client, "U");
#endif
			CPrintToChat(client, "%s Decal mode is unavailable on this map (materials missing). Choose Beam or Laser in !paint.", g_szChatPrefix);
			continue;
		}

		GetClientEyePosition(client, eye);
		GetClientEyeAngles(client, ang);
#if defined BEAMPAINT_DEVTEST
		Paint_RecSample(client, eye, ang);
#endif
		Paint_SampleAt(client, eye, ang, lift, minDist, maxDist);
	}
}

// One sample of one painter (the body of Paint_Sample's loop; the devtest replay calls it too).
void Paint_SampleAt(int client, const float eye[3], const float ang[3], float lift, float minDist, float maxDist)
{
	float hit[3], normal[3];
	// MASK_PLAYERSOLID, not MASK_SHOT: on prop ramps the surface players surf on is often a
	// player clip (surf_whiteout), and a shot trace passes through it to the ground behind.
	Handle trace = TR_TraceRayFilterEx(eye, ang, MASK_PLAYERSOLID, RayType_Infinite, Paint_TraceFilter);
	if (!TR_DidHit(trace))
	{
		delete trace;
		g_bPaintHasLast[client] = false;
		return;
	}
	TR_GetEndPosition(hit, trace);
	TR_GetPlaneNormal(trace, normal);
	if (g_hPaintDebug.IntValue >= 2)
		Paint_DebugTrace(client, trace, eye, ang);
	delete trace;

	// Decals use the surface itself, never the lifted beam position. Keep the
	// verified player-solid trace; prop/clip behaviour must be checked on dev.
	if (g_iPaintMode[client] == PAINT_MODE_DECAL)
	{
		if (!g_bPaintHasLast[client])
			Paint_PickStrokeColor(client);
		else if (GetVectorDistance(hit, g_fPaintLast[client]) <= 1.0)
			return;
		else if (GetVectorDistance(hit, g_fPaintLast[client]) > maxDist)
			Paint_PickStrokeColor(client);
		Paint_AddSegment(client, hit, hit);
		g_fPaintLast[client] = hit;
		g_bPaintHasLast[client] = true;
		return;
	}

	if (Paint_SampleStroke(client, eye, ang, hit, normal, lift, minDist, maxDist))
	{
		g_fPaintLastHit[client] = hit;
		g_fPaintLastNormal[client] = normal;
	}
}

// The beam half of a sample. Returns false when this hit must not become the last hit (only
// the minDist skip: current behaviour, it changes which samples can form a "samples" lock).
// Edge snap, crease detection and the crease half read the PREVIOUS last hit/normal, so the
// caller writes them only after this returns.
bool Paint_SampleStroke(int client, const float eye[3], const float ang[3], const float hit[3], const float normal[3], float lift, float minDist, float maxDist)
{
	if (!g_bPaintHasLast[client])
		g_bPaintEdge[client] = false;

	float snapped[3], t;
	if (g_bPaintHasLast[client] && Paint_EdgeSnap(client, eye, hit, normal, snapped, t))
	{
		Paint_EdgeExtend(client, snapped, t, minDist, maxDist);
		return true;
	}

	// Grazing hit (aim nearly parallel to the surface): a tiny aim change moves the
	// hit a long way, so these points zig-zag towards and away from the painter.
	float grazeMax = g_hPaintGrazeAngle.FloatValue;
	if (grazeMax > 0.0)
	{
		float aim[3];
		GetAngleVectors(ang, aim, NULL_VECTOR, NULL_VECTOR);
		float graze = RadToDeg(ArcSine(FloatAbs(GetVectorDotProduct(aim, normal))));
		if (graze < grazeMax)
		{
			if (g_hPaintDebug.IntValue >= 2)
				Paint_DebugLog(client, "graze skip: %.1f deg", graze);
			return true;
		}
	}

	float point[3];
	for (int i = 0; i < 3; i++)
		point[i] = hit[i] + normal[i] * lift;
	if (TR_PointOutsideWorld(point))
	{
		if (g_hPaintDebug.IntValue >= 2)
			Paint_DebugLog(client, "lifted point outside world, using the hit point");
		point = hit;
	}

	// First sample, or too far to join (aim jumped to another surface): a new stroke here.
	float dist;
	if (g_bPaintHasLast[client])
	{
		dist = GetVectorDistance(point, g_fPaintLast[client]);
		if (dist < minDist)
			return false;
	}
	if (!g_bPaintHasLast[client] || dist > maxDist)
	{
		Paint_StartStroke(client, point, normal);
		return true;
	}

	// Crossed a crease (over a spine or into a corner) between two samples: go via the
	// edge, so the beam follows the surface instead of cutting through the ramp.
	// Each half lies on its own face, so each gets that face's normal for its band.
	float ridge[3], segNormal[3];
	int fitEnds = 3;
	if (Paint_CreasePoint(client, hit, normal, lift, ridge))
	{
		Paint_AddSegment(client, g_fPaintLast[client], ridge, 0.0, g_fPaintLastNormal[client], 1);
		fitEnds = 2;	// the next half starts on the ridge
		g_fPaintLast[client] = ridge;
		segNormal = normal;
	}
	else
	{
		// Same face or a gentle bend: the average of both ends' normals.
		Paint_Bisector(g_fPaintLastPointNormal[client], normal, segNormal);
	}

	Paint_AddSegment(client, g_fPaintLast[client], point, 0.0, segNormal, fitEnds);
	Paint_SetLast(client, point, normal);
	return true;
}

// The stroke's last drawn point and the surface normal there.
void Paint_SetLast(int client, const float point[3], const float normal[3])
{
	g_fPaintLast[client] = point;
	g_fPaintLastPointNormal[client] = normal;
}

// A new stroke starting at point: nothing drawn yet, new stroke colour.
void Paint_StartStroke(int client, const float point[3], const float normal[3])
{
	Paint_SetLast(client, point, normal);
	g_bPaintHasLast[client] = true;
	Paint_PickStrokeColor(client);
}

/* ===== catch-up pass ===== */

// Starts (or restarts) a catch-up pass for the viewer. The delay lets the client render
// from its new position first; beams arriving earlier are checked against the old PVS.
void Paint_CatchupStart(int viewer, const char[] reason)
{
	// + 0.001: 0.0 means "no pass pending", and a zero delay must still start one.
	g_fPaintCatchTrigger[viewer] = GetGameTime();
	g_fPaintCatchAt[viewer] = g_fPaintCatchTrigger[viewer] + g_hPaintCatchupDelay.FloatValue + 0.001;
	g_iPaintCatchOwner[viewer] = 1;
	g_iPaintCatchIndex[viewer] = 0;
	g_iPaintCatchSent[viewer] = 0;
	g_bPaintCatchEntry[viewer] = false;
	if (g_hPaintDebug.BoolValue)
		Paint_DebugLog(viewer, "catchup: start, %s", reason);
}

// PVS mode: a pass for rows that entered the viewer's PVS without a live beam. No delay
// (g_fPaintEntryAt holds it back after a teleport) and no debug line: these are frequent.
void Paint_EntryStart(int viewer, float now)
{
	g_bPaintEntryDirty[viewer] = false;
	g_fPaintCatchTrigger[viewer] = now;
	g_fPaintCatchAt[viewer] = now + 0.001;
	g_iPaintCatchOwner[viewer] = 1;
	g_iPaintCatchIndex[viewer] = 0;
	g_iPaintCatchSent[viewer] = 0;
	g_bPaintCatchEntry[viewer] = true;
}

bool Paint_PvsOn()
{
	return g_hPaintPvs.BoolValue;
}

bool Paint_HasBit(const int[] mask, int client)
{
	return (mask[client / 32] & (1 << (client % 32))) != 0;
}

void Paint_SetBit(int[] mask, int client, bool on)
{
	if (on)
		mask[client / 32] |= 1 << (client % 32);
	else
		mask[client / 32] &= ~(1 << (client % 32));
}

int Paint_CatchupOwner(int viewer)
{
	if (g_iPaintCatchOwner[viewer] > MaxClients) return -1;
	return (viewer + g_iPaintCatchOwner[viewer] - 2) % MaxClients + 1;
}

// Paint_Scheduler (every tick). Max player speed is 3500 u/s = about 35-55 units a tick, so
// a move above sm_beampaint_catchup_dist (512) is a teleport; a hitch costs one harmless pass.
void Paint_WatchViewers()
{
	float dist = g_hPaintCatchupDist.FloatValue;
	float pos[3];
	char reason[48];
	for (int client = 1; client <= MaxClients; client++)
	{
		if (!IsClientInGame(client) || IsFakeClient(client) || IsClientSourceTV(client))
		{
			g_bPaintViewPosSet[client] = false;
			continue;
		}
		GetClientAbsOrigin(client, pos);
		if (g_bPaintViewPosSet[client])
		{
			float moved = GetVectorDistance(pos, g_fPaintViewPos[client]);
			if (dist > 0.0 && moved > dist)
			{
				if (Paint_PvsOn())
				{
					// Entry sends wait for the client to render the new position (a beam that
					// arrives earlier is tested against the old PVS), and the scan starts a new
					// full cycle now so the new place's rows are found within one cycle.
					g_fPaintEntryAt[client] = GetGameTime() + g_hPaintCatchupDelay.FloatValue;
					Paint_PvsRescan();
					if (g_hPaintDebug.BoolValue)
						Paint_DebugLog(client, "pvs: teleport, moved %.0f units, rescan", moved);
				}
				else
				{
					Format(reason, sizeof(reason), "moved %.0f units", moved);
					Paint_CatchupStart(client, reason);
				}
			}
		}
		else
			Paint_CatchupStart(client, "joined");
		g_fPaintViewPos[client] = pos;
		g_bPaintViewPosSet[client] = true;
	}
}

// Paint_Scheduler, after the round-robin, with its own budget (sm_beampaint_catchup_budget)
// plus whatever the round-robin left over this tick, capped by the engine snapshot limit.
// Rotates the viewer it starts from so one pass can't block the others.
void Paint_CatchupSend(float now, float life, int &budget, int &sentThisTick)
{
	if (budget <= 0)
		return;

	PaintSegment seg;
	int target[1];
	int first = g_iPaintNextViewer % MaxClients;
	g_iPaintNextViewer = first + 1;

	bool pvs = Paint_PvsOn();
	for (int k = 0; k < MaxClients && budget > 0; k++)
	{
		int viewer = (first + k) % MaxClients + 1;
		if (pvs && g_bPaintEntryDirty[viewer] && g_fPaintCatchAt[viewer] == 0.0 && now >= g_fPaintEntryAt[viewer])
			Paint_EntryStart(viewer, now);
		if (g_fPaintCatchAt[viewer] == 0.0 || now < g_fPaintCatchAt[viewer])
			continue;
		if (!IsClientInGame(viewer) || IsFakeClient(viewer))
		{
			g_fPaintCatchAt[viewer] = 0.0;
			continue;
		}

		target[0] = viewer;
		while (budget > 0 && g_iPaintCatchOwner[viewer] <= MaxClients)
		{
			int owner = Paint_CatchupOwner(viewer);
			bool visible = owner == viewer || g_iPaintView[viewer] == PAINT_VIEW_ALL;
			ArrayList list = g_hPaintSegs[owner];
			if (!visible || g_iPaintCatchIndex[viewer] >= list.Length)
			{
				g_iPaintCatchOwner[viewer]++;
				g_iPaintCatchIndex[viewer] = 0;
				continue;
			}
			// seg.lastSend is left alone: it belongs to the round-robin's late check.
			list.GetArray(g_iPaintCatchIndex[viewer], seg);
			// PVS mode: only rows the viewer can see now and has no live beam of. Decals are
			// persistent and deduplicated by decalSeen, so they keep the old path.
			if (pvs && seg.mode != PAINT_MODE_DECAL)
			{
				if (!Paint_HasBit(seg.pvsIn, viewer) || Paint_HasBit(seg.alive, viewer))
				{
					g_iPaintCatchIndex[viewer]++;
					continue;
				}
				Paint_SetBit(seg.alive, viewer, true);
			}
			int sent = Paint_Send(seg, life, target, 1);
			list.SetArray(g_iPaintCatchIndex[viewer], seg);
			budget -= sent;
			sentThisTick += sent;
			g_iPaintCatchSent[viewer] += sent;
			g_iPaintCatchIndex[viewer]++;
		}

		if (g_iPaintCatchOwner[viewer] > MaxClients)
		{
			if (g_hPaintDebug.BoolValue && !g_bPaintCatchEntry[viewer])
				Paint_DebugLog(viewer, "catchup: done, %d beams in %.2fs after the delay (%.2fs after the trigger)", g_iPaintCatchSent[viewer],
					now - g_fPaintCatchAt[viewer], now - g_fPaintCatchTrigger[viewer]);
			g_fPaintCatchAt[viewer] = 0.0;
		}
	}
}

// sm_beampaint_debug 2: what the paint trace (MASK_PLAYERSOLID, includes player clips) hit,
// next to what a shot trace (MASK_SHOT) hits on the same aim. DIFFERENT = paint is on a
// clip brush (invisible); the shot line shows what is visible behind it.
float g_fPaintDebugNext[MAXPLAYERS + 1];

void Paint_DebugTrace(int client, Handle shot, const float eye[3], const float ang[3])
{
#if defined BEAMPAINT_DEVTEST
	if (Paint_Replaying())
		return;	// throttled by game time, so not repeatable
#endif
	float now = GetGameTime();
	if (now < g_fPaintDebugNext[client] && now > g_fPaintDebugNext[client] - 1.0)
		return;
	g_fPaintDebugNext[client] = now + 0.5;

	float pos[3], normal[3];
	char cls[64], surf[64];
	TR_GetEndPosition(pos, shot);
	TR_GetPlaneNormal(shot, normal);
	int ent = TR_GetEntityIndex(shot);
	TR_GetSurfaceName(shot, surf, sizeof(surf));
	Paint_DebugEntName(ent, cls, sizeof(cls));
	float shotDist = GetVectorDistance(eye, pos);

	Paint_DebugLog(client, "paint: ent %d %s, surf %s, dist %.1f, normal %.2f %.2f %.2f",
		ent, cls, surf, shotDist, normal[0], normal[1], normal[2]);

	Handle solid = TR_TraceRayFilterEx(eye, ang, MASK_SHOT, RayType_Infinite, Paint_TraceFilter);
	if (!TR_DidHit(solid))
	{
		Paint_DebugLog(client, "shot: no hit");
		delete solid;
		return;
	}
	TR_GetEndPosition(pos, solid);
	ent = TR_GetEntityIndex(solid);
	TR_GetSurfaceName(solid, surf, sizeof(surf));
	delete solid;
	Paint_DebugEntName(ent, cls, sizeof(cls));
	float solidDist = GetVectorDistance(eye, pos);
	Paint_DebugLog(client, "shot: ent %d %s, surf %s, dist %.1f (%s)",
		ent, cls, surf, solidDist, FloatAbs(solidDist - shotDist) < 1.0 ? "same" : "DIFFERENT");
}

void Paint_DebugEntName(int ent, char[] buffer, int maxlen)
{
	if (ent == 0)
		strcopy(buffer, maxlen, "world/static prop");
	else if (ent > 0 && IsValidEntity(ent))
		GetEntityClassname(ent, buffer, maxlen);
	else
		strcopy(buffer, maxlen, "?");
}

// Random colour is one colour per stroke, so a stroke is not confetti.
void Paint_PickStrokeColor(int client)
{
	int preset = GetRandomInt(0, sizeof(g_iPaintPresets) - 1);
	for (int i = 0; i < 3; i++)
	{
		if (!g_bPaintRandom[client])
			g_iPaintStroke[client][i] = g_iPaintColor[client][i];
		else
			g_iPaintStroke[client][i] = g_iPaintMode[client] == PAINT_MODE_DECAL ? g_iPaintPresets[preset][i] : GetRandomInt(0, 255);
	}
}

float Paint_Width(int size)
{
	switch (size)
	{
		case 1: return g_hPaintWidthMedium.FloatValue;
		case 2: return g_hPaintWidthLarge.FloatValue;
	}
	return g_hPaintWidthSmall.FloatValue;
}

// Every segment is re-sent after sm_beampaint_resend_frac of its life. Each live beam costs
// client FPS (measured: about 0.8 us per beam in view). Copies alive per segment =
// 1 / fraction, so 0.85 keeps about 1.18 instead of 2. The cost: a beam temp entity lost
// on the way to a client leaves a gap until the next send, where 0.5 covered it with the other copy.
float Paint_Resend(float life)
{
	return life * g_hPaintResendFrac.FloatValue;
}

// fitEnds (bands only): which ends Paint_FitBand checks for surface under the band, 1 = start,
// 2 = end. A crease crossing's ridge end sits on the edge, so it is left out there.
void Paint_AddSegment(int client, const float a[3], const float b[3], float width = 0.0, const float normal[3] = NULL_VECTOR, int fitEnds = 3)
{
	PaintSegment seg;
	for (int i = 0; i < 3; i++)
	{
		seg.start[i] = a[i];
		seg.end[i] = b[i];
		seg.normal[i] = normal[i];
		seg.color[i] = g_iPaintStroke[client][i];
	}
	seg.color[3] = 255;
	seg.width = width > 0.0 ? width : Paint_Width(g_iPaintSize[client]);
	float w;
	if (g_iPaintMode[client] != PAINT_MODE_DECAL && GetVectorLength(normal) > 0.5 && Paint_BandSplit(seg.width, w) > 0)
	{
		float start[3], end[3], fitWidth = seg.width;
		start = a;
		end = b;
		Paint_FitBand(client, start, end, fitWidth, normal, fitEnds);
		seg.start = start;
		seg.end = end;
		seg.width = fitWidth;
	}
	seg.mode = g_iPaintMode[client];
	seg.size = g_iPaintSize[client];
	seg.saved = false;
	seg.saveGen = 0;

	float life = g_hPaintLife.FloatValue;
	seg.lastSend = GetGameTime();

	ArrayList list = g_hPaintSegs[client];
	int max = g_hPaintMaxSegs.IntValue;
	while (list.Length > 0 && list.Length >= max)
	{
		Paint_EraseRow(client, 0);
		Paint_ShiftCatchup(client);
		// Once per map (and again after a clear): otherwise old strokes just vanish for good.
		if (!g_bPaintCapWarned[client])
		{
			g_bPaintCapWarned[client] = true;
			CPrintToChat(client, "%s Paint limit reached ({lime}%d{default} segments): your oldest paint is now discarded as you draw. Use !paintclear to start over.", g_szChatPrefix, max);
		}
	}
	int index = list.PushArray(seg);
	g_fPaintDebt[client] += 1.0; // a row appended behind the cursor delays the rows after it by one: catch up
	g_bPaintDirty[client] = true;

	int clients[MAXPLAYERS];
#if defined BEAMPAINT_DEVTEST
	// A replay paints into slot 0 and only writes the segment to its dump.
	if (Paint_ReplayDump(seg, a, b, normal))
		return;
#endif
	Paint_PvsRefresh(client, seg);
	int count = Paint_Recipients(client, seg, clients);
	if (count > 0)
		Paint_Send(seg, life, clients, count);
	Paint_SetAlive(seg, clients, count);
	list.SetArray(index, seg);
}

// Removing the oldest row shifts an in-flight catch-up's next index too.
void Paint_ShiftCatchup(int owner)
{
	for (int viewer = 1; viewer <= MaxClients; viewer++)
	{
		if (Paint_CatchupOwner(viewer) == owner && g_iPaintCatchIndex[viewer] > 0)
			g_iPaintCatchIndex[viewer]--;
	}
}

// Loaded rows go in front of anything painted before the load came back (they are older).
void Paint_MergeLoaded(int client, ArrayList loaded)
{
	ArrayList list = g_hPaintSegs[client];
	ArrayList current = list.Clone();
	list.Clear();

	PaintSegment seg;
	for (int i = 0; i < loaded.Length; i++)
	{
		loaded.GetArray(i, seg);
		list.PushArray(seg);
	}
	for (int i = 0; i < current.Length; i++)
	{
		current.GetArray(i, seg);
		list.PushArray(seg);
	}
	delete current;

	int max = g_hPaintMaxSegs.IntValue;
	while (list.Length > 0 && list.Length > max)
		Paint_EraseRow(client, 0);
	g_iPaintCursor[client] = 0;

	// Restored paint is also for viewers already here, including persistent decals.
	for (int viewer = 1; viewer <= MaxClients; viewer++)
	{
		if (list.Length > 0 && IsClientInGame(viewer) && !IsFakeClient(viewer))
			Paint_CatchupStart(viewer, "loaded");
	}
}

/* ===== drawing ===== */

// The owner, plus everyone who shows other players' paint. Bots and SourceTV never.
// PVS mode: beam rows go only to viewers whose PVS has the row (seg.pvsIn); the others
// would drop the beam on arrival, and the entry send reaches them when it enters.
int Paint_Recipients(int owner, PaintSegment seg, int[] clients)
{
	int count = 0;
	bool pvs = Paint_PvsOn() && seg.mode != PAINT_MODE_DECAL;
	for (int i = 1; i <= MaxClients; i++)
	{
		if (pvs && !Paint_HasBit(seg.pvsIn, i))
			continue;
		if (!IsClientInGame(i) || IsFakeClient(i) || IsClientSourceTV(i))
			continue;
		if (i == owner || g_iPaintView[i] == PAINT_VIEW_ALL)
			clients[count++] = i;
	}
	return count;
}

// After a send to everyone who should have the row (round-robin, first send): exactly these
// viewers now have a live beam. A skipped viewer's old beam dies before the next pass.
void Paint_SetAlive(PaintSegment seg, const int[] clients, int count)
{
	for (int w = 0; w < PAINT_SEEN_WORDS; w++)
		seg.alive[w] = 0;
	for (int i = 0; i < count; i++)
		Paint_SetBit(seg.alive, clients[i], true);
}

// Enum structs are passed by reference: the caller stores decalSeen back in the list.
// Returns the temp entities sent (a flat band is several beams), for the per-tick budget.
int Paint_Send(PaintSegment seg, float life, int[] clients, int count)
{
	if (seg.mode == PAINT_MODE_DECAL)
	{
		if (!g_bPaintDecalsReady)
			return 0;
		int nearest = 0, best = 200000;
		for (int colour = 0; colour < sizeof(g_iPaintPresets); colour++)
		{
			int distance = 0;
			for (int channel = 0; channel < 3; channel++)
			{
				int delta = seg.color[channel] - g_iPaintPresets[colour][channel];
				distance += delta * delta;
			}
			if (distance < best)
			{
				best = distance;
				nearest = colour;
			}
		}
		int targets[MAXPLAYERS], targetsCount = 0;
		for (int i = 0; i < count; i++)
		{
			int viewer = clients[i], word = viewer / 32, bit = 1 << (viewer % 32);
			if (!g_bPaintOptionsLoaded[viewer] || (seg.decalSeen[word] & bit) != 0)
				continue;
			seg.decalSeen[word] |= bit;
			targets[targetsCount++] = viewer;
		}
		if (targetsCount > 0)
		{
			TE_Start("World Decal");
			TE_WriteVector("m_vecOrigin", seg.end);
			TE_WriteNum("m_nIndex", g_iPaintDecal[nearest][seg.size]);
			TE_Send(targets, targetsCount);
			return 1;
		}
		return 0;
	}

	int sprite = seg.mode == PAINT_MODE_LASER ? g_BeamSprite : g_iPaintBeam;
	float w, side[3], dir[3];
	int lines = Paint_BandSplit(seg.width, w);
	if (lines > 0)
	{
		// Across the face: perpendicular to the segment, in the surface plane.
		SubtractVectors(seg.end, seg.start, dir);
		GetVectorCrossProduct(dir, seg.normal, side);
		if (GetVectorLength(side) < 0.001)
			lines = 0;	// no normal stored (old row, ridge line), or the segment runs along it
		else
			NormalizeVector(side, side);
	}
	if (lines == 0)
	{
		Paint_SendBeam(seg.start, seg.end, sprite, life, seg.width, seg.color, clients, count);
		return 1;
	}

	// Each beam runs half a beam width past both ends: where the stroke turns, the next
	// segment's band starts at an angle and left a wedge-shaped gap on the outside of the turn.
	float a[3], b[3];
	NormalizeVector(dir, dir);
	ScaleVector(dir, w * 0.5);
	for (int k = 0; k < lines * 2; k++)
	{
		// Offsets -(lines - 0.5) w .. +(lines - 0.5) w: the beams' edges meet, filling seg.width.
		float off = (float(k - lines) + 0.5) * w;
		for (int i = 0; i < 3; i++)
		{
			a[i] = seg.start[i] + side[i] * off - dir[i];
			b[i] = seg.end[i] + side[i] * off + dir[i];
		}
		Paint_SendBeam(a, b, sprite, life, w, seg.color, clients, count);
	}
	return lines * 2;
}

void Paint_SendBeam(const float a[3], const float b[3], int sprite, float life, float width, const int color[4], int[] clients, int count)
{
	// BeamPoints is culled when its box reaches solid world behind a flat ramp.
	// BeamEntPoint with raw entity indices 0 uses these points without that cull.
	if (g_hPaintBeamTE.BoolValue)
	{
		TE_Start("BeamEntPoint");
		TE_WriteNum("m_nStartEntity", 0);
		TE_WriteNum("m_nEndEntity", 0);
		TE_WriteVector("m_vecStartPoint", a);
		TE_WriteVector("m_vecEndPoint", b);
		TE_WriteNum("m_nModelIndex", sprite);
		TE_WriteNum("m_nHaloIndex", 0);
		TE_WriteNum("m_nStartFrame", 0);
		TE_WriteNum("m_nFrameRate", 0);
		TE_WriteFloat("m_fLife", life);
		TE_WriteFloat("m_fWidth", width);
		TE_WriteFloat("m_fEndWidth", width);
		TE_WriteFloat("m_fAmplitude", 0.0);
		TE_WriteNum("r", color[0]);
		TE_WriteNum("g", color[1]);
		TE_WriteNum("b", color[2]);
		TE_WriteNum("a", color[3]);
		TE_WriteNum("m_nSpeed", 0);
		TE_WriteNum("m_nFadeLength", 0);
	}
	else
		TE_SetupBeamPoints(a, b, sprite, 0, 0, 0, life, width, width, 0, 0.0, color, 0);
	TE_WriteNum("m_nFlags", g_hPaintBeamFlags.IntValue);
	TE_Send(clients, count);
}

// Debug lines go to logs/beampaint_debug.log (chat truncates), tagged with the player.
void Paint_DebugLog(int client, const char[] format, any ...)
{
	char line[512], path[PLATFORM_MAX_PATH];
	VFormat(line, sizeof(line), format, 3);
#if defined BEAMPAINT_DEVTEST
	if (Paint_ReplayLog(line))
		return;
#endif
	BuildPath(Path_SM, path, sizeof(path), "logs/beampaint_debug.log");
	LogToFileEx(path, "[%N #%d] %s %s", client, GetClientUserId(client), g_szPaintMap, line);
}

// sm_beampaint_debug 1: per owner, re-sends and late re-sends (beam already gone) since the
// last report, printed to the owner once a second while they have paint.
int g_iPaintDbgSent[MAXPLAYERS + 1];
int g_iPaintDbgLate[MAXPLAYERS + 1];
float g_fPaintDbgMaxLate[MAXPLAYERS + 1];
float g_fPaintDbgReport;
int g_iPaintDbgPeak;	// most beams sent in one tick, all owners, since the last report

// Paint_Sample (every 100 ms).
void Paint_DebugReport()
{
	float now = GetGameTime();
	if (now < g_fPaintDbgReport && now > g_fPaintDbgReport - 2.0)
		return;
	g_fPaintDbgReport = now + 1.0;

	bool on = g_hPaintDebug.BoolValue;
	int budget = g_hPaintBudget.IntValue;
	for (int client = 1; client <= MaxClients; client++)
	{
		int len = g_hPaintSegs[client].Length;
		if (on && len > 0 && IsClientInGame(client) && !IsFakeClient(client))
		{
			int lost = g_iPaintDbgLate[client];
			Paint_DebugLog(client, "report: segs %d, cursor %d, re-sent %d/s, peak %d/tick all owners (budget %d/tick, life %.1f, tick %.4f), late %d (max %.2fs)%s",
				len, g_iPaintCursor[client], g_iPaintDbgSent[client], g_iPaintDbgPeak, budget, g_hPaintLife.FloatValue,
				GetTickInterval(), lost, g_fPaintDbgMaxLate[client], lost > 0 ? " LATE" : "");
			if (Paint_PvsOn())
				Paint_DebugLog(client, "pvs scan: cycle %.2fs (period %.2f), engine calls peak %d/tick (cap %d), cost avg %.0f us peak %.0f us per tick",
					g_fPaintScanCycle, g_hPaintPvsPeriod.FloatValue, g_iPaintScanCallsPeak, g_hPaintPvsMaxCalls.IntValue,
					g_iPaintScanTicks > 0 ? g_fPaintScanCostSum / g_iPaintScanTicks * 1000000.0 : 0.0, g_fPaintScanCostPeak * 1000000.0);
		}
		g_iPaintDbgSent[client] = 0;
		g_iPaintDbgLate[client] = 0;
		g_fPaintDbgMaxLate[client] = 0.0;
	}
	g_iPaintDbgPeak = 0;
	g_iPaintScanCallsPeak = 0;
	g_fPaintScanCostSum = 0.0;
	g_fPaintScanCostPeak = 0.0;
	g_iPaintScanTicks = 0;
}

/* ===== PVS-entry send (sm_beampaint_pvs) ===== */

// Viewers that may get paint now: in game, not a bot or SourceTV. eligAll: those who also
// show everyone's paint; an owner always sees their own rows.
void Paint_PvsEligible(int[] eligAll, int[] eligAny)
{
	for (int w = 0; w < PAINT_SEEN_WORDS; w++)
	{
		eligAll[w] = 0;
		eligAny[w] = 0;
	}
	for (int viewer = 1; viewer <= MaxClients; viewer++)
	{
		if (!IsClientInGame(viewer) || IsFakeClient(viewer) || IsClientSourceTV(viewer))
			continue;
		Paint_SetBit(eligAny, viewer, true);
		if (g_iPaintView[viewer] == PAINT_VIEW_ALL)
			Paint_SetBit(eligAll, viewer, true);
	}
}

// Fills mask with the viewers of this owner's row whose PVS has it. The engine's PVS test
// (GetClientsInRange, Visibility) runs on the start, the end, and every ~256 units between
// (3..8 points); the union approximates the client's box test. Returns the engine calls.
int Paint_PvsMask(int owner, PaintSegment seg, const int[] eligAll, const int[] eligAny, int[] mask)
{
	int want[PAINT_SEEN_WORDS];
	bool any = false;
	for (int w = 0; w < PAINT_SEEN_WORDS; w++)
	{
		mask[w] = 0;
		want[w] = eligAll[w];
	}
	if (Paint_HasBit(eligAny, owner))
		Paint_SetBit(want, owner, true);
	for (int w = 0; w < PAINT_SEEN_WORDS; w++)
		if (want[w] != 0) any = true;
	if (!any)
		return 0;

	int n = RoundToCeil(GetVectorDistance(seg.start, seg.end) / 256.0) + 1;
	if (n < 3) n = 3;
	if (n > 8) n = 8;
	int clients[MAXPLAYERS];
	float pt[3];
	int calls = 0;
	for (int p = 0; p < n; p++)
	{
		float f = float(p) / float(n - 1);
		for (int k = 0; k < 3; k++)
			pt[k] = seg.start[k] + (seg.end[k] - seg.start[k]) * f;
		int count = GetClientsInRange(pt, RangeType_Visibility, clients, MaxClients);
		calls++;
		for (int i = 0; i < count; i++)
			if (Paint_HasBit(want, clients[i]))
				Paint_SetBit(mask, clients[i], true);
		bool all = true;
		for (int w = 0; w < PAINT_SEEN_WORDS; w++)
			if (mask[w] != want[w]) all = false;
		if (all)
			break;
	}
	return calls;
}

// Stores the new PVS mask in the row. markDirty: viewers that see the row without a live
// beam get an entry pass (the scan); a first send right after a refresh needs none.
void Paint_PvsApply(PaintSegment seg, const int[] mask, bool markDirty)
{
	for (int w = 0; w < PAINT_SEEN_WORDS; w++)
	{
		seg.pvsIn[w] = mask[w];
		int need = markDirty ? mask[w] & ~seg.alive[w] : 0;
		for (int b = 0; need != 0 && b < 32; b++)
		{
			if ((need & (1 << b)) == 0)
				continue;
			need &= ~(1 << b);
			int viewer = w * 32 + b;
			if (viewer >= 1 && viewer <= MaxClients)
				g_bPaintEntryDirty[viewer] = true;
		}
	}
}

// Before a first send (a new stroke row): its pvsIn is not known yet.
void Paint_PvsRefresh(int owner, PaintSegment seg)
{
	if (!Paint_PvsOn() || seg.mode == PAINT_MODE_DECAL)
		return;
	int eligAll[PAINT_SEEN_WORDS], eligAny[PAINT_SEEN_WORDS], mask[PAINT_SEEN_WORDS];
	Paint_PvsEligible(eligAll, eligAny);
	Paint_PvsMask(owner, seg, eligAll, eligAny, mask);
	Paint_PvsApply(seg, mask, false);
}

// A teleport: the next scan (this tick, before the sends) checks every row at once, so all
// rows at the new place get their entry send together instead of over one scan cycle.
void Paint_PvsRescan()
{
	g_bPaintScanFull = true;
}

// Paint_Scheduler, every tick, before the sends. Walks all owners' rows so each is checked
// once per sm_beampaint_pvs_period; sm_beampaint_pvs_max_calls caps the engine calls per tick (a
// longer cycle instead of a heavier tick). Erasing a row may make one cycle skip a row.
void Paint_PvsScan()
{
	int total = 0;
	for (int owner = 1; owner <= MaxClients; owner++)
		total += g_hPaintSegs[owner].Length;
	if (total == 0)
		return;

	float t0 = GetEngineTime();
	float now = GetGameTime();
	int rows = RoundToCeil(float(total) * GetTickInterval() / g_hPaintPvsPeriod.FloatValue);
	if (rows > total) rows = total;
	int maxCalls = g_hPaintPvsMaxCalls.IntValue;
	if (g_bPaintScanFull)
	{
		// One-off, once per teleport: one full cycle from the start, no call cap.
		g_bPaintScanFull = false;
		g_iPaintScanOwner = 1;
		g_iPaintScanIndex = 0;
		g_fPaintScanCycleStart = now;
		rows = total;
		maxCalls = 2147483647;
	}
	int eligAll[PAINT_SEEN_WORDS], eligAny[PAINT_SEEN_WORDS], mask[PAINT_SEEN_WORDS];
	Paint_PvsEligible(eligAll, eligAny);

	PaintSegment seg;
	int calls = 0, done = 0;
	bool wrapped = false;
	while (done < rows && calls < maxCalls)
	{
		if (g_iPaintScanOwner < 1 || g_iPaintScanOwner > MaxClients)
		{
			g_iPaintScanOwner = 1;
			g_iPaintScanIndex = 0;
			g_fPaintScanCycle = now - g_fPaintScanCycleStart;
			g_fPaintScanCycleStart = now;
			if (wrapped)
				break;
			wrapped = true;
		}
		int owner = g_iPaintScanOwner;
		ArrayList list = g_hPaintSegs[owner];
		if (g_iPaintScanIndex >= list.Length)
		{
			g_iPaintScanOwner++;
			g_iPaintScanIndex = 0;
			continue;
		}
		int index = g_iPaintScanIndex++;
		done++;
		list.GetArray(index, seg);
		if (seg.mode == PAINT_MODE_DECAL)
			continue;
		calls += Paint_PvsMask(owner, seg, eligAll, eligAny, mask);
		Paint_PvsApply(seg, mask, true);
		list.SetArray(index, seg);
	}

	float cost = GetEngineTime() - t0;
	g_fPaintScanCostSum += cost;
	g_iPaintScanTicks++;
	if (cost > g_fPaintScanCostPeak) g_fPaintScanCostPeak = cost;
	if (calls > g_iPaintScanCallsPeak) g_iPaintScanCallsPeak = calls;
}

// OnGameFrame, every tick. Steady round-robin: each owner's list is walked from its
// cursor at an even rate of len / resend segments a second, so every segment is re-sent
// once per resend period with no bursts (a burst of temp entities is what gets dropped).
// A new row is sent straight away by Paint_AddSegment. The row at the cursor is the
// oldest; when it is overdue it is sent even without debt, which bounds every row's
// interval to about one resend period after list growth, a hitch or a held budget.
// sm_beampaint_budget caps
// the beams per tick over all owners; what it holds back stays owed for the next tick.
// The owner it starts from rotates so nobody is starved when the budget runs out.
void Paint_Scheduler()
{
	int snapshotLimit = g_hPaintTempEntLimit != null ? g_hPaintTempEntLimit.IntValue : 32;
	if (snapshotLimit <= 0) snapshotLimit = 32;
	int regularBudget = g_hPaintBudget.IntValue;
	if (regularBudget > snapshotLimit) regularBudget = snapshotLimit;
	int budget = regularBudget;
	if (budget <= 0 || MaxClients < 1)
		return;

	Paint_WatchViewers();
	if (Paint_PvsOn())
		Paint_PvsScan();

	float now = GetGameTime();
	float life = g_hPaintLife.FloatValue;
	float resend = Paint_Resend(life);
	float perTick = GetTickInterval() / resend;
	int clients[MAXPLAYERS];
	PaintSegment seg;
	int sentThisTick = 0;

	int first = g_iPaintNextOwner % MaxClients;
	g_iPaintNextOwner = first + 1;

	for (int k = 0; k < MaxClients; k++)
	{
		int owner = (first + k) % MaxClients + 1;
		ArrayList list = g_hPaintSegs[owner];
		int len = list.Length;
		if (len == 0)
		{
			g_fPaintDebt[owner] = 0.0;
			continue;
		}

		g_fPaintDebt[owner] += len * perTick;
		if (g_fPaintDebt[owner] > float(len))
			g_fPaintDebt[owner] = float(len);

		int ownerSteps = 0;
		while (budget > 0 && ownerSteps < PAINT_OWNER_STEPS_PER_TICK)
		{
			if (g_iPaintCursor[owner] >= len)
				g_iPaintCursor[owner] = 0;

			int index = g_iPaintCursor[owner];
			list.GetArray(index, seg);
			bool overdue = seg.mode != PAINT_MODE_DECAL && seg.lastSend > 0.0 && now - seg.lastSend >= resend;
			if (g_fPaintDebt[owner] < 1.0 && !overdue)
				break;
			ownerSteps++;

			int count = Paint_Recipients(owner, seg, clients);
			if (count > 0)
			{
				int sent = Paint_Send(seg, life, clients, count);
				budget -= sent;
				sentThisTick += sent;
			}
			Paint_SetAlive(seg, clients, count);

			// Debug: the previous send's beam died at lastSend + life; later than that = a gap.
			g_iPaintDbgSent[owner]++;
			float late = seg.mode != PAINT_MODE_DECAL && seg.lastSend > 0.0 ? now - (seg.lastSend + life) : 0.0;
			if (late > 0.0)
			{
				if (g_hPaintDebug.BoolValue)
					Paint_DebugLog(owner, "late: index %d of %d, %.2fs after the beam expired, budget left %d", index, len, late, budget);
				g_iPaintDbgLate[owner]++;
				if (late > g_fPaintDbgMaxLate[owner])
					g_fPaintDbgMaxLate[owner] = late;
			}

			seg.lastSend = now;
			list.SetArray(index, seg);
			g_iPaintCursor[owner] = index + 1;
			g_fPaintDebt[owner] -= 1.0;
			if (g_fPaintDebt[owner] < 0.0)
				g_fPaintDebt[owner] = 0.0;
		}
	}

	// A large catch-up needs a matching engine snapshot limit. With the stock 32,
	// keep the old 16 + 16 ceiling instead of sending beams the client will drop.
	int catchupRoom = snapshotLimit - regularBudget;
	if (catchupRoom < 0) catchupRoom = 0;
	int catchupBudget = g_hPaintCatchupBudget.IntValue;
	if (catchupBudget > catchupRoom) catchupBudget = catchupRoom;
	budget += catchupBudget;
	Paint_CatchupSend(now, life, budget, sentThisTick);

	if (sentThisTick > g_iPaintDbgPeak)
		g_iPaintDbgPeak = sentThisTick;
}

// Row `index` of this owner's list was just erased: keep the re-send cursor on the same row,
// so erasing does not make the rows after it wait a whole extra cycle or re-send early.
void Paint_RowErased(int owner, int index)
{
	if (index < g_iPaintCursor[owner])
		g_iPaintCursor[owner]--;
}

// Every erase from g_hPaintSegs goes through here (or Paint_RowErased).
void Paint_EraseRow(int owner, int index)
{
	g_hPaintSegs[owner].Erase(index);
	Paint_RowErased(owner, index);
}

/* ===== settings ===== */

void Paint_SetColor(int client, int r, int g, int b, bool random)
{
	g_iPaintColor[client][0] = r;
	g_iPaintColor[client][1] = g;
	g_iPaintColor[client][2] = b;
	g_bPaintRandom[client] = random;
	if (g_bPaintHasLast[client])
		Paint_PickStrokeColor(client);
	Paint_OptionsChanged(client);

	char szColor[32];
	Paint_ColorText(client, szColor, sizeof(szColor));
	CPrintToChat(client, "%s Paint colour now: {lime}%s", g_szChatPrefix, szColor);
}

void Paint_ColorText(int client, char[] buffer, int maxlen)
{
	if (g_bPaintRandom[client])
	{
		strcopy(buffer, maxlen, "Random");
		return;
	}

	for (int i = 0; i < sizeof(g_szPaintPresetNames); i++)
	{
		if (g_iPaintColor[client][0] == g_iPaintPresets[i][0]
			&& g_iPaintColor[client][1] == g_iPaintPresets[i][1]
			&& g_iPaintColor[client][2] == g_iPaintPresets[i][2])
		{
			strcopy(buffer, maxlen, g_szPaintPresetNames[i]);
			return;
		}
	}
	strcopy(buffer, maxlen, "Custom");
}

void Paint_OptionsChanged(int client)
{
	g_bPaintOptsChanged[client] = true;
	g_bPaintOptionsLoaded[client] = true;
	db_savePaintOptions(client);
}

void Paint_CycleMode(int client)
{
	int mode = (g_iPaintMode[client] + 1) % PAINT_MODES;
	if (mode == PAINT_MODE_DECAL && !g_bPaintDecalsReady)
	{
		CPrintToChat(client, "%s Decal mode is unavailable on this map (materials missing); switching to Beam.", g_szChatPrefix);
		mode = PAINT_MODE_BEAM;
	}
	g_iPaintMode[client] = mode;
	g_bPaintHasLast[client] = false;
	Paint_OptionsChanged(client);
	CPrintToChat(client, "%s Paint mode for new strokes: {lime}%s", g_szChatPrefix, g_szPaintModeNames[mode]);
}

void Paint_CycleSize(int client)
{
	g_iPaintSize[client] = (g_iPaintSize[client] + 1) % PAINT_SIZES;
	Paint_OptionsChanged(client);
}

void Paint_ToggleView(int client)
{
	g_iPaintView[client] = g_iPaintView[client] == PAINT_VIEW_ALL ? PAINT_VIEW_OWN : PAINT_VIEW_ALL;
	Paint_OptionsChanged(client);
	if (g_iPaintView[client] == PAINT_VIEW_ALL)
	{
		Paint_CatchupStart(client, "view toggle");
		CPrintToChat(client, "%s Paint: showing {lime}everyone's{default} paint.", g_szChatPrefix);
	}
	else
		CPrintToChat(client, "%s Paint: showing {lime}only your own{default} paint (others' beams fade within %.0f s).", g_szChatPrefix, g_hPaintLife.FloatValue);
}

void Paint_ToggleAutosave(int client)
{
	g_bPaintAutosave[client] = !g_bPaintAutosave[client];
	Paint_OptionsChanged(client);
	if (g_bPaintAutosave[client])
		CPrintToChat(client, "%s Paint autosave {lime}on{default}: saved when you release +paint, leave or the map ends.", g_szChatPrefix);
	else
		CPrintToChat(client, "%s Paint autosave {lime}off{default}.", g_szChatPrefix);
}

// Keeps only this player's segments whose saved flag equals keepSaved (all: keeps none).
// Returns how many went and whether any were decals.
int Paint_DropSegments(int client, bool all, bool keepSaved, bool &decals)
{
	ArrayList list = g_hPaintSegs[client];
	ArrayList kept = new ArrayList(sizeof(PaintSegment));
	PaintSegment seg;
	int dropped = 0;
	decals = false;
	for (int i = 0; i < list.Length; i++)
	{
		list.GetArray(i, seg);
		if (!all && seg.saved == keepSaved)
		{
			kept.PushArray(seg);
			continue;
		}
		Paint_RowErased(client, i - dropped); // its index once the earlier drops are gone
		dropped++;
		if (seg.mode == PAINT_MODE_DECAL)
			decals = true;
	}
	list.Clear();
	for (int i = 0; i < kept.Length; i++)
	{
		kept.GetArray(i, seg);
		list.PushArray(seg);
	}
	delete kept;

	// The re-send cursor stays on the same row (Paint_RowErased); a full clear resets it.
	// Any catch-up pass over this owner restarts. Decals already sent carry their seen
	// bits, so restarting never re-stamps them.
	if (list.Length == 0)
		g_iPaintCursor[client] = 0;
	for (int viewer = 1; viewer <= MaxClients; viewer++)
	{
		if (Paint_CatchupOwner(viewer) == client)
			g_iPaintCatchIndex[viewer] = 0;
	}
	if (list.Length < g_hPaintMaxSegs.IntValue)
		g_bPaintCapWarned[client] = false;
	return dropped;
}

// Autosave off: drops only paint that is not in the saved copy, so saved paint stays
// on screen. Autosave on: drops everything, and the next autosave saves that.
void Paint_Clear(int client)
{
	bool all = g_bPaintAutosave[client], decals;
	int dropped = Paint_DropSegments(client, all, true, decals);
	g_bPaintHasLast[client] = false;
	if (dropped > 0)
		g_bPaintDirty[client] = true;
	if (decals)
		CPrintToChat(client, "%s Cleared decals will no longer be saved or sent. Type {lime}r_cleardecals{default} in console to remove decals already shown.", g_szChatPrefix);
	if (all)
		CPrintToChat(client, "%s Paint cleared. Autosave is on, so your saved copy is replaced at the next save.", g_szChatPrefix);
	else if (dropped == 0)
		CPrintToChat(client, "%s No unsaved paint to clear. Use {lime}!paintdelete{default} to remove your saved paint.", g_szChatPrefix);
	else
		CPrintToChat(client, "%s Cleared {lime}%d{default} unsaved paint segments. Your saved paint stays.", g_szChatPrefix, dropped);
}

// The saved copy is being deleted: its segments leave the screen too, unsaved ones stay.
void Paint_DropSaved(int client)
{
	bool decals;
	Paint_DropSegments(client, false, false, decals);
	PaintSegment seg;
	ArrayList list = g_hPaintSegs[client];
	for (int i = 0; i < list.Length; i++)
	{
		list.GetArray(i, seg);
		seg.saveGen = 0;	// a save still in flight is replaced by the delete
		list.SetArray(i, seg);
	}
	g_bPaintHasLast[client] = false;
	if (decals)
		CPrintToChat(client, "%s Deleted decals already shown stay until you type {lime}r_cleardecals{default} in console.", g_szChatPrefix);
}

// Called when save number gen succeeded: everything it included is now in the saved copy.
void Paint_MarkSaved(int client, int gen)
{
	PaintSegment seg;
	ArrayList list = g_hPaintSegs[client];
	for (int i = 0; i < list.Length; i++)
	{
		list.GetArray(i, seg);
		if (seg.saveGen == 0 || seg.saveGen > gen || seg.saved)
			continue;
		seg.saved = true;
		list.SetArray(i, seg);
	}
}

// "0".."255", digits only
bool Paint_ParseByte(const char[] text, int &value)
{
	int len = strlen(text);
	if (len < 1 || len > 3)
		return false;
	for (int i = 0; i < len; i++)
	{
		if (!IsCharNumeric(text[i]))
			return false;
	}
	value = StringToInt(text);
	return value <= 255;
}

// "#RRGGBB"
bool Paint_ParseHex(const char[] text, int rgb[3])
{
	if (strlen(text) != 7 || text[0] != '#')
		return false;
	for (int i = 1; i < 7; i++)
	{
		int c = CharToLower(text[i]);
		if (!IsCharNumeric(c) && (c < 'a' || c > 'f'))
			return false;
	}
	char pair[3];
	for (int i = 0; i < 3; i++)
	{
		pair[0] = text[1 + i * 2];
		pair[1] = text[2 + i * 2];
		pair[2] = '\0';
		rgb[i] = StringToInt(pair, 16);
	}
	return true;
}

/* ===== commands ===== */

public Action Command_PaintStart(int client, int args)
{
	if (!IsValidClient(client) || IsFakeClient(client) || !Paint_CheckAccess(client))
		return Plugin_Handled;
	g_bPainting[client] = true;
	g_bPaintHasLast[client] = false;
#if defined BEAMPAINT_DEVTEST
	Paint_RecEvent(client, "D");
#endif
	return Plugin_Handled;
}

public Action Command_PaintStop(int client, int args)
{
	if (client < 1 || client > MaxClients || !IsClientInGame(client) || !g_bPainting[client])
		return Plugin_Handled;
	g_bPainting[client] = false;
	g_bPaintHasLast[client] = false;
#if defined BEAMPAINT_DEVTEST
	Paint_RecEvent(client, "U");
#endif
	if (g_bPaintAutosave[client] && g_bPaintDirty[client])
		db_savePaint(client, false);
	return Plugin_Handled;
}

public Action Command_Paint(int client, int args)
{
	if (!Paint_CheckAccess(client))
		return Plugin_Handled;
	Paint_ShowMenu(client);
	return Plugin_Handled;
}

public Action Command_PaintColour(int client, int args)
{
	if (!Paint_CheckAccess(client))
		return Plugin_Handled;

	if (args == 0)
	{
		Paint_ShowColorMenu(client);
		return Plugin_Handled;
	}

	char arg[16];
	if (args == 1)
	{
		GetCmdArg(1, arg, sizeof(arg));
		if (StrEqual(arg, "random", false))
		{
			Paint_SetColor(client, g_iPaintColor[client][0], g_iPaintColor[client][1], g_iPaintColor[client][2], true);
			return Plugin_Handled;
		}
		int rgb[3];
		if (Paint_ParseHex(arg, rgb))
		{
			Paint_SetColor(client, rgb[0], rgb[1], rgb[2], false);
			return Plugin_Handled;
		}
	}
	else if (args == 3)
	{
		int rgb[3];
		bool ok = true;
		for (int i = 0; i < 3 && ok; i++)
		{
			GetCmdArg(i + 1, arg, sizeof(arg));
			ok = Paint_ParseByte(arg, rgb[i]);
		}
		if (ok)
		{
			Paint_SetColor(client, rgb[0], rgb[1], rgb[2], false);
			return Plugin_Handled;
		}
	}

	CPrintToChat(client, "%s Usage: !paintcolour <r> <g> <b> (each 0-255), !paintcolour #RRGGBB or !paintcolour random", g_szChatPrefix);
	return Plugin_Handled;
}

public Action Command_PaintSize(int client, int args)
{
	if (!Paint_CheckAccess(client))
		return Plugin_Handled;

	if (args == 0)
	{
		Paint_CycleSize(client);
	}
	else
	{
		char arg[8];
		GetCmdArg(1, arg, sizeof(arg));
		int size = StringToInt(arg);
		if (size < 1 || size > PAINT_SIZES || strlen(arg) != 1)
		{
			CPrintToChat(client, "%s Usage: !paintsize <1-%d> (1 small, 2 medium, 3 large), or no number to cycle", g_szChatPrefix, PAINT_SIZES);
			return Plugin_Handled;
		}
		g_iPaintSize[client] = size - 1;
		Paint_OptionsChanged(client);
	}
	CPrintToChat(client, "%s Paint size now: {lime}%s", g_szChatPrefix, g_szPaintSizeNames[g_iPaintSize[client]]);
	return Plugin_Handled;
}

// Open to everyone: players without paint access still choose whether they see paint.
public Action Command_PaintView(int client, int args)
{
	if (client == 0)
		return Plugin_Handled;
	Paint_ToggleView(client);
	return Plugin_Handled;
}

public Action Command_PaintSave(int client, int args)
{
	if (Paint_CheckAccess(client))
		db_savePaint(client, true);
	return Plugin_Handled;
}

public Action Command_PaintAutosave(int client, int args)
{
	if (Paint_CheckAccess(client))
		Paint_ToggleAutosave(client);
	return Plugin_Handled;
}

public Action Command_PaintClear(int client, int args)
{
	if (Paint_CheckAccess(client))
		Paint_Clear(client);
	return Plugin_Handled;
}

public Action Command_PaintDelete(int client, int args)
{
	if (Paint_CheckAccess(client))
		db_deletePaint(client);
	return Plugin_Handled;
}

/* ===== menus ===== */

void Paint_ShowMenu(int client)
{
	Menu menu = new Menu(Paint_MenuHandler);
	menu.SetTitle("Paint\nHold +paint to draw (e.g. bind mouse3 +paint)\n ");

	char szColor[32], szItem[96];
	Paint_ColorText(client, szColor, sizeof(szColor));
	Format(szItem, sizeof(szItem), "Colour: %s", szColor);
	menu.AddItem("colour", szItem);

	Format(szItem, sizeof(szItem), "Mode: %s", g_szPaintModeNames[g_iPaintMode[client]]);
	menu.AddItem("mode", szItem);

	Format(szItem, sizeof(szItem), "Size: %s", g_szPaintSizeNames[g_iPaintSize[client]]);
	menu.AddItem("size", szItem);

	Format(szItem, sizeof(szItem), "Show: %s", g_iPaintView[client] == PAINT_VIEW_ALL ? "everyone's paint" : "only my paint");
	menu.AddItem("view", szItem);

	menu.AddItem("save", "Save my paint for this map");

	Format(szItem, sizeof(szItem), "Autosave: %s", g_bPaintAutosave[client] ? "on" : "off");
	menu.AddItem("autosave", szItem);

	menu.AddItem("clear", g_bPaintAutosave[client] ? "Clear my paint (autosave then replaces the saved copy)" : "Clear my unsaved paint (saved paint stays)");
	menu.AddItem("delete", "Delete my saved paint for this map");

	menu.Pagination = MENU_NO_PAGINATION;
	menu.ExitButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Paint_MenuHandler(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
		return 0;
	}
	if (action != MenuAction_Select)
		return 0;

	char info[16];
	menu.GetItem(item, info, sizeof(info));

	if (StrEqual(info, "colour"))
	{
		Paint_ShowColorMenu(client);
		return 0;
	}

	if (StrEqual(info, "mode"))
		Paint_CycleMode(client);
	else if (StrEqual(info, "size"))
		Paint_CycleSize(client);
	else if (StrEqual(info, "view"))
		Paint_ToggleView(client);
	else if (StrEqual(info, "save"))
		db_savePaint(client, true);
	else if (StrEqual(info, "autosave"))
		Paint_ToggleAutosave(client);
	else if (StrEqual(info, "clear"))
		Paint_Clear(client);
	else if (StrEqual(info, "delete"))
		db_deletePaint(client);

	Paint_ShowMenu(client);
	return 0;
}

void Paint_ShowColorMenu(int client)
{
	Menu menu = new Menu(Paint_ColorMenuHandler);
	menu.SetTitle("Paint colour\nCustom: !paintcolour <r> <g> <b>  or  #RRGGBB\n ");
	menu.AddItem("random", "Random (one colour per stroke)");

	char info[8], szItem[48];
	for (int i = 0; i < sizeof(g_szPaintPresetNames); i++)
	{
		IntToString(i, info, sizeof(info));
		Format(szItem, sizeof(szItem), "%s (%d %d %d)", g_szPaintPresetNames[i], g_iPaintPresets[i][0], g_iPaintPresets[i][1], g_iPaintPresets[i][2]);
		menu.AddItem(info, szItem);
	}

	menu.ExitBackButton = true;
	menu.Display(client, MENU_TIME_FOREVER);
}

public int Paint_ColorMenuHandler(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_End)
	{
		delete menu;
	}
	else if (action == MenuAction_Cancel)
	{
		if (item == MenuCancel_ExitBack)
			Paint_ShowMenu(client);
	}
	else if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		if (StrEqual(info, "random"))
		{
			Paint_SetColor(client, g_iPaintColor[client][0], g_iPaintColor[client][1], g_iPaintColor[client][2], true);
		}
		else
		{
			int i = StringToInt(info);
			if (i >= 0 && i < sizeof(g_szPaintPresetNames))
				Paint_SetColor(client, g_iPaintPresets[i][0], g_iPaintPresets[i][1], g_iPaintPresets[i][2], false);
		}
		Paint_ShowMenu(client);
	}
	return 0;
}
