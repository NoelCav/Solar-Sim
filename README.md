# Solar-Sim

A 2D side-view systems sandbox about harnessing sunlight: route spectral light through lenses, prisms and splitters onto solar cells, and manage the heat. See [docs/design.md](docs/design.md) (state and next steps: §18.14) and, for working on the code, [CLAUDE.md](CLAUDE.md).

## Running

Godot **4.7 .NET** (the C# build; the Steam build lacks C#) and the .NET 8+ SDK. The hot loops (light engine, beam mesh, heat) are C#; everything else is GDScript. Open the project in the editor and press Play (the editor builds the C# project), or:

```bash
dotnet build "Solar Sim.csproj"
godot --path .
```

The site is saved every 5 s (`user://site.json`: objects, wire, painted terrain, clock, money) and comes back when the game starts; `SimProbe.run("site", {"op": "reset"})` forgets it and starts fresh. A fresh site starts with a demo rig on stands: a crown-glass lens over an irradiance probe, a flint prism, a tilted mirror, a long-focus acrylic lens, and a silicon cell panel wired to a Grid Connection that sells its power. Hover anything for a summary in the inspector (top right); click an object for its full numbers (a lens's focus and transmission, a cell's efficiency card) and its actions. Cells, batteries and the Grid Connection carry analog power meters, scaled to rated power.

What you see: the sky glows from the screen edge the sunlight comes from and is colored by the sun's actual spectrum (red at dawn and dusk). At night the moon takes over: it goes through phases over 8 game days, rises about 3.4 h later each day, and its light (about a millionth of the sun's) is traced through the same optics and drawn pale blue at a night exposure; below the original ground line a dark earth backdrop sits behind the tiles. Lenses, prisms and mirrors have their own temperature (Heat view fills them with it).

Screen: the top bar (clock, time controls, money and price, views), the tool dock along the bottom, the tool's panel at the left (the build catalog, or paint and wire options), the inspector top right and the view legend bottom right. The map ignores the pointer while it is over a panel.

Controls (the window opens maximized and the interface scales with it; every key below also has a button):

