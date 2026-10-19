class_name RemoveObjectCommand
extends SimCommand
## Removes an object (creative mode). Undo restores it with the same id.

var object_id: int

var _removed: SimObject


func _init(p_object_id: int) -> void:
	object_id = p_object_id


func apply(world: SimWorld) -> bool:
	_removed = world.remove_object(object_id)
	return _removed != null


func undo(world: SimWorld) -> void:
	if _removed != null:
		world.add_object(_removed)
