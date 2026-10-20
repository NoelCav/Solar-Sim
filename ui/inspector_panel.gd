class_name InspectorPanel
extends PanelContainer
## The inspector, fixed at the top right under the top bar: the selected object, or else what
## the pointer is over (an object, then the tile under it). A selected object also gets its
## actions (tilt, level, delete) and its full numbers: for optics focus, transmission and
## material; for a cell its efficiency card (where the light goes, power by color, light
## straight from the source vs through optics). Hovered objects get the short version. A
## hovered probe shows its spectrum.

## Where a cell's light goes (SolarCell.analyze keys): label, color. The electrical factors
## (collection, voltage, temperature, series) are one part.
const LOSS_PARTS := [["power", "power_w", Color(0.45, 0.9, 0.55)],
	["reflected", "reflected_w", Color(0.62, 0.72, 0.86)],
	["below gap", "below_gap_w", Color(0.6, 0.18, 0.14)],
	["photon excess", "excess_w", Color(0.95, 0.55, 0.2)]]
const ELECTRICAL_KEYS := ["collection_w", "voltage_w", "temperature_w", "series_w"]
const ELECTRICAL_COLOR := Color(0.9, 0.8, 0.35)

const WIDTH := 340.0

var world: SimWorld
var tool: ObjectTool
var brush: CreativeBrush

var _light: LightSystem
var _power: PowerSystem
var _text: RichTextLabel
var _meter: MeterView
var _chart: SpectrumChart
var _losses: StackBar
var _colors: StackBar
var _actions: HBoxContainer
var _turn_buttons: Array[Button] = []   ## Tilt and Level: only for objects that can turn


func setup(p_world: SimWorld, p_tool: ObjectTool, p_brush: CreativeBrush) -> void:
	world = p_world
	tool = p_tool
	brush = p_brush
	_light = world.get_system(&"light")
	_power = world.get_system(&"power")
	UiStyle.style_panel(self, 8, 12)
	set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	offset_left = -WIDTH - UiStyle.GAP
	offset_right = -UiStyle.GAP
	offset_top = UiStyle.TOP_BAR_H + UiStyle.GAP
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 8)
	add_child(col)
	_text = RichTextLabel.new()
	_text.bbcode_enabled = true
	_text.fit_content = true
	_text.scroll_active = false
	_text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_text.add_theme_font_size_override(&"normal_font_size", 13)
	_text.custom_minimum_size.x = WIDTH - 24.0   # A width to wrap at; without it each word wraps
	col.add_child(_text)
	_meter = MeterView.new()
	col.add_child(_meter)
	_chart = SpectrumChart.new()
	col.add_child(_chart)
	_losses = StackBar.new(WIDTH - 24.0)
	col.add_child(_losses)
	_colors = StackBar.new(WIDTH - 24.0)
	col.add_child(_colors)
	_actions = HBoxContainer.new()
	_actions.add_theme_constant_override(&"separation", 4)
	_turn_buttons = [
		UiStyle.button("Tilt −5°", "Rotate counterclockwise (R, Shift for 1°)", tool.rotate_by.bind(-5.0)),
		UiStyle.button("Tilt +5°", "Rotate clockwise (F, Shift for 1°)", tool.rotate_by.bind(5.0)),
		UiStyle.button("Level", "Reset the tilt to 0°", _level),
	]
	for b in _turn_buttons:
		_actions.add_child(b)
	_actions.add_child(UiStyle.button("Delete", "Remove the object (X / Delete)", tool.delete_target))
	col.add_child(_actions)


func update() -> void:
	var selected := tool.selected_object()
	var obj := selected if selected != null else world.objects.get(tool.hovered_id) as SimObject
	var cell := brush.hovered_cell()
	var over_world := world.grid.in_bounds(cell.x, cell.y) and get_viewport().gui_get_hovered_control() == null
	var lines := PackedStringArray()
	if obj != null:
		lines.append(_object_text(obj, obj == selected))
	if selected == null and over_world:
		lines.append(_tile_text(world.grid.idx(cell.x, cell.y), cell))
	visible = not lines.is_empty()
	if not visible:
		return
	_text.text = "\n".join(lines)
	_actions.visible = selected != null
	for b in _turn_buttons:
		b.visible = selected != null and selected.def.can_rotate()
	_meter.show_meter(world, obj)
	_chart.visible = obj != null and obj.def.kind == ObjectDef.Kind.PROBE and obj.incident_irradiance() > 0.0
	if _chart.visible:
		_chart.show_spectrum(obj.incident_spectrum(), world.light_spectrum)
	var card := selected != null and obj == selected and obj.def.kind == ObjectDef.Kind.CELL
	_losses.visible = card and SolarCell.object_irradiance(obj, 1.0) > 0.0
	_colors.visible = _losses.visible
	if _losses.visible:
		_show_cell_bars(obj)
	reset_size()


