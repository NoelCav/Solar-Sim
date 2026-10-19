class_name ObjectTool
extends Node2D
## Creative-mode object placement (full build menu and lens-mount handles are M2).
## 1–9 pick an object to place, 0 returns to the tile brush. With an object picked,
## LMB places it, or drags an existing one; RMB removes. In any mode, R / F rotate the
## hovered object (Shift for fine steps) and X deletes it. All edits are commands (D6).

const PICK_RADIUS_M := 0.2
const ROTATE_STEP_DEG := 5.0
const FINE_STEP_DEG := 1.0

var world: SimWorld
var brush: CreativeBrush
var renderer: ObjectRenderer
var defs: Array[ObjectDef] = []
var selected := -1      ## Index into defs, or -1 for the tile brush
var hovered_id := -1    ## Object under the cursor, refreshed each frame

var _drag_id := -1
var _drag_offset := Vector2.ZERO
var _drag_from := Vector2.ZERO


func setup(p_world: SimWorld, object_db: ObjectDB, p_brush: CreativeBrush, p_renderer: ObjectRenderer) -> void:
	world = p_world
	brush = p_brush
	renderer = p_renderer
	defs = object_db.defs
	z_index = 11


func selected_def() -> ObjectDef:
	return defs[selected] if selected >= 0 and selected < defs.size() else null


func mouse_m() -> Vector2:
	return get_global_mouse_position() / (SimConst.TILE_PX / SimConst.TILE_M)


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


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var key := (event as InputEventKey).physical_keycode
		if key >= KEY_0 and key <= KEY_9:
			var n := key - KEY_0
			selected = n - 1 if n >= 1 and n <= defs.size() else -1
			brush.enabled = selected < 0
			get_viewport().set_input_as_handled()
			return
	if event.is_action_pressed(&"obj_rotate_ccw") or event.is_action_pressed(&"obj_rotate_cw"):
		var id := hovered_object()
		if id >= 0:
			var step := FINE_STEP_DEG if Input.is_key_pressed(KEY_SHIFT) else ROTATE_STEP_DEG
			var direction := -1.0 if event.is_action_pressed(&"obj_rotate_ccw") else 1.0
			var obj: SimObject = world.objects[id]
			world.enqueue(TransformObjectCommand.new(id, obj.position, obj.angle + direction * deg_to_rad(step)))
		return
	if event.is_action_pressed(&"obj_delete"):
		var id := hovered_object()
		if id >= 0:
			world.enqueue(RemoveObjectCommand.new(id))
		return
	if selected < 0:
		return
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				var id := hovered_object()
				if id >= 0:
					var obj: SimObject = world.objects[id]
					_drag_id = id
					_drag_from = obj.position
					_drag_offset = obj.position - mouse_m()
				else:
					world.enqueue(PlaceObjectCommand.new(selected_def(), mouse_m(), 0.0))
			elif _drag_id >= 0:
				var obj: SimObject = world.objects.get(_drag_id)
				if obj != null:
					world.enqueue(TransformObjectCommand.new(_drag_id, mouse_m() + _drag_offset, obj.angle)
						.with_origin(_drag_from, obj.angle))
				_drag_id = -1
			get_viewport().set_input_as_handled()
		elif mb.button_index == MOUSE_BUTTON_RIGHT and mb.pressed:
			var id := hovered_object()
			if id >= 0:
				world.enqueue(RemoveObjectCommand.new(id))
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _drag_id >= 0:
		var obj: SimObject = world.objects.get(_drag_id)
		if obj != null:
			world.enqueue(TransformObjectCommand.new(_drag_id, mouse_m() + _drag_offset, obj.angle, false))


func _process(_delta: float) -> void:
	if world == null:
		return
	hovered_id = hovered_object()
	renderer.highlighted_id = _drag_id if _drag_id >= 0 else hovered_id
	queue_redraw()


func _draw() -> void:
	var def := selected_def()
	if def == null or _drag_id >= 0 or renderer.highlighted_id >= 0:
		return
	# Placement ghost.
	var px := SimConst.TILE_PX / SimConst.TILE_M
	var xf := Transform2D(0.0, mouse_m())
	for piece in OpticsGen.transformed(def.build_pieces(), xf):
		var pts := PackedVector2Array()
		for p: Vector2 in piece[0]:
			pts.append(p * px)
		draw_polyline(pts, Color(1, 1, 1, 0.5), 1.0, true)
