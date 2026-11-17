// Edge snapping and band fit for Beam and Laser strokes (moved out of paint.sp as is).
// Called from paint.sp: Paint_SampleStroke, Paint_AddSegment, Paint_Send and Paint_ResetClient.

// Edge snap and band fit tuning (not cvars).
#define PAINT_FACE_EXACT_DOT 0.99985	// same face as a lock face (about 1 deg; brush normals are exact)
#define PAINT_FACE_SAME_DOT 0.98		// roughly the same face (about 11 deg)
#define PAINT_PARALLEL_MIN 0.05			// |cross| of two face normals below this: no usable edge line
#define PAINT_BAND_MAX_LINES 4			// most band beams on each side of the centre line
#define PAINT_DOWN_PROBE_LIFT 2.0		// EdgeFind local down trace: start this far above the hit
#define PAINT_SIDE_PROBE_OFF 4.0		// EdgeSide probe: this far to each side of the edge,
#define PAINT_SIDE_PROBE_LIFT 4.0		// starting this far above the face,
#define PAINT_SIDE_PROBE_DEPTH 12.0		// tracing this far along -normal
#define PAINT_ONFACE_LIFT 3.0			// OnFace probe: from this far above the point
#define PAINT_ONFACE_DEPTH 6.0			// to this far below it
// Multiples of the snap tolerance (Paint_SnapTolerance). Powers of two, so the products are
// exact and match the old ProbeReach-based arithmetic bit for bit.
#define PAINT_PROBE_STEP 2.0			// EdgeFind side traces aim this far from the hit
#define PAINT_PROBE_HIT_TOL 4.0			// a probe lock's other-face hit may be this far off the line
#define PAINT_PROBE_RADIUS 8.0			// EdgeFind: other-face hit radius and down-trace depth

// Edge snapping (beam and laser modes). On a sharp ramp spine the aim trace flips between
// the two faces and, looking along the spine, lands far along it with tiny aim changes;
// joining those points drew a star of short beams. When two samples in a row hit faces
// whose normals differ by more than sm_beampaint_edge_angle, the points snap to the line
// where the two face planes meet, and the stroke only grows at the ends of that line.
float g_fPaintLastHit[MAXPLAYERS + 1][3];		// last raw trace hit (any sample), for edge detection
float g_fPaintLastNormal[MAXPLAYERS + 1][3];
bool g_bPaintEdge[MAXPLAYERS + 1];				// locked onto an edge
bool g_bPaintEdgeNew[MAXPLAYERS + 1];			// locked, no edge point drawn yet
bool g_bPaintEdgeChained[MAXPLAYERS + 1];		// debug text only: this lock came from a drop in the same sample (curved spine)
float g_fPaintEdgeOrigin[MAXPLAYERS + 1][3];	// a point on the edge line (t = 0)
float g_fPaintEdgeDir[MAXPLAYERS + 1][3];		// unit direction of the edge line
float g_fPaintEdgeN1[MAXPLAYERS + 1][3];		// the two face normals
float g_fPaintEdgeN2[MAXPLAYERS + 1][3];
float g_fPaintEdgeLift[MAXPLAYERS + 1][3];		// lift offset for edge points (bisector * lift)
float g_fPaintEdgeSide1[MAXPLAYERS + 1][3];		// unit direction on face 1 away from the edge
float g_fPaintEdgeSide2[MAXPLAYERS + 1][3];		// same on face 2
float g_fPaintEdgeMin[MAXPLAYERS + 1];			// drawn extent along the edge
float g_fPaintEdgeMax[MAXPLAYERS + 1];

/* ===== edge snapping ===== */

// out = origin + dir * t (out may be origin itself).
void Paint_LinePoint(const float origin[3], const float dir[3], float t, float out[3])
{
	for (int i = 0; i < 3; i++)
		out[i] = origin[i] + dir[i] * t;
}

// Unit direction halfway between two face normals.
void Paint_Bisector(const float n1[3], const float n2[3], float out[3])
{
	AddVectors(n1, n2, out);
	NormalizeVector(out, out);
}

