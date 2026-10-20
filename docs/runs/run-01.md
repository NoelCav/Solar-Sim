# Run 01: M3a, power and the interface

Built on my own, group by group; you review at the end, one section per group. Each group is a
separate commit (or a few), so any group can be reviewed, reverted or reworked on its own.

## Decisions given before the run (2026-10-19)

- Groups, in order: 1 surface skin (D18) · 2 stands and solar cells · 3 wires, grid and money ·
  4 shop and unlocks · 5 batteries, powered objects, cell damage. Fire and burning are not in this run.
- Lenses, mirrors and cell panels all sit on **stands** that snap to the tile grid (D16); stands are
  background props (D19): drawn behind, never block light. Free floating stays only in creative mode.
- Small **surface cells** can be placed directly on the ground.
- **Wires** are a painted tile layer (D14); networks rebuild when wires change.
- **Money:** placing costs money, removal refunds a share; a creative toggle keeps free placement.
- One report at the end (this file), group by group.

Changed during the run:

- Group 4 became the **interface and readouts** (you asked for a clearer UI and efficiency panels). The shop, prices and unlocks move to after the core systems (2026-10-20).
- Asked for along the way: site save, power meters on devices, catalog click-to-place, the display-lighting plan (design §6.8), a docs and cleanup pass.

## Rules I hold myself to during the run

- Locked decisions (design §3) are not changed. If a group needs a change to one, or an overhaul of
  an existing system beyond what the group names, I stop that thread, write the question under
  **Open questions** below, and continue with what doesn't depend on it.
- Where a choice is a judgement call, I pick the option that keeps the system simplest and most
  complete, and list it under the group's **Choices made** so you can overrule it.
- Every group ends with: tests (new physics tested against hand-worked numbers), `tools/check.py`,
  a self-review of the group's diff for bugs (then fixes), a check in the running game through
  SimProbe, design-doc notes, and a commit.

## Report

### Group 1: surface skin (D18)

**What it does.** Every face where a solid meets air or liquid is split into 10 strips (2.5 cm).
Light absorbed by a solid lands in the strips; the solid exchanges heat with the outside only
through them (conduction into its block, a film to the air or liquid, lateral spreading along
the surface, radiation). Evenly lit ground behaves exactly as before (the series conductance is
the old one), but a focus now heats a spot: the demo's acrylic lens at noon puts 22.8 kW/m²
(~23×) on one strip of dirt, which reaches ~350 °C while the block under it stays at 18 °C.

**Where to look.** `sim/thermal/surface_skin.gd` (model and data), `sim/thermal/SkinKernel.cs`
(steady solve per run of faces), `ThermalSystem.step_skin`, light per strip in
`LightEngine` (`StripIds`, `AbsorbLanding`, `DirectDeposit`), `LightSystem` (publishing strips,
`_map_surface_light`), heat view `render/heat_overlay.gdshader`.

