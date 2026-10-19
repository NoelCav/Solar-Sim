class_name PaintWiresCommand
extends SimCommand
## Lays or removes wire on a set of tiles (D14: wires are a tile layer). Wire runs behind the
## play plane like stands (D19): it goes through air, liquid and ground alike.

var cells: PackedInt32Array
var value: int                  ## 1 lays wire, 0 removes it

var _changed := PackedInt32Array()
var _prev := PackedByteArray()


func _init(p_cells: PackedInt32Array, p_value: int = 1) -> void:
	cells = p_cells
	value = p_value


func apply(world: SimWorld) -> bool:
	var g := world.grid
	_changed.clear()
	_prev.clear()
	for i in cells:
		if i >= 0 and i < g.size() and g.wire[i] != value:
			_changed.append(i)
			_prev.append(g.wire[i])
			g.wire[i] = value
	if _changed.is_empty():
		return false
	g.conduit_version += 1
	return true


func undo(world: SimWorld) -> void:
	var g := world.grid
	for k in _changed.size():
		g.wire[_changed[k]] = _prev[k]
	g.conduit_version += 1
