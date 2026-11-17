# Beam Paint

A SourceMod plugin for CS:GO and CS:S surf servers. Players hold `+paint` to draw on the map: on ramps, walls, props and the player clips that surf ramps are often made of. Paint can be saved per player and map in MySQL.

Most paint plugins use world decals. Decals can't stick to static props, so you can't paint surf ramps built from props (surf_whiteout, for example). Beam Paint traces where you aim, including player clips, so it hits the surface you actually surf on. It draws your stroke there as flat bands of beams lying on the surface, and it follows ramp edges.

Beam Paint is a standalone copy of the paint in surftimer-gf (as of rc148). It does not need SurfTimer.

## Features
- **Paints any surface**: brushes, static props, player clips.
- **Flat bands**: a wide stroke is drawn as thin beams side by side on the surface, so it doesn't stand off a ramp like a card when you see it at a shallow angle.
- **Ramp spines and edges**: a stroke along a sharp edge (a ramp spine) snaps to it and wraps both faces. Curved spines are followed piece by piece. Bands are trimmed so they don't hang over an edge into the air.
- **Shows up in time**: beams are sent when they come into a player's view area (PVS), including right after a teleport or saveloc.
- **Three modes**: Beam, Laser, Decal.
- **Saving**: per player and map, manually or automatically.
- **Show everyone's paint or only your own**, per player.

## Modes
| Mode | What it is |
|---|---|
| **Beam** (default) | Solid colour in any RGB, black included (`materials/beampaint/paintbeam.vmt`). |
| **Laser** | The stock `sprites/laserbeam` look. It is additive, so black is invisible. |
| **Decal** | Classic world decals in 14 preset colours (custom colours use the nearest preset). Round dots, about 6 / 12 / 24 units across (`materials/decals/beampaint/`). |

Sizes: small, medium and large (4 / 12 / 30 units by default). Colours: 14 presets, any `r g b`, `#RRGGBB`, or random (one colour per stroke).

## Install
1. Copy `addons/` and `materials/` to the server's game directory (`csgo/` or `cstrike/`). The compiled `beampaint.smx` is included.
2. Put `materials/beampaint/` and `materials/decals/beampaint/` on your FastDL so clients can download them. The plugin adds them to the downloads table. A player who joins before the files are on FastDL sees no Beam paint (Laser and Decal still show) until they restart their game, because the game keeps the missing material for the rest of the session; reconnecting is not enough.
3. Add a `"beampaint"` entry to `addons/sourcemod/configs/databases.cfg` (see `configs/databases.beampaint.example.cfg`). Without one, the plugin uses `"default"`. It creates its tables `beampaint_options` and `beampaint_segments` by itself.
4. Restart the server or change the map. `cfg/sourcemod/beampaint.cfg` is created on the first load.

Requires SourceMod 1.10 or newer. MySQL only. Painting works without a database, but saving does not.

**Updating from an earlier build:** an existing `cfg/sourcemod/beampaint.cfg` keeps its old values. SourceMod does not add new cvars to it or change the defaults. Delete it to get a fresh one, or set the new cvars by hand.

### Decal mode textures
Decal mode uses `materials/decals/beampaint/<colour>.vtf` and `<colour>{,_med,_large}.vmt` for the 14 colours (white, black, red, orange, yellow, green, darkgreen, cyan, lightblue, blue, purple, pink, lightpink, brown). They are included. If any are missing on the server, Decal mode turns off for that map and players are told to use Beam or Laser.

## Commands
| Command | |
|---|---|
| `+paint` | Hold to paint, e.g. `bind mouse3 +paint` |
| `!paint` | Menu: colour, mode, size, view, save, autosave, clear, delete |
| `!paintcolour` / `!paintcolor` `[r g b \| #RRGGBB \| random]` | Set the colour (no argument opens the colour menu) |
| `!paintsize [1-3]` | Set or cycle the size |
| `!paintview` | Show everyone's paint or only your own (open to everyone, even without paint access) |
| `!paintsave` | Save your paint for this map |
| `!paintautosave` | Save automatically when you release +paint, leave, or the map ends |
| `!paintclear` | Remove your unsaved paint. Saved paint stays. With autosave on, it clears everything |
| `!paintdelete` | Delete your saved paint for this map |

The server cannot remove decals already drawn by a client. After clearing decals, use `r_cleardecals` in the client console.

