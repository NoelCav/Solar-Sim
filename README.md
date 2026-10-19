# Solar-Sim

A 2D side-view systems sandbox about harnessing sunlight: route spectral light through lenses, prisms and splitters onto solar cells, and manage the heat. See [docs/design.md](docs/design.md).

## Running

Godot **4.7 .NET** (the C# build; the Steam build lacks C#) and the .NET 8+ SDK. The hot loops (light engine, beam mesh, heat) are C#; everything else is GDScript. Open the project in the editor and press Play (the editor builds the C# project), or:

```bash
dotnet build "Solar Sim.csproj"
godot --path .
```

The site starts with a demo rig: a crown-glass lens over an irradiance probe, a flint prism, a tilted mirror and a long-focus acrylic lens. Hover anything for the inspector (material, temperature, absorbed light by band, object readings).

Controls:

| Keys | Action |
|---|---|
| WASD / middle-drag, wheel | Pan, zoom |
| Space, Tab | Pause, cycle speed (1× 2× 4×) |
| `,` `.` | Time −/+ 1 hour |
| H, or the view bar (top right) | Views: Normal · Light (all wavelengths, false color) · UV · Infrared · Heat |
| F1 | Hide/show the help bar |
| 0 | Tile brush: LMB paint, RMB erase, Q/E material, `[` `]` size |
| 1–5 | Object tool: LMB place or drag, RMB remove |
| R / F (Shift = fine) | Rotate hovered object |
| X / Delete | Delete hovered object |
| Ctrl+Z | Undo |

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