// The line where two planes meet. origin is the point on it closest to p2.
bool Paint_PlanesLine(const float p1[3], const float n1[3], const float p2[3], const float n2[3], float origin[3], float dir[3])
{
	GetVectorCrossProduct(n1, n2, dir);
	float len = GetVectorLength(dir);
	if (len < PAINT_PARALLEL_MIN)	// nearly parallel faces: no usable edge
		return false;
	ScaleVector(dir, 1.0 / len);

	float c = GetVectorDotProduct(n1, n2);
	float det = 1.0 - c * c;
	float d1 = GetVectorDotProduct(n1, p1);
	float d2 = GetVectorDotProduct(n2, p2);
	float a = (d1 - d2 * c) / det;
	float b = (d2 - d1 * c) / det;
	for (int i = 0; i < 3; i++)
		origin[i] = a * n1[i] + b * n2[i];

	// Re-anchor next to the painter: keeps t small.
	float v[3];
	SubtractVectors(p2, origin, v);
	float t = GetVectorDotProduct(v, dir);
	for (int i = 0; i < 3; i++)
		origin[i] += dir[i] * t;
	return true;
}

// Distance from point to the line, and its position t along it.
float Paint_LineDistance(const float origin[3], const float dir[3], const float point[3], float &t)
{
	float v[3];
	SubtractVectors(point, origin, v);
	t = GetVectorDotProduct(v, dir);
	for (int i = 0; i < 3; i++)
		v[i] -= dir[i] * t;
	return GetVectorLength(v);
}

bool Paint_IsCrease(const float n1[3], const float n2[3])
{
	float maxAngle = g_hPaintEdgeAngle.FloatValue;
	return maxAngle > 0.0 && GetVectorDotProduct(n1, n2) < Cosine(DegToRad(maxAngle));
}

// Starts, keeps or drops the edge lock. True: snapped = hit moved onto the edge, t = its
// position along it. hit itself is never changed.
bool Paint_EdgeSnap(int client, const float eye[3], const float hit[3], const float normal[3], float snapped[3], float &t)
{
	float snap = g_hPaintEdgeSnap.FloatValue;
	if (snap <= 0.0 || g_hPaintEdgeAngle.FloatValue <= 0.0)
	{
		g_bPaintEdge[client] = false;
		return false;
	}

	bool chained = false;
	if (g_bPaintEdge[client])
	{
		// Stay locked only while the aim is on one of the edge's two faces, and exactly those:
		// a curved ramp is short flat pieces a few degrees apart, and a lock kept across them
		// followed the first piece's straight spine on into the air or inside the ramp. Brush
		// faces give exact normals, so 1 degree only lets go when the face really changed.
		float d1 = GetVectorDotProduct(normal, g_fPaintEdgeN1[client]);
		float d2 = GetVectorDotProduct(normal, g_fPaintEdgeN2[client]);
		if (d1 < PAINT_FACE_EXACT_DOT && d2 < PAINT_FACE_EXACT_DOT)
			Paint_EdgeDrop(client, d1 < PAINT_FACE_SAME_DOT && d2 < PAINT_FACE_SAME_DOT ? "left the faces" : "face changed (curve)");
		else if (!Paint_EdgeNear(eye, g_fPaintEdgeOrigin[client], g_fPaintEdgeDir[client], hit, snap, t))
			Paint_EdgeDrop(client, "aim moved off the edge");
		else
		{
			Paint_LinePoint(g_fPaintEdgeOrigin[client], g_fPaintEdgeDir[client], t, snapped);
			return true;
		}
		// Dropped: try the next piece of spine with this same sample, carrying the band on.
		chained = true;
	}

	// Two samples in a row on the two faces; else, aim kept on one face near the spine:
	// look for the other face next to this hit.
	if (!Paint_EdgeTryLock(client, eye, g_fPaintLastHit[client], g_fPaintLastNormal[client], hit, normal, false, t))
	{
		float otherHit[3], otherNormal[3];
		if (!Paint_EdgeFind(client, eye, hit, normal, otherHit, otherNormal)
			|| !Paint_EdgeTryLock(client, eye, otherHit, otherNormal, hit, normal, true, t))
			return false;
	}
	g_bPaintEdgeChained[client] = chained;

	// TryLock checked this hit is near the new line (units or angle); t = its place on it.
	Paint_LinePoint(g_fPaintEdgeOrigin[client], g_fPaintEdgeDir[client], t, snapped);
	return true;
}

