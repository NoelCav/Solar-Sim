class_name ToolIcon
extends Control
## A small line drawing for a toolbar button: the tools (select, build, paint, wire, undo, menu) and
## the catalog's sections (optics, power, machines, tools).

var glyph: StringName
var color := Color(0.85, 0.88, 0.92)


func _init(p_glyph: StringName, box := Vector2(22, 22)) -> void:
	glyph = p_glyph
	custom_minimum_size = box
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var s := size / 22.0
	var w := 1.6
	match glyph:
		&"select":
			var pts := PackedVector2Array([Vector2(5, 3), Vector2(17, 11), Vector2(11, 12), Vector2(8, 19), Vector2(5, 3)])
			draw_polyline(_scaled(pts, s), color, w, true)
		&"build":   # A crate with a plus: what you buy and place
			draw_rect(Rect2(Vector2(3, 8) * s, Vector2(16, 11) * s), color, false, w)
			draw_line(Vector2(3, 8) * s, Vector2(7, 3.5) * s, color, w, true)
			draw_line(Vector2(19, 8) * s, Vector2(15, 3.5) * s, color, w, true)
			draw_line(Vector2(7, 3.5) * s, Vector2(15, 3.5) * s, color, w, true)
			draw_line(Vector2(11, 11) * s, Vector2(11, 16) * s, UiStyle.ACCENT, w + 0.4, true)
			draw_line(Vector2(8.5, 13.5) * s, Vector2(13.5, 13.5) * s, UiStyle.ACCENT, w + 0.4, true)
		&"paint":
			for r: Rect2 in [Rect2(3, 3, 7, 7), Rect2(12, 3, 7, 7), Rect2(12, 12, 7, 7)]:
				draw_rect(Rect2(r.position * s, r.size * s), color, false, w)
		&"wire":
			var copper := Color(0.85, 0.54, 0.27)
			draw_polyline(_scaled(PackedVector2Array([Vector2(3, 16), Vector2(9, 16), Vector2(9, 6), Vector2(19, 6)]), s),
				copper, w + 0.6, true)
			draw_circle(Vector2(3, 16) * s, 2.0 * s.x, copper)
			draw_circle(Vector2(19, 6) * s, 2.0 * s.x, copper)
		&"undo":
			draw_polyline(_scaled(PackedVector2Array([Vector2(8, 4), Vector2(3, 9), Vector2(8, 14)]), s), color, w, true)
			draw_arc(Vector2(12, 14) * s, 5.0 * s.x, -PI * 0.5, PI * 0.5, 12, color, w, true)
			draw_line(Vector2(3, 9) * s, Vector2(12, 9) * s, color, w, true)
		&"view_normal":   # An eye
			draw_arc(Vector2(11, 20) * s, 12.0 * s.x, -2.3, -0.84, 14, color, w, true)
			draw_arc(Vector2(11, 2) * s, 12.0 * s.x, 0.84, 2.3, 14, color, w, true)
			draw_circle(Vector2(11, 11) * s, 3.2 * s.x, color)
		&"view_light":   # A sun
			draw_arc(Vector2(11, 11) * s, 4.0 * s.x, 0.0, TAU, 16, Color(1.0, 0.85, 0.45), w, true)
			for k in 8:
				var d := Vector2.from_angle(k * TAU / 8.0)
				draw_line((Vector2(11, 11) + d * 6.5) * s, (Vector2(11, 11) + d * 9.5) * s, Color(1.0, 0.85, 0.45), w, true)
		&"view_heat":   # A thermometer
			draw_line(Vector2(11, 3) * s, Vector2(11, 14) * s, UiStyle.WARM, w + 2.0, true)
			draw_circle(Vector2(11, 16) * s, 3.6 * s.x, UiStyle.WARM)
			draw_arc(Vector2(11, 6) * s, 2.5 * s.x, PI, TAU, 8, color, w, true)
		&"menu":
			for y in [6.0, 11.0, 16.0]:
				draw_line(Vector2(4, y) * s, Vector2(18, y) * s, color, w + 0.4, true)
		&"optics":   # A lens
			draw_arc(Vector2(5, 11) * s, 10.0 * s.x, -0.9, 0.9, 12, color, w, true)
			draw_arc(Vector2(17, 11) * s, 10.0 * s.x, PI - 0.9, PI + 0.9, 12, color, w, true)
		&"power":   # A bolt
			draw_polyline(_scaled(PackedVector2Array([Vector2(12, 2), Vector2(5, 12), Vector2(11, 12), Vector2(9, 20),
				Vector2(17, 9), Vector2(11, 9), Vector2(12, 2)]), s), UiStyle.POWER, w, true)
		&"machines":   # A gear
			draw_arc(Vector2(11, 11) * s, 5.0 * s.x, 0.0, TAU, 24, color, w, true)
			for k in 8:
				var d := Vector2.from_angle(k * TAU / 8.0)
				draw_line((Vector2(11, 11) + d * 6.5) * s, (Vector2(11, 11) + d * 9.0) * s, color, w + 0.8, true)
		&"tools":   # A wrench
			draw_line(Vector2(5, 18) * s, Vector2(13, 10) * s, color, w + 0.8, true)
			draw_arc(Vector2(15, 8) * s, 4.0 * s.x, 0.7, TAU - 0.7, 14, color, w, true)
		&"help":
			draw_arc(Vector2(11, 11) * s, 8.5 * s.x, 0.0, TAU, 32, color, w, true)
			draw_arc(Vector2(11, 8.5) * s, 3.0 * s.x, PI, TAU + PI * 0.4, 12, color, w, true)
			draw_line(Vector2(11, 12) * s, Vector2(11, 13.5) * s, color, w, true)
			draw_circle(Vector2(11, 16.5) * s, 1.1 * s.x, color)


static func _scaled(pts: PackedVector2Array, s: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		out.append(p * s)
	return out
