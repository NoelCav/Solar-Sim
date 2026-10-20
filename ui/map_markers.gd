class_name MapMarkers
extends Node2D
## World-space labels that make the current view readable at a glance: the peak of the
## overlay (hottest tile, brightest absorbed light) and each probe's reading, drawn as tags
## at a constant screen size. Labels are information, not objects: they are never dimmed
## at night. A probe's tag also picks the probe (ObjectTool uses probe_tag_rect). Power
## readings are meters on the devices themselves (PowerMeters).

const MIN_NIGHT_W_M2 := 1.0       ## Dimmer than this at night isn't worth a marker
const MIN_SUNS := 2.0   ## Normal view: only mark light concentrated at least this much
const TAG_FONT := 14
const TAG_BG := Color(0.05, 0.07, 0.1, 0.85)
const TAG_PAD := Vector2(4, 3)
const TAG_TEXT := Color(1.0, 0.9, 0.6)

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


## A probe's reading: irradiance and how many times plain light from the source it is.
static func probe_text(world: SimWorld, obj: SimObject) -> String:
	var irr := obj.incident_irradiance()
	return "%s  (%.1f×)" % [Readout.irradiance(irr), Readout.times_light(world, irr)]


## Where a probe's tag sits, in zoomed canvas units (world pixels × zoom): just past the
## probe's end point.
static func probe_tag_rect(world: SimWorld, obj: SimObject, zoom: float) -> Rect2:
	var end: Vector2 = obj.world_pieces()[0][0][1] * SimConst.PX_PER_M * zoom
	var size := ThemeDB.fallback_font.get_string_size(probe_text(world, obj), HORIZONTAL_ALIGNMENT_LEFT, -1, TAG_FONT)
	return Rect2(end + Vector2(8, -size.y * 0.5), size).grow_individual(TAG_PAD.x, TAG_PAD.y, TAG_PAD.x, TAG_PAD.y)


func _draw() -> void:
	if world == null:
		return
	# Screen units throughout (see ObjectRenderer), so tags stay crisp at any zoom.
	var zoom := get_viewport().get_canvas_transform().get_scale().x
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE / zoom)
	for obj: SimObject in world.objects.values():
		if obj.def.kind == ObjectDef.Kind.PROBE:
			_draw_tag(probe_tag_rect(world, obj, zoom), probe_text(world, obj), obj.def.color)
	_draw_peak(zoom)


## A label on a dark box that reads on any background, day or night.
func _draw_tag(rect: Rect2, text: String, color: Color) -> void:
	draw_rect(rect, TAG_BG)
	var baseline := rect.position + Vector2(TAG_PAD.x, TAG_PAD.y + _font.get_ascent(TAG_FONT))
	draw_string(_font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1, TAG_FONT, color)


func _draw_peak(zoom: float) -> void:
	if overlay.peak_tile < 0:
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
			# A multiple of the sun is a useful number by day; at night the light is the moon's or a
			# lamp's, and a multiple of the moon means nothing, so the plain irradiance is shown.
			var suns := Readout.times_light(world, overlay.peak_value)
			if world.light_is_moon or not world.sun_is_up:
				if overlay.peak_value < MIN_NIGHT_W_M2:
					return
				text = "peak %s" % Readout.irradiance(overlay.peak_value)
			elif suns >= MIN_SUNS:
				text = "≈%.0f× sun" % suns
			else:
				return
	var c := world.grid.coords(overlay.peak_tile)
	var center := (Vector2(c) + Vector2(0.5, 0.5)) * SimConst.TILE_PX * zoom
	var r := 10.0
	draw_arc(center, r, 0.0, TAU, 32, Color(1, 1, 1, 0.9), 2.0, true)
	draw_line(center + Vector2(r, -r) * 0.7, center + Vector2(r * 2.2, -r * 2.2), Color(1, 1, 1, 0.9), 1.5, true)
	var size := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, TAG_FONT)
	var at := center + Vector2(r * 2.4, -r * 2.2 - size.y)
	_draw_tag(Rect2(at, size).grow_individual(TAG_PAD.x, TAG_PAD.y, TAG_PAD.x, TAG_PAD.y), text, TAG_TEXT)
