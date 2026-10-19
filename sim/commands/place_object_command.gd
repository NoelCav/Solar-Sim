class_name PlaceObjectCommand
extends SimCommand
## Places a new object instance (creative mode: free and instant).

var def: ObjectDef
var position: Vector2
var angle: float

var placed_id := -1


func _init(p_def: ObjectDef, p_position: Vector2, p_angle: float = 0.0) -> void:
	def = p_def
	position = p_position
	angle = p_angle


func apply(world: SimWorld) -> bool:
	if def == null:
		return false
	placed_id = world.next_object_id
	world.add_object(SimObject.new(placed_id, def, position, angle))
	return true


func undo(world: SimWorld) -> void:
	world.remove_object(placed_id)
