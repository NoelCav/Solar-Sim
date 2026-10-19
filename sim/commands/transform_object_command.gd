class_name TransformObjectCommand
extends SimCommand
## Moves and/or rotates an object (dragging, tilting). A mounted object snaps to its stand or
## the ground (Mounting). A move into occupied space (another object, a solid tile; see
## Placement) is refused and the object stays where it was.
## A drag sends non-undoable steps while moving, then `finish`: one undoable command that
## records the move from where the drag started to wherever the object ended up.

var object_id: int
var position: Vector2
var angle: float
var undoable := true

var _finish := false            ## Record the move to the object's current transform
var _prev_position: Vector2
var _prev_angle: float


func _init(p_object_id: int, p_position: Vector2, p_angle: float, p_undoable := true) -> void:
	object_id = p_object_id
	position = p_position
	angle = p_angle
	undoable = p_undoable


## Ends a drag that started at `from_position`, `from_angle`: one undo step back there.
static func finish(p_object_id: int, from_position: Vector2, from_angle: float) -> TransformObjectCommand:
	var cmd := TransformObjectCommand.new(p_object_id, from_position, from_angle)
	cmd._finish = true
	cmd._prev_position = from_position
	cmd._prev_angle = from_angle
	return cmd


func apply(world: SimWorld) -> bool:
	var obj: SimObject = world.objects.get(object_id)
	if obj == null:
		return false
	if _finish:
		position = obj.position
		angle = obj.angle
		return _prev_position != position or _prev_angle != angle
	_prev_position = obj.position
	_prev_angle = obj.angle
	if obj.mounted:
		position = Mounting.snap_position(world, obj.def, position)
		angle = Mounting.snap_angle(obj.def, angle)
	if _prev_position == position and _prev_angle == angle:
		return false
	if not position.is_finite() or not Placement.is_clear(world, obj.def, position, angle, object_id):
		return false
	world.set_object_transform(object_id, position, angle)
	return true


func undo(world: SimWorld) -> void:
	world.set_object_transform(object_id, _prev_position, _prev_angle)


func is_undoable() -> bool:
	return undoable