**Try it.** Noon, Heat view, zoom on the ground under the acrylic lens: the skin shows as a thin
colored line on surfaces (orange in sun, cyan in the lens's shadow, white at the focus); hover the
spot for "surface up to N °C".

**Choices made.**
- The skin is solved steady (no heat capacity of its own): a 5 mm skin holds almost nothing next
  to its 25 cm block, and a steady solve is exact on energy and needs no tiny time step.
- Lateral spreading uses a near-surface layer as deep as a strip is wide (k · depth); that sets how
  hot a focus gets. It is the one new physical parameter worth tuning by feel.
- Faces of solids only; liquids keep their whole-tile surface exchange.

**Found and fixed while building.** Direct sunlight landed whole 2 cm lanes on 2.5 cm strips, so
plain ground read 1.6× and 0.8× sunlight in a repeating pattern; lanes now spread over their
footprint, across tile borders. The first version also recomputed every lit strip in GDScript each
tick and allocated per-strip lists during beam refinement; both were reworked (rates written once
per pass, a yes/no surface test while refining).

**Known cost.** Debug build: demo-rig tick ~1.5 → ~2.2 ms; the 30-lens field at 09:00 takes ~51 ms
per full pass instead of ~34 (passes are spread over ticks). Noon and the demo rig's passes are back
at their old cost. If it matters later: store each landing as a strip range and fill strips once
when a pass publishes.

**Review before committing.** Fixed a strip that could be listed twice when a contribution rounded
to zero (it would have subtracted its light from its tile twice), and removed an unused per-strip
energy input and a redundant rebuild check.

### Group 2: stands and solar cells (D21, §9.1)

**What it does.** A silicon cell panel (`cell_si`, 1 m) and a 25 cm surface cell
(`cell_si_surface`) join the build bar. A cell reflects what its anti-reflection coating doesn't
catch, heats up with the rest, and its front records the light arriving per wavelength band. From
that, the cell model gives the power it could make: 22 % at plain sunlight and 25 °C, more under
moderate concentration, nothing by ~500 suns (series loss), less when hot (−0.4 %/K). Wires come
in group 3, so for now its power is shown, and all of its light stays heat.
Optics and panels now stand on stands: the pole is centered in a tile column, the height snaps to
25 cm steps (0.5–6 m) above the ground under the cursor, and tilt stays free. Surface cells lie on
the ground. Probes float. Alt while placing floats anything (creative mode, on by default).

**Where to look.** `sim/power/solar_cell.gd`, `sim/objects/mounting.gd`, the `CoatCell` cases in
`LightEngine.SurfaceHit` and the beam path, `PlaceObjectCommand` / `TransformObjectCommand`.

**Try it.** The demo's last object (right) is a cell panel on a 1 m stand; hover it for "could
make N W (η of irradiance)". Headless at noon it gets 967 W/m² and could make 43.8 W (18 %: it is
already 49 °C after a few seconds). Pick a lens in Build: the ghost shows its stand and snaps.

**Choices made.**
- A stand is part of its object (`ObjectDef.mount`, `SimObject.mounted`), not an object of its own:
  stands are background props with no physics, and one object per thing keeps dragging, deleting
  and undo as they were. Swapping a stand's contents (D16) can come with the crafter.
- The sim enforces the rule: the commands snap, so tools, SimProbe and the demo rig all agree.
- Cells reuse the probe's per-band record ("incident" light) instead of a second mechanism.
- The model's voltage factor is 0.5, not the design doc's 0.75 (that gives the ~33 % theoretical
  limit); the doc is updated. (Group 4: 0.52, once the coating's reflection came out of the output.)

**Not done / limits.** Stands don't change when the ground under them is dug out (the pole just
reaches the new ground); poles don't occupy space, so two stands may share a column. Probe
readings are published at the traced light level and not rescaled as the sun moves between passes
(cells are). I could not check this group in the running game: the open editor needs a project
reload to see the new classes (see below).

### Group 3: wires, grid and money (D14, §10)

**What it does.** The Wire tool (V) paints wire on tiles with the paint brush (LMB lay, RMB
remove, `[` `]` size). Wire runs behind everything, through air and ground. Wire tiles that touch
edge to edge form one network. Objects connect at the foot of their stand (the tile just above
the ground, or the ground tile under it). A new machine, the Grid Connection, is a box that sits
on the ground; on a network with one, every cell delivers what it can make and the network sells
it. Delivered power leaves the cell's heat, so a working cell runs cooler (40 °C against 48 °C at
noon). The price follows a duck curve (3 ¢/kWh at noon, 35 ¢ at 19:00); money and the current
price are on the status line.

**Where to look.** `sim/conduits/conduit_networks.gd`, `sim/commands/paint_wires_command.gd`,
`sim/power/power_system.gd`, `sim/power/market.gd`, `Mounting.port_tiles`,
`render/wire_renderer.gd`.

**Try it.** The demo's cell panel is wired along the ground to a Grid Connection two meters to its
right; hover the cell ("making 45 W (19 % of 967 W/m²)") and the box ("selling 45 W at 3 ¢/kWh").
Erase a wire tile with the Wire tool and the cell drops to "could make … (not wired to a grid
connection)".

**Choices made.**
- Ports are at the foot of the stand, so wiring is painted along the ground like real cable runs.
- Machines are background boxes (D19): they don't block light and don't collide with optics, only
  with other machines.
- Energy is counted in real time (a game day stands for 24 h), so a 45 W panel makes realistic
  kWh. Real prices make that cents a day; the shop's costs in group 4 decide the game's scale.
- No wire losses or limits yet; a network without a grid connection draws nothing.

