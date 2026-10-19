class_name PlaceObjectCommand
extends SimCommand
## Places a new object instance. A mounted object snaps to its stand or the ground (Mounting);
## an unmounted one floats where it is put, which only creative mode allows (probes always
## float). Refused when the space is occupied (Placement) or there is no ground to stand on.

var def: ObjectDef
var position: Vector2
var angle: float
var mounted: bool

var placed_id := -1


func _init(p_def: ObjectDef, p_position: Vector2, p_angle: float = 0.0, p_mounted := false) -> void:
	def = p_def
	position = p_position
	angle = p_angle
	mounted = p_mounted


func apply(world: SimWorld) -> bool:
	if def == null:
		return false
	if mounted:
		position = Mounting.snap_position(world, def, position)
		angle = Mounting.snap_angle(def, angle)
	elif not world.creative and def.mount != ObjectDef.Mount.FREE:
		return false
	if not position.is_finite() or not Placement.is_clear(world, def, position, angle):
		return false
	placed_id = world.next_object_id
	var obj := SimObject.new(placed_id, def, position, angle)
	obj.mounted = mounted and def.mount != ObjectDef.Mount.FREE
	world.add_object(obj)
	return true


func undo(world: SimWorld) -> void:
	world.remove_object(placed_id)
