class_name ObjectTool
extends Node2D
## Pointer tools (creative mode). All edits are commands (D6).
## - Select (default, Esc / 0): click an object to select it, drag it to move, drag the ring
##   handle to tilt (Ctrl snaps to 15°); dragging empty space pans the view.
## - Build (B): pick an item in the catalog (ToolPanel) or with 1–9 and click the map to place
##   it, as often as you like; or drag a card onto the map to place one (R / F tilt the ghost
##   first; RMB drops the pick). With nothing picked the mouse works as in Select. Objects go
##   on stands (Mounting) that snap to tile columns and heights; in creative mode Alt floats them.
## The map ignores the pointer while it is over a panel (Hud.covers): no ghost, no hover.
## - Paint (T): the tile brush (CreativeBrush) owns the mouse.
## - Wire (V): the same brush lays wire (LMB) and removes it (RMB).
## In any mode R / F rotate the selected or hovered object (Shift for fine steps), as does
## Shift + wheel, and X / Delete removes it.

enum Mode { SELECT, BUILD, PAINT, WIRE }

const TOOL_ACTIONS := {&"tool_select": Mode.SELECT, &"tool_build": Mode.BUILD, &"tool_paint": Mode.PAINT,
	&"tool_wire": Mode.WIRE}

const PICK_PX := 6.0            ## How close (screen pixels) the pointer must be to a line
const ROTATE_STEP_DEG := 5.0
const FINE_STEP_DEG := 1.0
const SNAP_DEG := 15.0
const HANDLE_PX := 7.0          ## Screen radius of the tilt handle
const RING_MARGIN_M := 0.15     ## Gap between an object and its tilt ring

var world: SimWorld
var hud: Hud                     ## Set by Main after setup: which screen areas are panels
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
	if mode != Mode.BUILD:
		selected = -1
	brush.enabled = uses_brush()
	brush.wire = mode == Mode.WIRE
	_end_gestures()


## Whether the brush owns the mouse (Paint and Wire tools).
func uses_brush() -> bool:
	return mode == Mode.PAINT or mode == Mode.WIRE


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


## The object under the cursor (a probe's reading tag, inside a body, or near a line), or -1.
func hovered_object() -> int:
	if _over_ui():
		return -1
	var m := mouse_m()
	var zoom := _zoom()
	var at := m * SimConst.TILE_PX / SimConst.TILE_M * zoom   # Zoomed canvas units, as tags
	for obj: SimObject in world.objects.values():
		if obj.def.kind == ObjectDef.Kind.PROBE and MapMarkers.probe_tag_rect(world, obj, zoom).has_point(at):
			return obj.id
	var best := -1
	var best_d := PICK_PX / (SimConst.TILE_PX / SimConst.TILE_M * _zoom())
	for obj: SimObject in world.objects.values():
		var pieces := obj.world_pieces()
		if obj.def.is_closed() and Geometry2D.is_point_in_polygon(m, OpticsGen.outline(pieces)):
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
	for action: StringName in TOOL_ACTIONS:
		if event.is_action_pressed(action):
			set_mode(TOOL_ACTIONS[action])
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
	if uses_brush():
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		if mb.pressed:
			_press()
		else:
			_release()
		get_viewport().set_input_as_handled()
	elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
		if selected_def() != null:
			selected = -1   # Drop the picked item first
		elif mode == Mode.BUILD:
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
	elif selected_def() != null:
		place_selected()
	else:
		selected_id = -1
		_panning = true


func _release() -> void:
	if _rotating:
		var obj := selected_object()
		if obj != null:
			world.enqueue(TransformObjectCommand.finish(obj.id, obj.position, _from_angle))
	elif _drag_id >= 0:
		var obj: SimObject = world.objects.get(_drag_id)
		if obj != null:
			world.enqueue(TransformObjectCommand.finish(_drag_id, _drag_from, obj.angle))
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


## Places the picked item at the pointer (on its stand unless Alt floats it in creative mode).
func place_selected() -> void:
	if selected_def() != null:
		world.enqueue(PlaceObjectCommand.new(selected_def(), mouse_m(), ghost_angle, _mounting()))


## Whether the pointer is over a panel (the map underneath ignores it).
func _over_ui() -> bool:
	return hud != null and hud.covers(_pointer)


## Whether the next placed object goes on its stand (always, unless Alt in creative mode).
func _mounting() -> bool:
	return not (world.creative and Input.is_key_pressed(KEY_ALT))


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
	hovered_id = hovered_object() if not uses_brush() else -1
	brush.on_map = not _over_ui()
	renderer.highlighted_id = _drag_id if _drag_id >= 0 else hovered_id
	renderer.selected_id = selected_id
	if (mode == Mode.SELECT or mode == Mode.BUILD) and not _over_ui():
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
	# Screen units (scaled back by 1/zoom), so lines and text stay crisp at any zoom.
	var zoom := _zoom()
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE / zoom)
	var px := SimConst.TILE_PX / SimConst.TILE_M * zoom
	var obj := selected_object()
	if obj != null and not uses_brush():
		# Tilt ring: a faint circle, a line along the object's axis and a handle to drag.
		var c := obj.position * px
		var r := ring_radius(obj) * px
		var h := handle_m(obj) * px
		var hot := _rotating or _over_handle()
		var ring_col := Color(1.0, 0.85, 0.45, 0.35)
		draw_arc(c, r, 0.0, TAU, 96, ring_col, 1.5, true)
		draw_line(c, h, Color(1.0, 0.85, 0.45, 0.5), 1.0, true)
		draw_circle(h, HANDLE_PX * (1.25 if hot else 1.0), Color(1.0, 0.85, 0.45, 0.95), true, -1.0, true)
		draw_circle(h, HANDLE_PX * 0.45, Color(0.1, 0.1, 0.12), true, -1.0, true)
		var label := "%.1f°" % wrapf(rad_to_deg(obj.angle), -180.0, 180.0)
		draw_string_outline(_font, h + Vector2(12, -10), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 4,
			Color(0, 0, 0, 0.7))
		draw_string(_font, h + Vector2(12, -10), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.9, 0.6))
	var def := selected_def()
	if def == null or _drag_id >= 0 or hovered_id >= 0 or _over_ui():
		return
	# Placement ghost where the object will go (snapped to its stand, Mounting), red where the
	# space is occupied (Placement) or there is no ground.
	var at := mouse_m()
	var angle := ghost_angle
	if _mounting():
		at = Mounting.snap_position(world, def, at)
		angle = Mounting.snap_angle(def, angle)
	var clear := at.is_finite() and Placement.is_clear(world, def, at, angle)
	if not at.is_finite():
		at = mouse_m()
	var col := Color(1, 1, 1, 0.5) if clear else Color(1.0, 0.3, 0.25, 0.8)
	if _mounting() and def.mount == ObjectDef.Mount.STAND:
		var base := Mounting.stand_base(world, at)
		if is_finite(base):
			ObjectRenderer.draw_stand(self, at, base, px, Color(col, 0.35))
	for piece in OpticsGen.transformed(def.build_pieces(), Transform2D(angle, at)):
		var pts := PackedVector2Array()
		for p: Vector2 in piece[0]:
			pts.append(p * px)
		draw_polyline(pts, col, 1.5, true)