// The snap tolerance at this distance: sm_beampaint_edge_snap units, or the snap angle as
// seen from the eye if that is wider (far away). The probe distances are multiples of it
// (PAINT_PROBE_*).
float Paint_SnapTolerance(const float eye[3], const float point[3])
{
	float tol = g_hPaintEdgeSnap.FloatValue;
	float angular = GetVectorDistance(eye, point) * Tangent(DegToRad(g_hPaintEdgeSnapAngle.FloatValue));
	if (angular > tol)
		tol = angular;
	return tol;
}

// Near the edge: within maxUnits of the line, or (far away, where a tiny aim wobble moves
// the hit a long way along a grazed face) within sm_beampaint_edge_snap_angle of it as seen
// from the eye. t = the point's position along the line.
bool Paint_EdgeNear(const float eye[3], const float origin[3], const float dir[3], const float point[3], float maxUnits, float &t)
{
	if (Paint_LineDistance(origin, dir, point, t) <= maxUnits)
		return true;
	float maxAngle = g_hPaintEdgeSnapAngle.FloatValue;
	if (maxAngle <= 0.0)
		return false;
	float q[3], a[3], b[3];
	Paint_LinePoint(origin, dir, t, q);
	SubtractVectors(point, eye, a);
	SubtractVectors(q, eye, b);
	NormalizeVector(a, a);
	NormalizeVector(b, b);
	return GetVectorDotProduct(a, b) >= Cosine(DegToRad(maxAngle));
}

// Locks onto the edge between face 1 (h1, n1) and face 2 (h2, n2, this sample). h2 must be
// within the snap distance of the edge; h1 too for two real samples, but a probe hit on the
// other face can land further off (past a spine the face drops away from the probe ray).
// probe: h1 came from Paint_EdgeFind, not the previous sample. t = h2's position on the line.
bool Paint_EdgeTryLock(int client, const float eye[3], const float h1[3], const float n1[3], const float h2[3], const float n2[3], bool probe, float &t)
{
	if (!Paint_IsCrease(n1, n2))
		return false;
	float origin[3], dir[3];
	if (!Paint_PlanesLine(h1, n1, h2, n2, origin, dir))
		return false;
	float snap = g_hPaintEdgeSnap.FloatValue;
	float t1;
	// The probe's own hit can be as far off as its traces reached (far away that is well past
	// 4 x snap, which refused every probe lock painting from 700+ units).
	float h1Max = snap;
	if (probe)
		h1Max = Paint_SnapTolerance(eye, h2) * PAINT_PROBE_HIT_TOL;
	// Was: h1Max = Paint_ProbeReach(eye, h2) * 2.0; if (h1Max < snap * 4.0) h1Max = snap * 4.0;
	// The clamp could never fire: ProbeReach was 2 x max(snap, angular), so h1Max was always
	// at least 4 x snap already.
	if (!Paint_EdgeNear(eye, origin, dir, h2, snap, t) || !Paint_EdgeNear(eye, origin, dir, h1, h1Max, t1))
	{
		if (probe && g_hPaintDebug.IntValue >= 2)
			Paint_DebugLog(client, "edge probe: other face found, aim %.1f units off the edge, no lock", Paint_LineDistance(origin, dir, h2, t1));
		return false;	// a crossing, not aiming at the edge: Paint_CreasePoint handles it
	}

	g_bPaintEdge[client] = true;
	g_bPaintEdgeNew[client] = true;
	g_fPaintEdgeOrigin[client] = origin;
	g_fPaintEdgeDir[client] = dir;
	g_fPaintEdgeN1[client] = n1;
	g_fPaintEdgeN2[client] = n2;
	float bis[3];
	Paint_Bisector(n1, n2, bis);
	ScaleVector(bis, g_hPaintLift.FloatValue);
	g_fPaintEdgeLift[client] = bis;
	bool probed1 = Paint_EdgeSide(origin, dir, n1, h1, g_fPaintEdgeSide1[client]);
	bool probed2 = Paint_EdgeSide(origin, dir, n2, h2, g_fPaintEdgeSide2[client]);
	if (g_hPaintDebug.IntValue >= 2)
	{
		Paint_DebugLog(client, "edge lock (%s): dir %.2f %.2f %.2f, face angle %.0f deg", probe ? "probe" : "samples", dir[0], dir[1], dir[2],
			RadToDeg(ArcCosine(GetVectorDotProduct(n1, n2))));
		Paint_DebugLog(client, "edge sides: face1 %.2f %.2f %.2f (%s), face2 %.2f %.2f %.2f (%s)",
			g_fPaintEdgeSide1[client][0], g_fPaintEdgeSide1[client][1], g_fPaintEdgeSide1[client][2], probed1 ? "probe" : "hit fallback",
			g_fPaintEdgeSide2[client][0], g_fPaintEdgeSide2[client][1], g_fPaintEdgeSide2[client][2], probed2 ? "probe" : "hit fallback");
	}
	return true;
}

