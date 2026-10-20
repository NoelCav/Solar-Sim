class_name MapMarkers
extends Node2D
## World-space labels that make the current view readable at a glance: the peak of the
## overlay (hottest tile, brightest absorbed light), each probe's reading, and a power dial
## under each cell, drawn at a constant screen size. Labels are information, not objects: they
## are never dimmed at night. A probe's tag also picks the probe (ObjectTool uses probe_tag_rect).
##
## A cell's dial fills to its rated power (SolarCell.rated_power: plain sunlight face-on), so
## a full ring means "as good as a panel in full sun". Concentrated light goes past that: the
## ring turns warm and the multiple shows under the watts. Grey: not wired to a grid connection
## (what it could make).

const MIN_SUNS := 2.0   ## Normal view: only mark light concentrated at least this much
const TAG_FONT := 14
const TAG_BG := Color(0.05, 0.07, 0.1, 0.85)
const TAG_PAD := Vector2(4, 3)
const TAG_TEXT := Color(1.0, 0.9, 0.6)
const DIAL_R := 23.0                    ## Dial radius, screen pixels
const DIAL_GAP := 34.0                  ## Dial center below the cell center, screen pixels
const DIAL_SWEEP := 1.5 * PI            ## The ring's arc, open at the bottom
const DIAL_SELLING := Color(0.45, 0.9, 0.55)
const DIAL_OVER := Color(1.0, 0.7, 0.3)
const DIAL_IDLE := Color(0.6, 0.64, 0.7)

var world: SimWorld
var overlay: OverlayRenderer
var view := ViewMode.NORMAL

var _font: Font
var _light: LightSystem
var _power: PowerSystem


func setup(p_world: SimWorld, p_overlay: OverlayRenderer) -> void:
	world = p_world
	overlay = p_overlay
	_light = world.get_system(&"light")
	_power = world.get_system(&"power")
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
	var end: Vector2 = obj.world_pieces()[0][0][1] * SimConst.TILE_PX / SimConst.TILE_M * zoom
	var size := ThemeDB.fallback_font.get_string_size(probe_text(world, obj), HORIZONTAL_ALIGNMENT_LEFT, -1, TAG_FONT)
	return Rect2(end + Vector2(8, -size.y * 0.5), size).grow_individual(TAG_PAD.x, TAG_PAD.y, TAG_PAD.x, TAG_PAD.y)


func _draw() -> void:
	if world == null:
		return
	# Screen units throughout (see ObjectRenderer), so tags stay crisp at any zoom.
	var zoom := get_viewport().get_canvas_transform().get_scale().x
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE / zoom)
	_power.sync(world)
	for obj: SimObject in world.objects.values():
		if obj.def.kind == ObjectDef.Kind.PROBE:
			_draw_tag(probe_tag_rect(world, obj, zoom), probe_text(world, obj), obj.def.color)
		elif obj.def.kind == ObjectDef.Kind.CELL:
			_draw_dial(obj, zoom)
	_draw_peak(zoom)


## A cell's power dial (see the class notes); read from the light now, so right while paused.
func _draw_dial(obj: SimObject, zoom: float) -> void:
	var center := obj.position * SimConst.TILE_PX / SimConst.TILE_M * zoom + Vector2(0, DIAL_GAP)
	var watts := SolarCell.object_power(obj, _light.power_scale(world))
	var rated := SolarCell.rated_power(obj.def)
	var ratio := watts / rated if rated > 0.0 else 0.0
	var color := DIAL_IDLE
	if _power.sells(world, obj):
		color = DIAL_OVER if ratio > 1.0 else DIAL_SELLING
	var start := 0.5 * PI + (TAU - DIAL_SWEEP) * 0.5   # Open at the bottom, filling clockwise
	draw_circle(center, DIAL_R + 3.0, TAG_BG)
	draw_arc(center, DIAL_R, start, start + DIAL_SWEEP, 40, Color(1, 1, 1, 0.15), 4.0, true)
	if ratio > 0.0:
		draw_arc(center, DIAL_R, start, start + DIAL_SWEEP * minf(ratio, 1.0), 40, color, 4.0, true)
	var text := Readout.power(watts) if watts >= 0.05 else "0 W"
	var size := 11
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var y := center.y + _font.get_ascent(size) * 0.5 - (4.0 if ratio > 1.0 else 0.0)
	draw_string(_font, Vector2(center.x - w * 0.5, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color.WHITE)
	if ratio > 1.0:
		var over := "%.1f×" % ratio
		w = _font.get_string_size(over, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		draw_string(_font, Vector2(center.x - w * 0.5, y + 11.0), over, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, color)


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
			var suns := Readout.times_light(world, overlay.peak_value)
			if suns < MIN_SUNS:
				return
			text = "≈%.0f× %s" % [suns, Readout.light_name(world)]
	var c := world.grid.coords(overlay.peak_tile)
	var center := (Vector2(c) + Vector2(0.5, 0.5)) * SimConst.TILE_PX * zoom
	var r := 10.0
	draw_arc(center, r, 0.0, TAU, 32, Color(1, 1, 1, 0.9), 2.0, true)
	draw_line(center + Vector2(r, -r) * 0.7, center + Vector2(r * 2.2, -r * 2.2), Color(1, 1, 1, 0.9), 1.5, true)
	var size := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, TAG_FONT)
	var at := center + Vector2(r * 2.4, -r * 2.2 - size.y)
	_draw_tag(Rect2(at, size).grow_individual(TAG_PAD.x, TAG_PAD.y, TAG_PAD.x, TAG_PAD.y), text, TAG_TEXT)
