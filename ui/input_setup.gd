class_name InputSetup
extends RefCounted
## Registers default input actions at startup (only those not already defined,
## so bindings set in Project Settings win).

const KEYS := {
	&"cam_left": [KEY_A, KEY_LEFT],
	&"cam_right": [KEY_D, KEY_RIGHT],
	&"cam_up": [KEY_W, KEY_UP],
	&"cam_down": [KEY_S, KEY_DOWN],
	&"sim_pause": [KEY_SPACE],
	&"sim_speed": [KEY_TAB],
	&"brush_next": [KEY_E],
	&"brush_prev": [KEY_Q],
	&"brush_bigger": [KEY_BRACKETRIGHT],
	&"brush_smaller": [KEY_BRACKETLEFT],
	&"obj_rotate_ccw": [KEY_R],
	&"obj_rotate_cw": [KEY_F],
	&"obj_delete": [KEY_X, KEY_DELETE],
	&"overlay_cycle": [KEY_H],
	&"time_back": [KEY_COMMA],
	&"time_forward": [KEY_PERIOD],
	&"toggle_help": [KEY_F1],
}


static func ensure_defaults() -> void:
	for action: StringName in KEYS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for keycode: Key in KEYS[action]:
			var ev := InputEventKey.new()
			ev.physical_keycode = keycode
			InputMap.action_add_event(action, ev)
	if not InputMap.has_action(&"undo"):
		InputMap.add_action(&"undo")
		var ev := InputEventKey.new()
		ev.physical_keycode = KEY_Z
		ev.ctrl_pressed = true
		InputMap.action_add_event(&"undo", ev)