// One trace for Paint_EdgeFind: true if it hits a face at a crease angle to normal, within
// radius of hit. checkStartSolid skips a trace that starts inside the world. otherHit and
// otherNormal are written whenever the trace hits, as before.
bool Paint_ProbeFace(const float start[3], const float end[3], const float hit[3], const float normal[3], float radius, bool checkStartSolid, float otherHit[3], float otherNormal[3])
{
	Handle trace = TR_TraceRayFilterEx(start, end, MASK_PLAYERSOLID, RayType_EndPoint, Paint_TraceFilter);
	bool found = false;
	if (TR_DidHit(trace) && !(checkStartSolid && TR_StartSolid(trace)))
	{
		TR_GetEndPosition(otherHit, trace);
		TR_GetPlaneNormal(trace, otherNormal);
		found = Paint_IsCrease(normal, otherNormal) && GetVectorDistance(hit, otherHit) <= radius;
	}
	delete trace;
	return found;
}

// Aim stays on one face beside a spine: no two samples straddle it, so the lock never starts.
// Look for the other face next to the hit, to each side across the stroke direction: first
// two extra eye traces, then (if those find nothing) two local traces straight down. A hit
// on a face at a crease angle, close enough to this hit, gives the other face.
bool Paint_EdgeFind(int client, const float eye[3], const float hit[3], const float normal[3], float otherHit[3], float otherNormal[3])
{
	// Stroke direction on the face: from the last hit, or the aim if the hit barely moved.
	float m[3];
	SubtractVectors(hit, g_fPaintLastHit[client], m);
	if (GetVectorLength(m) < 0.5)
		SubtractVectors(hit, eye, m);
	float d = GetVectorDotProduct(m, normal);
	for (int i = 0; i < 3; i++)
		m[i] -= normal[i] * d;
	if (GetVectorLength(m) < 0.01)
		return false;

	float s[3], end[3];
	GetVectorCrossProduct(m, normal, s);
	NormalizeVector(s, s);
	float tol = Paint_SnapTolerance(eye, hit);
	float reach = tol * PAINT_PROBE_STEP;
	float radius = tol * PAINT_PROBE_RADIUS;
	for (int k = 0; k < 2; k++)
	{
		float sign = k == 0 ? 1.0 : -1.0;
		for (int i = 0; i < 3; i++)
			end[i] = eye[i] + (hit[i] + s[i] * sign * reach - eye[i]) * 2.0;
		if (Paint_ProbeFace(eye, end, hit, normal, radius, false, otherHit, otherNormal))
			return true;
	}

	// Far away at a shallow view, the side ray past a convex spine skims over it and lands far
	// down the other face (or misses), so the eye probe finds nothing (surf_mesa_fix). Probe
	// locally instead: step across from just above the hit and trace straight down onto the
	// other face. Beside the spine on our own face this lands on our face (no crease) and is
	// ignored; in a concave corner the start is inside the wall (start-solid) and is skipped.
	float start[3];
	for (int k = 0; k < 2; k++)
	{
		float sign = k == 0 ? 1.0 : -1.0;
		for (int i = 0; i < 3; i++)
		{
			start[i] = hit[i] + normal[i] * PAINT_DOWN_PROBE_LIFT + s[i] * sign * reach;
			end[i] = start[i];
		}
		end[2] -= radius;
		if (Paint_ProbeFace(start, end, hit, normal, radius, true, otherHit, otherNormal))
		{
			if (g_hPaintDebug.IntValue >= 2)
				Paint_DebugLog(client, "edge probe: other face found by the local down trace");
			return true;
		}
	}
	return false;
}

void Paint_EdgeDrop(int client, const char[] reason)
{
	g_bPaintEdge[client] = false;
	if (g_hPaintDebug.IntValue >= 2)
		Paint_DebugLog(client, "edge drop: %s", reason);
}

