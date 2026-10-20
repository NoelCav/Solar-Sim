class_name CreativeBrush
extends Node2D
## Tile painting (the Paint tool; ObjectTool switches it on). LMB paints the selected
## material, RMB erases to air, Q/E cycle material, [ and ] change brush size. With `wire`
## (the Wire tool) it draws wire as a line instead (D14), like a road: press, drag, release lays
## the whole run (straight, or with one bend: horizontal first when it is wider than tall, Shift
## flips it), RMB the same removes it; a press on a device starts at its foot. One undo each.
## Ctrl+Z undoes in any tool. All edits go through commands (D6).

var world: SimWorld
var selected_index := 0
var brush_radius := 0
var enabled := false     ## True while the Paint or Wire tool is active
var wire := false        ## Paints the wire layer instead of materials
var pointer := Vector2(-1e6, -1e6)   ## Last pointer position, viewport pixels (set by ObjectTool)
var on_map := true                   ## False while the pointer is over a panel (set by ObjectTool)

var palette: Array[MaterialDef] = []
var _painting_button := MOUSE_BUTTON_NONE
var _last_cell := Vector2i(-1, -1)
var _stroke := 0                    ## Undo group of the stroke in progress
var _line_from := Vector2i(-1, -1)   ## Where the wire line being drawn started


func setup(p_world: SimWorld) -> void:
	world = p_world
	palette.assign(world.materials.placeable().filter(
		func(d: MaterialDef) -> bool: return d.id != MaterialDB.AIR_ID))
	selected_index = maxi(0, palette.find(world.materials.get_by_key(&"stone")))
	z_index = 10


func selected() -> MaterialDef:
	return palette[selected_index] if not palette.is_empty() else null


func hovered_cell() -> Vector2i:
	var p := get_viewport().get_canvas_transform().affine_inverse() * pointer / SimConst.TILE_PX
	return Vector2i(floori(p.x), floori(p.y))


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"undo"):
		world.enqueue(UndoCommand.new())
	elif not enabled:
		return
	elif not wire and event.is_action_pressed(&"brush_next"):
		selected_index = (selected_index + 1) % palette.size()
	elif not wire and event.is_action_pressed(&"brush_prev"):
		selected_index = (selected_index - 1 + palette.size()) % palette.size()
	elif event.is_action_pressed(&"brush_bigger"):
		brush_radius = mini(brush_radius + 1, 8)
	elif event.is_action_pressed(&"brush_smaller"):
		brush_radius = maxi(brush_radius - 1, 0)
	elif event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
			get_viewport().set_input_as_handled()
			if mb.pressed:
				_painting_button = mb.button_index
				_last_cell = Vector2i(-1, -1)
				_stroke = SimCommand.new_group()
				if wire:
					_line_from = _snapped(hovered_cell())
				else:
					_paint_at(hovered_cell())
			elif mb.button_index == _painting_button:
				if wire:
					_lay_line(mb.button_index == MOUSE_BUTTON_RIGHT)
				_painting_button = MOUSE_BUTTON_NONE
	elif event is InputEventMouseMotion and _painting_button != MOUSE_BUTTON_NONE and not wire:
		_paint_at(hovered_cell())


func _process(_delta: float) -> void:
	queue_redraw()


## The tiles a wire line from `a` to `b` covers: straight when they share a row or column, else
## with one bend, horizontal first (or vertical first with `vertical_first`).
static func line_path(a: Vector2i, b: Vector2i, vertical_first := false) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	var corner := Vector2i(a.x, b.y) if vertical_first else Vector2i(b.x, a.y)
	for leg: Array in [[a, corner], [corner, b]]:
		var from: Vector2i = leg[0]
		var to: Vector2i = leg[1]
		var step := Vector2i(signi(to.x - from.x), signi(to.y - from.y))
		var at := from
		while true:
			if out.is_empty() or out.back() != at:
				out.append(at)
			if at == to:
				break
			at += step
	return out


