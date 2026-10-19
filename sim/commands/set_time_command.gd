class_name SetTimeCommand
extends SimCommand
## Jumps the clock (creative mode); sun and ambient update at once, so it works while paused.

var time_s: float


func _init(p_time_s: float) -> void:
	time_s = p_time_s


func apply(world: SimWorld) -> bool:
	world.time_s = maxf(time_s, 0.0)
	world.refresh_environment()
	return true


func is_undoable() -> bool:
	return false
