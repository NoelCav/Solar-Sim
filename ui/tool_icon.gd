class_name ToolIcon
extends Control
## A small line drawing for a tool rail button (select, build, paint, wire, undo, help).

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
		&"build":
			draw_line(Vector2(4, 18) * s, Vector2(18, 18) * s, color, w, true)
			draw_line(Vector2(11, 3) * s, Vector2(11, 14) * s, color, w, true)
			draw_polyline(_scaled(PackedVector2Array([Vector2(6, 9), Vector2(11, 14), Vector2(16, 9)]), s), color, w, true)
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