## The line being drawn now: from where the press started to the pointer (a device's foot when the
## pointer is on a device), bending the way the shape suggests unless Shift flips it.
func current_line() -> Array[Vector2i]:
	var to := _snapped(hovered_cell())
	var wide := absi(to.x - _line_from.x) >= absi(to.y - _line_from.y)
	return line_path(_line_from, to, wide == Input.is_key_pressed(KEY_SHIFT))


func _lay_line(erase: bool) -> void:
	var g := world.grid
	var cells := PackedInt32Array()
	for c in current_line():
		if g.in_bounds(c.x, c.y):
			cells.append(g.idx(c.x, c.y))
	if cells.is_empty():
		return
	var cmd := PaintWiresCommand.new(cells, 0 if erase else 1)
	cmd.group = _stroke
	world.enqueue(cmd)


## A cell the pointer is on, or, when the pointer is on a device, the tile the device connects at.
func _snapped(cell: Vector2i) -> Vector2i:
	var at := get_viewport().get_canvas_transform().affine_inverse() * pointer / SimConst.PX_PER_M
	for obj: SimObject in world.objects.values():
		if obj.def.kind not in [ObjectDef.Kind.CELL, ObjectDef.Kind.BATTERY, ObjectDef.Kind.GRID_TIE, ObjectDef.Kind.LAMP]:
			continue
		var box := Rect2()
		var first := true
		for p: Vector2 in OpticsGen.outline(obj.world_pieces()):
			box = Rect2(p, Vector2.ZERO) if first else box.expand(p)
			first = false
		if box.grow(0.08).has_point(at):
			var ports := Mounting.port_tiles(world, obj)
			if not ports.is_empty():
				return Vector2i(ports[0] % world.grid.width, ports[0] / world.grid.width)
	return cell


func _paint_at(cell: Vector2i) -> void:
	if cell == _last_cell:
		return
	_last_cell = cell
	var erase := _painting_button == MOUSE_BUTTON_RIGHT
	var g := world.grid
	var cells := PackedInt32Array()
	for dy in range(-brush_radius, brush_radius + 1):
		for dx in range(-brush_radius, brush_radius + 1):
			if dx * dx + dy * dy > brush_radius * brush_radius + brush_radius:
				continue
			var c := cell + Vector2i(dx, dy)
			if g.in_bounds(c.x, c.y):
				cells.append(g.idx(c.x, c.y))
	if cells.is_empty():
		return
	var cmd: SimCommand
	if wire:
		cmd = PaintWiresCommand.new(cells, 0 if erase else 1)
	else:
		cmd = PaintTilesCommand.new(cells, MaterialDB.AIR_ID if erase else selected().id)
	cmd.group = _stroke
	world.enqueue(cmd)


func _draw() -> void:
	if world == null or not enabled or not on_map:
		return
	if wire:
		_draw_line_preview()
		return
	var cell := hovered_cell()
	var r := brush_radius
	var rect := Rect2(Vector2(cell - Vector2i(r, r)) * SimConst.TILE_PX, Vector2.ONE * (2 * r + 1) * SimConst.TILE_PX)
	draw_rect(rect, Color(1, 1, 1, 0.6), false, 1.0)


## The wire line being drawn (or, before the press, the tile it would start on).
func _draw_line_preview() -> void:
	var erase := _painting_button == MOUSE_BUTTON_RIGHT
	var color := Color(1.0, 0.45, 0.35, 0.6) if erase else Color(0.95, 0.7, 0.35, 0.6)
	var tiles: Array[Vector2i] = [_snapped(hovered_cell())]
	if _painting_button != MOUSE_BUTTON_NONE:
		tiles = current_line()
	for c in tiles:
		draw_rect(Rect2(Vector2(c) * SimConst.TILE_PX, Vector2.ONE * SimConst.TILE_PX), color, true)
