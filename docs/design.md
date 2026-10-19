# Solar-Sim — Design Document

> Living document. Sections marked **LOCKED** are architecture decisions we build against and should not change without a deliberate migration. Everything else is tunable.
>
> Last updated: 2026-10-19 (UI/sky/thermal pass; next: moonlight)

---

## 1. Vision

A 2D side-view, god-view systems sandbox about harnessing sunlight. You build optical rigs — lenses, mirrors, prisms, splitters — that route real (simplified) spectral light onto solar cells. Every photon becomes **electricity or heat**, and heat is the enemy, the byproduct, and the resource. Systems interact the way they do in *Oxygen Not Included*: heat, fluids, smoke, light and power all read and write shared state, so emergent failures (a melting lens, a steam-burst pipe, a fire whose smoke darkens the next array) come from the rules, not scripts.

Building scale is closer to *Terraria* / *Sandustry* (small tiles, precise placement) than ONI.

## 2. Pillars

1. **Light is the showpiece.** Physically based ray optics, dispersion, caustics, bloom. It should be beautiful and *readable*.
2. **Everything becomes heat.** One shared thermal field connects every system.
3. **Real science, simplified.** Real formulas and real material properties, with tuning dials — never fake rules where a real one is cheap.
4. **Destruction is real.** No click-to-repair. Burned, melted, cracked things become debris you must clear and rebuild.
5. **Sim first.** God-view cursor, overlays, time controls. The simulation is the game.

## 3. Locked decisions — LOCKED

| # | Decision | Notes |
|---|---|---|
| D1 | **Side-view 2D**, god-view cursor, no player avatar | Avatar may be added later; sim must not depend on one |
| D2 | **Layered simulation** — each system at its own resolution (see §5) | No per-pixel falling-sand sim |
| D3 | **Light is continuous**, not grid-based: 2D ray tracing with real refraction | Grid only used as a spatial acceleration structure |
| D4 | **All optical surfaces are polylines** with per-vertex normals | Analytic shapes (arcs) are *generated* into polylines. Enables deformation, cracks, Fresnel teeth, custom profiles |
| D5 | **Sim is pure data, separate from nodes** | Packed arrays + plain classes; nodes only render and send commands |
| D6 | **All mutations go through a command queue** applied at tick start | Enables determinism, undo (creative), replays, saves |
| D7 | **Fixed tick, 20 Hz**, deterministic, seeded RNG | Never use frame delta in the sim |
| D8 | **Sim uses SI units internally** (m, kg, s, W, J, K) | Display converts (°C, kWh, etc.). One constants file for unit/scale |
| D9 | **Every tile layer exists in the data from day one**, even if its system ships later | This is how we avoid a rebuild |
| D10 | **Physics time = sim time.** The sun moves faster than reality; physics does not | A 12-min day compresses the sun's path, not heat flow |
| D11 | **Data-driven content**: materials and objects are Godot `Resource`s (`.tres`) | New content without code |
| D12 | **Destruction leaves debris tiles**; objects cannot be repaired in place | Must be mined/deconstructed and rebuilt |
| D13 | **Objects own internal thermal nodes** coupled to their footprint tiles by contact conductance | One mechanism for cells (M3), lens slices (M7), batteries, heatsinks. Replaces "lens absorption heats host air tiles" |
| D14 | **Conduits are tile layers + rebuilt graphs**: wires, pipes (and later data) share one network framework; each kind plugs in its own per-tick solver | Graph rebuilt only when a conduit tile changes; per-tick work runs on the compact graph |
| D15 | **Designs are data**: an object instance references a design (def parameters), saved by value; built-in `.tres` defs are just stock designs. Every buyable thing carries `cost` and `unlock` fields in its def | Lens bench, shop, saves and research all read the same data (D11) |
| D16 | **Placed objects can hold components**: a stand holds a lens, a cell module holds its layers. Components are designs (D15) with their own state | Swap a lens without moving the stand; one inspector and save path for both |
| D17 | **Systems exchange energy only through the heat field and object ports** (power, pipe). No system reads another's internals | Keeps thermal power, cells, fluids and light composable as scope grows |
| D18 | **Lit faces carry a thin surface skin** split into strips (~2.5 cm) that take the light deposits at the light engine's resolution; the skin couples to its 25 cm tile by conduction. Charring, ignition, melting and cell damage read the skin | Focal spots heat a spot, not a whole tile: a magnifying glass singes wood in seconds while the block stays cool |
| D19 | **Light is shown where it lands.** Terrain is lit on its exposed faces only, never through a block; things behind the play plane are **background props** (trees, stands, panel frames, machine bodies) that catch light for display but never block, absorb or heat. Daylight lights everything; at night only lit faces and props show (`DisplayLight`) | Keeps optics and heat 2D while the world reads as lit by real light: focused moonlight, later lamps, light up spots in a dark world |
| D20 | **Objects occupy space.** An object's shape may not overlap another object's shape or a solid tile (air and liquids are free). Placing or moving into occupied space is refused (`Placement`, checked in the commands); a drag stops at the last free spot and still undoes in one step | No stacked lenses or lenses sunk into rock; one rule for every placement path (tools, SimProbe, saves) |

## 4. World & scale

- **Tile:** 16 px = **0.25 m**.
- **2D slice depth:** the world is a slice **0.25 m deep** (one tile). Tile volume = 0.25³ = 0.0156 m³. All mass/heat capacity derives from this.
- **Site size (initial):** 300 × 120 tiles (75 m × 30 m). Configurable per site.
- **Day length:** 12 real minutes at 1× (tunable). Roughly 8 min daylight, 4 min night; varies by site latitude/season.
- **Time controls:** pause / 1× / 2× / 4× (multiple ticks per frame at higher speeds).
- **Coordinates:** tile index `i = y * W + x`, y increasing downward (Godot convention). World positions in meters for the sim; pixels only in rendering.

## 5. Simulation architecture — LOCKED

