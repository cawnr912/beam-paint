// Beam paint (paint.sp): settings (beampaint_options) and saved paint per player and map (beampaint_segments).
// Same columns as surftimer-gf's ck_paint_options / ck_paint_segments, so rows copy over with INSERT ... SELECT;
// beampaint_segments adds nx/ny/nz (surface normal for flat bands, 0 = one plain beam) which copied rows leave at 0.
// MySQL only (ON DUPLICATE KEY UPDATE).

char sql_createPaintOptions[] = "CREATE TABLE IF NOT EXISTS `beampaint_options` (`steamid` varchar(32) NOT NULL, `r` tinyint unsigned NOT NULL DEFAULT '255', `g` tinyint unsigned NOT NULL DEFAULT '255', `b` tinyint unsigned NOT NULL DEFAULT '255', `random_color` tinyint unsigned NOT NULL DEFAULT '1', `size` tinyint unsigned NOT NULL DEFAULT '0', `view_mode` tinyint unsigned NOT NULL DEFAULT '0', `autosave` tinyint unsigned NOT NULL DEFAULT '0', `mode` tinyint unsigned NOT NULL DEFAULT '0', PRIMARY KEY (`steamid`)) DEFAULT CHARSET=utf8mb4;";
char sql_createPaintSegments[] = "CREATE TABLE IF NOT EXISTS `beampaint_segments` (`steamid` varchar(32) NOT NULL, `mapname` varchar(64) NOT NULL, `seq` smallint unsigned NOT NULL, `x1` float NOT NULL, `y1` float NOT NULL, `z1` float NOT NULL, `x2` float NOT NULL, `y2` float NOT NULL, `z2` float NOT NULL, `r` tinyint unsigned NOT NULL, `g` tinyint unsigned NOT NULL, `b` tinyint unsigned NOT NULL, `width` float NOT NULL, `mode` tinyint unsigned NOT NULL DEFAULT '0', `decal_size` tinyint unsigned NOT NULL DEFAULT '0', `nx` float NOT NULL DEFAULT '0', `ny` float NOT NULL DEFAULT '0', `nz` float NOT NULL DEFAULT '0', PRIMARY KEY (`steamid`, `mapname`, `seq`)) DEFAULT CHARSET=utf8mb4;";
char sql_selectPaintOptions[] = "SELECT r, g, b, random_color, size, view_mode, autosave, mode FROM beampaint_options WHERE steamid = '%s';";
char sql_upsertPaintOptions[] = "INSERT INTO beampaint_options (steamid, r, g, b, random_color, size, view_mode, autosave, mode) VALUES ('%s', %d, %d, %d, %d, %d, %d, %d, %d) ON DUPLICATE KEY UPDATE r = VALUES(r), g = VALUES(g), b = VALUES(b), random_color = VALUES(random_color), size = VALUES(size), view_mode = VALUES(view_mode), autosave = VALUES(autosave), mode = VALUES(mode);";
char sql_selectPaintSegments[] = "SELECT x1, y1, z1, x2, y2, z2, r, g, b, width, mode, decal_size, nx, ny, nz FROM beampaint_segments WHERE steamid = '%s' AND mapname = '%s' ORDER BY seq LIMIT %d;";
char sql_deletePaintSegments[] = "DELETE FROM beampaint_segments WHERE steamid = '%s' AND mapname = '%s';";
char sql_insertPaintSegmentsHead[] = "INSERT INTO beampaint_segments (steamid, mapname, seq, x1, y1, z1, x2, y2, z2, r, g, b, width, mode, decal_size, nx, ny, nz) VALUES ";

/* ===== connection ===== */

// databases.cfg entry "beampaint", else "default". g_hDb stays null (saving off) until
// the tables exist; then players already in game get their settings and paint.
void db_connect()
{
	Database.Connect(SQL_PaintConnectCallback, SQL_CheckConfig("beampaint") ? "beampaint" : "default");
}

