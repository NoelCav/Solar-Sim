class_name MapMarkers
extends Node2D
## World-space labels that make the current view readable at a glance: the peak of the
## overlay (hottest tile, brightest absorbed light), drawn at a constant screen size.

const MIN_SUNS := 2.0   ## Normal view: only mark light concentrated at least this much

var world: SimWorld
var overlay: OverlayRenderer
var view := ViewMode.NORMAL

var _font: Font


func setup(p_world: SimWorld, p_overlay: OverlayRenderer) -> void:
	world = p_world
	overlay = p_overlay
	z_index = 12
	_font = ThemeDB.fallback_font


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if world == null or overlay.peak_tile < 0:
		return
	var text := ""
	match ViewMode.overlay(view):
		ViewMode.Overlay.TEMPERATURE:
			if overlay.peak_value - world.ambient_k < 15.0:   # Nothing notably hot
				return
			text = "hottest %.0f °C" % SimConst.k_to_c(overlay.peak_value)
		ViewMode.Overlay.ABSORBED:
			text = "peak %s" % Readout.irradiance(overlay.peak_value)
		_:
			var suns := Readout.times_light(world, overlay.peak_value)
			if suns < MIN_SUNS:
				return
			text = "≈%.0f× %s" % [suns, Readout.light_name(world)]
	var g := world.grid
	var c := g.coords(overlay.peak_tile)
	# Screen units throughout (see ObjectRenderer), so the marker stays crisp at any zoom.
	var zoom := get_viewport().get_canvas_transform().get_scale().x
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE / zoom)
	var center := (Vector2(c) + Vector2(0.5, 0.5)) * SimConst.TILE_PX * zoom
	var r := 10.0
	draw_arc(center, r, 0.0, TAU, 32, Color(1, 1, 1, 0.9), 2.0, true)
	draw_line(center + Vector2(r, -r) * 0.7, center + Vector2(r * 2.2, -r * 2.2), Color(1, 1, 1, 0.9), 1.5, true)
	var pos := center + Vector2(r * 2.4, -r * 2.2)
	var size := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
	draw_rect(Rect2(pos + Vector2(-4, -15), size + Vector2(8, 6)), Color(0.05, 0.07, 0.1, 0.8))
	draw_string(_font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1.0, 0.9, 0.6))
