class_name PaintWiresCommand
extends SimCommand
## Lays or removes wire of one channel (a color) on a set of tiles (D14: wires are a tile layer).
## Wire runs behind the play plane like stands (D19): it goes through air, liquid and ground alike.
## Wires of different channels share a tile without touching (they cross).

var cells: PackedInt32Array
var value: int                  ## 1 lays wire, 0 removes it
var channel: int                ## Which color (0 to ConduitNetworks.CHANNELS - 1)

var _changed := PackedInt32Array()
var _prev := PackedByteArray()


func _init(p_cells: PackedInt32Array, p_value: int = 1, p_channel := 0) -> void:
	cells = p_cells
	value = p_value
	channel = p_channel


func apply(world: SimWorld) -> bool:
	var g := world.grid
	var bit := 1 << channel
	_changed.clear()
	_prev.clear()
	for i in cells:
		if i < 0 or i >= g.size():
			continue
		var now: int = (g.wire[i] | bit) if value != 0 else (g.wire[i] & ~bit)
		if now != g.wire[i]:
			_changed.append(i)
			_prev.append(g.wire[i])
			g.wire[i] = now
	if _changed.is_empty():
		return false
	g.conduit_version += 1
	return true


func undo(world: SimWorld) -> void:
	var g := world.grid
	for k in _changed.size():
		g.wire[_changed[k]] = _prev[k]
	g.conduit_version += 1
