// Devtest build only (BEAMPAINT_DEVTEST): record what a painter's samples were, replay them
// later through the same stroke code and dump every segment it makes, so a refactor can be
// checked by diffing dumps instead of painting every map again by hand.
//
// Stroke output depends only on the samples (eye, angles, mode, size, +bpaint down/up), the
// cvars and the map, so a replay on the same map with the same cvars must give the same dump.
// Left out because they are not repeatable: colour (random), send timing, 'late' re-sends and
// the throttled 'paint:/shot:' trace lines.
//
//   sm_bpaint_rec <name>   start recording your own samples to data/beampaint/rec_<name>.txt
//   sm_bpaint_rec          stop recording
//   sm_bpaint_replay [name] replay rec_<name>.txt, or every recording made on this map, to
//                          data/beampaint/dump_<name>.txt (summary in data/beampaint/replay.log)
//
// A replay paints into slot 0 (the console), which no player sees: its segments are never
// sent, the scheduler only serves slots 1..MaxClients, and the list is cleared afterwards.
// Floats are stored as their bit patterns, so a replay sees exactly the recorded values.

#define PAINT_REPLAY_SLOT 0
#define PAINT_REPLAY_LINES_PER_TICK 100

File g_hPaintRec[MAXPLAYERS + 1];
int g_iPaintRecSamples[MAXPLAYERS + 1];

ArrayList g_hPaintReplayQueue;			// recording names still to replay
File g_hPaintReplayIn;
File g_hPaintReplayOut;
Handle g_hPaintReplayTimer;
char g_szPaintReplayName[64];
bool g_bPaintReplayDown;				// recorded +bpaint is held
bool g_bPaintInReplay;					// inside a replayed Paint_SampleAt call
int g_iPaintReplaySamples;
int g_iPaintReplaySegs;
int g_iPaintReplayLines;

void Paint_RecOnPluginStart()
{
	RegConsoleCmd("sm_bpaint_rec", Command_PaintRec, "[paint devtest] <name> - record your paint samples; no name stops");
	RegAdminCmd("sm_bpaint_replay", Command_PaintReplay, ADMFLAG_ROOT, "[paint devtest] [name] - replay recordings made on this map and dump the segments");
	g_hPaintReplayQueue = new ArrayList(ByteCountToCells(64));
	char dir[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, dir, sizeof(dir), "data/beampaint");
	if (!DirExists(dir))
		CreateDirectory(dir, 511);
}

void Paint_RecPath(char[] path, int maxlen, const char[] prefix, const char[] name)
{
	BuildPath(Path_SM, path, maxlen, "data/beampaint/%s%s.txt", prefix, name);
}

bool Paint_RecValidName(const char[] name)
{
	if (name[0] == '\0')
		return false;
	for (int i = 0; name[i] != '\0'; i++)
	{
		if (!IsCharAlpha(name[i]) && !IsCharNumeric(name[i]) && name[i] != '_' && name[i] != '-')
			return false;
	}
	return true;
}

// The cvars stroke output depends on, so a dump made with other settings visibly differs.
void Paint_RecCvars(char[] buffer, int maxlen)
{
	Format(buffer, maxlen, "# cvars lift %.4f min_dist %.4f max_dist %.4f widths %.4f %.4f %.4f edge_angle %.4f edge_snap %.4f edge_snap_angle %.4f graze_angle %.4f band_width %.4f max_segments %d",
		g_hPaintLift.FloatValue, g_hPaintMinDist.FloatValue, g_hPaintMaxDist.FloatValue,
		g_hPaintWidthSmall.FloatValue, g_hPaintWidthMedium.FloatValue, g_hPaintWidthLarge.FloatValue,
		g_hPaintEdgeAngle.FloatValue, g_hPaintEdgeSnap.FloatValue, g_hPaintEdgeSnapAngle.FloatValue,
		g_hPaintGrazeAngle.FloatValue, g_hPaintBandWidth.FloatValue, g_hPaintMaxSegs.IntValue);
}

/* ===== recording ===== */

void Paint_RecEvent(int client, const char[] event)
{
	if (g_hPaintRec[client] != null)
		g_hPaintRec[client].WriteLine("%s", event);
}

