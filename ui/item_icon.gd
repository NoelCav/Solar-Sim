class_name ItemIcon
extends Control
## A small picture of an object definition (its optical outline, fitted to the box) or a
## material swatch, for the toolbar's item lists.

var def: ObjectDef
var swatch := Color.TRANSPARENT


func _init(p_def: ObjectDef = null, p_swatch := Color.TRANSPARENT, box := Vector2(36, 24)) -> void:
	def = p_def
	swatch = p_swatch
	custom_minimum_size = box
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	if def == null:
		var r := Rect2(Vector2(2, 2), size - Vector2(4, 4))
		draw_rect(r, Color(0.08, 0.08, 0.1))
		draw_rect(r.grow(-1.0), swatch)
		return
	var pieces := def.build_pieces()
	var lo := Vector2(INF, INF)
	var hi := -lo
	for piece in pieces:
		for p: Vector2 in piece[0]:
			lo = lo.min(p)
			hi = hi.max(p)
	var span := (hi - lo).max(Vector2(1e-3, 1e-3))
	var s := minf((size.x - 6.0) / span.x, (size.y - 6.0) / span.y)
	var off := size * 0.5 - (lo + hi) * 0.5 * s
	var line := Color(0.9, 0.97, 1.0, 0.95)
	if def.is_body():
		var pts := PackedVector2Array()
		for p in OpticsGen.outline(pieces):
			pts.append(p * s + off)
		if pts.size() >= 3:
			draw_colored_polygon(pts, Color(def.color, maxf(def.color.a, 0.5)))
			pts.append(pts[0])
			draw_polyline(pts, line, 1.0, true)
		return
	for piece in pieces:
		var pts := PackedVector2Array()
		for p: Vector2 in piece[0]:
			pts.append(p * s + off)
		var col := def.color if def.kind != ObjectDef.Kind.MIRROR else line
		draw_polyline(pts, Color(col, 1.0), 2.0, true)
