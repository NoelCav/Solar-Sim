class_name ObjectTool
extends Node2D
## Pointer tools (creative mode). All edits are commands (D6).
## - Select (default, Esc / 0): click an object to select it, drag it to move, drag the ring
##   handle to tilt (Ctrl snaps to 15°); dragging empty space pans the view.
## - Build (B, 1–9): pick an item from the list, LMB places it (R / F tilt the ghost first);
##   existing objects can still be dragged. RMB goes back to Select.
## - Paint (T): the tile brush (CreativeBrush) owns the mouse.
## In any mode R / F rotate the selected or hovered object (Shift for fine steps), as does
## Shift + wheel, and X / Delete removes it.

enum Mode { SELECT, BUILD, PAINT }

const PICK_RADIUS_M := 0.2
const ROTATE_STEP_DEG := 5.0
const FINE_STEP_DEG := 1.0
const SNAP_DEG := 15.0
const HANDLE_PX := 7.0          ## Screen radius of the tilt handle
const RING_MARGIN_M := 0.15     ## Gap between an object and its tilt ring

var world: SimWorld
var brush: CreativeBrush
var renderer: ObjectRenderer
var defs: Array[ObjectDef] = []
var mode := Mode.SELECT
var selected := -1      ## Index into defs for Build
var selected_id := -1   ## Selected object, or -1
var hovered_id := -1    ## Object under the cursor, refreshed each frame
var ghost_angle := 0.0  ## Rotation of the Build ghost and the next placed object

var _drag_id := -1
var _drag_offset := Vector2.ZERO
var _drag_from := Vector2.ZERO
var _rotating := false
var _rotate_grab := 0.0          ## Object angle minus pointer angle when the handle was grabbed
var _from_angle := 0.0
var _panning := false
var _pointer := Vector2(-1e6, -1e6)   ## Last pointer position, viewport pixels
var _font: Font


func setup(p_world: SimWorld, object_db: ObjectDB, p_brush: CreativeBrush, p_renderer: ObjectRenderer) -> void:
	world = p_world
	brush = p_brush
	renderer = p_renderer
	defs = object_db.defs
	z_index = 11
	_font = ThemeDB.fallback_font
	set_mode(Mode.SELECT)


func set_mode(m: Mode) -> void:
	mode = m
	if mode == Mode.BUILD and (selected < 0 or selected >= defs.size()):
		selected = 0
	brush.enabled = mode == Mode.PAINT
	_end_gestures()


## Switches to Build with item `index` picked.
func pick_item(index: int) -> void:
	selected = index
	set_mode(Mode.BUILD)


func selected_def() -> ObjectDef:
	return defs[selected] if mode == Mode.BUILD and selected >= 0 and selected < defs.size() else null


func selected_object() -> SimObject:
	return world.objects.get(selected_id) if world != null else null


## Pointer position in meters, from the last mouse event (so it follows the camera too).
func mouse_m() -> Vector2:
	var world_px := get_viewport().get_canvas_transform().affine_inverse() * _pointer
	return world_px / (SimConst.TILE_PX / SimConst.TILE_M)


func _input(event: InputEvent) -> void:
	if event is InputEventMouse:
		_pointer = (event as InputEventMouse).position
		brush.pointer = _pointer


## Rotates the selected (else hovered) object by `deg`.
func rotate_by(deg: float) -> void:
	var obj: SimObject = world.objects.get(_target_id())
	if obj != null:
		world.enqueue(TransformObjectCommand.new(obj.id, obj.position, obj.angle + deg_to_rad(deg)))


## Removes the selected (else hovered) object.
func delete_target() -> void:
	var id := _target_id()
	if id >= 0:
		world.enqueue(RemoveObjectCommand.new(id))
		if id == selected_id:
			selected_id = -1


func _target_id() -> int:
	return selected_id if world.objects.has(selected_id) else hovered_id


## The object under the cursor (inside a body, or near a line), or -1.
func hovered_object() -> int:
	var m := mouse_m()
	var best := -1
	var best_d := PICK_RADIUS_M
	for obj: SimObject in world.objects.values():
		var pieces := obj.world_pieces()
		if obj.def.is_body() and Geometry2D.is_point_in_polygon(m, OpticsGen.outline(pieces)):
			return obj.id
		for piece in pieces:
			var pts: PackedVector2Array = piece[0]
			for k in pts.size() - 1:
				var d := m.distance_to(Geometry2D.get_closest_point_to_segment(m, pts[k], pts[k + 1]))
				if d < best_d:
					best_d = d
					best = obj.id
	return best