void Paint_RecSample(int client, const float eye[3], const float ang[3])
{
	if (g_hPaintRec[client] == null)
		return;
	g_hPaintRec[client].WriteLine("S %d %d %d %d %d %d %d %d", g_iPaintMode[client], g_iPaintSize[client],
		view_as<int>(eye[0]), view_as<int>(eye[1]), view_as<int>(eye[2]),
		view_as<int>(ang[0]), view_as<int>(ang[1]), view_as<int>(ang[2]));
	g_iPaintRecSamples[client]++;
}

void Paint_RecStop(int client)
{
	if (g_hPaintRec[client] == null)
		return;
	delete g_hPaintRec[client];
	if (IsClientInGame(client))
		PrintToChat(client, "[beampaint] Recording stopped, %d samples.", g_iPaintRecSamples[client]);
}

public Action Command_PaintRec(int client, int args)
{
	if (!IsValidClient(client))
	{
		ReplyToCommand(client, "[beampaint] Recording is in-game only.");
		return Plugin_Handled;
	}
	if (args < 1)
	{
		if (g_hPaintRec[client] == null)
			ReplyToCommand(client, "[beampaint] Not recording. Usage: sm_bpaint_rec <name>");
		Paint_RecStop(client);
		return Plugin_Handled;
	}
	char name[64], path[PLATFORM_MAX_PATH], cvars[512];
	GetCmdArg(1, name, sizeof(name));
	if (!Paint_RecValidName(name))
	{
		ReplyToCommand(client, "[beampaint] Name: letters, digits, _ and - only.");
		return Plugin_Handled;
	}
	Paint_RecStop(client);
	Paint_RecPath(path, sizeof(path), "rec_", name);
	g_hPaintRec[client] = OpenFile(path, "w");
	if (g_hPaintRec[client] == null)
	{
		ReplyToCommand(client, "[beampaint] Cannot write %s", path);
		return Plugin_Handled;
	}
	g_iPaintRecSamples[client] = 0;
	Paint_RecCvars(cvars, sizeof(cvars));
	g_hPaintRec[client].WriteLine("# map %s", g_szPaintMap);
	g_hPaintRec[client].WriteLine("%s", cvars);
	// Samples only count from the next +bpaint, so the replay starts on a stroke start.
	ReplyToCommand(client, "[beampaint] Recording to rec_%s.txt. Paint with +bpaint, then sm_bpaint_rec to stop.", name);
	return Plugin_Handled;
}

/* ===== replay ===== */

bool Paint_Replaying()
{
	return g_bPaintInReplay;
}

// Paint_DebugLog: lines from a replayed sample go to the dump.
bool Paint_ReplayLog(const char[] line)
{
	if (!g_bPaintInReplay)
		return false;
	g_hPaintReplayOut.WriteLine("  log %s", line);
	g_iPaintReplayLines++;
	return true;
}

// Paint_AddSegment: true = a replayed segment, written to the dump and not sent.
bool Paint_ReplayDump(PaintSegment seg, const float a[3], const float b[3], const float normal[3])
{
	if (!g_bPaintInReplay)
		return false;
	g_hPaintReplayOut.WriteLine("  seg mode %d size %d in %.6f %.6f %.6f -> %.6f %.6f %.6f n %.8f %.8f %.8f",
		seg.mode, seg.size, a[0], a[1], a[2], b[0], b[1], b[2], normal[0], normal[1], normal[2]);
	g_hPaintReplayOut.WriteLine("      out %.6f %.6f %.6f -> %.6f %.6f %.6f w %.6f",
		seg.start[0], seg.start[1], seg.start[2], seg.end[0], seg.end[1], seg.end[2], seg.width);
	g_iPaintReplaySegs++;
	return true;
}

void Paint_ReplayResetSlot()
{
	int c = PAINT_REPLAY_SLOT;
	Paint_ResetClient(c);
	g_bPaintCapWarned[c] = true;	// the cap warning would print to the console slot
	g_bPaintOptionsLoaded[c] = true;
	g_bPaintEdge[c] = false;
	g_bPaintEdgeNew[c] = false;
	g_bPaintEdgeChained[c] = false;
	g_fPaintEdgeMin[c] = 0.0;
	g_fPaintEdgeMax[c] = 0.0;
	for (int i = 0; i < 3; i++)
	{
		g_fPaintLast[c][i] = 0.0;
		g_fPaintLastPointNormal[c][i] = 0.0;
		g_fPaintLastHit[c][i] = 0.0;
		g_fPaintLastNormal[c][i] = 0.0;
		g_fPaintEdgeOrigin[c][i] = 0.0;
		g_fPaintEdgeDir[c][i] = 0.0;
		g_fPaintEdgeN1[c][i] = 0.0;
		g_fPaintEdgeN2[c][i] = 0.0;
		g_fPaintEdgeLift[c][i] = 0.0;
		g_fPaintEdgeSide1[c][i] = 0.0;
		g_fPaintEdgeSide2[c][i] = 0.0;
	}
}