public void SQL_PaintConnectCallback(Database db, const char[] error, any data)
{
	if (db == null)
	{
		LogError("[beampaint] Database connection failed: %s. Paint works but is not saved.", error);
		return;
	}
	char driver[16];
	db.Driver.GetIdentifier(driver, sizeof(driver));
	if (!StrEqual(driver, "mysql"))
	{
		LogError("[beampaint] Database driver '%s' is not supported (MySQL only). Paint works but is not saved.", driver);
		delete db;
		return;
	}
	db.SetCharset("utf8mb4");

	Transaction txn = new Transaction();
	txn.AddQuery(sql_createPaintOptions);
	txn.AddQuery(sql_createPaintSegments);
	db.Execute(txn, SQLTxn_PaintTablesSuccess, SQLTxn_PaintTablesFailed, db, DBPrio_High);
}

public void SQLTxn_PaintTablesSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	g_hDb = view_as<Database>(data);
	for (int client = 1; client <= MaxClients; client++)
	{
		if (IsClientInGame(client) && !IsFakeClient(client) && IsClientAuthorized(client))
			Paint_LoadClient(client);
	}
}

public void SQLTxn_PaintTablesFailed(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	LogError("[beampaint] Creating the paint tables failed (query %d of %d): %s. Paint works but is not saved.", failIndex + 1, numQueries, error);
	Database handle = view_as<Database>(data);
	delete handle;
}

bool Paint_CanUseDb(int client)
{
	return g_hDb != null && IsClientAuthorized(client) && g_szSteamID[client][0] != '\0' && g_szPaintMap[0] != '\0';
}

/* ===== settings ===== */

void db_selectPaintOptions(int client)
{
	if (g_hDb == null || !IsClientAuthorized(client) || g_szSteamID[client][0] == '\0')
		return;

	char szSteamId[64], szQuery[256];
	EscapeQueryString(g_szSteamID[client], szSteamId, sizeof(szSteamId));
	Format(szQuery, sizeof(szQuery), sql_selectPaintOptions, szSteamId);
	g_hDb.Query(SQL_selectPaintOptionsCallback, szQuery, ClientToRef(client), DBPrio_Low);
}

public void SQL_selectPaintOptionsCallback(Database db, DBResultSet results, const char[] error, any ref)
{
	if (SqlFailed(results, error, "SQL_selectPaintOptionsCallback"))
		return;

	int client = ClientFromRef(ref);
	if (client == 0)
		return;
	g_bPaintOptionsLoaded[client] = true;
	// No row yet (defaults), or the player changed something while this ran.
	if (g_bPaintOptsChanged[client] || !results.FetchRow())
		return;

	for (int i = 0; i < 3; i++)
		g_iPaintColor[client][i] = Paint_ClampByte(results.FetchInt(i));
	g_bPaintRandom[client] = results.FetchInt(3) != 0;
	int size = results.FetchInt(4);
	g_iPaintSize[client] = (size >= 0 && size < PAINT_SIZES) ? size : 0;
	g_iPaintView[client] = results.FetchInt(5) == PAINT_VIEW_OWN ? PAINT_VIEW_OWN : PAINT_VIEW_ALL;
	g_bPaintAutosave[client] = results.FetchInt(6) != 0;
	int mode = results.FetchInt(7);
	g_iPaintMode[client] = (mode >= 0 && mode < PAINT_MODES) ? mode : PAINT_MODE_BEAM;
	g_bPaintHasLast[client] = false;
}

int Paint_ClampByte(int value)
{
	if (value < 0)
		return 0;
	if (value > 255)
		return 255;
	return value;
}

void db_savePaintOptions(int client)
{
	if (g_hDb == null || !IsClientAuthorized(client) || g_szSteamID[client][0] == '\0')
		return;

	char szSteamId[64], szQuery[512];
	EscapeQueryString(g_szSteamID[client], szSteamId, sizeof(szSteamId));
	Format(szQuery, sizeof(szQuery), sql_upsertPaintOptions, szSteamId,
		g_iPaintColor[client][0], g_iPaintColor[client][1], g_iPaintColor[client][2],
		g_bPaintRandom[client] ? 1 : 0, g_iPaintSize[client], g_iPaintView[client], g_bPaintAutosave[client] ? 1 : 0, g_iPaintMode[client]);
	g_hDb.Query(SQL_PaintWriteCallback, szQuery, 0, DBPrio_Low);
}

public void SQL_PaintWriteCallback(Database db, DBResultSet results, const char[] error, any data)
{
	SqlFailed(results, error, "SQL_PaintWriteCallback");
}