### 5.1 Layers

| Layer | Resolution | Model | Ships in |
|---|---|---|---|
| Structure | Per tile | Material id + flags + occupying object | M0 |
| Heat | Per tile (+ object internal nodes) | Conduction between neighbors, convection bias, sky radiation | M1 |
| Light | Continuous | Ray tracer over polyline geometry | M1 |
| Objects | Multi-tile entities | Own internal models (cells, lenses, batteries…) | M1+ |
| Power | Graph | Supply → consumers → storage → grid per tick | M3 |
| Pipes | Graph of segments | ONI-style packets (mass, fluid, T) | M4 |
| Damage/fire | Per tile + per object | Integrity, ignition, burn-to | M5 |
| Free liquid | Per tile | Terraria-style cellular automaton, fill 0–1 | M6 |
| Gas fields | Per tile | Scalar densities (smoke, steam): rise, diffuse, decay | M6 |

### 5.2 Per-tile data (struct-of-arrays)

All allocated at world creation, regardless of milestone (D9).

| Array | Type | Meaning |
|---|---|---|
| `material` | `PackedInt32Array` (u16 used) | Material id (air is a material) |
| `temperature` | `PackedFloat32Array` | Kelvin |
| `integrity` | `PackedFloat32Array` | 0–1, structural health |
| `flags` | `PackedInt32Array` | Bitfield: burning, wet, supported, dirty-light, background wall… |
| `object_id` | `PackedInt32Array` | Occupying object, or -1 |
| `liquid_amount` | `PackedFloat32Array` | 0–1 fill of non-solid tiles |
| `liquid_type` | `PackedInt32Array` | Material id of the liquid |
| `smoke` | `PackedFloat32Array` | Density 0–1 |
| `steam` | `PackedFloat32Array` | Density 0–1 |
| `energy_in` | `PackedFloat32Array` | Joules deposited this tick (light, fire, electrical losses); consumed by heat step |

One temperature per tile: liquid in a tile adds its heat capacity to the tile's total rather than having a separate temperature.

### 5.3 Tick order

Each tick (dt = 0.05 s):

1. **Apply commands** (build, remove, creative edits).
2. **Environment** — sun position, air mass, weather, ambient temperature, wind.
3. **Light** — re-trace if dirty (sun moved past threshold, geometry changed); deposit absorbed power into `energy_in` and object receivers.
4. **Objects** — cells convert absorbed light; lenses update internal thermal slices; batteries, pumps, etc.
5. **Power network** solve.
6. **Pipe network** — move packets, exchange heat with host tiles.
7. **Heat** — fold `energy_in` into temperature, then conduction/convection/radiation (subcycled if stability requires).
8. **Free liquid** CA step.
9. **Gas fields** step.
10. **Phase change, combustion, damage** — boiling, condensation, ignition, melting, cracking, debris conversion.
11. **Publish render state** — upload fields (heat, smoke, liquid) to textures; hand ray segments to the renderer.

Some layers may run every Nth tick (e.g. gas at 10 Hz) — that's a tuning choice, not an architecture change.

### 5.4 Code boundaries

```
Input/UI ──commands──▶ SimWorld ──read-only state──▶ Renderers / Overlays / Inspector
```

- `SimWorld` and everything under `sim/` are `RefCounted` / plain classes — **no Node dependencies**. Runnable headless for tests.
- Renderers never mutate sim state.
- Hot loops (heat diffusion, liquid CA, ray tracing) are written against packed arrays behind narrow interfaces so they can be ported to C# or GDExtension if GDScript is too slow, **without design changes**.

### 5.5 Performance budget (target, per tick at 1×)

| System | Budget |
|---|---|
| Light trace (when dirty) | ≤ 4 ms |
| Heat (36k tiles) | ≤ 2 ms |
| Liquid + gas | ≤ 2 ms |
| Everything else | ≤ 2 ms |

If a system exceeds budget in GDScript, port that system first.

## 6. Light

### 6.1 Spectrum

Six bins. Each bin has a representative wavelength (for dispersion) and photon energy (for cell physics, `E = 1240 / λ[nm]`).

| Bin | λ (nm) | E (eV) | Share of AM1.5 power | Render color |
|---|---|---|---|---|
| UV | 350 | 3.54 | 5% | violet |
| Blue | 460 | 2.70 | 14% | blue |
| Green | 540 | 2.30 | 16% | green |
| Red | 680 | 1.82 | 25% | red |
| NIR | 950 | 1.31 | 22% | faint deep red / invisible (overlay only) |
| IR | 1500 | 0.83 | 18% | invisible (overlay / heat shimmer only) |

Shares are approximate and live in data.

### 6.2 The sun

- Elevation/azimuth from time of day + site latitude + season. In 2D side view we use the projected angle in the slice plane.
- **Direct irradiance** (DNI) ~900–1000 W/m² at noon, reduced by **air mass** (longer path at low sun). Air mass also shifts the spectrum red (blue bins attenuate faster) → real red sunsets.
- **Diffuse irradiance** is a separate, non-focusable term applied to sky-exposed surfaces (sky-visibility per tile). Clouds move power from direct to diffuse. **Lenses cannot focus diffuse light.**
- Direct light is emitted as a bundle of parallel rays across the whole site width, perpendicular to the sun direction. Default spacing ~2 cm → each ray carries `DNI × spacing × depth` watts split across bins.

The atmosphere is per bin: direct sunlight is the AM0 spectrum attenuated by Rayleigh scattering (λ^-4), haze (Ångström λ^-1.3) and water/ozone absorption, times the Kasten–Young air mass (`Spectrum.atmospheric`). Low sun is dimmer and redder without a fudge factor (≈1010 W/m² overhead, ≈770 at 30°, ≈110 at 5°, mostly red/IR); the sky color is the same light weighted by scattering.

