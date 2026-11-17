# Changelog

## 1.0.1 (2026-11-17)
- Fix: Beam/Laser strokes running down flat world-brush ramps (e.g. surf_elysium5) mostly vanished. Beams are now sent as BeamEntPoint (`sm_beampaint_beam_te`, default 1).
- CS:S check on surf_kitsune2: BeamEntPoint draws, but the known view-dependent static-prop ramp occlusion remains.

## 1.0.0 (2026-11-17)
- Standalone copy of the surftimer-gf paint, as of rc144 (master e38414ac).
- Its own MySQL connection ("beampaint" entry, else "default") and its own tables `beampaint_options` / `beampaint_segments`, with the same columns as ck_paint_*.
- Cvars renamed from `ck_paint_*` to `sm_beampaint_*`. New: `sm_beampaint_flag` (empty = everyone) and `sm_beampaint_prefix`.
- Beam material moved to `materials/beampaint/paintbeam.vmt`.
- CS:S support, tested on surf_kismet and surf_whiteout. Known issue: on CS:S, surf_kitsune2's prop ramps hide paint at a distance (see README, Compatibility).
- Own Decal mode textures bundled in `materials/decals/beampaint/` (round dots, 14 colours, 3 sizes); SlidyBat's `decals/paint/laser_*` files are no longer used. Without the files, Decal mode turns itself off.
- Beam and Laser strokes are flat bands of thin beams lying on the surface (`sm_beampaint_band_width`), so they no longer stand off ramps at shallow view angles. `beampaint_segments` stores the surface normal (`nx`/`ny`/`nz`).
- Strokes along a sharp edge (ramp spine) snap to it and wrap both faces (`sm_beampaint_edge_angle`, `_edge_snap`, `_edge_snap_angle`); grazing samples are skipped (`sm_beampaint_graze_angle`).
- `sm_beampaint_budget` default 8 -> 16: a band is several beams.
- Fix: the configured beam material is precached after beampaint.cfg runs (OnConfigsExecuted).
- Sending as in surftimer-gf rc148 (stroke drawing unchanged):
  - PVS-entry send: beams go only to players whose PVS has them, and a beam is sent the moment it enters a player's PVS. A teleport rechecks all paint at once (`sm_beampaint_pvs`, `_pvs_period`, `_pvs_max_calls`).
  - `sm_beampaint_resend_frac` 0.85: each beam is re-sent after 85% of its life instead of 50%, about 1.18 live copies instead of 2 (lower client FPS cost).
  - `sm_beampaint_tempents` 256: sets the engine's hidden `sv_multiplayer_maxtempentities`, so a teleport's paint arrives in one tick. The budgets are capped by that engine limit.
  - Catch-up delay 0 (was 0.1) and catch-up budget 240 (was 16).
  - Scheduler: an overdue row is sent even without debt, at most 32 steps per owner per tick. Erasing a row (cap, clear) keeps the re-send cursor on the same row, so there is no burst of re-sends.