void Paint_EdgePoint(int client, float t, float point[3])
{
	Paint_LinePoint(g_fPaintEdgeOrigin[client], g_fPaintEdgeDir[client], t, point);
	for (int i = 0; i < 3; i++)
		point[i] += g_fPaintEdgeLift[client][i];
}

// Edge points only extend the drawn part of the edge; jitter inside it adds nothing.
void Paint_EdgeExtend(int client, const float hit[3], float t, float minDist, float maxDist)
{
	float point[3], from[3], bis[3];
	for (int i = 0; i < 3; i++)
		point[i] = hit[i] + g_fPaintEdgeLift[client][i];
	Paint_Bisector(g_fPaintEdgeN1[client], g_fPaintEdgeN2[client], bis);

	if (g_bPaintEdgeNew[client])
	{
		g_bPaintEdgeNew[client] = false;
		g_fPaintEdgeMin[client] = t;
		g_fPaintEdgeMax[client] = t;
		// The stroke's last point is already on this edge line (next piece of a curved spine,
		// or a relock after a short unlocked stretch): carry the band on from it (projected
		// onto this piece's line), so the spine stays one band instead of a thin neck.
		float tLast;
		if (g_hPaintBandWidth.FloatValue > 0.0
			&& Paint_LineDistance(g_fPaintEdgeOrigin[client], g_fPaintEdgeDir[client], g_fPaintLast[client], tLast) <= g_hPaintEdgeSnap.FloatValue
			&& FloatAbs(t - tLast) >= minDist && FloatAbs(t - tLast) <= maxDist)
		{
			Paint_EdgeBand(client, tLast, t);
			g_fPaintEdgeMin[client] = tLast < t ? tLast : t;
			g_fPaintEdgeMax[client] = tLast < t ? t : tLast;
			if (g_hPaintDebug.IntValue >= 2)
				Paint_DebugLog(client, "edge chain: band carried on %.1f units (%s)", FloatAbs(t - tLast), g_bPaintEdgeChained[client] ? "same sample" : "after unlocked stretch");
		}
		else
		{
			// The piece joining the stroke onto the edge: thin like the band, or it shows as a card.
			float dist = GetVectorDistance(g_fPaintLast[client], point);
			if (dist >= minDist && dist <= maxDist)
				Paint_AddSegment(client, g_fPaintLast[client], point, Paint_LineWidth(client));
		}
		Paint_SetLast(client, point, bis);
		return;
	}

	float tFrom;
	if (t > g_fPaintEdgeMax[client] + minDist)
	{
		tFrom = g_fPaintEdgeMax[client];
		g_fPaintEdgeMax[client] = t;
	}
	else if (t < g_fPaintEdgeMin[client] - minDist)
	{
		tFrom = g_fPaintEdgeMin[client];
		g_fPaintEdgeMin[client] = t;
	}
	else
		return;

	if (FloatAbs(t - tFrom) > maxDist)
	{
		// Jumped far along the edge: a new stroke from here.
		g_fPaintEdgeMin[client] = t;
		g_fPaintEdgeMax[client] = t;
		Paint_StartStroke(client, point, bis);
		return;
	}
	if (g_hPaintBandWidth.FloatValue > 0.0)
		Paint_EdgeBand(client, tFrom, t);
	else
	{
		Paint_EdgePoint(client, tFrom, from);
		Paint_AddSegment(client, from, point);
	}
	Paint_SetLast(client, point, bis);
}

// The in-face direction away from the edge. cross(dir, n) lies in the face; a short probe
// trace down onto the face on each side shows which sign is the face (the other side is
// air past a spine, or solid inside a corner). If the probe can't tell, the sign comes from
// the trace hit on that face. True: the probe decided.
bool Paint_EdgeSide(const float origin[3], const float dir[3], const float n[3], const float faceHit[3], float side[3])
{
	GetVectorCrossProduct(dir, n, side);
	NormalizeVector(side, side);

	bool onFace[2];
	float start[3], end[3];
	for (int k = 0; k < 2; k++)
	{
		float sign = k == 0 ? 1.0 : -1.0;
		for (int i = 0; i < 3; i++)
		{
			start[i] = origin[i] + side[i] * sign * PAINT_SIDE_PROBE_OFF + n[i] * PAINT_SIDE_PROBE_LIFT;
			end[i] = start[i] - n[i] * PAINT_SIDE_PROBE_DEPTH;
		}
		onFace[k] = Paint_TraceOnFace(start, end, n);
	}

	if (onFace[0] != onFace[1])
	{
		if (onFace[1])
			ScaleVector(side, -1.0);
		return true;
	}
	float v[3];
	SubtractVectors(faceHit, origin, v);
	if (GetVectorDotProduct(v, side) < 0.0)
		ScaleVector(side, -1.0);
	return false;
}

