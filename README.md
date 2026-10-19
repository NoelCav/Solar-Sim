# Solar-Sim

A 2D side-view systems sandbox about harnessing sunlight: route spectral light through lenses, prisms and splitters onto solar cells, and manage the heat. See [docs/design.md](docs/design.md).

## Running

Godot **4.7 .NET** (the C# build; the Steam build lacks C#) and the .NET 8+ SDK. The hot loops (light engine, beam mesh, heat) are C#; everything else is GDScript. Open the project in the editor and press Play (the editor builds the C# project), or:

```bash
dotnet build "Solar Sim.csproj"
godot --path .
```

The site starts with a demo rig: a crown-glass lens over an irradiance probe, a flint prism, a tilted mirror and a long-focus acrylic lens. Hover anything for the inspector (material, temperature, absorbed light by band, object readings and temperature).

What you see: the sky glows from the screen edge the sunlight comes from and is colored by the sun's actual spectrum (red at dawn and dusk); below the original ground line a dark earth backdrop sits behind the tiles. Lenses, prisms and mirrors have their own temperature (Heat view fills them with it).

Controls (the window opens maximized and the interface scales with it; every key below also has a button):

| Keys | Action |
|---|---|
| Select tool (Esc, 0) — default | Click an object to select it, drag to move, drag its ring handle to tilt (Ctrl snaps 15°); drag empty space to pan |
| Build tool (B, 1–5) | Pick an item from the bar, LMB place (R/F tilt the ghost first), RMB back to Select |
| Paint tool (T) | LMB paint, RMB erase, Q/E or the swatches for material, `[` `]` size |
| WASD / middle-drag, wheel | Pan, zoom (up to 64×; outlines and labels stay crisp) |
| R / F (Shift = fine), Shift+wheel | Tilt the selected or hovered object |
| X / Delete | Delete the selected or hovered object |
| Space, Tab, or the speed buttons | Pause, speed 1× 2× 4× 8× 16× |
| `,` `.` (Shift: 6 h), or the jump buttons | Move the clock −/+ 30 min, 1 h, 6 h without simulating the time between (the sun moves, temperatures don't) |
| H, or the view bar (top right) | Views: Normal · Light (all wavelengths in false color, tiles show absorbed light) · Heat (every tile's temperature; hover the legend to read values) |
| G / J, or the wavelength slider | Show one spectral band (UV, blue, green, red, near IR, IR) or all |
| F1 | Hide/show the help lines |
| Ctrl+Z | Undo |

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

Other commands: `state`, `defs`, `object`, `tile`, `peaks`, `beams`, `place`, `move`, `remove`, `time`, `pause`, `speed`, `view`, `wavelength`, `camera` (see `help`). Prefer these over screenshots when checking behaviour: they return exact numbers and cost far less.

Positions are meters (x right, y down), angles degrees. Commands go through the sim's command queue like player input.

## Tests

Headless sim tests (a test also fails on any script error raised while it runs). Build the C# project first if it changed:

```bash
dotnet build "Solar Sim.csproj"
godot --headless --path . -s res://tests/run_tests.gd
```

Per-system timings on a full-size site (demo rig and a 30-lens field; full passes, mesh build, heat, ticks, dragging a lens), with a checksum to confirm optimizations don't change results:

```bash
godot --headless --path . -s res://tests/bench.gd
```

## Layout

- `sim/` — pure simulation (no Nodes): world, tile grid, materials, commands, systems
  - `light/` — spectrum, optical surfaces, generators, sun map, light passes; `LightEngine.cs` (ray work)
  - `thermal/` — heat grid; `HeatKernel.cs` (per-tile loops)
  - `objects/` — object definitions and instances
- `data/materials/`, `data/objects/` — content definitions (`.tres`, SI units)
- `render/`, `ui/` — Nodes that read sim state and send commands (`BeamMesh.cs` builds beam triangles)
- `scenes/` — entry scene
- `tests/` — headless tests and benchmark
- `addons/godot_ai/` — Godot AI MCP plugin (v4.3.0)
