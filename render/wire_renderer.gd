class_name WireRenderer
extends Node2D
## Draws the wire layer (D14) over the tiles: a copper line between the centers of neighbouring
## wire tiles, a dot where a wire ends alone. Wires run behind the play plane (D19), so they
## show through ground. Redrawn only when the layer changes.

const COLOR := Color(0.85, 0.5, 0.25, 0.85)
const WIDTH_TILES := 0.12

var world: SimWorld
var _version := -1


func setup(p_world: SimWorld) -> void:
	world = p_world
	z_index = 2


func _process(_delta: float) -> void:
	if world != null and world.grid.conduit_version != _version:
		_version = world.grid.conduit_version
		queue_redraw()


func _draw() -> void:
	var g := world.grid
	var px := float(SimConst.TILE_PX)
	var width := WIDTH_TILES * px
	for i in g.size():
		if g.wire[i] == 0:
			continue
		var x := i % g.width
		var y := i / g.width
		var c := (Vector2(x, y) + Vector2(0.5, 0.5)) * px
		var right := x < g.width - 1 and g.wire[i + 1] != 0
		var down := y < g.height - 1 and g.wire[i + g.width] != 0
		if right:
			draw_line(c, c + Vector2(px, 0.0), COLOR, width)
		if down:
			draw_line(c, c + Vector2(0.0, px), COLOR, width)
		draw_circle(c, width * 0.75, COLOR)