/* ===== saved paint ===== */

void db_selectPaintSegments(int client)
{
	if (!Paint_CanUseDb(client))
		return;

	char szSteamId[64], szMap[160], szQuery[512];
	EscapeQueryString(g_szSteamID[client], szSteamId, sizeof(szSteamId));
	EscapeQueryString(g_szPaintMap, szMap, sizeof(szMap));
	Format(szQuery, sizeof(szQuery), sql_selectPaintSegments, szSteamId, szMap, g_hPaintMaxSegs.IntValue);

	DataPack pack = new DataPack();
	pack.WriteCell(ClientToRef(client));
	pack.WriteCell(g_iPaintMapSerial);
	g_hDb.Query(SQL_selectPaintSegmentsCallback, szQuery, pack, DBPrio_Low);
}

public void SQL_selectPaintSegmentsCallback(Database db, DBResultSet results, const char[] error, DataPack pack)
{
	pack.Reset();
	int client = ClientFromRef(pack.ReadCell());
	int serial = pack.ReadCell();
	delete pack;

	if (SqlFailed(results, error, "SQL_selectPaintSegmentsCallback"))
		return;

	// Player gone, or the map changed while the query ran
	if (client == 0 || serial != g_iPaintMapSerial)
		return;

	ArrayList loaded = new ArrayList(sizeof(PaintSegment));
	PaintSegment seg;
	while (results.FetchRow())
	{
		for (int i = 0; i < 3; i++)
		{
			seg.start[i] = results.FetchFloat(i);
			seg.end[i] = results.FetchFloat(3 + i);
			seg.normal[i] = results.FetchFloat(12 + i);
			seg.color[i] = Paint_ClampByte(results.FetchInt(6 + i));
		}
		seg.color[3] = 255;
		seg.width = results.FetchFloat(9);
		if (seg.width <= 0.0)
			seg.width = Paint_Width(0);
		int mode = results.FetchInt(10), size = results.FetchInt(11);
		seg.mode = (mode >= 0 && mode < PAINT_MODES) ? mode : PAINT_MODE_BEAM;
		seg.size = (size >= 0 && size < PAINT_SIZES) ? size : 0;
		for (int word = 0; word < PAINT_SEEN_WORDS; word++)
		{
			seg.decalSeen[word] = 0;
			seg.pvsIn[word] = 0;	// found by the PVS scan, then sent as an entry
			seg.alive[word] = 0;
		}
		seg.lastSend = 0.0;		// not sent yet: drawn by the scheduler within one re-send period
		seg.saved = true;
		seg.saveGen = 0;
		loaded.PushArray(seg);
	}

	if (loaded.Length > 0)
		Paint_MergeLoaded(client, loaded);
	delete loaded;
}

// Replaces this player's saved paint for this map with what is drawn now. Transactions on
// the one connection run in order, so a later save always lands after an earlier one.
void db_savePaint(int client, bool manual)
{
	if (!Paint_CanUseDb(client))
	{
		if (manual)
			CPrintToChat(client, "%s Your paint can't be saved right now (Steam ID or database not ready).", g_szChatPrefix);
		return;
	}

	char szSteamId[64], szMap[160], szRow[320];
	static char szQuery[8192];
	EscapeQueryString(g_szSteamID[client], szSteamId, sizeof(szSteamId));
	EscapeQueryString(g_szPaintMap, szMap, sizeof(szMap));

	Transaction txn = new Transaction();
	Format(szQuery, sizeof(szQuery), sql_deletePaintSegments, szSteamId, szMap);
	txn.AddQuery(szQuery);

	ArrayList list = g_hPaintSegs[client];
	int len = list.Length;
	int rows = 0;
	int gen = ++g_iPaintSaveGen[client];
	PaintSegment seg;
	for (int i = 0; i < len; i++)
	{
		list.GetArray(i, seg);
		seg.saveGen = gen;
		list.SetArray(i, seg);
		if (rows == 0)
			strcopy(szQuery, sizeof(szQuery), sql_insertPaintSegmentsHead);
		else
			StrCat(szQuery, sizeof(szQuery), ", ");

		Format(szRow, sizeof(szRow), "('%s', '%s', %d, %.2f, %.2f, %.2f, %.2f, %.2f, %.2f, %d, %d, %d, %.2f, %d, %d, %.3f, %.3f, %.3f)",
			szSteamId, szMap, i,
			seg.start[0], seg.start[1], seg.start[2], seg.end[0], seg.end[1], seg.end[2],
			seg.color[0], seg.color[1], seg.color[2], seg.width, seg.mode, seg.size,
			seg.normal[0], seg.normal[1], seg.normal[2]);
		StrCat(szQuery, sizeof(szQuery), szRow);

		if (++rows == PAINT_ROWS_PER_INSERT || i == len - 1)
		{
			txn.AddQuery(szQuery);
			rows = 0;
		}
	}

	DataPack pack = new DataPack();
	pack.WriteCell(ClientToRef(client));
	pack.WriteCell(manual);
	pack.WriteCell(len);
	pack.WriteCell(g_iPaintMapSerial);
	pack.WriteString(g_szPaintMap);
	pack.WriteCell(gen);

	g_bPaintDirty[client] = false;
	g_hDb.Execute(txn, SQLTxn_PaintSaveSuccess, SQLTxn_PaintSaveFailed, pack, DBPrio_Normal);
}

