class_name CameraController
extends Camera2D
## God-view camera: WASD/arrow pan, middle-mouse drag, wheel zoom toward cursor.

@export var pan_speed := 900.0
@export var zoom_step := 1.15
@export var min_zoom := 0.25
@export var max_zoom := 6.0

var _dragging := false


func _process(delta: float) -> void:
	var dir := Vector2(
		Input.get_axis(&"cam_left", &"cam_right"),
		Input.get_axis(&"cam_up", &"cam_down"))
	if dir != Vector2.ZERO:
		position += dir.normalized() * pan_speed * delta / zoom.x


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = mb.pressed
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(zoom_step)
		elif mb.pressed and mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(1.0 / zoom_step)
	elif event is InputEventMouseMotion and _dragging:
		position -= (event as InputEventMouseMotion).relative / zoom.x


func _zoom_at(factor: float) -> void:
	# Keep the world point under the cursor fixed. Computed by hand because the
	# camera's canvas transform doesn't update until the next frame.
	var offset := get_viewport().get_mouse_position() - get_viewport_rect().size * 0.5
	var before := position + offset / zoom.x
	var z := clampf(zoom.x * factor, min_zoom, max_zoom)
	zoom = Vector2(z, z)
	position = before - offset / z