**Checked.** Tests: networks join and split (with undo), a wired cell sells exactly what the model
gives and runs cooler, an unwired one sells nothing, the price curve. Headless boot of the game
scene: the demo network has 11 wire tiles, grid on, 45.3 W sold. Tick cost unchanged (2.2 ms).

### Group 4: interface and readouts (design §16, §18.12)

**What it does.** A new screen layout: a top bar (clock and sky, pause, speed − / +, clock jumps
and Set time, money, what the site sells and the price trend, views), a tool rail on the left, a
side panel with the build catalog (search, category tabs, item cards), the inspector fixed top
right and the legend bottom right. Click a card, then click the map to place as many as you like,
or drag a card onto the map. Hovering gives summaries; selecting gives everything: a lens's focus,
transmission and material, a cell's efficiency card (rated vs now, where the light goes, power by
color, direct sun vs through optics). Cells and the Grid Connection have analog power meters on
the device. The site saves every 5 s and comes back on start.

**Where to look.** `ui/hud.gd` and the panels it assembles, `ui/ui_style.gd`, `ui/stack_bar.gd`,
`render/power_meters.gd`, `SolarCell.analyze` / `rated_power`, `SimObject.incident_direct` (the
light engine's direct/optics split), `sim/site_save.gd`.

**Try it.** Select the cell panel at noon: about 43 W of 55 W rated, 18 % against 22 % rated (it
runs warm), and red and near-IR making most of the power. Put a lens over it and watch the
"through optics" share and the meter's needle climb into the red zone.

**Choices made.**
- Tool rail plus side catalog (your pick), drag or click to place.
- Meters scale to rated power (the nameplate watts: plain sunlight face-on at 25 °C); past it the
  needle pins and the amber lamp lights. An unwired cell's meter reads zero (it makes nothing);
  the inspector says what it could make.
- Display lighting is planned as a separate display pass (design §6.8), not part of the sim.

**Cleanup pass.** Removed helpers left from the GDScript tracer; gave pixels per meter, face area,
the game-day compression and Stefan–Boltzmann one home each (guarded by `tools/check.py`); shared
panel and spacer helpers in `UiStyle`. Then a cohesion pass over the whole codebase: removed the
`object_id` tile layer (D20's outline rule had replaced it; it was also wrong where two objects'
boxes overlapped), scaffolding nothing used (a tick signal, an RNG, per-system enable flags, a flag
enum, three material tables), and made every renderer a scene node. Tests and benchmark unchanged.

### Tooling: scenarios, benchmark and bug sweep, headless probe (design §18.13)

**What it does.** Seven named test scenarios you can load in the game (top bar → Site; your site
is saved first and never overwritten) and that the benchmark runs headless. The benchmark checks
physics invariants, compares the beam engine with plain rays and with small sun steps, compares
everything with a recorded baseline, and counts work in machine-independent units (ray paths,
cache misses, mesh vertices…) so a laptop on battery doesn't look like a regression. SimProbe now
runs headless too (`python tools/probe.py <scenario> cmd …`), so investigating needs no throwaway
scripts.

**Found.** Saves lost float precision (fixed). Open: light in water flickers as the sun moves (a
spectral bin drops out of one surface tile at a time); beams spread a sharp focus slightly
unevenly; incremental passes keep changed pooled reflections briefly. Also: crown glass absorbs a
quarter of a big lens's light, and a fixed lens loses a 25 cm target within seconds of game time.

### Decisions taken during the run (all in the design doc)

- Interface: tool rail and side catalog; hover = summary, select = full numbers; power meters on the devices (§16, §18.12).
- Shop, prices and unlocks after the core systems (§15).
- Display lighting as a display-only pass with a shared light field (§6.8).
- A 24-minute day; optical materials absorb as measured, no gameplay exaggeration (§4, §8).
- Water: one fill-based liquid system with no cosmetic falling; it drains when support is removed and spills from broken pipes (§11).
- Optical components to add, in order (§6.9); projection and camera ideas (§6.10).

### Where to pick up

Design doc §18.14 lists the state and the next steps in order; `CLAUDE.md` has the commands and working rules. Group 5 (batteries, the lamp, cell damage) is next.

## Open questions

- ~~The editor has to be reloaded whenever a run adds a new `class_name` script.~~ Solved without a
  reload: the MCP's `filesystem_manage` reimport of each new script registers it. (Its full `scan`
  must not be used for this: it drops classes a headless import found first.)