// Beams are camera-facing ribbons, so one wide strip seen at a shallow angle stands off the
// surface like a card. A segment with a surface normal is sent as a flat band instead: thin
// beams side by side, parallel to the segment, across the face (Paint_Send).
// Beams on each side of the centre line for a band of this total width, and their width w.
// 0: bands are off, or the width is already thin enough for one beam.
int Paint_BandSplit(float width, float &w)
{
	float bandWidth = g_hPaintBandWidth.FloatValue;
	w = width;
	if (bandWidth <= 0.0 || width <= bandWidth)
		return 0;
	int lines = RoundToCeil(width * 0.5 / bandWidth);
	if (lines < 1)
		lines = 1;
	else if (lines > PAINT_BAND_MAX_LINES)
		lines = PAINT_BAND_MAX_LINES;
	w = width / float(2 * lines);
	return lines;
}

// Width of one band beam at the painter's size (ridge line and edge connector).
float Paint_LineWidth(int client)
{
	float w;
	Paint_BandSplit(Paint_Width(g_iPaintSize[client]), w);
	return w;
}

// Along an edge: per face one half-width band lying on that face, from the edge out, so
// the stroke wraps the spine. Plus a thin line along the ridge itself: each face's beams are
// lifted off their own face, which left a thin gap over the spine.
void Paint_EdgeBand(int client, float tFrom, float tTo)
{
	float width = Paint_Width(g_iPaintSize[client]);
	float lift = g_hPaintLift.FloatValue;
	float a[3], b[3], side[3], n[3];
	Paint_EdgePoint(client, tFrom, a);
	Paint_EdgePoint(client, tTo, b);
	Paint_AddSegment(client, a, b, Paint_LineWidth(client));
	for (int face = 0; face < 2; face++)
	{
		if (face == 0)
		{
			side = g_fPaintEdgeSide1[client];
			n = g_fPaintEdgeN1[client];
		}
		else
		{
			side = g_fPaintEdgeSide2[client];
			n = g_fPaintEdgeN2[client];
		}
		for (int i = 0; i < 3; i++)
		{
			float base = g_fPaintEdgeOrigin[client][i] + side[i] * width * 0.25 + n[i] * lift;
			a[i] = base + g_fPaintEdgeDir[client][i] * tFrom;
			b[i] = base + g_fPaintEdgeDir[client][i] * tTo;
		}
		Paint_AddSegment(client, a, b, width * 0.5, n);
	}
}

// The last raw hit and this one are on two faces of a crease, and no edge lock formed (not
// aiming along the edge, or edge snapping is off): the lifted point on the edge between them,
// to route the stroke over it. The midpoint of the two hits picks the place along the edge.
bool Paint_CreasePoint(int client, const float hit[3], const float normal[3], float lift, float ridge[3])
{
	if (!Paint_IsCrease(g_fPaintLastNormal[client], normal))
		return false;
	float origin[3], dir[3], t;
	if (!Paint_PlanesLine(g_fPaintLastHit[client], g_fPaintLastNormal[client], hit, normal, origin, dir))
		return false;

	float mid[3];
	for (int i = 0; i < 3; i++)
		mid[i] = (g_fPaintLastHit[client][i] + hit[i]) * 0.5;
	Paint_LineDistance(origin, dir, mid, t);
	float edge[3];
	Paint_LinePoint(origin, dir, t, edge);

	// A real crossing has the edge between the two hits; unrelated faces (aim jumped
	// from a ramp to a far wall) can meet anywhere.
	float span = GetVectorDistance(g_fPaintLastHit[client], hit);
	if (GetVectorDistance(edge, hit) > span || GetVectorDistance(edge, g_fPaintLastHit[client]) > span)
		return false;

	float bis[3];
	Paint_Bisector(g_fPaintLastNormal[client], normal, bis);
	for (int i = 0; i < 3; i++)
		ridge[i] = edge[i] + bis[i] * lift;
	if (g_hPaintDebug.IntValue >= 2)
		Paint_DebugLog(client, "crease crossing: via edge point %.1f %.1f %.1f", ridge[0], ridge[1], ridge[2]);
	return true;
}