func _level() -> void:
	var o := tool.selected_object()
	if o != null:
		world.enqueue(TransformObjectCommand.new(o.id, o.position, 0.0))


func _tile_text(i: int, cell: Vector2i) -> String:
	var g := world.grid
	var def := world.materials.get_def(g.material[i])
	var t := g.temperature[i]
	var dt := t - world.ambient_k
	var s := "[b]%s[/b]  [color=#8a93a0](%d, %d)[/color]\n" % [def.display_name if def else "?", cell.x, cell.y]
	s += "%.1f °C  [color=#8a93a0](%+.1f vs air)[/color]" % [SimConst.k_to_c(t), dt]
	var surface := world.skin.max_temperature(i)
	if surface > t + 1.0:
		s += "\nsurface up to %.0f °C" % SimConst.k_to_c(surface)
	if def == null or not def.is_solid() and def.phase != MaterialDef.Phase.LIQUID:
		return s
	var light := _light_text(i)
	return s + ("\n" + light if light != "" else "")


func _light_text(i: int) -> String:
	if _light.sky.tile_power.size() != world.grid.size():
		return ""
	var irr := _light.tile_irradiance(i, world)
	if irr <= 0.0:
		return "[color=#8a93a0]in shadow[/color]" if world.light_is_up or not _light.lamps.is_empty() else ""
	var suns := Readout.times_light(world, _light.sky.strip_irradiance_max(i, world))   # The sky's light, not a lamp's
	var bands := _light.tile_band_irradiance(i, world)
	var source := Readout.light_name(world) if _light.sky.tile_power[i] > 0.0 else "lamp"
	var head := "[color=#ffd873]≈%.0f× %s[/color]" % [suns, source] if suns >= 1.5 \
		else "in " + source + "light"
	return "%s · absorbing %s\n[color=#8a93a0]%s[/color]" % [head, Readout.irradiance(irr),
		Readout.bands(bands[0], bands[1], bands[2])]


func _object_text(obj: SimObject, selected: bool) -> String:
	var s := "[b][color=#ffd873]%s[/color][/b]  [color=#8a93a0]%.1f°[/color]" % [obj.def.display_name,
		wrapf(rad_to_deg(obj.angle), -180.0, 180.0)]
	if selected and obj.def.kind in [ObjectDef.Kind.LENS, ObjectDef.Kind.MIRROR, ObjectDef.Kind.PRISM]:
		s += "