public void SQLTxn_PaintSaveSuccess(Database db, any data, int numQueries, DBResultSet[] results, any[] queryData)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int client = ClientFromRef(pack.ReadCell());
	bool manual = pack.ReadCell();
	int count = pack.ReadCell();
	int serial = pack.ReadCell();
	char szMap[64];
	pack.ReadString(szMap, sizeof(szMap));
	int gen = pack.ReadCell();
	delete pack;

	if (client != 0 && serial == g_iPaintMapSerial)
		Paint_MarkSaved(client, gen);

	if (client != 0 && manual)
	{
		if (count == 0)
			CPrintToChat(client, "%s Nothing painted, so your saved paint for {lime}%s{default} was removed.", g_szChatPrefix, szMap);
		else
			CPrintToChat(client, "%s Saved {lime}%d{default} paint segments for {lime}%s{default}.", g_szChatPrefix, count, szMap);
	}
}

public void SQLTxn_PaintSaveFailed(Database db, any data, int numQueries, const char[] error, int failIndex, any[] queryData)
{
	DataPack pack = view_as<DataPack>(data);
	pack.Reset();
	int client = ClientFromRef(pack.ReadCell());
	bool manual = pack.ReadCell();
	pack.ReadCell();
	int serial = pack.ReadCell();
	char szMap[64];
	pack.ReadString(szMap, sizeof(szMap));
	delete pack;

	LogError("[beampaint] Paint save for %s failed (query %d of %d): %s", szMap, failIndex + 1, numQueries, error);

	if (client != 0 && serial == g_iPaintMapSerial)
	{
		g_bPaintDirty[client] = true;
		if (manual)
			CPrintToChat(client, "%s Saving your paint failed. Try again later.", g_szChatPrefix);
	}
}

void db_deletePaint(int client)
{
	if (!Paint_CanUseDb(client))
	{
		CPrintToChat(client, "%s Your saved paint can't be deleted right now (Steam ID or database not ready).", g_szChatPrefix);
		return;
	}

	char szSteamId[64], szMap[160], szQuery[512];
	EscapeQueryString(g_szSteamID[client], szSteamId, sizeof(szSteamId));
	EscapeQueryString(g_szPaintMap, szMap, sizeof(szMap));
	Format(szQuery, sizeof(szQuery), sql_deletePaintSegments, szSteamId, szMap);
	g_hDb.Query(SQL_deletePaintCallback, szQuery, ClientToRef(client), DBPrio_Normal);
	Paint_DropSaved(client);
}

public void SQL_deletePaintCallback(Database db, DBResultSet results, const char[] error, any ref)
{
	int client = ClientFromRef(ref);
	if (SqlFailed(results, error, "SQL_deletePaintCallback"))
	{
		if (client != 0)
			CPrintToChat(client, "%s Deleting your saved paint failed. Try again later.", g_szChatPrefix);
		return;
	}
	if (client != 0)
		CPrintToChat(client, "%s Deleted {lime}%d{default} saved paint segments for {lime}%s{default}. Unsaved paint stays until you clear it or leave.", g_szChatPrefix, results.AffectedRows, g_szPaintMap);
}
