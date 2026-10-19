class_name SimConst
extends RefCounted
## Units, scale and tunables for the simulation (design doc D8, §4).
## The sim works in SI units; only rendering/UI convert.

# --- World scale ---
const TILE_PX := 16                 ## Pixels per tile (rendering only)
const TILE_M := 0.25                ## Meters per tile edge
const DEPTH_M := 0.25               ## Depth of the 2D slice
const TILE_VOLUME_M3 := TILE_M * TILE_M * DEPTH_M

# --- Time ---
const TICK_RATE := 20               ## Sim ticks per second at 1x (D7)
const DT := 1.0 / TICK_RATE         ## Seconds per tick
const DAY_LENGTH_S := 720.0         ## One full day at 1x (12 real minutes)
const START_TIME_OF_DAY := 0.30     ## 0 = midnight, 0.5 = noon
const MAX_TICKS_PER_FRAME := 8      ## Catch-up cap so a slow frame can't spiral

# --- Physics ---
const KELVIN_OFFSET := 273.15
const STEFAN_BOLTZMANN := 5.670374419e-8
const DEFAULT_AMBIENT_K := 293.15   ## 20 °C
const AMBIENT_SWING_K := 6.0        ## Day/night ambient amplitude


static func k_to_c(kelvin: float) -> float:
	return kelvin - KELVIN_OFFSET


static func c_to_k(celsius: float) -> float:
	return celsius + KELVIN_OFFSET

# --- Sun (§6.2) ---
const SOLAR_CONSTANT := 1361.0      ## W/m² above the atmosphere (AM0)
const DIFFUSE_W_M2 := 110.0         ## Diffuse sky irradiance with the sun high (non-focusable)

# --- Moon (§6.2) ---
const MOON_CYCLE_DAYS := 8.0        ## Game days from full moon to full moon (rises ~3 h later each day)
const MOON_START_PHASE := 0.45      ## Phase at world start (0 new, 0.5 full): a bright first night
const MOON_FULL_RATIO := 2.2e-6     ## Full-moon irradiance / sunlight, both above the atmosphere
const MOON_DISPLAY := 0.35          ## Night exposure: a full moon draws at this fraction of daylight

# --- Light (§6.4) ---
const LANE_WIDTH_M := 0.02          ## Sun-map lane width across the sun direction
const MIN_CHILD_W := 0.02           ## Reflected child rays below this power are culled
const MIN_RAY_W := 1e-4           ## Any ray below this is culled
const CULL_REFERENCE_DNI := 1000.0  ## Cull thresholds hold at this DNI and scale down with dimmer light
const REFL_POOL_M := 0.25          ## Pooled Fresnel reflections: one secondary ray per this much wavefront (at most)
const MAX_RAY_EVENTS := 24          ## Surface interactions along one ray path, children included
const RETRACE_ANGLE_DEG := 0.1      ## Re-trace when the sun has moved this far (≈0.27 s at 1×), so light moves smoothly
const RESTART_ANGLE_DEG := 3.0      ## Abandon a pass in progress if the sun jumps this far

# --- Heat (§7) ---
const HEAT_BANDS := 6               ## Heat updates one of N row bands per tick, with dt × N
## Gameplay heat-capacity dial per phase (formulas stay real, things heat on game timescales).
const HEAT_CAPACITY_SCALE_SOLID := DAY_LENGTH_S / 86400.0
const HEAT_CAPACITY_SCALE_LIQUID := DAY_LENGTH_S / 86400.0
const HEAT_CAPACITY_SCALE_GAS := 1.0
const CONVECTION_H := 10.0          ## W/(m²·K), solid/liquid surface ↔ air
const AIR_EDDY_K := 1.0             ## W/(m·K), effective air↔air conductivity (mixing)
const BUOYANCY_BOOST := 4.0         ## Extra air↔air transfer when the lower tile is hotter
const AIR_RELAX_PER_S := 0.05       ## Rate open air relaxes toward ambient
const SKY_DEPRESSION_K := 20.0      ## Clear-sky temperature below ambient
const RAY_PATHS_PER_TICK := 1000    ## Ray paths (children included) traced per tick (~3 ms in C#); a re-trace may span ticks
