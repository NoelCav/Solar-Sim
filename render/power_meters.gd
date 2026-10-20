class_name PowerMeters
extends RefCounted
## Analog power meters drawn on the devices themselves rather than as labels: a cell's meter is
## clamped to its stand's pole (or stands on the ground beside a surface cell), a grid
## connection's is set into its cabinet and reads the whole network.
## - The scale runs to FULL_SCALE × rated power (SolarCell.rated_power, summed over the network
##   for a grid connection), with the rated mark at 1 and a red zone past it. Concentrated light
##   pins the needle there and lights the amber lamp.
## - The lamp is green while the device is on a network that sells, dark otherwise (an open
##   cell makes nothing: the inspector says what it could make).
## - The LCD under the scale shows the watts once it is big enough to read. A battery's meter
##   reads its flow against its maximum (either way) and shows its charge on the LCD.
## Sizes are in meters, so the meters zoom with the world.

const FULL_SCALE := 1.25
const SWEEP := 0.8                        ## Half the scale's arc, radians either side of up
const CELL_METER_M := Vector2(0.34, 0.3)
const CABINET_METER_M := Vector2(0.4, 0.34)
const CABINET_RAISE_M := 0.12             ## Meter center above the cabinet center
const POLE_DROP_M := 0.1                  ## Meter top below a mounted cell's center
const MIN_TEXT := 5                       ## Smallest LCD font (screen units) worth drawing
const HOUSING := Color(0.17, 0.18, 0.2)
const FACE := Color(0.9, 0.88, 0.8)
const INK := Color(0.15, 0.15, 0.17)
const OVER_ZONE := Color(0.85, 0.3, 0.2)
const NEEDLE := Color(0.75, 0.12, 0.1)
const LCD_BG := Color(0.06, 0.1, 0.07)
const LCD_TEXT := Color(0.55, 1.0, 0.6)
const LAMP_SELLING := Color(0.35, 0.95, 0.45)
const LAMP_OVER := Color(1.0, 0.65, 0.2)
const LAMP_OFF := Color(0.3, 0.3, 0.3)


## Draws the meter of every cell, battery and grid connection on `ci`; `base` is the canvas item's
## screen-unit transform (restored afterwards), `px` screen units per meter. Read from the
## light now, so the meters are right while paused too. A meter on a surface cell is drawn only
## while that cell is `focus` (hovered or selected): a row of them would overlap into a pile.
static func draw_all(ci: CanvasItem, world: SimWorld, base: Transform2D, px: float, focus: Array = []) -> void:
	for obj: SimObject in world.objects.values():
		var r := reading(world, obj)
		if r.is_empty() or (obj.def.mount == ObjectDef.Mount.GROUND and obj.def.kind == ObjectDef.Kind.CELL
				and obj.id not in focus):
			continue
		_draw_meter(ci, base * Transform2D(obj.angle if obj.def.is_machine() else 0.0, r.center * px),
			r.size * px, r.watts, r.rated, r.on, r.text)
	ci.draw_set_transform_matrix(base)


## What `obj`'s meter shows now: {center (m), size (m), watts, rated, on, text}; empty for objects
## without one.
static func reading(world: SimWorld, obj: SimObject) -> Dictionary:
	var power: PowerSystem = world.get_system(&"power")
	power.sync(world)
	var n := power.network_of(world, obj)
	var cabinet := obj.position + Vector2(0.0, -CABINET_RAISE_M).rotated(obj.angle)
	match obj.def.kind:
		ObjectDef.Kind.CELL:
			var sells := power.delivers(world, obj)
			return {"center": _cell_meter_m(world, obj), "size": CELL_METER_M, "on": sells, "text": "",
				"watts": power.flows(world, n, SimConst.DT).cells[obj.id] if sells else 0.0,
				"rated": SolarCell.rated_power(obj.def)}
		ObjectDef.Kind.BATTERY:
			var charge := obj.stored_j / (obj.def.battery_capacity_kwh * Market.J_PER_KWH)
			return {"center": cabinet, "size": CABINET_METER_M, "on": n >= 0, "text": "%.0f %%" % (charge * 100.0),
				"watts": absf(power.flows(world, n, SimConst.DT).batteries[obj.id]) if n >= 0 else 0.0,
				"rated": obj.def.battery_max_w}
		ObjectDef.Kind.GRID_TIE:
			return {"center": cabinet, "size": CABINET_METER_M, "on": n >= 0 and power.network_grid[n] == 1, "text": "",
				"watts": power.output_w(world, n), "rated": power.rated_w(world, n)}
	return {}