## Radius of the tilt ring around an object (meters).
static func ring_radius(obj: SimObject) -> float:
	var r := 0.0
	for piece in obj.world_pieces():
		for p: Vector2 in piece[0]:
			r = maxf(r, p.distance_to(obj.position))
	return r + RING_MARGIN_M


## Tilt handle position (meters): on the ring, along the object's own x axis.
static func handle_m(obj: SimObject) -> Vector2:
	return obj.position + Vector2.from_angle(obj.angle) * ring_radius(obj)


func _over_handle() -> bool:
	var obj := selected_object()
	if obj == null:
		return false
	var px := SimConst.TILE_PX / SimConst.TILE_M
	var screen_px := mouse_m().distance_to(handle_m(obj)) * px * _zoom()
	return screen_px <= HANDLE_PX * 1.8


func _zoom() -> float:
	return get_viewport().get_canvas_transform().get_scale().x


func _end_gestures() -> void:
	_drag_id = -1
	_rotating = false
	_panning = false


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).physical_keycode
		if key >= KEY_0 and key <= KEY_9:
			var n := key - KEY_0
			if n >= 1 and n <= defs.size():
				pick_item(n - 1)
			else:
				set_mode(Mode.SELECT)
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed(&"tool_select"):
		set_mode(Mode.SELECT)
		return
	if event.is_action_pressed(&"tool_build"):
		set_mode(Mode.BUILD)
		return
	if event.is_action_pressed(&"tool_paint"):
		set_mode(Mode.PAINT)
		return
	if event.is_action_pressed(&"obj_rotate_ccw") or event.is_action_pressed(&"obj_rotate_cw"):
		var step := FINE_STEP_DEG if Input.is_key_pressed(KEY_SHIFT) else ROTATE_STEP_DEG
		var direction := -1.0 if event.is_action_pressed(&"obj_rotate_ccw") else 1.0
		if mode == Mode.BUILD and not world.objects.has(selected_id) and hovered_id < 0:
			ghost_angle += direction * deg_to_rad(step)
		else:
			rotate_by(direction * step)
		return
	if event.is_action_pressed(&"obj_delete"):
		delete_target()
		return
	if event is InputEventMouseButton:
		_mouse_button(event as InputEventMouseButton)
	elif event is InputEventMouseMotion:
		_mouse_motion(event as InputEventMouseMotion)


func _mouse_button(mb: InputEventMouseButton) -> void:
	# Shift + wheel tilts what is under the cursor (the camera zooms otherwise).
	if mb.pressed and mb.shift_pressed and mb.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var direction := -1.0 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0
		if mode == Mode.BUILD and hovered_id < 0:
			ghost_angle += direction * deg_to_rad(FINE_STEP_DEG)
		else:
			rotate_by(direction * FINE_STEP_DEG)
		get_viewport().set_input_as_handled()
		return
	if mode == Mode.PAINT:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_press()
		else:
			_release()
		get_viewport().set_input_as_handled()
	elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		if mode == Mode.BUILD:
			set_mode(Mode.SELECT)
		else:
			selected_id = -1
		get_viewport().set_input_as_handled()


func _press() -> void:
	var obj := selected_object()
	if obj != null and _over_handle():
		_rotating = true
		_from_angle = obj.angle
		_rotate_grab = obj.angle - (mouse_m() - obj.position).angle()
		return
	var id := hovered_object()
	if id >= 0:
		obj = world.objects[id]
		selected_id = id
		_drag_id = id
		_drag_from = obj.position
		_drag_offset = obj.position - mouse_m()
	elif mode == Mode.BUILD:
		world.enqueue(PlaceObjectCommand.new(selected_def(), mouse_m(), ghost_angle))
	else:
		selected_id = -1
		_panning = true


