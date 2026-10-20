# Solar-Sim

A 2D side-view systems sandbox about harnessing sunlight: route spectral light through lenses, prisms and splitters onto solar cells, and manage the heat. See [docs/design.md](docs/design.md).

## Running

Godot **4.7 .NET** (the C# build; the Steam build lacks C#) and the .NET 8+ SDK. The hot loops (light engine, beam mesh, heat) are C#; everything else is GDScript. Open the project in the editor and press Play (the editor builds the C# project), or:

```bash
dotnet build "Solar Sim.csproj"
godot --path .
```

The site is saved every 5 s (`user://site.json`: objects, wire, painted terrain, clock, money) and comes back when the game starts; `SimProbe.run("site", {"op": "reset"})` forgets it and starts fresh. A fresh site starts with a demo rig on stands: a crown-glass lens over an irradiance probe, a flint prism, a tilted mirror, a long-focus acrylic lens, and a silicon cell panel wired to a Grid Connection that sells its power. Hover anything for a summary in the inspector (top right); click an object for its full numbers (a lens's focus and transmission, a cell's efficiency card) and its actions. Cells and the Grid Connection carry analog power meters, scaled to rated power.

What you see: the sky glows from the screen edge the sunlight comes from and is colored by the sun's actual spectrum (red at dawn and dusk). At night the moon takes over: it goes through phases over 8 game days, rises about 3.4 h later each day, and its light (about a millionth of the sun's) is traced through the same optics and drawn pale blue at a night exposure; below the original ground line a dark earth backdrop sits behind the tiles. Lenses, prisms and mirrors have their own temperature (Heat view fills them with it).

Screen: the top bar (clock, time controls, money and price, views), the tool rail on the left, the tool's side panel (the build catalog, or paint and wire options), the inspector top right and the view legend bottom right. The map ignores the pointer while it is over a panel.

Controls (the window opens maximized and the interface scales with it; every key below also has a button):

| Keys | Action |
|---|---|
| Select tool (Esc, 0) — default | Click an object to select it, drag to move, drag its ring handle to tilt (Ctrl snaps 15°); drag empty space to pan |
| Build tool (B) | Click a catalog card, then click the map to place it as often as you like (R/F tilt the ghost first); RMB or the card again drops it. Or drag a card onto the map to place one. 1–9 pick items by number. With nothing picked it works like Select. Objects go on stands that snap to tile columns and 25 cm heights (surface cells lie on the ground); hold Alt to float one (creative) |
| Paint tool (T) | LMB paint, RMB erase, Q/E or the swatches for material, `[` `]` size |
| Wire tool (V) | LMB lay wire, RMB remove, `[` `]` size. Objects connect at the foot of their stand; cells wired to a Grid Connection sell their power (money and price in the top bar) |
| WASD / middle-drag, wheel | Pan, zoom (up to 64×; outlines and labels stay crisp) |
| R / F (Shift = fine), Shift+wheel | Tilt the selected or hovered object |
| X / Delete | Delete the selected or hovered object |
| Space; Tab or − / + | Pause; speed 1× 2× 4× 8× 16× |
| `,` `.` (Shift: 6 h), the jump buttons, Set time… | Move the clock (−1 h, +30 min, +1 h, +6 h, or to a chosen hour) without simulating the time between (the sun moves, temperatures don't) |
| H, or the view buttons (top bar) | Views: Normal · Light (all wavelengths in false color, tiles show absorbed light) · Heat (every tile's temperature; hover the legend to read values) |
| G / J, or the wavelength list | Show one spectral band (UV, blue, green, red, near IR, IR) or all |
| F1, or ? on the rail | Hide/show the help line |
| Ctrl+Z, or the rail's undo | Undo |

## Agent tools (inspect the running game)

`debug/sim_probe.gd` is an autoload (`SimProbe`) that answers questions about the live sim and sends commands without a mouse. Call it through the Godot MCP's `game_eval`:

```gdscript
return SimProbe.run("help")                    # list commands
return SimProbe.run("objects")                 # ids, positions, angles, absorbed W, probe readings
return SimProbe.run("region", {"x0": 40, "y0": 14, "x1": 48, "y1": 20, "layer": "light"})  # ASCII map
return SimProbe.run("trace", {"x": 43.4, "y": 17.0, "dx": 0.96, "dy": -0.28})  # one test ray, leg by leg
return SimProbe.run("rotate", {"id": 4, "angle": 30})
return SimProbe.run("step", {"n": 5})          # pause, then advance exactly 5 ticks
return SimProbe.run("fan", {...})              # dense plain-ray ground truth (exit-angle histogram)
```

Other commands: `state` (sun, moon, traced light), `power` (money, price, wire networks), `wire`, `site` (save, reset), `defs`, `object`, `tile`, `peaks`, `beams`, `strips` (beam widths and concentration per leg), `place`, `move`, `remove`, `time`, `pause`, `speed`, `view`, `wavelength`, `camera` (see `help`). Prefer these over screenshots when checking behaviour: they return exact numbers and cost far less.

Positions are meters (x right, y down), angles degrees. Commands go through the sim's command queue like player input.

## Tests

Headless sim tests (a test also fails on any script error raised while it runs). Build the C# project first if it changed; `tools/test.py` re-registers new `class_name` scripts first (an open editor rewrites the class cache) and uses `$GODOT` (the `_console.exe` on Windows) or `godot` on the PATH:

```bash
dotnet build "Solar Sim.csproj"
python tools/test.py            # tests
python tools/test.py --bench    # tests, then the benchmark
```

The benchmark gives per-system timings on a full-size site (demo rig and a 30-lens field; full passes, mesh build, heat, ticks, dragging a lens), with a checksum to confirm optimizations don't change results.

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
- `debug/` — `SimProbe`, agent tooling for the running game
- `scenes/` — entry scene
- `tests/` — headless tests and benchmark
- `tools/` — `check.py` (lint and house rules), `test.py` (tests and benchmark)
- `docs/` — design document, style guide, run reports (`runs/`)
- `addons/godot_ai/` — Godot AI MCP plugin (v4.3.0)
