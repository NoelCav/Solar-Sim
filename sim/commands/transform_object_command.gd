class_name TransformObjectCommand
extends SimCommand
## Moves and/or rotates an object (dragging, tilting).
## A drag sends non-undoable steps while moving, then one undoable command on release
## whose `from_*` is where the drag started, so undo returns there in one step.

var object_id: int
var position: Vector2
var angle: float
var undoable := true

var _from_given := false
var _prev_position: Vector2
var _prev_angle: float


func _init(p_object_id: int, p_position: Vector2, p_angle: float, p_undoable := true) -> void:
	object_id = p_object_id
	position = p_position
	angle = p_angle
	undoable = p_undoable


## Sets the state undo returns to (instead of the state just before apply).
func with_origin(from_position: Vector2, from_angle: float) -> TransformObjectCommand:
	_from_given = true
	_prev_position = from_position
	_prev_angle = from_angle
	return self


func apply(world: SimWorld) -> bool:
	var obj: SimObject = world.objects.get(object_id)
	if obj == null:
		return false
	if not _from_given:
		_prev_position = obj.position
		_prev_angle = obj.angle
	if _prev_position == position and _prev_angle == angle:
		return false
	world.set_object_transform(object_id, position, angle)
	return true


func undo(world: SimWorld) -> void:
	world.set_object_transform(object_id, _prev_position, _prev_angle)


func is_undoable() -> bool:
	return undoable