[color=#8a93a0]%s[/color]" % Readout.item_stats(obj.def, world.materials, true)
	if obj.def.kind == ObjectDef.Kind.PROBE:
		var irr := obj.incident_irradiance()
		s += "\nreads %s  (%.1f× %s)" % [Readout.irradiance(irr), Readout.times_light(world, irr), Readout.light_name(world)]
		var spectrum := obj.incident_spectrum()
		var bands := PackedFloat32Array([0, 0, 0])
		for b in Spectrum.BIN_COUNT:
			bands[Spectrum.BAND_OF[b]] += spectrum[b]
		s += "\n[color=#8a93a0]%s[/color]" % Readout.bands(bands[0], bands[1], bands[2])
		return s
	if obj.def.kind == ObjectDef.Kind.CELL:
		s += _cell_text(obj, selected)
	elif obj.def.kind == ObjectDef.Kind.LAMP:
		return s + _lamp_text(obj)
	elif obj.def.kind == ObjectDef.Kind.BATTERY:
		return s + _battery_text(obj)
	elif obj.def.kind == ObjectDef.Kind.GRID_TIE:
		var n := _power.network_of(world, obj)
		if n < 0:
			return s + "\n[color=#8a93a0]not wired: run wire to its foot[/color]"
		return s + "\nselling %s at %.1f ¢/kWh" % [Readout.power(_power.output_w(world, n)),
			Market.price_per_kwh(world) * 100.0]
	s += "\nabsorbing %.1f W" % obj.absorbed_w
	if obj.temperature_k > 0.0:
		s += " · %.1f °C" % SimConst.k_to_c(obj.temperature_k)
	return s


## A lamp's brightness, what it draws and what it gives as light.
func _lamp_text(obj: SimObject) -> String:
	if _power.network_of(world, obj) < 0:
		return "\n[color=#8a93a0]not wired: run wire to its foot[/color]"
	var def := obj.def
	var s := "\n%.0f %% bright · %s drawn · %s of light" % [obj.lamp_level * 100.0, Readout.power(def.lamp_watts * obj.lamp_level),
		Readout.power(def.lamp_light_w() * obj.lamp_level)]
	if obj.lamp_level < 0.99:
		s += "\n[color=#8a93a0]its network can't supply it (no grid connection, or too little power)[/color]"
	return s


## A battery's charge, what it is doing at this price, and what it can still take or give.
func _battery_text(obj: SimObject) -> String:
	var n := _power.network_of(world, obj)
	if n < 0:
		return "\n[color=#8a93a0]not wired: run wire to its foot[/color]"
	var cap := obj.def.battery_capacity_kwh * Market.J_PER_KWH
	var w: float = _power.flows(world, n, SimConst.DT).batteries[obj.id]
	var doing := "idle" if absf(w) < 0.05 else ("giving %s" % Readout.power(w) if w > 0.0 else "taking %s" % Readout.power(-w))
	var s := "\n%s of %s (%.0f %%) · %s" % [Readout.energy(obj.stored_j), Readout.energy(cap), obj.stored_j / cap * 100.0, doing]
	if _power.network_grid[n] == 0:
		return s + "\n[color=#8a93a0]no grid connection: it only charges[/color]"
	return s + "\n[color=#8a93a0]price %.1f ¢/kWh: %s[/color]" % [Market.price_per_kwh(world) * 100.0,
		["charges from surplus", "holds", "sells"][Market.stance(world)]]


## What a cell makes now (on a network that sells) or could make (not wired to one); read from
## the light now, so it is right while paused too. `full` adds its efficiency against rated,
## and how much of its light came straight from the source.
func _cell_text(obj: SimObject, full: bool) -> String:
	var irr := SolarCell.object_irradiance(obj, _light.power_scale(world))
	var watts := SolarCell.object_power(obj, _light.power_scale(world))
	var rated := SolarCell.rated_power(obj.def)
	var eta := watts / (irr * obj.def.face_area_m2()) if irr > 0.0 else 0.0
	var s := "\nmaking %s" % Readout.power(watts) if _power.delivers(world, obj) \
		else "\ncould make %s  [color=#8a93a0](not wired to a grid connection)[/color]" % Readout.power(watts)
	if not full:
		return s + "  [color=#8a93a0](%.0f%% of %s)[/color]" % [eta * 100.0, Readout.irradiance(irr)]
	s += "  [color=#8a93a0]of %s rated (%.0f%%)[/color]" % [Readout.power(rated), watts / rated * 100.0]
	s += "\nefficiency %.1f%%  [color=#8a93a0](rated %.1f%%)[/color]" % [eta * 100.0,
		SolarCell.rated_efficiency(obj.def) * 100.0]
	var total := Spectrum.total(SolarCell.object_light(obj, 1.0))
	if total > 0.0:
		var direct := Spectrum.total(SolarCell.object_light(obj, 1.0, true)) / total
		s += "\nlight %s · " % Readout.irradiance(irr)
		s += "all direct %s" % Readout.light_name(world) if direct > 0.995 \
			else "%.0f%% direct · %.0f%% through optics" % [direct * 100.0, (1.0 - direct) * 100.0]
	return s


## The selected cell's bars: where its light goes, and its power by color.
func _show_cell_bars(obj: SimObject) -> void:
	var a := SolarCell.object_analysis(obj, _light.power_scale(world))
	var light := 0.0
	for k: String in ["power_w", "reflected_w", "below_gap_w", "excess_w"] + ELECTRICAL_KEYS:
		light += a[k]
	var parts := []
	for p: Array in LOSS_PARTS:
		parts.append([p[0], a[p[1]], p[2], "%.0f%%" % (a[p[1]] / light * 100.0)])
	var electrical := 0.0
	for k: String in ELECTRICAL_KEYS:
		electrical += a[k]
	parts.append(["electrical", electrical, ELECTRICAL_COLOR, "%.0f%%" % (electrical / light * 100.0)])
	_losses.show_parts("Where the light goes", parts)
	parts = []
	for b in Spectrum.BIN_COUNT:
		parts.append([SpectrumChart.BIN_LABELS[b], a.power_bin_w[b], SpectrumChart.BAR_COLOR[b],
			Readout.power(a.power_bin_w[b])])
	_colors.show_parts("Power by color", parts)