void Paint_ReplayLogSummary(const char[] format, any ...)
{
	char line[512], path[PLATFORM_MAX_PATH];
	VFormat(line, sizeof(line), format, 2);
	PrintToServer("[beampaint] %s", line);
	BuildPath(Path_SM, path, sizeof(path), "data/beampaint/replay.log");
	LogToFileEx(path, "%s", line);
}

public Action Command_PaintReplay(int client, int args)
{
	if (g_hPaintReplayTimer != null)
	{
		ReplyToCommand(client, "[beampaint] A replay is already running.");
		return Plugin_Handled;
	}
	g_hPaintReplayQueue.Clear();
	char name[64];
	if (args >= 1)
	{
		GetCmdArg(1, name, sizeof(name));
		if (!Paint_RecValidName(name))
		{
			ReplyToCommand(client, "[beampaint] Name: letters, digits, _ and - only.");
			return Plugin_Handled;
		}
		g_hPaintReplayQueue.PushString(name);
	}
	else
	{
		char dir[PLATFORM_MAX_PATH], entry[PLATFORM_MAX_PATH];
		BuildPath(Path_SM, dir, sizeof(dir), "data/beampaint");
		DirectoryListing list = OpenDirectory(dir);
		FileType type;
		while (list != null && list.GetNext(entry, sizeof(entry), type))
		{
			int len = strlen(entry);
			if (type != FileType_File || len <= 8 || strncmp(entry, "rec_", 4) != 0 || !StrEqual(entry[len - 4], ".txt"))
				continue;
			entry[len - 4] = '\0';
			if (Paint_ReplayMapMatches(entry[4]))
				g_hPaintReplayQueue.PushString(entry[4]);
		}
		delete list;
		if (g_hPaintReplayQueue.Length == 0)
		{
			ReplyToCommand(client, "[beampaint] No recordings for %s.", g_szPaintMap);
			return Plugin_Handled;
		}
	}
	ReplyToCommand(client, "[beampaint] Replaying %d recording(s), summary in data/beampaint/replay.log.", g_hPaintReplayQueue.Length);
	g_hPaintReplayTimer = CreateTimer(0.1, Timer_PaintReplay, _, TIMER_REPEAT | TIMER_FLAG_NO_MAPCHANGE);
	return Plugin_Handled;
}

bool Paint_ReplayMapMatches(const char[] name)
{
	char path[PLATFORM_MAX_PATH], line[256];
	Paint_RecPath(path, sizeof(path), "rec_", name);
	File f = OpenFile(path, "r");
	if (f == null)
		return false;
	bool match = false;
	if (f.ReadLine(line, sizeof(line)))
	{
		TrimString(line);
		match = strncmp(line, "# map ", 6) == 0 && StrEqual(line[6], g_szPaintMap, false);
	}
	delete f;
	return match;
}

// Opens the next recording in the queue; false = queue empty.
bool Paint_ReplayOpenNext()
{
	char path[PLATFORM_MAX_PATH], line[512], cvars[512];
	while (g_hPaintReplayQueue.Length > 0)
	{
		g_hPaintReplayQueue.GetString(0, g_szPaintReplayName, sizeof(g_szPaintReplayName));
		g_hPaintReplayQueue.Erase(0);
		if (!Paint_ReplayMapMatches(g_szPaintReplayName))
		{
			Paint_ReplayLogSummary("replay %s: skipped, missing or recorded on another map (now %s)", g_szPaintReplayName, g_szPaintMap);
			continue;
		}
		Paint_RecPath(path, sizeof(path), "rec_", g_szPaintReplayName);
		g_hPaintReplayIn = OpenFile(path, "r");
		Paint_RecPath(path, sizeof(path), "dump_", g_szPaintReplayName);
		g_hPaintReplayOut = OpenFile(path, "w");
		if (g_hPaintReplayIn == null || g_hPaintReplayOut == null)
		{
			Paint_ReplayLogSummary("replay %s: cannot open the recording or %s", g_szPaintReplayName, path);
			delete g_hPaintReplayIn;
			delete g_hPaintReplayOut;
			continue;
		}
		Paint_RecCvars(cvars, sizeof(cvars));
		g_hPaintReplayOut.WriteLine("# replay of rec_%s on %s", g_szPaintReplayName, g_szPaintMap);
		g_hPaintReplayOut.WriteLine("%s", cvars);
		// Second header line of the recording: the cvars it was painted with.
		g_hPaintReplayIn.ReadLine(line, sizeof(line));
		g_hPaintReplayIn.ReadLine(line, sizeof(line));
		TrimString(line);
		if (!StrEqual(line, cvars))
			Paint_ReplayLogSummary("replay %s: WARNING cvars differ from the recording: %s", g_szPaintReplayName, line);
		Paint_ReplayResetSlot();
		g_bPaintReplayDown = false;
		g_iPaintReplaySamples = 0;
		g_iPaintReplaySegs = 0;
		g_iPaintReplayLines = 0;
		return true;
	}
	return false;
}

