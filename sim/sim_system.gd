class_name SimSystem
extends RefCounted
## One layer of the simulation, stepped in a fixed order by SimWorld (design doc §5.3).

func system_name() -> StringName:
	return &"system"


func tick(_world: SimWorld, _dt: float) -> void:
	pass
