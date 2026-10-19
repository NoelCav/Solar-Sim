# Code style and consistency rules

The goal is a codebase that stays easy to change as it grows: one way to do each thing, each thing in one place, and no patches layered over problems. `python tools/check.py` enforces the mechanical rules; the rest is on review.

## 1. Principles

1. **One source of truth.** Every formula, constant and conversion has one home; everything else calls it. Before writing a formula, search for it. Plain sunlight is `SimConst.REFERENCE_DNI`, a material's sun-weighted absorptivity is `MaterialDB.sun_absorptivity`, tile watts become W/m² through `LightSystem.irradiance_scale`, display exposure comes from `DisplayLight`. When you centralize something, add its pattern to `ONE_HOME` in `tools/check.py` so copies can't creep back.
2. **Fix the model, not the symptom.** A fix changes the system so the whole class of problem can't happen again (a beam split drawn wrong is fixed where splits are drawn, not by hiding the seam). If the right fix is an overhaul, stop and discuss it first, and prefer the design that makes the system complete and simple over one that bolts on a case.
3. **Less code.** Generalize the existing path instead of adding a parallel one; delete what the generalization replaces. Duplicate systems are the main source of rot.
4. **Build a system when it is its time.** The roadmap (design §18) orders the work. Record decisions early (design doc), build them when their milestone comes; don't scaffold ahead.
5. **Verify with numbers.** Physics changes get a test against closed-form or ground-truth results; behaviour in the running game is checked with SimProbe before screenshots.

## 2. Where code lives (layers)

| Directory | Holds | May use | Never |
|---|---|---|---|
| `sim/` | World state and physics, SI units (D5, D8), deterministic (D7), mutated only through commands (D6). `*.cs`: compiled hot loops behind a small API; GDScript orchestrates | `sim/`, `data/` | Reference `render/`, `ui/`, `scenes/`, `debug/` (checked) |
| `render/` | Draws sim state. Display policy for light: `DisplayLight` (exposure, night, tint); beam tone: `BeamGeometry` | `sim/` (read only) | Mutate sim state |
| `ui/` | Input → commands, panels, text. All value formatting through `Readout` | `sim/` (read), `render/`, commands | Mutate sim state directly |
| `debug/` | `SimProbe`: agent tooling. Extend it with every new system | Public APIs only | Reach into private members |
| `tests/` | Headless checks (`run_tests.gd`) and the benchmark (`bench.gd`) | Public APIs | |
| `data/` | Content as `.tres` (D11, D15) | | Hold logic |
| `tools/` | Project scripts (`check.py`) | | |

## 3. GDScript

- **Order** (gdlint `class-definitions-order`): `class_name`, `extends`, `##` class doc, signals, enums, constants, exports, public vars, private vars, `@onready` vars, then functions: engine callbacks and public API first, private helpers after.
- **Names:** `snake_case` variables and functions, `PascalCase` classes and enums, `UPPER_SNAKE` constants. A leading `_` marks anything outside the class's API; **another class's `_private` is never used** (checked). If you need it from outside, give the class a public method or property that says what it is for.
- **Units in names** where they aren't obvious: `_m`, `_w`, `_w_m2`, `_k`, `_c`, `_s`, `_deg`, `_px`. The sim stores SI; only render/UI convert.
- **Static typing everywhere:** `:=` inference, typed arrays and dictionaries, typed function signatures.
- **Formatting:** tabs; lines ≤ 120 columns (checked); a continued line ends in `\` and the continuation is indented two levels; trailing `##` comments on a block of declarations are aligned. `gdformat` is not used: it would strip that alignment and rewrite continuations.
- **Docs:** every script starts with a `##` comment under `extends` saying what it is (checked); every public function and non-obvious member has a `##` comment. Comments explain why and the physics, not what the next line does. Refer to the design doc as `§6.2` and decisions as `D13`.

## 4. C#

- Public methods `PascalCase`, private fields `_camelCase`, constants `PascalCase`; `///` doc comments on the class and public methods.
- C# holds hot loops only (ray work, heat kernel, mesh building). Orchestration, content and policy stay in GDScript.
- After changing C#: `dotnet build "Solar Sim.csproj"` before running Godot or the tests.

## 5. Before committing

```
python tools/check.py           # gdlint + house rules
python tools/test.py            # tests (re-registers new class_name scripts first)
python tools/test.py --bench    # also the benchmark, if it touches light, heat or meshes
```

Every new system brings: SimProbe commands to read it, tests for its physics, and a note in the design doc (§18 pass notes, decisions in §3). Keep each file's existing line endings (mixed endings are flagged).
