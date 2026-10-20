class_name SetTimeCommand
extends SimCommand
## Jumps the clock (creative mode); sun and ambient update at once, so it works while paused.

var time_s: float


func _init(p_time_s: float) -> void:
	time_s = p_time_s


## A jump to `hours` (0–24, more for the next days) after the start of the current day.
static func at_hour(world: SimWorld, hours: float) -> SetTimeCommand:
	var day_start := floorf(world.time_s / SimConst.DAY_LENGTH_S) * SimConst.DAY_LENGTH_S
	return SetTimeCommand.new(day_start + hours / 24.0 * SimConst.DAY_LENGTH_S)


func apply(world: SimWorld) -> bool:
	world.time_s = maxf(time_s, 0.0)
	world.refresh_environment()
	return true


func is_undoable() -> bool:
	return false
