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