## Draws `obj`'s meter filling a control of `size` screen units (the inspector's enlarged copy).
static func draw_enlarged(ci: CanvasItem, world: SimWorld, obj: SimObject, size: Vector2) -> void:
	var r := reading(world, obj)
	if r.is_empty():
		return
	_draw_meter(ci, Transform2D(0.0, size * 0.5), size, r.watts, r.rated, r.on, r.text)
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)


## Center of a cell's meter (m): on the pole under a mounted cell, else on the ground beside it.
static func _cell_meter_m(world: SimWorld, obj: SimObject) -> Vector2:
	if obj.mounted and obj.def.mount == ObjectDef.Mount.STAND:
		return obj.position + Vector2(0.0, POLE_DROP_M + CELL_METER_M.y * 0.5)
	var x := obj.position.x + (obj.def.size_m + CELL_METER_M.x) * 0.5 + 0.05
	var ground := Mounting.stand_base(world, Vector2(x, obj.position.y))
	return Vector2(x, (ground if is_finite(ground) else obj.position.y) - CELL_METER_M.y * 0.5)


## One meter of `s` screen units centered on `at`'s origin: housing, face with scale and
## needle, LCD and lamp.
static func _draw_meter(ci: CanvasItem, at: Transform2D, s: Vector2, watts: float, rated: float,
		selling: bool, text := "") -> void:
	ci.draw_set_transform_matrix(at)
	var box := Rect2(-s * 0.5, s)
	ci.draw_rect(box, HOUSING)
	var pad := s.y * 0.08
	var face := Rect2(box.position + Vector2(pad, pad), Vector2(s.x - 2.0 * pad, s.y * 0.58))
	ci.draw_rect(face, FACE)
	var pivot := Vector2(0.0, face.end.y - pad * 0.3)
	var r := face.size.y * 0.8
	var a0 := -PI * 0.5 - SWEEP
	var a1 := -PI * 0.5 + SWEEP
	var width := maxf(s.y * 0.025, 1.0)
	ci.draw_arc(pivot, r, a0, a1, 24, INK, width, true)
	ci.draw_arc(pivot, r, lerpf(a0, a1, 1.0 / FULL_SCALE), a1, 8, OVER_ZONE, width * 2.0, true)
	for k in 5:   # Ticks at 0, ¼, ½, ¾ and the rated mark
		var d := Vector2.from_angle(lerpf(a0, a1, k * 0.25 / FULL_SCALE))
		ci.draw_line(pivot + d * r, pivot + d * r * (0.75 if k == 4 else 0.87), INK, width, true)
	var ratio := watts / rated if rated > 0.0 else 0.0
	var needle := Vector2.from_angle(lerpf(a0, a1, clampf(ratio / FULL_SCALE, 0.0, 1.0)))
	ci.draw_line(pivot, pivot + needle * r * 0.95, NEEDLE, width * 1.3, true)
	ci.draw_circle(pivot, width * 1.5, INK)
	var lamp_r := s.y * 0.05
	var lcd := Rect2(Vector2(face.position.x, face.end.y + pad),
		Vector2(face.size.x - lamp_r * 3.0, box.end.y - face.end.y - 2.0 * pad))
	ci.draw_rect(lcd, LCD_BG)
	var lamp := LAMP_OFF
	if selling:
		lamp = LAMP_OVER if ratio > 1.0 else (LAMP_SELLING if watts > 0.0 else LAMP_SELLING.darkened(0.6))
	ci.draw_circle(Vector2(face.end.x - lamp_r, lcd.get_center().y), lamp_r, lamp)
	var font_size := int(lcd.size.y * 0.8)
	if font_size < MIN_TEXT:
		return
	var font := ThemeDB.fallback_font
	if text == "":
		text = Readout.power(watts) if selling else "no grid"
	var baseline := lcd.get_center().y + (font.get_ascent(font_size) - font.get_descent(font_size)) * 0.5
	ci.draw_string(font, Vector2(lcd.position.x + pad * 0.5, baseline), text, HORIZONTAL_ALIGNMENT_RIGHT,
		lcd.size.x - pad, font_size, LCD_TEXT)
