# Solar-Sim

A 2D side-view systems sandbox about harnessing sunlight: route spectral light through lenses, prisms and splitters onto solar cells, and manage the heat. See [docs/design.md](docs/design.md).

## Running

Godot 4.7+. Open the project in the editor and press Play, or:

```bash
godot --path .
```

Controls: WASD / middle-drag pan, wheel zoom, Space pause, Tab speed, LMB paint, RMB erase, Q/E material, `[` `]` brush size, Ctrl+Z undo.

## Tests

Headless sim tests:

```bash
godot --headless --path . -s res://tests/run_tests.gd
```

## Layout

- `sim/` — pure simulation (no Nodes): world, tile grid, materials, commands, systems
- `data/materials/` — material definitions (`.tres`, SI units)
- `render/`, `ui/` — Nodes that read sim state and send commands
- `scenes/` — entry scene
- `tests/` — headless tests
- `addons/godot_ai/` — Godot AI MCP plugin (v4.3.0)
