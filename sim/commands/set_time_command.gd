class_name SetTimeCommand
extends SimCommand
## Jumps the clock (creative mode). The environment updates on the next tick.

var time_s: float


func _init(p_time_s: float) -> void:
	time_s = p_time_s


func apply(world: SimWorld) -> bool:
	world.time_s = maxf(time_s, 0.0)
	return true


func is_undoable() -> bool:
	return false