| Keys | Action |
|---|---|
| Select tool (Esc, 0) — default | Click an object to select it, drag to move, drag its ring handle to tilt (Ctrl snaps 15°); drag empty space to pan |
| Build tool (B) | Click a catalog card, then click the map to place it as often as you like (R/F tilt the ghost first); RMB or the card again drops it. Or drag a card onto the map to place one. 1–9 pick items by number. With nothing picked it works like Select. Objects go on stands that snap to tile columns and 25 cm heights (surface cells lie on the ground); hold Alt to float one (creative) |
| Paint tool (T) | LMB paint, RMB erase, Q/E or the swatches for material, `[` `]` size |
| Wire tool (V) | Drag a line (one bend; Shift flips it), right-drag erases; pick one of four colors, which cross without touching. Objects connect at the foot of their stand and surface cells conduct, so touching cells need one connection; cells wired to a Grid Connection sell their power and lamps draw from it (money and price in the top bar) |
| WASD / middle-drag, wheel | Pan, zoom (up to 64×; outlines and labels stay crisp) |
| R / F (Shift = fine), Shift+wheel | Tilt the selected or hovered object |
| X / Delete | Delete the selected or hovered object |
| Space; Tab or − / + | Pause; speed 1× 2× 4× 8× 16× |
| `,` `.` (Shift: 6 h), the jump buttons, Set time… | Move the clock (−1 h, +30 min, +1 h, +6 h, or to a chosen hour) without simulating the time between (the sun moves, temperatures don't) |
| H, or the view buttons (top bar) | Views: Normal · Light (all wavelengths in false color, tiles show absorbed light) · Heat (every tile's temperature; hover the legend to read values) |
| G / J, or the wavelength list | Show one spectral band (UV, blue, green, red, near IR, IR) or all |
| F1, or Menu in the dock | Controls and options (performance numbers) |
| Ctrl+Z, or the rail's undo | Undo |

## Agent tools (inspect and drive the sim)

`debug/sim_probe.gd` (`SimProbe`) answers questions about the sim and sends commands without a mouse. Two ways in.

Headless, on a test scenario or the saved site (no game window; commands apply at once, in order, on one world):

```bash
python tools/probe.py power_farm --hour 12 state objects 'analyze {"id": 20}'
python tools/probe.py edge_optics 'truth {"x0": 10, "x1": 17.25}' 'symmetry {"about": -24}' 'steady {"steps": 8}'
python tools/probe.py saved 'tile {"x": 40, "y": 20}'      # the player's site, left unchanged
python tools/probe.py demo help
```

In the running game, through the Godot MCP's `game_eval`:

```gdscript
return SimProbe.run("help")                    # list commands
return SimProbe.run("objects")                 # ids, positions, angles, absorbed W, probe readings
return SimProbe.run("region", {"x0": 40, "y0": 14, "x1": 48, "y1": 20, "layer": "light"})  # ASCII map
return SimProbe.run("trace", {"x": 43.4, "y": 17.0, "dx": 0.96, "dy": -0.28})  # one test ray, leg by leg
return SimProbe.run("rotate", {"id": 4, "angle": 30})
return SimProbe.run("step", {"n": 5})          # pause, then advance exactly 5 ticks
return SimProbe.run("fan", {...})              # dense plain-ray ground truth (exit-angle histogram)
```

Other commands: `state` (sun, moon, traced light), `scenarios`, `power` (money, price, wire networks), `wire`, `site` (save, reset, show a scenario, back to your site), `defs`, `object`, `analyze` (a cell's loss breakdown), `tile`, `peaks`, `retrace`, `truth` (plain rays vs beams), `steady` (popping as the sun steps), `symmetry`, `beams`, `strips` (beam widths and concentration per leg), `place`, `move`, `remove`, `time`, `pause`, `speed`, `view`, `wavelength`, `camera` (see `help`; the last few need the game). Prefer these over screenshots or one-off scripts: they return exact numbers and cost far less.

Positions are meters (x right, y down), angles degrees. Commands go through the sim's command queue like player input.

## Tests

Headless sim tests (a test also fails on any script error raised while it runs). Build the C# project first if it changed; `tools/test.py` re-registers new `class_name` scripts first (an open editor rewrites the class cache) and finds Godot through `$GODOT`, `godot` on the PATH, or a `Godot_v*_console.exe` under your home folder:

```bash
dotnet build "Solar Sim.csproj"
python tools/test.py                        # tests
python tools/test.py --bench                # tests, then the benchmark and bug sweep vs the baseline
python tools/test.py --bench --only=demo    # one scenario
python tools/test.py --baseline             # record a new baseline (after an intended change)
```

**Test scenarios** (`sim/scenarios.gd`) are named sites the benchmark and the game load identically (top bar → Site menu, or SimProbe `site`; a scenario is never saved over your site): `demo`, `lens_field`, `power_farm`, `optics_mix`, `night`, `dug_terrain`, `optics_lab` (splitters, a hot mirror, a telescope and filters), `lamp_lab` (LED and spot lamps: a collimated beam from a lamp at a lens's focus), `edge_optics` (awkward optics: lenses in series, a mirror V, light sent back up through a lens, a half-shaded lens, a lens in water, grazing angles).

**The benchmark** (`tests/bench.gd`, ~45 s) runs every scenario at its hours and reports:
- **Checks** (a failure is a bug; exit code 1): energy balance; no NaN or impossible values; cells never deliver more than reaches them; power and money add up; an incremental light pass matches a fresh one; two runs are identical; a save restores the same site; probes block nothing; ground truth (plain rays vs beams) and popping (the sun stepped 0.1° at a time) within sanity limits; a symmetric rig is symmetric.
- **Less accurate**: the light checks' error measures, ratcheted against the baseline (worse by 25 % fails).
- **Results changed**: fingerprints (sums of light, temperatures, power) vs `tests/bench_baseline.json`. Expected after a physics change: look, then `--baseline`.
- **More work**: machine-independent counts (ray paths, cache misses, lanes, lit tiles and strips, secondary rays, beam memory, mesh vertices, passes per 300 ticks, heat subcycles). The reliable performance signal: they don't depend on the machine or its power plan.
- **Slower / faster**: timings, advisory only.

## Code rules

[docs/style.md](docs/style.md) is the style guide: one source of truth per formula, where each kind of code lives, naming and docs. Check before committing (needs `pip install "gdtoolkit==4.*"`):

```bash
python tools/check.py
```

It runs gdlint (`gdlintrc`) plus the house rules: the sim never uses render/UI classes, no use of another class's `_private` members, centralized formulas stay in their one home, every script has a doc comment, no mixed line endings.

## Layout

- `sim/` — pure simulation (no Nodes): world, tile grid, materials, commands, systems
  - `light/` — spectrum, optical surfaces, generators, sun map, light passes; `LightEngine.cs` (ray work)
  - `thermal/` — heat grid; `HeatKernel.cs` (per-tile loops)
  - `objects/` — object definitions and instances, stands (`Mounting`), occupancy (`Placement`)
  - `conduits/` — conduit networks (wire); `power/` — cell model, power system, market
  - `thermal/` also holds the surface skin (`SkinKernel.cs`) and object thermal nodes
- `data/materials/`, `data/objects/` — content definitions (`.tres`, SI units)
- `render/`, `ui/` — Nodes that read sim state and send commands (`BeamMesh.cs` builds beam triangles; `DisplayLight` holds exposure and night policy, `PowerMeters` draws the meters, `Readout` formats values, `UiStyle` holds the interface's look, `Hud` assembles the panels)
- `debug/` — `SimProbe` (agent tooling), `probe_cli.gd` (it headless), `LightChecks` (ground truth, popping, symmetry)
- `scenes/` — entry scene
- `tests/` — headless tests and benchmark
- `tools/` — `check.py` (lint and house rules), `test.py` (tests and benchmark), `probe.py` (SimProbe headless)
- `docs/` — design document, style guide, run reports (`runs/`)
- `addons/godot_ai/` — Godot AI MCP plugin (v4.3.0)
