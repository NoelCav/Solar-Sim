class_name ObjectRenderer
extends Node2D
## Draws placed objects from their optical polylines: lens and prism bodies as tinted
## glass, mirrors as a bright face over a dark back, probes as a dashed line with readout.
## In the heat view, lenses, prisms and mirrors are filled with their own temperature color.

var world: SimWorld
var highlighted_id := -1
var selected_id := -1
var view := ViewMode.NORMAL
var overlay: OverlayRenderer   ## For the heat scale

var _font: Font


func setup(p_world: SimWorld) -> void:
	world = p_world
	z_index = 4
	_font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if world == null:
		return
	# Draw in screen units (scaled back by 1/zoom), so outlines, their anti-aliased edges and
	# text stay one screen pixel sharp at any zoom instead of being magnified.
	var zoom := get_viewport().get_canvas_transform().get_scale().x
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE / zoom)
	var px := SimConst.TILE_PX / SimConst.TILE_M * zoom
	var heat := view == ViewMode.HEAT and overlay != null
	for obj: SimObject in world.objects.values():
		var def := obj.def
		var pieces := obj.world_pieces()
		var hl := obj.id == highlighted_id or obj.id == selected_id
		match def.kind:
			ObjectDef.Kind.LENS, ObjectDef.Kind.PRISM:
				var outline := OpticsGen.outline(pieces)
				var pts := PackedVector2Array()
				for p in outline:
					pts.append(p * px)
				if pts.size() >= 3:
					draw_colored_polygon(pts, _heat_color(obj) if heat else def.color)
					pts.append(pts[0])
					var edge := Color(0.9, 0.97, 1.0, 0.9 if hl else 0.6)
					if obj.id == selected_id:
						edge = Color(1.0, 0.85, 0.45)
					draw_polyline(pts, edge, 2.0 if hl else 1.0, true)
			ObjectDef.Kind.MIRROR:
				var a: Vector2 = pieces[0][0][0] * px
				var b: Vector2 = pieces[0][0][1] * px
				var back := Vector2.from_angle(obj.angle + PI * 0.5) * clampf(0.004 * px, 1.5, 12.0)
				draw_line(a + back, b + back, _heat_color(obj) if heat else Color(0.15, 0.15, 0.18),
					clampf(0.006 * px, 2.0, 16.0), true)
				draw_line(a, b, def.color if not hl else Color.WHITE, 2.0, true)
			ObjectDef.Kind.PROBE:
				var a: Vector2 = pieces[0][0][0] * px
				var b: Vector2 = pieces[0][0][1] * px
				draw_dashed_line(a, b, def.color, 2.0 if hl else 1.5, 4.0)
				var label := "%s  (%.1f×)" % [Readout.irradiance(obj.probe_irradiance()),
					Readout.times_light(world, obj.probe_irradiance())]
				draw_string_outline(_font, b + Vector2(6, 5), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 3,
					Color(0, 0, 0, 0.6))
				draw_string(_font, b + Vector2(6, 5), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, def.color)


func _heat_color(obj: SimObject) -> Color:
	var t := obj.temperature_k if obj.temperature_k > 0.0 else world.ambient_k
	var c := overlay.heat_gradient.sample(OverlayRenderer.heat_x(SimConst.k_to_c(t)))
	c.a = 0.95
	return c
