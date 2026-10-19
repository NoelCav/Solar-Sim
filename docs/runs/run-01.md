# Run 01: M3a and power (autonomous)

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
  limit); the doc is updated.

**Not done / limits.** Stands don't change when the ground under them is dug out (the pole just
reaches the new ground); poles don't occupy space, so two stands may share a column. Probe
readings are published at the traced light level and not rescaled as the sun moves between passes
(cells are). I could not check this group in the running game: the open editor needs a project
reload to see the new classes (see below).

## Open questions

- The editor has to be reloaded (Project → Reload Current Project) whenever a run adds a new
  `class_name` script; until then the game fails to start from the editor. Headless tests are not
  affected (`tools/test.py`).
