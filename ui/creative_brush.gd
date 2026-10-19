class_name CreativeBrush
extends Node2D
## Minimal creative-mode painting (full creative tools are M2).
## LMB paints the selected material, RMB erases to air, Q/E cycle material,
## [ and ] change brush size, Ctrl+Z undoes. All edits go through commands (D6).

var world: SimWorld
var selected_index := 0
var brush_radius := 0
var enabled := true      ## False while the object tool owns the mouse

var _palette: Array[MaterialDef] = []
var _painting_button := MOUSE_BUTTON_NONE
var _last_cell := Vector2i(-1, -1)


func setup(p_world: SimWorld) -> void:
	world = p_world
	_palette.assign(world.materials.placeable().filter(
		func(d: MaterialDef) -> bool: return d.id != MaterialDB.AIR_ID))
	selected_index = maxi(0, _palette.find(world.materials.get_by_key(&"stone")))
	z_index = 10


func selected() -> MaterialDef:
	return _palette[selected_index] if not _palette.is_empty() else null


func hovered_cell() -> Vector2i:
	var p := get_global_mouse_position() / SimConst.TILE_PX
	return Vector2i(floori(p.x), floori(p.y))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"brush_next"):
		selected_index = (selected_index + 1) % _palette.size()
	elif event.is_action_pressed(&"brush_prev"):
		selected_index = (selected_index - 1 + _palette.size()) % _palette.size()
	elif event.is_action_pressed(&"brush_bigger"):
		brush_radius = mini(brush_radius + 1, 8)
	elif event.is_action_pressed(&"brush_smaller"):
		brush_radius = maxi(brush_radius - 1, 0)
	elif event.is_action_pressed(&"undo"):
		world.enqueue(UndoCommand.new())
	elif event is InputEventMouseButton and enabled:
		var mb := event as InputEventMouseButton
		if mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			if mb.pressed:
				_painting_button = mb.button_index
				_last_cell = Vector2i(-1, -1)
				_paint_at(hovered_cell())
			elif mb.button_index == _painting_button:
				_painting_button = MOUSE_BUTTON_NONE
	elif event is InputEventMouseMotion and _painting_button != MOUSE_BUTTON_NONE:
		_paint_at(hovered_cell())


func _process(_delta: float) -> void:
	queue_redraw()


func _paint_at(cell: Vector2i) -> void:
	if cell == _last_cell:
		return
	_last_cell = cell
	var mat_id := MaterialDB.AIR_ID if _painting_button == MOUSE_BUTTON_RIGHT else selected().id
	var g := world.grid
	var cells := PackedInt32Array()
	for dy in range(-brush_radius, brush_radius + 1):
		for dx in range(-brush_radius, brush_radius + 1):
			if dx * dx + dy * dy > brush_radius * brush_radius + brush_radius:
				continue
			var c := cell + Vector2i(dx, dy)
			if g.in_bounds(c.x, c.y):
				cells.append(g.idx(c.x, c.y))
	if not cells.is_empty():
		world.enqueue(PaintTilesCommand.new(cells, mat_id))


func _draw() -> void:
	if world == null or not enabled:
		return
	var cell := hovered_cell()
	var r := brush_radius
	var rect := Rect2(Vector2(cell - Vector2i(r, r)) * SimConst.TILE_PX, Vector2.ONE * (2 * r + 1) * SimConst.TILE_PX)
	draw_rect(rect, Color(1, 1, 1, 0.6), false, 1.0)