## Cvars
| Cvar | Default | |
|---|---|---|
| `sm_beampaint_flag` | *(empty)* | Admin flag(s) needed to paint, e.g. `o`. Empty = everyone. The override name is `beampaint` |
| `sm_beampaint_prefix` | `{lime}[Paint]{default}` | Chat prefix |
| `sm_beampaint_width_small/medium/large` | 4 / 12 / 30 | Stroke widths |
| `sm_beampaint_max_segments` | 1024 | Segments per player. The oldest go first |
| `sm_beampaint_lift` | 1.0 | Units painted off the surface |
| `sm_beampaint_min_dist` / `max_dist` | 2 / 256 | Sample spacing. Above max a new stroke starts |
| `sm_beampaint_band_width` | 4.0 | Strokes wider than this are drawn as flat bands of thin beams, each at most this wide. 0 = one wide beam |
| `sm_beampaint_edge_angle` | 20 | Faces meeting at more than this angle (degrees) count as an edge, e.g. a ramp spine. 0 = no edge snapping |
| `sm_beampaint_edge_snap` / `_snap_angle` | 8 / 1.5 | Aim within this many units, or degrees as seen by the painter, of an edge snaps the stroke to it |
| `sm_beampaint_graze_angle` | 4 | Skip samples where the aim meets the surface at less than this many degrees |
| `sm_beampaint_life` | 5.0 | Beam life on the client (s) |
| `sm_beampaint_resend_frac` | 0.85 | Each beam is re-sent after this fraction of its life. 0.5 keeps two copies alive (safer against a lost packet, but twice the client FPS cost) |
| `sm_beampaint_budget` | 16 | Beams re-sent per tick, all painters together |
| `sm_beampaint_pvs` | 1 | Send beams only to players whose PVS has them, and send a beam as soon as it comes into a player's PVS. 0 = old behaviour |
| `sm_beampaint_pvs_period` / `_pvs_max_calls` | 0.1 / 192 | How often (s) every segment is checked against every player's PVS, and the most engine PVS checks per tick |
| `sm_beampaint_catchup_dist` / `_delay` / `_budget` | 512 / 0 / 240 | A move longer than this in one tick is a teleport: the player's paint there is sent again at once, with up to this many extra beams per tick |
| `sm_beampaint_tempents` | 256 | Sets the engine's hidden `sv_multiplayer_maxtempentities` (see below). 0 = leave it alone |
| `sm_beampaint_material` | `materials/beampaint/paintbeam.vmt` | Beam material. Changes take effect next map |
| `sm_beampaint_beam_flags` | 0 | Beam flag test value. CS:GO ignores it |
| `sm_beampaint_beam_te` | 1 | Send beams as BeamEntPoint temp entities. BeamPoints can drop strokes down flat world-brush ramps when their bounding box reaches solid world. 0 = old BeamPoints |
| `sm_beampaint_debug` | 0 | 1 or 2: logs to `logs/beampaint_debug.log` |

## How it works
**Painting.** Every 0.1 s the plugin traces where each painter aims. Consecutive hits become segments, lifted 1 unit off the surface. A beam always turns to face the camera, so a wide one seen at a shallow angle stands off the surface like a card. Strokes wider than `sm_beampaint_band_width` are therefore drawn as flat bands: thin beams side by side on the surface (up to 8 per segment). When a stroke runs along a sharp edge, it snaps to the edge and draws half its width on each face.

**Sending.** Beams are temporary on the client, so every segment is re-sent at an even rate under a per-tick budget. That avoids bursts that get dropped. A client also drops a beam that arrives while it is outside its PVS. So the plugin checks which players' PVS has each segment (`GetClientsInRange`) and sends a segment to a player the moment it comes into their PVS. On our dev server, with about 100 segments painted, this check cost about 0.1 ms per tick on average (peak about 0.5 ms).

**Temp-entity limit.** The engine sends at most `sv_multiplayer_maxtempentities` temp entities per player per tick (stock 32). Every band beam is one. After a teleport, all paint near the new position has to arrive at once, and 32 per tick spreads it over several ticks, so paint visibly redraws. That cvar is development-only, so a cfg or the console cannot set it, but a plugin can. `sm_beampaint_tempents 256` (default) sets it on every map. Set it to 0 if you don't want the plugin to change an engine setting. The plugin then stays within the stock limit (16 regular + 16 catch-up). This limit is shared with every other plugin that sends temp entities (beams, effects, other paint plugins).

**Busy servers.** Each band beam counts against the budgets. At Large size a segment is up to 8 beams, so the server keeps fewer segments alive per budget than with single beams. If paint flickers, raise `sm_beampaint_budget` or set `sm_beampaint_band_width 0`.

## Compatibility
Built with spcomp 1.10. Tested on:
- **CS:GO** (SourceMod 1.11): surf_kismet, surf_elysium5, surf_mesa_fix, surf_whiteout, surf_kitsune2_GO.
- **CS:S** (SourceMod 1.12, 64-bit): surf_kismet, surf_whiteout, de_dust2 (walls), all three modes.

The beam and decal textures are bundled, so nothing depends on game-specific materials. CS:S has no `sv_multiplayer_maxtempentities`, so `sm_beampaint_tempents` does nothing there and the stock temp-entity limit applies.

**Known issue: surf_kitsune2 on CS:S.** Paint on its ramps flickers or disappears at a distance. The ramps are static props, and the game swaps them for simpler models as you move away; those sit above the surface you surf on (and the paint), so they hide it. `r_lod 0` on the client shows it again. Raising `sm_beampaint_lift` up to 8 did not fix it and made paint float. The CS:GO version (surf_kitsune2_GO) and surf_whiteout, which also use prop ramps, are fine, so other prop-ramp maps can go either way.

## Building
`spcomp beampaint.sp -iinclude` with SourceMod 1.10 or newer includes (built with spcomp 1.10). `colorvariables.inc` is bundled.

Add `BEAMPAINT_DEVTEST=` to build with `sm_bpaint` / `+bpaint` command names, so you can test it on a server that also runs another paint plugin. The devtest build also has `sm_bpaint_rec <name>` (records your paint samples) and `sm_bpaint_replay [name]` (replays them through the stroke code and dumps every segment to `data/beampaint/dump_<name>.txt`). Use them to check that a code change draws exactly the same paint.

## Credits
- SlidyBat: the original "Paint!" decal plugin that Decal mode is based on
- Raska (KissLick) and Drixevel: colorvariables

## License
GPLv3, see `LICENSE`.
