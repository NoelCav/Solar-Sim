class_name MeterView
extends Control
## An enlarged copy of a device's power meter (PowerMeters), shown in the inspector so a meter
## too small to read on the map can be read in detail.

const SIZE := Vector2(240.0, 190.0)

var world: SimWorld
var obj: SimObject


func _init() -> void:
	custom_minimum_size = SIZE
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## Shows the meter of `p_obj` (null hides the view).
func show_meter(p_world: SimWorld, p_obj: SimObject) -> void:
	world = p_world
	obj = p_obj
	visible = obj != null and not PowerMeters.reading(world, obj).is_empty()
	queue_redraw()


func _draw() -> void:
	if visible and world != null and obj != null:
		PowerMeters.draw_enlarged(self, world, obj, SIZE)
