class_name LightSource
extends RefCounted
## A source of light for one light pass (design doc §6.11). Parallel: the sun or the moon, the
## light's direction and its irradiance per bin (W/m² across the light). Point: a lamp, its
## position, the angles it emits into and its intensity per bin (W per radian in the slice; a lamp
## is a line source along the slice depth, so its light falls as 1/r).

enum Kind { PARALLEL, POINT }

var kind := Kind.PARALLEL
var spectrum := Spectrum.make_zero()   ## Per bin: W/m² (parallel) or W/rad (point)
var direction := Vector2.ZERO          ## Parallel: the way the light travels
var dni := 0.0                         ## Parallel: total irradiance across the light, W/m²
var position := Vector2.ZERO           ## Point: where it is, m
var angle_min := -PI                   ## Point: emits into [angle_min, angle_max], radians
var angle_max := PI


static func parallel(p_direction: Vector2, p_spectrum: PackedFloat32Array, p_dni: float) -> LightSource:
	var s := LightSource.new()
	s.direction = p_direction
	s.spectrum = p_spectrum.duplicate()
	s.dni = p_dni
	return s


## A lamp at `p_position` with `p_spectrum` W/rad per bin into [from, to] (radians; a full circle
## by default).
static func point(p_position: Vector2, p_spectrum: PackedFloat32Array, from := -PI, to := PI) -> LightSource:
	var s := LightSource.new()
	s.kind = Kind.POINT
	s.position = p_position
	s.spectrum = p_spectrum.duplicate()
	s.angle_min = from
	s.angle_max = to
	return s


## Cull thresholds scale with how much a sample ray carries compared with full sunlight's (the
## engine culls rays below fixed watts), so dim light keeps the same relative detail.
func cull_scale() -> float:
	if kind == Kind.PARALLEL:
		return minf(dni / SimConst.REFERENCE_DNI, 1.0)
	var sample_w := Spectrum.total(spectrum) * SimConst.BEAM_SPACING_M / SimConst.LAMP_RANGE_M
	return minf(sample_w / (SimConst.REFERENCE_DNI * SimConst.BEAM_SPACING_M * SimConst.DEPTH_M), 1.0)


## How much light it gives: a parallel source's irradiance across the light, W/m² (DNI); a lamp's
## total intensity, W/rad.
func strength() -> float:
	return dni if kind == Kind.PARALLEL else Spectrum.total(spectrum)


## Whether another source sends its rays the same way (only its strength may differ).
func same_light(other: LightSource) -> bool:
	return other != null and other.kind == kind and direction.is_equal_approx(other.direction) \
		and position.is_equal_approx(other.position) and is_equal_approx(angle_min, other.angle_min) \
		and is_equal_approx(angle_max, other.angle_max)


## Whether another source would trace the same light (an incremental pass may then reuse this one).
func same_as(other: LightSource) -> bool:
	if not same_light(other):
		return false
	for b in Spectrum.BIN_COUNT:
		if absf(spectrum[b] - other.spectrum[b]) > 1e-6 * maxf(spectrum[b], 1.0):
			return false
	return true
