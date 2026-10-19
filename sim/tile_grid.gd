class_name TileGrid
extends RefCounted
## Struct-of-arrays tile data (design doc §5.2). Every layer is allocated up front,
## even for systems that ship in later milestones (D9).
## Index: i = y * width + x, with y increasing downward.

enum Flag {
	BURNING = 1 << 0,
	WET = 1 << 1,
	SUPPORTED = 1 << 2,
	LIGHT_DIRTY = 1 << 3,
	BACKGROUND_WALL = 1 << 4,
}

var width: int
var height: int

var material := PackedInt32Array()          ## Material id (0 = air)
var temperature := PackedFloat32Array()     ## Kelvin
var integrity := PackedFloat32Array()       ## 0..1 structural health
var flags := PackedInt32Array()             ## Flag bitfield
var object_id := PackedInt32Array()         ## Occupying object, -1 if none
var liquid_amount := PackedFloat32Array()   ## 0..1 fill of non-solid tiles
var liquid_type := PackedInt32Array()       ## Material id of the liquid, -1 if none
var smoke := PackedFloat32Array()           ## Density 0..1
var steam := PackedFloat32Array()           ## Density 0..1
var energy_in := PackedFloat32Array()       ## Joules deposited this tick, consumed by heat step

## Bumped on any structural change so renderers know to rebuild.
var structure_version: int = 0


func _init(w: int, h: int, ambient_k: float = SimConst.DEFAULT_AMBIENT_K) -> void:
	width = w
	height = h
	var n := w * h
	material.resize(n)
	material.fill(MaterialDB.AIR_ID)
	temperature.resize(n)
	temperature.fill(ambient_k)
	integrity.resize(n)
	integrity.fill(1.0)
	flags.resize(n)
	flags.fill(0)
	object_id.resize(n)
	object_id.fill(-1)
	liquid_amount.resize(n)
	liquid_amount.fill(0.0)
	liquid_type.resize(n)
	liquid_type.fill(-1)
	smoke.resize(n)
	smoke.fill(0.0)
	steam.resize(n)
	steam.fill(0.0)
	energy_in.resize(n)
	energy_in.fill(0.0)


func size() -> int:
	return width * height


func idx(x: int, y: int) -> int:
	return y * width + x


func in_bounds(x: int, y: int) -> bool:
	return x >= 0 and y >= 0 and x < width and y < height


func coords(i: int) -> Vector2i:
	return Vector2i(i % width, i / width)


func get_material(x: int, y: int) -> int:
	return material[idx(x, y)]


## Low-level setter; callers outside the sim should go through commands (D6).
func set_material(i: int, mat_id: int) -> void:
	material[i] = mat_id
	integrity[i] = 1.0
	structure_version += 1


func mark_structure_changed() -> void:
	structure_version += 1


## Content hash over all persistent layers, used by determinism tests and desync checks.
func state_hash() -> int:
	return hash([material, temperature, integrity, flags, object_id,
		liquid_amount, liquid_type, smoke, steam])
