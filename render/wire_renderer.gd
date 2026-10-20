class_name WireRenderer
extends Node2D
## Draws the wire layer (D14) over the tiles: a copper line between the centers of neighbouring
## wire tiles, a dot where a wire ends alone. Wires run behind the play plane (D19), so they
## show through ground. The foot of a surface cell conducts too (drawn dimmer, so a row of cells
## reads as one run), and every device has a lug from its foot to the tile it connects at: bright
## copper when it is on a network, grey when nothing is connected. Redrawn only when something
## it shows changes.

const CHANNEL_COLORS: Array[Color] = [Color(0.85, 0.5, 0.25), Color(0.35, 0.62, 1.0), Color(0.4, 0.85, 0.45),
	Color(0.76, 0.5, 1.0)]
const CHANNEL_NAMES := ["Copper", "Blue", "Green", "Violet"]
const ALPHA := 0.85
const CELL_ALPHA := 0.7              ## A surface cell's foot, drawn dimmer than laid wire
const LOOSE := Color(0.55, 0.55, 0.6, 0.9)
const WIDTH_TILES := 0.12

var world: SimWorld
var _power: PowerSystem
var _version := -1


func setup(p_world: SimWorld) -> void:
	world = p_world
	_power = world.get_system(&"power")
	z_index = 2


func _process(_delta: float) -> void:
	if world == null:
		return
	_power.sync(world)
	if _power.networks.version != _version:
		_version = _power.networks.version
		queue_redraw()


func _draw() -> void:
	_power.sync(world)
	var g := world.grid
	var px := float(SimConst.TILE_PX)
	var width := WIDTH_TILES * px
	var conducts := _power.conducts
	for i in g.size():
		if conducts[i] == 0:
			continue
		var x := i % g.width
		var y := i / g.width
		var c := (Vector2(x, y) + Vector2(0.5, 0.5)) * px
		for channel in ConduitNetworks.CHANNELS:
			var bit := 1 << channel
			if conducts[i] & bit == 0:
				continue
			var color := Color(CHANNEL_COLORS[channel], ALPHA if g.wire[i] & bit != 0 else CELL_ALPHA)
			var at := c + Vector2.ONE * channel * width * 0.5   # Crossing wires sit side by side
			if x < g.width - 1 and conducts[i + 1] & bit != 0:
				draw_line(at, at + Vector2(px, 0.0), color, width)
			if y < g.height - 1 and conducts[i + g.width] & bit != 0:
				draw_line(at, at + Vector2(0.0, px), color, width)
			draw_circle(at, width * 0.75, color)
	for obj: SimObject in world.objects.values():
		if obj.def.kind in [ObjectDef.Kind.CELL, ObjectDef.Kind.BATTERY, ObjectDef.Kind.GRID_TIE, ObjectDef.Kind.LAMP]:
			_draw_lug(obj, px, width)


## A short lead from the foot of `obj` (where its stand meets the ground) up to the tile it
## connects at.
func _draw_lug(obj: SimObject, px: float, width: float) -> void:
	var ports := Mounting.port_tiles(world, obj)
	if ports.is_empty():
		return
	var tile := ports[0]
	var top := (Vector2(tile % world.grid.width, tile / world.grid.width) + Vector2(0.5, 0.5)) * px
	var foot := Vector2(obj.position.x * SimConst.PX_PER_M, (Mounting.stand_base(world, obj.position)) * SimConst.PX_PER_M)
	var channel := 0
	for k in ConduitNetworks.CHANNELS:
		if _power.networks.at(tile, k) >= 0:
			channel = k
			break
	var color := Color(CHANNEL_COLORS[channel], ALPHA) if _power.network_of(world, obj) >= 0 else LOOSE
	draw_line(foot, top, color, width)
	draw_circle(foot, width * 1.1, color)
