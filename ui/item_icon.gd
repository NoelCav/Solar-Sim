class_name ItemIcon
extends Control
## A small picture of an object definition or a material swatch, for the catalog: lenses, prisms and
## mirrors show their optical outline; panels, batteries, lamps, the grid connection and probes are drawn
## as what they are.

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
	if _draw_device():
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
	if def.is_closed():
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


## Draws the glyph of a device kind; false for the optical kinds (drawn from their outline).
func _draw_device() -> bool:
	var u := minf(size.x, size.y) / 24.0   # One unit = 1/24 of the box
	var c := size * 0.5
	var line := Color(0.88, 0.93, 1.0, 0.95)
	match def.kind:
		ObjectDef.Kind.CELL:
			var top := PackedVector2Array([c + Vector2(-9, 3) * u, c + Vector2(-5, -5) * u, c + Vector2(9, -5) * u,
				c + Vector2(5, 3) * u])
			draw_colored_polygon(top, Color(0.12, 0.2, 0.45))
			for k in 1 if def.mount == ObjectDef.Mount.GROUND else 3:
				var t := (k + 1.0) / 4.0
				draw_line(top[0].lerp(top[1], t), top[3].lerp(top[2], t), line.darkened(0.3), 1.0, true)
			draw_polyline(top + PackedVector2Array([top[0]]), line, 1.2, true)
			if def.mount != ObjectDef.Mount.GROUND:
				draw_line(c + Vector2(0, 3) * u, c + Vector2(0, 11) * u, line.darkened(0.4), 1.6, true)
		ObjectDef.Kind.PROBE:
			draw_dashed_line(c + Vector2(-9, 0) * u, c + Vector2(9, 0) * u, def.color, 2.0, 4.0)
			draw_arc(c + Vector2(0, -3) * u, 4.0 * u, PI, TAU, 10, line, 1.2, true)
		ObjectDef.Kind.BATTERY:
			var body := Rect2(c + Vector2(-8, -6) * u, Vector2(16, 12) * u)
			draw_rect(body, Color(0.2, 0.3, 0.38))
			draw_rect(body, line, false, 1.2)
			draw_rect(Rect2(c + Vector2(8, -2.5) * u, Vector2(2.5, 5) * u), line)
			for k in 3:
				draw_rect(Rect2(c + Vector2(-6.5 + k * 4.2, -4) * u, Vector2(3, 8) * u),
					Color(0.45, 0.95, 0.6) if k < 2 else Color(0.25, 0.35, 0.3))
		ObjectDef.Kind.GRID_TIE:
			var pts := PackedVector2Array([c + Vector2(0, -10) * u, c + Vector2(-6, 10) * u, c + Vector2(6, 10) * u,
				c + Vector2(0, -10) * u])
			draw_polyline(pts, line, 1.4, true)
			for y in [-4.0, 2.0]:
				draw_line(c + Vector2(-5 + (y + 10) * 0.12, y) * u, c + Vector2(5 - (y + 10) * 0.12, y) * u, line, 1.2, true)
			draw_line(c + Vector2(-9, -6) * u, c + Vector2(9, -6) * u, line, 1.4, true)
			draw_circle(c + Vector2(-9, -6) * u, 1.3 * u, UiStyle.POWER)
			draw_circle(c + Vector2(9, -6) * u, 1.3 * u, UiStyle.POWER)
		ObjectDef.Kind.LAMP:
			draw_circle(c + Vector2(0, -2) * u, 5.0 * u, Color(1.0, 0.88, 0.5))
			draw_rect(Rect2(c + Vector2(-2.5, 3) * u, Vector2(5, 4) * u), line.darkened(0.2))
			for k in 5:
				var d := Vector2.from_angle(PI * (1.15 + 0.175 * k))
				var hub := c + Vector2(0, -2) * u
				draw_line(hub + d * 7.5 * u, hub + d * 10.0 * u, Color(1.0, 0.88, 0.5, 0.8), 1.2, true)
		_:
			return false
	return true
