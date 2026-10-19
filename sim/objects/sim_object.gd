class_name SimObject
extends RefCounted
## A placed object instance: definition + rigid transform (meters, radians) + runtime state.

var id: int
var def: ObjectDef
var position: Vector2
var angle: float

## Written by the light system each trace: power absorbed in the body (W), and for probes
## the power crossing the probe per spectral bin (W).
var absorbed_w := 0.0
var incident := Spectrum.make_zero()

## Own thermal node (D13), kept by ThermalSystem: temperature (0 until first set to the air
## around it) and energy received this tick (light), J.
var temperature_k := 0.0
var heat_in := 0.0


func _init(p_id: int, p_def: ObjectDef, p_position: Vector2, p_angle: float) -> void:
	id = p_id
	def = p_def
	position = p_position
	angle = p_angle


func transform() -> Transform2D:
	return Transform2D(angle, position)


## World-space optical pieces.
func world_pieces() -> Array:
	return OpticsGen.transformed(def.build_pieces(), transform())


## Probe reading per spectral bin, W/m² across its face.
func probe_spectrum() -> PackedFloat32Array:
	var s := incident.duplicate()
	var area := def.size_m * SimConst.DEPTH_M
	for b in Spectrum.BIN_COUNT:
		s[b] /= area
	return s


## Probe irradiance, W/m² across its face.
func probe_irradiance() -> float:
	return Spectrum.total(probe_spectrum())


## Tiles whose area the object's bounding box touches.
func footprint(grid: TileGrid) -> PackedInt32Array:
	var rect := Rect2(position, Vector2.ZERO)
	for piece in world_pieces():
		for p: Vector2 in piece[0]:
			rect = rect.expand(p)
	var inv := 1.0 / SimConst.TILE_M
	var out := PackedInt32Array()
	for y in range(floori(rect.position.y * inv), floori(rect.end.y * inv) + 1):
		for x in range(floori(rect.position.x * inv), floori(rect.end.x * inv) + 1):
			if grid.in_bounds(x, y):
				out.append(grid.idx(x, y))
	return out