// A band is centred on the aim, so painting beside a spine (closer than half the width) or
// crossing a face edge at an angle left part of it hanging past the edge in the air. Probe
// under each side of the band and trim it (shift + narrow) to where the surface carries on.
void Paint_FitBand(int client, float a[3], float b[3], float &width, const float normal[3], int ends)
{
	float dir[3], side[3];
	SubtractVectors(b, a, dir);
	GetVectorCrossProduct(dir, normal, side);
	if (GetVectorLength(side) < 0.001)
		return;
	NormalizeVector(side, side);

	float half = width * 0.5;
	float reach[2];
	for (int k = 0; k < 2; k++)
	{
		float s[3];
		s = side;
		if (k == 1)
			ScaleVector(s, -1.0);
		reach[k] = Paint_FaceReach(a, b, s, normal, half, ends);
	}
	if (reach[0] >= half && reach[1] >= half)
		return;
	float lo = -reach[1], hi = reach[0];
	if (hi - lo < 1.0)
		return;		// no surface found either side (odd geometry): keep it as painted
	float shift = (lo + hi) * 0.5;
	for (int i = 0; i < 3; i++)
	{
		a[i] += side[i] * shift;
		b[i] += side[i] * shift;
	}
	if (g_hPaintDebug.IntValue >= 2)
		Paint_DebugLog(client, "band fit: width %.1f -> %.1f (surface %.1f / %.1f of %.1f each side)", width, hi - lo, reach[0], reach[1], half);
	width = hi - lo;
}

// How far (up to half) the surface carries on from the band's centre line towards s, at the
// checked ends. Binary search, 5 steps: within half/32 (under 0.5 units at Large).
float Paint_FaceReach(const float a[3], const float b[3], const float s[3], const float normal[3], float half, int ends)
{
	if (Paint_BandOnFace(a, b, s, normal, half - 0.5, ends))
		return half;
	float lo = 0.0, hi = half;
	for (int step = 0; step < 5; step++)
	{
		float mid = (lo + hi) * 0.5;
		if (Paint_BandOnFace(a, b, s, normal, mid, ends))
			lo = mid;
		else
			hi = mid;
	}
	return lo;
}

bool Paint_BandOnFace(const float a[3], const float b[3], const float s[3], const float normal[3], float off, int ends)
{
	float p[3];
	for (int e = 0; e < 2; e++)
	{
		if ((ends & (1 << e)) == 0)
			continue;
		for (int i = 0; i < 3; i++)
			p[i] = (e == 0 ? a[i] : b[i]) + s[i] * off;
		if (!Paint_OnFace(p, normal))
			return false;
	}
	return true;
}

// p (a lifted paint point) is just above a surface facing the same way: past a spine the
// trace finds air, past a corner it starts inside the other wall.
bool Paint_OnFace(const float p[3], const float normal[3])
{
	float start[3], end[3];
	for (int i = 0; i < 3; i++)
	{
		start[i] = p[i] + normal[i] * PAINT_ONFACE_LIFT;
		end[i] = p[i] - normal[i] * PAINT_ONFACE_DEPTH;
	}
	return Paint_TraceOnFace(start, end, normal);
}

// The trace from start to end hits a face facing the same way as normal. Starting inside
// solid (a corner's other wall) or hitting nothing (air past a spine) counts as off the face.
// Callers build start/end themselves so each keeps its exact arithmetic.
bool Paint_TraceOnFace(const float start[3], const float end[3], const float normal[3])
{
	float hitNormal[3];
	Handle trace = TR_TraceRayFilterEx(start, end, MASK_PLAYERSOLID, RayType_EndPoint, Paint_TraceFilter);
	bool on = false;
	if (!TR_StartSolid(trace) && TR_DidHit(trace))
	{
		TR_GetPlaneNormal(trace, hitNormal);
		on = GetVectorDotProduct(hitNormal, normal) > PAINT_FACE_SAME_DOT;
	}
	delete trace;
	return on;
}