func _release() -> void:
	if _rotating:
		var obj := selected_object()
		if obj != null:
			world.enqueue(TransformObjectCommand.new(obj.id, obj.position, _pointer_angle(obj))
				.with_origin(obj.position, _from_angle))
	elif _drag_id >= 0:
		var obj: SimObject = world.objects.get(_drag_id)
		if obj != null:
			world.enqueue(TransformObjectCommand.new(_drag_id, mouse_m() + _drag_offset, obj.angle)
				.with_origin(_drag_from, obj.angle))
	_end_gestures()


func _mouse_motion(mm: InputEventMouseMotion) -> void:
	if _panning:
		var cam := get_viewport().get_camera_2d()
		if cam != null:
			cam.position -= mm.relative / cam.zoom.x
	elif _rotating:
		var obj := selected_object()
		if obj != null:
			world.enqueue(TransformObjectCommand.new(obj.id, obj.position, _pointer_angle(obj), false))
	elif _drag_id >= 0:
		var obj: SimObject = world.objects.get(_drag_id)
		if obj != null:
			world.enqueue(TransformObjectCommand.new(_drag_id, mouse_m() + _drag_offset, obj.angle, false))


## Object angle that keeps the grabbed handle under the pointer (Ctrl snaps, else 0.5° steps).
func _pointer_angle(obj: SimObject) -> float:
	var deg := rad_to_deg((mouse_m() - obj.position).angle() + _rotate_grab)
	var step := SNAP_DEG if Input.is_key_pressed(KEY_CTRL) else 0.5
	return deg_to_rad(snappedf(deg, step))


func _process(_delta: float) -> void:
	if world == null:
		return
	if selected_id >= 0 and not world.objects.has(selected_id):
		selected_id = -1
	hovered_id = hovered_object() if mode != Mode.PAINT else -1
	renderer.highlighted_id = _drag_id if _drag_id >= 0 else hovered_id
	renderer.selected_id = selected_id
	if mode == Mode.SELECT or mode == Mode.BUILD:
		var shape := Input.CURSOR_ARROW
		if _panning:
			shape = Input.CURSOR_DRAG
		elif _rotating or _over_handle():
			shape = Input.CURSOR_CROSS
		elif _drag_id >= 0 or hovered_id >= 0:
			shape = Input.CURSOR_MOVE
		Input.set_default_cursor_shape(shape)
	else:
		Input.set_default_cursor_shape(Input.CURSOR_ARROW)
	queue_redraw()


func _draw() -> void:
	if world == null:
		return
	var px := SimConst.TILE_PX / SimConst.TILE_M
	var w := 1.0 / _zoom()   # One screen pixel in canvas units
	var obj := selected_object()
	if obj != null and mode != Mode.PAINT:
		# Tilt ring: a faint circle, a line along the object's axis and a handle to drag.
		var c := obj.position * px
		var r := ring_radius(obj) * px
		var h := handle_m(obj) * px
		var hot := _rotating or _over_handle()
		var ring_col := Color(1.0, 0.85, 0.45, 0.35)
		draw_arc(c, r, 0.0, TAU, 64, ring_col, 1.5 * w, true)
		draw_line(c, h, Color(1.0, 0.85, 0.45, 0.5), 1.0 * w, true)
		draw_circle(h, HANDLE_PX * w * (1.25 if hot else 1.0), Color(1.0, 0.85, 0.45, 0.95))
		draw_circle(h, HANDLE_PX * w * 0.45, Color(0.1, 0.1, 0.12))
		var label := "%.1f°" % wrapf(rad_to_deg(obj.angle), -180.0, 180.0)
		draw_set_transform(h, 0.0, Vector2(w, w))   # Label at a fixed screen size
		draw_string_outline(_font, Vector2(12, -10), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 4,
			Color(0, 0, 0, 0.7))
		draw_string(_font, Vector2(12, -10), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.9, 0.6))
		draw_set_transform(Vector2.ZERO)
	var def := selected_def()
	if def == null or _drag_id >= 0 or hovered_id >= 0:
		return
	# Placement ghost.
	var xf := Transform2D(ghost_angle, mouse_m())
	for piece in OpticsGen.transformed(def.build_pieces(), xf):
		var pts := PackedVector2Array()
		for p: Vector2 in piece[0]:
			pts.append(p * px)
		draw_polyline(pts, Color(1, 1, 1, 0.5), 1.5 * w, true)