**The moon** is a second light source. Its phase runs over `MOON_CYCLE_DAYS` (8) game days and it trails the sun by phase × 24 h on the same arc, so a full moon rises at sunset and each moonrise comes a day/7 (≈3.4 h) later. Moonlight is reflected sunlight: `MOON_FULL_RATIO` (2.2 × 10⁻⁶, the real full-moon/sun ratio) of the AM0 spectrum at full, reshaped by the lunar reflectance (`Spectrum.MOON_REFLECTANCE`, roughly tripling from UV to near IR, so moonlight is redder than sunlight), times the lit fraction cubed (a quarter moon ≈ 1/8 of full, close to the real phase curve), through the atmosphere at the moon's own air mass. The light passes trace one source, `world.light_*`: the sun when it is up, else the moon. Cull thresholds scale with the traced DNI, so dim light keeps the same relative detail. Display: moonlight is drawn at a night exposure (a full moon at `MOON_DISPLAY` ≈ 0.35 of daylight) in a pale-blue tint, and the sky's moon glow follows the real moon; readouts stay physical (mW/m², "× moon").

### 6.3 Geometry (D4)

- Every optical object exposes **surfaces**: polylines with per-vertex normals (interpolated across segments for smooth refraction), a material on each side, and a surface coating (none, AR, mirror, dichroic cutoff…).
- Generators build polylines from parameters: convex/concave lens (arc radii, thickness, diameter), Fresnel lens (tooth profile), flat/parabolic mirror, prism (angles), dichroic plate.
- Solid tiles contribute axis-aligned edges (opaque, with the tile material's absorptivity).
- Acceleration: uniform grid over segments, rebuilt incrementally when geometry is dirty.

### 6.4 Ray interactions

Per hit, by surface and material:

- **Refraction** — Snell's law. Index per bin from **Cauchy's equation** `n(λ) = A + B/λ²` (material data). This gives real dispersion and chromatic aberration.
- **Reflection** — Fresnel reflectance via Schlick's approximation (~4% per uncoated glass surface at normal incidence); AR coatings reduce it; mirrors reflect a material-defined fraction per bin.
- **Total internal reflection** — falls out of Snell.
- **Dichroic** — reflect bins above a cutoff energy, transmit below.
- **Absorption in media** — Beer–Lambert along the path inside a transparent body; absorbed energy goes to the body's internal thermal slice at that location (§6.6).
- **Absorption at opaque surfaces** — per-bin absorptivity; absorbed power → that tile's `energy_in` or that object's receiver. The rest reflects diffusely (cheap: drop below threshold, or one low-power scattered child).
- **Participating media** — smoke/steam density attenuates rays crossing a tile; scattered fraction feeds visual-only god rays.

#### 6.4.1 Light pass pipeline (since M1.5)

Rays are only spent where light meets optics:

1. **Sun map (direct light):** sunlight is parallel, so the site is cut into 2 cm lanes across the sun direction and every sun-facing tile face and optical surface is projected onto them, keeping the nearest hit per lane (a 1D shadow map, as in terrain shadow-height maps). Lanes ending on opaque faces deposit directly with no rays; shadows fall out for free. Cost scales with exposed faces, not ray length.
2. **Beams (optics):** consecutive lanes whose first hit is the same object (or tile media: water, glass) form a run, traced per spectral bin as a wavefront. Sample rays start 10 cm apart; an interval is halved until both rays follow the same optical path (same faces, landing on one straight stretch of surface) or it is 1 cm wide (adaptive beam tracing). A coherent interval is a beam: its energy is spread exactly over where it lands and it is drawn as a filled strip with brightness ∝ 1/width, so focal spots are smooth and correctly concentrated from a few dozen rays. Each sample ray stands for half of each neighbouring interval; deposits recorded along its path are applied with that weight, so energy is conserved exactly.
3. **Secondary light:** Fresnel reflections are pooled along the wavefront (one ray per 0.5 m) and traced as an ordinary ray tree.

Ray tree rules (secondary light):
- Rays carry all 6 bins until the first refraction, then split per bin (so prisms make rainbows).
- Child rays (reflections) spawn only above a power threshold. Max depth 8.
- Output of a trace: (a) segment list with per-bin power → renderer, (b) energy deposits → sim.

### 6.5 Stands & the lens crafter

- **Stands** (bought by size class) hold a lens (D16). Stand qualities: max lens diameter/mass, height and tilt range, adjustment precision (coarse steps → smooth), heat tolerance (a stand near a stray focus can sag or burn). Later: motorized sun tracking (uses power, can fail).
- **Generic lenses** are sold in the shop from the start; the lens crafter unlocks custom ones.
- **Lens crafter:** the player drags the **target focus** (and later shapes each face). The crafter traces the design together with its manufacturing tolerance and draws the **focus region** — where the focus will actually land and how spread it is. Early it is a big circle; upgrades shrink it to a dot. Clever designers can correct a poor lens with a second one, because the optics are real.
- **Upgrades** add information and control, never different physics: focus region size (tolerance), predicted focal point / chromatic spread / concentration / safe temperature readouts, control of both faces, Fresnel and achromatic doublet types, better materials (acrylic → crown → flint → fused silica → sapphire), costs shown.
- **Manufacturing error is real** (§6.6): each crafted lens gets a seeded profile perturbation, saved with its design. In 2D, real-lens flaws show as a focus that is smeared along the axis (wrong curvature / spherical aberration), shifted sideways (wedge), comet-shaped (asymmetric "coma" term) or blurred (surface ripple).

### 6.6 Lens heating, deformation & failure

**One mechanism for every imperfection:** a lens surface is a polyline (D4), and manufacturing error, thermal sag and cracks are all perturbations of it. Manufacturing error is a fixed sum of a few smooth modes across the aperture (curvature, wedge, coma-like cubic, ripple) with amplitudes set by crafter quality; heat effects are added on top over time. The tracer needs nothing new. (Perturbed lenses are unique designs, so they don't share the object cache with other lenses.)


Lenses are not rigid props — they have internal state:

- Each lens is divided into **thermal slices** (8–16 across its width), each with a temperature, coupled to each other and to surrounding air.
- **Absorption** (especially IR in glass, UV in acrylic) heats slices where the beam passes.
- **Thermal lensing:** index shifts with temperature (`dn/dT`) per slice → focal point drifts. Real effect, exaggerated by a tuning dial.
- **Softening:** above the material's softening temperature, polyline vertices sag (gravity + viscosity) → surface warps → focus degrades and moves.
- **Thermal shock:** if the gradient between adjacent slices exceeds the material limit, the lens **cracks**: new internal surfaces are inserted with perturbed normals → stray focal points outside the normal zone, which can ignite things or damage the lens itself.
- **Melting:** lens becomes **glass slag** debris tiles.

Real-ish lens materials:

| Material | n (≈ green) | Dispersion | Softens | Notes |
|---|---|---|---|---|
| Acrylic (PMMA) | 1.49 | low | ~100 °C | Cheap, light, absorbs UV |
| Crown glass | 1.52 | low | ~550 °C | Standard |
| Flint glass | 1.62 | high | ~450 °C | Pairs with crown for achromats |
| Fused silica | 1.46 | very low | ~1600 °C | Tiny thermal expansion, expensive |
| Sapphire | 1.77 | low | ~2000 °C | Endgame |

### 6.7 Light rendering

- **2D HDR + glow** enabled in project settings; concentrated light blooms.
- Beams drawn as **additive soft quads** (not 1 px lines) into a light buffer; per-bin colors combine to white where bins overlap, separate into rainbows after prisms.
- **Caustics** emerge from overlapping additive rays — no special code.
- Intensity → brightness through a log tone curve so 1× and 1000× are both readable.
- **Dust motes** (particles) brighten where they sample the light buffer → visible beams.
- **Heat shimmer** distortion shader driven by the heat texture.
- NIR/IR are invisible in normal view but shown in a **light overlay** (false color per bin).
- **World lighting (D19):** by day everything is lit; after dusk the ambient fades to near black and a block shows only in a thin skin on the faces light lands on (the light engine records light arriving per tile face; the D18 skin will refine that along each face). Moonlight is drawn at a night exposure in a pale-blue tint. All display exposure and night policy lives in `DisplayLight`.
- **Background props (planned, D19):** a display layer behind the play plane, lit by the light passing in front of it (sheet, beams) so a lens stand or a panel frame glows where light crosses it. Display only: props never enter the optics or the heat field.

## 7. Heat

- Per tile: temperature T, from material: density ρ, specific heat c, conductivity k, emissivity ε.
- **Conduction:** 4-neighbor flux using harmonic-mean conductivity; explicit integration, subcycled when `dt > dx² / (4α)` for the fastest material present.
- **`energy_in`** (light, electrical losses, fire) is folded in first: `ΔT = E / (m·c)`.
- **Air convection (cheap):** air tiles bias heat transfer upward and relax toward ambient temperature (rate scales with wind and openness).
- **Sky radiation:** sky-exposed surfaces radiate `ε·σ·(T⁴ − T_sky⁴)`. Strong at night; in orbit it is the only cooling.
- **Objects** have internal thermal nodes coupled to their footprint tiles via contact conductance. Thin objects (cells) have small heat capacity — they spike fast.
- **Tuning dial:** a global heat-capacity scale per material class so things heat on gameplay timescales while formulas stay real.

## 8. Materials — data driven

`MaterialDef` resource fields (initial):

- Identity: `id`, `name`, `phase` (solid / powder / liquid / gas), `color`, `texture`
- Thermal: `density`, `specific_heat`, `conductivity`, `emissivity`
- Optical: `transparent`, `cauchy_a`, `cauchy_b`, `absorption_per_bin[6]` (bulk, per m), `surface_absorptivity_per_bin[6]`, `dn_dt`
- Mechanical: `hardness` (mining time), `softening_temp`, `melt_temp`, `melts_to`, `thermal_shock_limit`, `falls_when_unsupported` (sand, ash)
- Fire: `flammable`, `ignition_temp`, `burn_rate`, `burn_energy`, `smoke_rate`, `burns_to`
- Liquid/gas: `boil_temp`, `boils_to`, `condense_temp`, `condenses_to`, `viscosity`

Starter set: air, dirt, stone, sand, wood, steel, copper, aluminum, crown glass, acrylic, water, char, ash, glass slag, silicon (cell material).

## 9. Objects

`ObjectDef` resource: footprint (tiles), construction materials, optical surfaces (generator + params), thermal nodes, ports (power, pipe), behavior script.

Milestone 1 objects: lens (convex, parametric), flat mirror, prism, Si solar cell, heatsink, irradiance probe (debug).

### 9.1 Solar cell model

For each bin with photon energy E absorbed by a junction of bandgap Eg:

- **E < Eg:** not absorbed → transmits to the next layer (stacks) or is partly absorbed by the back contact as heat (single cells).
- **E ≥ Eg:** absorbed. Electrical output `= P_bin × (Eg / E) × η_collect × η_voltage × η_temp × η_series`; everything else → heat.
  - `η_collect` ≈ 0.9
  - `η_voltage` ≈ 0.75 × (1 + (kT/q)·ln(C) / Voc₀) — concentration *raises* efficiency (real)
  - `η_temp` = 1 − β·(T − 298 K); β ≈ 0.004/K (Si), 0.002/K (GaAs)
  - `η_series` = 1 − r_s·C — resistive loss grows with concentration
- **Multi-junction (series):** each layer's photon current ∝ Σ(P_bin / E_bin) absorbed; stack current = **min** of layers; excess becomes heat. 4-terminal upgrade removes matching.
- **Damage:** degrades above ~85 °C, fails ~150–200 °C (encapsulant smokes, cell cracks → debris).

Junction materials: Ge 0.67, Si 1.12, GaAs 1.42, GaInP 1.9 eV; perovskite (tunable 1.5–2.3, degrades with heat/moisture).

### 9.2 Cells in the world (no crafting screen)

- Cells are placed in the world, Factorio-style, and must never feel clunky: drag to place rows, cells placed side by side **join into one array automatically**, one wire drag connects an array to the network.
- **Stacks emerge from placement:** a cell passes the light it can't absorb (E < Eg), so a GaInP cell in front of a Si cell is a tandem; series current matching (§9.1) applies to cells wired as a stack. Research adds cell types and coatings (AR, back reflectors), not recipes.
- **Emergent play comes from the shared physics, never recipes:** spectrum splitting with prisms/dichroic mirrors to matched cells, concentration vs heat vs series loss, current matching, unused IR to a boiler. Every cell reads the same traced light.

## 10. Power & economy (M3)

- Networks are graphs of wires/ports. Per tick: production → consumers (priority) → batteries → grid export (capped).
- **Batteries:** capacity, max charge/discharge rate, ~90% round-trip; losses become heat; degrade with temperature; thermal runaway at extreme.
- **Grid market:** price follows a **duck curve** — cheap midday (solar glut), expensive evening peak. Events: heatwaves, export caps, negative-price hours.
- Internal consumers: pumps, trackers/lens motors, fans, research lab, lens kiln, later electrolyzer.

## 11. Fluids

### 11.1 Pipes (M4)

- ONI-style packets: each pipe segment holds ≤ 1 packet (fluid type, mass, temperature). Pumps inject; packets advance along flow direction each tick.
- Each segment exchanges heat with its host tile (pipe material sets conductance; insulated pipes exist).
- No general pressure sim. **Exception:** liquid that boils inside a pipe → overpressure → burst chance; burst spills liquid into the free-liquid layer and vents steam into the gas layer.
- Coolants: water → glycol → thermal oil → molten salt.

### 11.3 Thermal power (M4) — the Ivanpah path

An alternative to cells: heliostat mirrors on tracking stands focus onto a **receiver/boiler** on a tower; steam drives a **turbine** (power ∝ heat flow × a Carnot-limited efficiency of the hot/cold temperatures); a **condenser/radiator** dumps the rest. Closed loop inside pipes (§11.1): no new simulation system — the boiler takes heat from the heat field, the turbine is an object with a pipe port and a power port (D17). Open loops (venting steam, rain falling back) wait for the free-liquid and gas layers (M6) and stay optional.

### 11.2 Free liquid (M6)

- Terraria-style CA on non-solid tiles: fall, then spread sideways, by `liquid_amount`.
- Contributes heat capacity to its tile; evaporates (to steam field) based on temperature; boils at `boil_temp`.
- Sources: reservoirs, rain, pipe bursts.

## 12. Gas fields (M6)

- `smoke` and `steam` densities on non-solid tiles: advect upward, diffuse, decay (smoke) or condense to liquid when cool (steam).
- Attenuate and scatter light (§6.4). Visual: soft volumetric sprites driven by a texture.
- No conserved gas mass, no sealed-room pressure. Stored gases (e.g. hydrogen) exist only inside tanks/pipes.

## 13. Fire, damage & destruction (M5)

- Tiles and objects have `integrity`. Heat above thresholds reduces it; reaching 0 converts to the material's `burns_to` / `melts_to` / debris.
- **Fire:** a flammable tile above `ignition_temp` gets the burning flag → adds heat, emits smoke, consumes integrity, spreads via heat.
- **Focused beams ignite anything** they concentrate on.
- **No repair** (D12). Debris (char, ash, slag, broken cell) must be mined/deconstructed; deconstruction refunds a fraction of materials. Powders (ash, sand) fall when unsupported.

## 14. Byproduct chains

```
Sunlight ─▶ Cells ─▶ Power ─▶ Batteries / Grid ($ by time of day)
   │          └─▶ Waste heat ─▶ Hot water ─┬─▶ Sell (district heating)
   │                                       ├─▶ Thermoelectric generator (low eff.)
   │                                       ├─▶ Steam turbine (needs >100 °C)
   │                                       └─▶ Solar still → fresh water (desert)
   └─▶ Missed light ─▶ Heats ground/air (or starts fires)
```

Water is a resource: open cooling (towers, evaporating pools) loses water; desert sites force closed loops or desalination.

## 15. Progression (sketch — later)

- **Shop / buy menu:** pages by category (Optics, Stands, Power, Cooling, Materials, Research); only unlocked items show. Start with simple versions (generic lenses, basic stands, Si cells). Each item has a price (D15). Bought items are placed directly (no inventory juggling at first); deconstruction refunds a fraction (D12). Creative mode (later) ignores prices and locks.
- **Two currencies, two sources:** money from selling power (grid market, §10) buys items; **research** comes from feeding power into a research machine (kWh → research points), so "putting power in the machine" unlocks new materials and objects. Money may also buy research at a poor rate, so a stuck player can always progress.
- Research unlocks materials, coatings (AR, texturing, passivation), lens types, cells, coolants, automation.
- Sites as prestige: temperate → desert (high DNI, hot, dust, scarce water) → arctic (cold, low sun) → high altitude (UV) → orbit (AM0 1361 W/m², radiative cooling only).
- Contracts/challenges for sandbox direction.

## 16. Controls & UI

- Camera: pan (WASD / middle-drag), zoom (wheel).
- Time: pause/space, speed keys.
- **Overlays:** normal, light (per-bin false color + intensity), heat, power, liquid, gas, integrity.
- **Inspector:** hover a tile/object → material, T, integrity, absorbed power, liquid/gas, object state.
- Build: hotbar + categorized menu; place, rotate, remove; drag handles for lens mounts.

### 16.1 Creative mode (M2)

- Place any tile/object anywhere, free and instant; erase; area fill.
- Paint temperature / add heat; spawn liquid, smoke, steam (once those layers ship).
- Set time of day, freeze sun, set weather, set site latitude.
- Undo/redo (via command queue, D6).
- Toggle sim layers on/off for debugging.

## 17. Project structure (Godot 4, latest stable)

```
res://
  sim/                 # pure logic, no Nodes (D5)
    sim_world.gd       # owns layers, tick loop, command queue
    constants.gd       # units, scale, tunables (D8)
    tile_grid.gd       # struct-of-arrays tile data (§5.2)
    commands/          # build/remove/edit commands
    light/             # spectrum, surfaces, generators, tracer, accel grid
    thermal/
    objects/           # object runtime models (cell, lens, ...)
    power/  pipes/  liquid/  gas/  damage/   # later milestones
  data/
    materials/*.tres
    objects/*.tres
  render/              # Nodes that read sim state: tiles, beams, overlays, shaders
  ui/                  # HUD, inspector, build menu, creative tools
  scenes/main.tscn
  tests/               # headless sim tests (godot --headless)
docs/design.md
```

Workflow: develop with the Godot MCP server; sim systems get headless tests so physics can be checked numerically (e.g. lens focal length matches the lensmaker's equation, energy is conserved across a trace).

## 18. Roadmap

| Milestone | Scope |
|---|---|
| **M0 — Skeleton** | Godot project, `SimWorld` tick loop, command queue, tile grid with all layers allocated, material resources, debug tile renderer, camera |
| **M1 — Light & heat** ✅ | Sun + day cycle, polyline optics, tracer (refraction, reflection, dispersion, absorption), lens/mirror/prism objects, beam rendering v1 with HDR glow, heat grid with deposition + conduction, heat overlay, inspector. See §18.1 |
| M2 — Environment & creative mode | Sky, sunsets and per-bin atmosphere done (§18.5); creative mode deferred, current free-placement tools stay as dev tools |
| **Moonlight & moon cycle** ✅ | Done (§6.2, §18.6). Moon as a second light source at night: position from a moon cycle (phases over a few game days, rising later each day), irradiance from phase (full moon ≈ sunlight reflected, ~10⁻⁶ of the sun), spectrum = reflected sunlight; traced by the same light passes when it is up; pale-blue display tint; sky glow follows the real moon (§18.5) |
| **M3a — First playable loop** | Object thermal nodes (D13 ✅), surface skin (D18), Si cell, wires (D14), grid sale → money, shop pages with unlocks |
| M3b — Stands & crafter | Stands holding lenses (D16), generic lenses, lens crafter with focus region and manufacturing error; background props layer (D19) for stands and machine bodies |
| M3c — Research | Research machine (power → research), crafter upgrades, more cell types |
| M3 — Cells & power | Cell model, power network, batteries, grid market; **lamps**: the light engine generalizes from one parallel source to a list of sources (parallel sun/moon, point lamps, spread-limited directional lamps that a user-made Fresnel lens collimates), designed once; lamps draw power |
| M4 — Pipes & cooling | Pumps, pipes, radiators, heat exchange, burst rule |
| M5 — Fire & destruction | Integrity, ignition, debris, mining/deconstruction |
| M6 — Liquids & gases | Free liquid CA, smoke/steam fields, phase change, light attenuation |
| M7 — Lens failure | Thermal slices, thermal lensing, sag, cracks, slag |
| M8 — Progression | Research, economy, sites, survival mode |

### 18.1 M1 notes (2026-10-18)

What shipped, and decisions made while building it (none change a LOCKED decision):

- **Sun:** Kasten–Young air mass, Meinel DNI, per-bin Rayleigh-style reddening; diffuse light lands on each column's first non-gas tile (not traced, not focusable).
- **Tracer:** sun rays start just above the highest tile or surface; rays over empty 8×8-tile air blocks skip the block in one step. Outside bodies a ray's medium is the tile it is in, so painted glass/water tiles refract and absorb too. Inside/outside a body is decided by which side of a face is hit, with a bounds check so grazing rays at corners can't stay "inside". Opaque-surface remainder is counted as `scattered` (not yet traced). Every emitted watt is accounted as absorbed, escaped, scattered or culled (tested).
- **Re-traces are tick-sliced:** a pass traces `RAY_PATHS_PER_TICK` ray paths per tick (deterministic), and published deposits are scaled by current DNI between passes. Geometry changes or a sun jump restart a pass. While paused, a render-only preview trace shows edits without touching sim state.
- **Heat:** banded explicit integration, one of `HEAT_BANDS` row bands per tick, each pair exchanged once per cycle (energy conserved, tested). Convective film between surfaces and air, buoyancy-boosted air mixing, air relaxing to ambient, sky radiation from sky-facing tiles. Heat-capacity dial is 0.05 for solids and liquids.
- **Objects:** lens (bi/plano-convex), prism, flat mirror (double-sided for now), irradiance probe. Absorption inside a lens heats the air tiles it sits in until lens thermal slices arrive (M7). The Si cell and heatsink move to M3 with the cell model and power network.
- **Creative extras pulled forward:** object placement/drag/rotate/delete with undo, and ±1 h time skip.

**Performance (GDScript, full 300×120 site, demo rig, noon):** a full re-trace is ~50–60 ms (~3.5k ray paths, ~15 µs per path); a heat band is ~2 ms. Slicing keeps an average tick at ~6–7 ms headless, but the in-editor debug build is roughly 1.5–2× slower and 4× speed drops well below 60 fps. Per §5.5, the tracer and heat loop are the first candidates for a C#/GDExtension port.

### 18.2 Light engine v2 and views (2026-10-18)

- Light pass rebuilt as §6.4.1 (sun map + adaptive beams + pooled reflections). Demo rig: rays per pass 3.5k → ~0.9k; direct light needs none; exact energy balance; beams agree with dense plain rays at a lens focus within 5 % (tested). Caustics (spherical-aberration cusps, off-axis arcs) now render as filled, gradient-lit shapes.
- Re-trace threshold raised to 1° of sun movement (≈2 cm focal shift for a 1.2 m lens); intensity between passes still follows DNI. Average tick ~6 ms headless. (Since the C# port: back to 0.1°, with a 0.25 s crossfade between published passes, so light moves smoothly.)
- Views: Normal (visible light; lit surfaces glow with absorbed light; ×-sun marker at the hottest spot of light), Light (all bins in false color + absorbed-light overlay), UV, Infrared (single-band beams + absorbed-band overlay), Heat (temperature, hidden within the daily swing of the site mean). Legend and peak marker per view; cursor inspector shows material, temperature, sun/shadow/concentration and absorbed light by band, and object readings.
- Still GDScript-bound: a primary path costs ~70–100 µs (PathRec bookkeeping and marching). 1× is comfortable; 4× in the editor's debug build runs ~14 fps. The native port remains the next performance step, now on a port-friendly algorithm (flat arrays, no recursion besides shallow refinement).

### 18.3 Performance pass (2026-10-19)

Goal: cheaper light and heat without changing results. Measured headless, plugged in (`tests/bench.gd`: demo rig and a 30-lens field; each line carries an absorbed-light checksum and energy balance to prove results are unchanged).

| | Before | After |
|---|---|---|
| Full light pass, demo rig 09:00 | 55 ms | 37 ms |
| Full light pass, lens field 09:00 | 2,505 ms | ~340 ms |
| Beam mesh build, lens field 09:00 | 255 ms | ~30 ms |
| Heat per tick | 1.2 ms | 0.77 ms |
| Dragging a lens in the field (1×) | 18.8 ms/tick, light never updated | ~5–6 ms/tick, light updates every ~0.4 s |
| Worst tick, lens field | 34–45 ms | ~10–20 ms |

What changed, in order of impact:

- **Incremental passes.** Each pass owns a snapshot of the geometry and runs to completion. Every beam task (one run of lanes, one bin) logs its contributions and the area its rays touched; a geometry-only pass keeps the shown sun and replays every task the edit can't have affected (beam bounds, plus secondary rays as segments), re-tracing only the rest. An edit during a long sun-triggered pass preempts it with such a pass. Tested equal to a full trace.
- **Object cache.** Within a pass, identical convex objects at the same angle share the in-glass part of every sample ray (object-fixed sample grid); only the outside part is traced per object.
- **Render data off the sim.** Beam tracing writes compact records into one float buffer; the renderer builds triangles only for the bins the current view shows, with slice counts ∝ log of the width ratio. Traced paths are freed per run instead of all at publish (that free was a ~25 ms spike).
- **Leaner tracing.** Flat segment arrays in the intersection loop; 16-segment lens faces (shape error < 0.5 mm, normals interpolated); refinement stops at one lane (2 cm); an air distance field (updated locally after edits; tested equal to a rebuild) replaces 8×8 empty blocks.
- **Heat quiet rows.** Rows at one temperature next to an equal row exchange nothing and are skipped (tested < 0.01 K from full conduction).

Still GDScript-bound: a primary path costs ~40 µs, a full field pass ~0.3 s spread over ticks. The native port (tracer core, heat loop) remains the next large step; the code is now organised around flat arrays and self-contained tasks, which is what a port wants.

### 18.4 C# port (2026-10-19)

The hot loops moved to C# (Godot .NET), per §5.5; GDScript keeps the models and orchestration. The boundary is coarse: GDScript calls in once per pass setup and once per tick (light) or once per band (heat), never per ray or per tile, because every crossing copies arrays.

- `LightEngine.cs`: marching, ray tree, primary paths, beam tracer, object cache, task logs/replay, air distance field — a function-by-function port of the former `tracer.gd`/`beam_tracer.gd`, geometry in doubles.
- `HeatKernel.cs`: energy fold, conduction (quiet rows), radiation, ambient relaxation.
- `BeamMesh.cs`: beam triangles for the renderer.

| | GDScript | C# |
|---|---|---|
| Full light pass, demo rig 09:00 | 37 ms | 4.4 ms |
| Full light pass, 30-lens field 09:00 | 340 ms | 21 ms |
| Heat per tick | 0.77 ms | ~0.2 ms (mostly array copies) |
| Beam mesh, lens field | 29 ms | 8 ms |
| Average tick, demo / field | 1.7 / 4.7 ms | 0.35 / 0.8 ms |
| 4× speed in the editor (debug build) | ~14 fps | 60 fps |

Results match the GDScript implementation (all tests; checksums within ~0.003 %). Remaining GDScript cost sits in per-pass setup (surface sync, sun map, direct-light sheet: ~3–6 ms) and is the next candidate if edits need to get cheaper still.

### 18.5 UI, sky and thermal pass (2026-10-19)

- **Interface:** full-window with canvas_items scaling; tool bar with Select (default: click, drag, ring handle to tilt, drag empty space to pan), Build (item list with shape icons) and Paint (material swatches); views Normal · Light · Heat with a wavelength slider for one bin; legend hover shows the value; speed buttons 1–16×; clock jumps ±30 min, 1 h, 6 h; zoom to 64× with objects, tool overlays and markers drawn in screen units (crisp).
- **Light:** re-trace every 0.1° of sun with a 0.25 s crossfade (smooth motion). Run samples sit on a grid fixed to the run's object and pooled reflections use fixed boundaries, direction splits and a weighted-median representative, so caustics no longer pop between passes (checked tick by tick against a dense plain-ray ground truth with SimProbe `fan`). Fixed: glass absorption depended on tile alignment (inside-body check now uses the stretch to the next surface); object cache verifies the entry point and re-splits cached absorption legs across tiles.
- **Beam rendering fixes:** a split that stays unresolved (one ray clips an edge, its neighbour passes) is drawn as one beam over the events both rays share and up to where the nearer stops, so no bright/dark seams run back along the path; probes only read crossings (no path event), so they no longer split or seem to block beams; strip slices are spaced geometrically in width on both sides of a focus, so focus brightness no longer smears along long legs (a mirror just inside a lens focus looked far brighter than one just past it). Sky drawn in screen space (no black edges while panning); objects pick within 6 screen px of their lines.
- **Atmosphere (§6.2):** per-bin Rayleigh, haze and water/ozone optical depths × Kasten–Young air mass replace the Meinel total and reddening dial.
- **Sky:** no sun/moon disks; a glow from the screen edge the light comes from, colored by the arriving spectrum; zenith colored by short-path scattered light, horizon by the reddened direct light; stars and a pale-blue moon glow at night (placeholder until moonlight is simulated, see roadmap).
- **Heat:** solid/liquid heat capacity scales with the day compression (1/120): realistic daily ground cycle, air warmed by the ground. Heat view colors every tile by absolute temperature. Objects own a thermal node (D13): light absorbed in a body heats the object, which convects into the tiles its outline touches and radiates.
- **World:** background walls below the original ground line, earth beyond the site edges; tile shader (grain, bevels, seams, depth).
- **Agent tooling:** `debug/sim_probe.gd` (`SimProbe` autoload) reads and drives the running game through the MCP's game_eval. Extend it with every new system so behaviour can be checked by numbers rather than screenshots.

### 18.6 Moonlight (2026-10-19)

- **Moon (§6.2):** phase cycle of 8 game days, trailing the sun by its phase (moonrise ≈3.4 h later each day); irradiance = 2.2 × 10⁻⁶ of AM0 × lit fraction³, through the atmosphere at the moon's air mass (≈1.7 mW/m² for a 95 %-lit moon at 46°).
- **One traced light:** `world.light_*` is the sun when up, else the moon; light passes, deposits, the inspector, probe labels and the peak marker use it ("× moon" at night, mW/µW/m² readouts). Engine cull thresholds scale with the traced DNI (`SetCullScale`), so moonlight keeps reflections and secondary rays.
- **Display:** night exposure (full moon ≈ 0.35 of daylight) in a pale-blue tint for beams, the light sheet and the Light view; the sky's moon glow follows the real moon and its phase. HUD shows moon elevation, % lit and irradiance.
- **Tests:** moonrise spacing, the moon as the night light (direction, irradiance, moon set), moonlight through a lens (energy balance, culling, concentration). SimProbe `state` reports the moon and the traced light.

### 18.7 Lighting, consistency pass (2026-10-19)

- **Night and glow:** sun and moon glows are soft, centred past the screen edge, with a cubic falloff (no disk, no rim). Nights are near black (`DisplayLight.NIGHT_AMBIENT`; the HDR buffer is linear, so 0.2 % reads as ~4 % on screen); blocks show only a lit skin on exposed faces (D19). Objects keep a 12 % floor so they can still be edited in the dark.
- **Consolidation:** one home each for plain sunlight (`SimConst.REFERENCE_DNI`), sun-weighted absorptivity (`MaterialDB.sun_absorptivity`), tile watts → W/m² (`LightSystem.irradiance_scale`), arc angles (`world.sun_arc_angle`, `moon_arc_angle`), display light policy (`DisplayLight`) and value text (`Readout`). SimProbe commands are one table (`COMMANDS`) that drives both help and dispatch; SimProbe and the benchmark use public APIs only (`Main.object_db`, `Main.invalidate_preview`, `LightSystem.probe_engine`, `retrace(world, fresh)`, `BeamRenderer.rebuild`).
- **Rules and tooling:** `docs/style.md` (principles, layers, naming, docs); `python tools/check.py` runs gdlint (config `gdlintrc`, 120 columns) plus layering, privacy, one-home, docs and line-ending checks. gdformat is not used (it strips aligned comments).
- **Light per face:** the light engine records the watts arriving on each tile face (`LightEngine.FaceLight`, published as `LightSystem.face_light`, replayed by incremental passes). The tile shader lights each face's skin from its own value, so only faces light really reaches show at night, and the inspector's "≈ N× sun" reads the light arriving instead of estimating it back from absorption.
- **Known cost:** geometric beam slicing (§18.5 fixes) raised the lens-field beam mesh build from ~12 to ~17 ms (debug build, 09:00); candidate for the next performance pass.

### 18.8 Occupancy and probe spectra (2026-10-19)

- **D20:** `Placement.is_clear` tests outlines (closed for bodies, open for mirrors/probes) against other objects and solid tiles; Place/Transform commands refuse overlaps, `TransformObjectCommand.finish` records a whole drag as one undo step to wherever it stopped; the build ghost turns red where it can't go.
- **Probe spectrum:** hovering a probe shows its spectrum (`SpectrumChart`): W/m² per µm across each bin's wavelength range (`Spectrum.BIN_EDGES_UM`, log axis), with the source's plain spectrum outlined at the same total. Moonlight is now redder than sunlight (lunar reflectance). SimProbe `objects` reports each probe's spectrum.
- **Probe readability:** probe readings are tags drawn by `MapMarkers` (dark box, never dimmed at night), and clicking a tag picks the probe; the probe line is thicker with a dark underlay.
- **Tooling:** `tools/check.py` flags tabs inside a line (a joined `\` continuation).

## 19. Open questions

- Art direction: pixel art at 16 px (fits scale) vs. clean vector? Light rendering looks good either way.
- Working title: *Bandgap*, *Heliolab*, *Photon Farm*, *Sunsink*…
- Tuning: ray count/spacing, heat-capacity scale, dn/dT exaggeration.
- Wind and weather depth.
- ~~GDScript vs. C#/GDExtension port~~ — done in C# (§18.4).
- ~~Thermal tuning~~ — solid/liquid heat capacity now scales with the day compression (DAY_LENGTH_S / 86400 ≈ 1/120), so ground warms and cools on a realistic daily cycle (dirt surface ~16 → 49 °C, subsurface lags by hours) and focal spots heat ~6× faster than before.
- Lens absorption heats host air tiles until M7 thermal slices; acceptable stopgap?
