class_name PowerMeters
extends RefCounted
## Analog power meters drawn on the devices themselves rather than as labels: a cell's meter is
## clamped to its stand's pole (or stands on the ground beside a surface cell), a grid
## connection's is set into its cabinet and reads the whole network.
## - The scale runs to FULL_SCALE × rated power (SolarCell.rated_power, summed over the set or the
##   network), in green up to 80 % of rated, amber to rated and red past it, with the rated mark at 1.
##   Concentrated light pins the needle at the end and lights the amber lamp.
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
const HOUSING := Color(0.11, 0.13, 0.16)
const HOUSING_EDGE := Color(0.30, 0.34, 0.40)
const FACE := Color(0.045, 0.055, 0.07)
const TRACK := Color(0.16, 0.19, 0.24)
const ZONE_OK := Color(0.30, 0.78, 0.50)
const ZONE_HIGH := Color(0.95, 0.72, 0.25)
const ZONE_OVER := Color(0.92, 0.32, 0.26)
const NEEDLE := Color(0.96, 0.96, 0.98)
const TICK := Color(0.62, 0.68, 0.76)
const LCD_BG := Color(0.03, 0.07, 0.05)
const LCD_TEXT := Color(0.50, 1.0, 0.65)
const LAMP_SELLING := Color(0.35, 0.95, 0.45)
const LAMP_OVER := Color(1.0, 0.65, 0.2)
const LAMP_OFF := Color(0.3, 0.3, 0.3)
const DETAIL_PX := 110.0                  ## Meters at least this tall (screen units) draw titles and scale marks


## Draws the meter of every cell set, battery and grid connection on `ci`; `base` is the canvas
## item's screen-unit transform (restored afterwards), `px` screen units per meter. Read from the
## light now, so the meters are right while paused too.
static func draw_all(ci: CanvasItem, world: SimWorld, base: Transform2D, px: float) -> void:
	for obj: SimObject in world.objects.values():
		var r := reading(world, obj)
		if r.is_empty() or not _shows_meter(world, obj):
			continue
		_draw_meter(ci, base * Transform2D(obj.angle if obj.def.is_machine() else 0.0, r.center * px),
			r.size * px, r.watts, r.rated, r.on, r.text, r.title)
	ci.draw_set_transform_matrix(base)


## Whether `obj` carries its group's meter: a surface cell shares one with the cells it touches,
## which sits by the rightmost.
static func _shows_meter(world: SimWorld, obj: SimObject) -> bool:
	if not (obj.def.kind == ObjectDef.Kind.CELL and obj.def.mount == ObjectDef.Mount.GROUND):
		return true
	var power: PowerSystem = world.get_system(&"power")
	power.sync(world)
	return power.sets[power.set_of[obj.id]].back() == obj.id


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
			var members := [obj.id]
			var shown := obj
			if obj.def.mount == ObjectDef.Mount.GROUND:
				members = power.sets[power.set_of[obj.id]]
				shown = world.objects[members.back()]
			var watts := 0.0
			var rated := 0.0
			var flows: Dictionary = power.flows(world, n, SimConst.DT) if sells else {}
			for id: int in members:
				watts += flows.cells[id] if sells else 0.0
				rated += SolarCell.rated_power(world.objects[id].def)
			return {"center": _cell_meter_m(world, shown), "size": CELL_METER_M, "on": sells, "text": "",
				"watts": watts, "rated": rated,
				"title": "Panel" if members.size() == 1 else "%d cells" % members.size()}
		ObjectDef.Kind.BATTERY:
			var charge := obj.stored_j / (obj.def.battery_capacity_kwh * Market.J_PER_KWH)
			return {"center": cabinet, "size": CABINET_METER_M, "on": n >= 0, "text": "%.0f %%" % (charge * 100.0),
				"watts": absf(power.flows(world, n, SimConst.DT).batteries[obj.id]) if n >= 0 else 0.0,
				"rated": obj.def.battery_max_w, "title": "Battery"}
		ObjectDef.Kind.GRID_TIE:
			return {"center": cabinet, "size": CABINET_METER_M, "on": n >= 0 and power.network_grid[n] == 1, "text": "",
				"watts": power.output_w(world, n), "rated": power.rated_w(world, n), "title": "Grid"}
	return {}


## Where `obj`'s meter is drawn on the map (m; empty when it has none).
static func meter_rect(world: SimWorld, obj: SimObject) -> Rect2:
	var size := CELL_METER_M
	var center := Vector2.ZERO
	match obj.def.kind:
		ObjectDef.Kind.CELL:
			var shown := obj
			if obj.def.mount == ObjectDef.Mount.GROUND:
				var power: PowerSystem = world.get_system(&"power")
				power.sync(world)
				shown = world.objects[power.sets[power.set_of[obj.id]].back()]
			center = _cell_meter_m(world, shown)
		ObjectDef.Kind.BATTERY, ObjectDef.Kind.GRID_TIE:
			size = CABINET_METER_M
			center = obj.position + Vector2(0.0, -CABINET_RAISE_M).rotated(obj.angle)
		_:
			return Rect2()
	return Rect2(center - size * 0.5, size)


## Draws `obj`'s meter filling a control of `size` screen units (the inspector's enlarged copy).
static func draw_enlarged(ci: CanvasItem, world: SimWorld, obj: SimObject, size: Vector2) -> void:
	var r := reading(world, obj)
	if r.is_empty():
		return
	_draw_meter(ci, Transform2D(0.0, size * 0.5), size, r.watts, r.rated, r.on, r.text, r.title)
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)


