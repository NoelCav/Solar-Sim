class_name PaintTilesCommand
extends SimCommand
## Sets a set of tiles to one material (creative-mode brush, area fill, erase).
## New tiles start at `temperature_k`, or at ambient if it is NAN.

var cells: PackedInt32Array
var material_id: int
var temperature_k: float

var _prev_material := PackedInt32Array()
var _prev_temperature := PackedFloat32Array()
var _prev_integrity := PackedFloat32Array()
var _changed := PackedInt32Array()


func _init(p_cells: PackedInt32Array, p_material_id: int, p_temperature_k: float = NAN) -> void:
	cells = p_cells
	material_id = p_material_id
	temperature_k = p_temperature_k


func apply(world: SimWorld) -> bool:
	var g := world.grid
	var t := world.ambient_k if is_nan(temperature_k) else temperature_k
	_changed.clear()
	_prev_material.clear()
	_prev_temperature.clear()
	_prev_integrity.clear()
	for i in cells:
		if i < 0 or i >= g.size() or g.material[i] == material_id:
			continue
		_changed.append(i)
		_prev_material.append(g.material[i])
		_prev_temperature.append(g.temperature[i])
		_prev_integrity.append(g.integrity[i])
		g.material[i] = material_id
		g.temperature[i] = t
		g.integrity[i] = 1.0
	if _changed.is_empty():
		return false
	g.mark_structure_changed()
	return true


func undo(world: SimWorld) -> void:
	var g := world.grid
	for k in _changed.size():
		var i := _changed[k]
		g.material[i] = _prev_material[k]
		g.temperature[i] = _prev_temperature[k]
		g.integrity[i] = _prev_integrity[k]
	g.mark_structure_changed()