void Paint_ReplayFinish()
{
	if (g_hPaintReplayIn == null)
		return;
	delete g_hPaintReplayIn;
	delete g_hPaintReplayOut;
	Paint_ReplayResetSlot();
	Paint_ReplayLogSummary("replay %s on %s: %d samples, %d segments, %d log lines -> dump_%s.txt",
		g_szPaintReplayName, g_szPaintMap, g_iPaintReplaySamples, g_iPaintReplaySegs, g_iPaintReplayLines, g_szPaintReplayName);
}

void Paint_ReplayLine(const char[] line)
{
	int c = PAINT_REPLAY_SLOT;
	switch (line[0])
	{
		case 'D':
		{
			g_bPaintReplayDown = true;
			g_bPaintHasLast[c] = false;
		}
		case 'U':
		{
			g_bPaintReplayDown = false;
			g_bPaintHasLast[c] = false;
		}
		case 'R':
			g_bPaintHasLast[c] = false;
		case 'S':
		{
			if (!g_bPaintReplayDown)
				return;
			char parts[9][16];
			if (ExplodeString(line, " ", parts, sizeof(parts), sizeof(parts[])) != 9)
				return;
			float eye[3], ang[3];
			g_iPaintMode[c] = StringToInt(parts[1]);
			g_iPaintSize[c] = StringToInt(parts[2]);
			for (int i = 0; i < 3; i++)
			{
				eye[i] = view_as<float>(StringToInt(parts[3 + i]));
				ang[i] = view_as<float>(StringToInt(parts[6 + i]));
			}
			g_iPaintReplaySamples++;
			g_hPaintReplayOut.WriteLine("sample %d", g_iPaintReplaySamples);
			// Debug 2 for this call only, so the edge lines reach the dump (no chat notify).
			int debugLevel = g_hPaintDebug.IntValue;
			g_hPaintDebug.SetInt(2);
			g_bPaintInReplay = true;
			Paint_SampleAt(c, eye, ang, g_hPaintLift.FloatValue, g_hPaintMinDist.FloatValue, g_hPaintMaxDist.FloatValue);
			g_bPaintInReplay = false;
			g_hPaintDebug.SetInt(debugLevel);
		}
	}
}

public Action Timer_PaintReplay(Handle timer)
{
	char line[256];
	for (int n = 0; n < PAINT_REPLAY_LINES_PER_TICK; n++)
	{
		if (g_hPaintReplayIn == null && !Paint_ReplayOpenNext())
		{
			g_hPaintReplayTimer = null;
			Paint_ReplayLogSummary("replay done");
			return Plugin_Stop;
		}
		if (!g_hPaintReplayIn.ReadLine(line, sizeof(line)))
		{
			Paint_ReplayFinish();
			continue;
		}
		TrimString(line);
		Paint_ReplayLine(line);
	}
	return Plugin_Continue;
}

// Map end: recordings and a running replay belong to the old map.
void Paint_RecOnMapEnd()
{
	for (int client = 1; client <= MaxClients; client++)
		Paint_RecStop(client);
	if (g_hPaintReplayIn != null)
	{
		Paint_ReplayLogSummary("replay %s: ABORTED by map end after %d samples", g_szPaintReplayName, g_iPaintReplaySamples);
		delete g_hPaintReplayIn;
		delete g_hPaintReplayOut;
		Paint_ReplayResetSlot();
	}
	g_hPaintReplayQueue.Clear();
	g_hPaintReplayTimer = null;	// TIMER_FLAG_NO_MAPCHANGE kills it
}