## Center of a cell's meter (m): on the pole under a mounted cell, else on the ground beside it.
static func _cell_meter_m(world: SimWorld, obj: SimObject) -> Vector2:
	if obj.mounted and obj.def.mount == ObjectDef.Mount.STAND:
		return obj.position + Vector2(0.0, POLE_DROP_M + CELL_METER_M.y * 0.5)
	var x := obj.position.x + (obj.def.size_m + CELL_METER_M.x) * 0.5 + 0.05
	var ground := Mounting.stand_base(world, Vector2(x, obj.position.y))
	return Vector2(x, (ground if is_finite(ground) else obj.position.y) - CELL_METER_M.y * 0.5)


## One meter of `s` screen units centered on `at`'s origin: a rounded housing, the dial (a track
## with green, amber and red zones and a needle), the LCD and the status lamp; a tall one also
## names the device and marks the scale.
static func _draw_meter(ci: CanvasItem, at: Transform2D, s: Vector2, watts: float, rated: float,
		selling: bool, text := "", title := "") -> void:
	ci.draw_set_transform_matrix(at)
	var detail := s.y >= DETAIL_PX
	var box := Rect2(-s * 0.5, s)
	var radius := int(s.y * 0.1)
	ci.draw_style_box(_rounded(HOUSING, radius, HOUSING_EDGE, 1 if detail else 0), box)
	var pad := s.y * 0.07
	var head := s.y * 0.14 if detail else 0.0   # Room for the title
	var face := Rect2(box.position + Vector2(pad, pad + head), Vector2(s.x - 2.0 * pad, s.y * 0.6 - head))
	ci.draw_style_box(_rounded(FACE, int(radius * 0.7)), face)
	var pivot := Vector2(0.0, face.end.y - pad * 0.5)
	var r := minf(face.size.x * 0.46, face.size.y * 0.95)
	var a0 := -PI * 0.5 - SWEEP
	var a1 := -PI * 0.5 + SWEEP
	var width := maxf(s.y * 0.045, 1.5)
	var ratio := watts / rated if rated > 0.0 else 0.0
	var angle_at := func(x: float) -> float: return lerpf(a0, a1, clampf(x / FULL_SCALE, 0.0, 1.0))
	ci.draw_arc(pivot, r, a0, a1, 32, TRACK, width, true)
	if rated > 0.0:
		ci.draw_arc(pivot, r, a0, angle_at.call(0.8), 20, ZONE_OK, width, true)
		ci.draw_arc(pivot, r, angle_at.call(0.8), angle_at.call(1.0), 8, ZONE_HIGH, width, true)
		ci.draw_arc(pivot, r, angle_at.call(1.0), a1, 8, ZONE_OVER, width, true)
	if detail:
		var font := ThemeDB.fallback_font
		var fs := int(s.y * 0.075)
		for mark: Array in [[0.0, "0"], [0.5, "½"], [1.0, ""]]:
			var d := Vector2.from_angle(angle_at.call(mark[0]))
			ci.draw_line(pivot + d * r * 0.82, pivot + d * r * 0.94, TICK, 1.5, true)
			if mark[1] != "":
				ci.draw_string(font, pivot + d * r * 0.66 - Vector2(fs * 0.3, -fs * 0.35), mark[1], HORIZONTAL_ALIGNMENT_LEFT,
					-1, fs, TICK)
		ci.draw_string(font, Vector2(box.position.x + pad, box.position.y + pad + head * 0.75), title,
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(s.y * 0.09), UiStyle.DIM)
	var needle := Vector2.from_angle(angle_at.call(ratio))
	ci.draw_line(pivot + needle * 2.0, pivot + needle * r * 0.88, Color(0, 0, 0, 0.5), width * 0.7 + 1.0, true)
	ci.draw_line(pivot, pivot + needle * r * 0.88, NEEDLE, maxf(width * 0.45, 1.2), true)
	ci.draw_circle(pivot, width * 0.9, TICK)
	var lamp_r := s.y * 0.045
	var lcd := Rect2(Vector2(box.position.x + pad, face.end.y + pad), Vector2(s.x - 2.0 * pad - lamp_r * 3.0,
		box.end.y - face.end.y - 2.0 * pad))
	ci.draw_style_box(_rounded(LCD_BG, int(radius * 0.5)), lcd)
	var lamp := LAMP_OFF
	if selling:
		lamp = LAMP_OVER if ratio > 1.0 else (LAMP_SELLING if watts > 0.0 else LAMP_SELLING.darkened(0.6))
	ci.draw_circle(Vector2(box.end.x - pad - lamp_r, lcd.get_center().y), lamp_r, lamp)
	var font_size := int(lcd.size.y * 0.7)
	if font_size < MIN_TEXT:
		return
	var lcd_font := ThemeDB.fallback_font
	if text == "":
		text = Readout.power(watts) if selling else "no grid"
	var baseline := lcd.get_center().y + (lcd_font.get_ascent(font_size) - lcd_font.get_descent(font_size)) * 0.5
	ci.draw_string(lcd_font, Vector2(lcd.position.x + pad * 0.5, baseline), text, HORIZONTAL_ALIGNMENT_RIGHT,
		lcd.size.x - pad, font_size, LCD_TEXT)


static func _rounded(color: Color, radius: int, edge := Color.TRANSPARENT, border := 0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = color
	sb.set_corner_radius_all(radius)
	if border > 0:
		sb.border_color = edge
		sb.set_border_width_all(border)
	return sb
