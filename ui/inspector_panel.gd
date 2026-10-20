class_name InspectorPanel
extends PanelContainer
## The inspector, fixed at the top right under the top bar: the selected object, or else what
## the pointer is over (an object, then the tile under it). A selected object also gets its
## actions (tilt, level, delete). A hovered probe shows its spectrum.

const WIDTH := 340.0

var world: SimWorld
var tool: ObjectTool
var brush: CreativeBrush

var _light: LightSystem
var _power: PowerSystem
var _text: RichTextLabel
var _chart: SpectrumChart
var _actions: HBoxContainer


func setup(p_world: SimWorld, p_tool: ObjectTool, p_brush: CreativeBrush) -> void:
	world = p_world
	tool = p_tool
	brush = p_brush
	_light = world.get_system(&"light")
	_power = world.get_system(&"power")
	add_theme_stylebox_override(&"panel", UiStyle.box(UiStyle.PANEL_BG, 8, 12, UiStyle.PANEL_EDGE))
	mouse_filter = Control.MOUSE_FILTER_STOP
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
	col.add_child(_text)
	_chart = SpectrumChart.new()
	col.add_child(_chart)
	_actions = HBoxContainer.new()
	_actions.add_theme_constant_override(&"separation", 4)
	_actions.add_child(UiStyle.button("Tilt −5°", "Rotate counterclockwise (R, Shift for 1°)", tool.rotate_by.bind(-5.0)))
	_actions.add_child(UiStyle.button("Tilt +5°", "Rotate clockwise (F, Shift for 1°)", tool.rotate_by.bind(5.0)))
	_actions.add_child(UiStyle.button("Level", "Reset the tilt to 0°", _level))
	_actions.add_child(UiStyle.button("Delete", "Remove the object (X / Delete)", tool.delete_target))
	col.add_child(_actions)


func update() -> void:
	var selected := tool.selected_object()
	var obj := selected if selected != null else world.objects.get(tool.hovered_id) as SimObject
	var cell := brush.hovered_cell()
	var over_world := world.grid.in_bounds(cell.x, cell.y) and get_viewport().gui_get_hovered_control() == null
	var lines := PackedStringArray()
	if obj != null:
		lines.append(_object_text(obj))
	if selected == null and over_world:
		lines.append(_tile_text(world.grid.idx(cell.x, cell.y), cell))
	visible = not lines.is_empty()
	if not visible:
		return
	_text.text = "\n".join(lines)
	_actions.visible = selected != null
	_chart.visible = obj != null and obj.def.kind == ObjectDef.Kind.PROBE and obj.incident_irradiance() > 0.0
	if _chart.visible:
		_chart.show_spectrum(obj.incident_spectrum(), world.light_spectrum)
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
	var tp := _light.tile_power
	if tp.size() != world.grid.size():
		return ""
	var scale := _light.irradiance_scale(world)
	var irr := tp[i] * scale
	if irr <= 0.0:
		return "[color=#8a93a0]in shadow[/color]" if world.light_is_up else ""
	var suns := Readout.times_light(world, _light.strip_irradiance_max(i, world))
	var o := i * Spectrum.BAND_COUNT
	var bp := _light.band_power
	var head := "[color=#ffd873]≈%.0f× %s[/color]" % [suns, Readout.light_name(world)] if suns >= 1.5 \
		else "in " + Readout.light_name(world) + "light"
	return "%s · absorbing %s\n[color=#8a93a0]%s[/color]" % [head, Readout.irradiance(irr),
		Readout.bands(bp[o] * scale, bp[o + 1] * scale, bp[o + 2] * scale)]


func _object_text(obj: SimObject) -> String:
	var s := "[b][color=#ffd873]%s[/color][/b]  [color=#8a93a0]%.1f°[/color]" % [obj.def.display_name,
		wrapf(rad_to_deg(obj.angle), -180.0, 180.0)]
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
		s += _cell_text(obj)
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


## What a cell makes now (on a network that sells) or could make (not wired to one); read from
## the light now, so it is right while paused too.
func _cell_text(obj: SimObject) -> String:
	var irr := obj.incident_irradiance() * _light.power_scale(world)
	var watts := SolarCell.object_power(obj, _light.power_scale(world))
	if not _power.sells(world, obj):
		return "\ncould make %s  [color=#8a93a0](not wired to a grid connection)[/color]" % Readout.power(watts)
	var eta := watts / (irr * obj.def.size_m * SimConst.DEPTH_M) if irr > 0.0 else 0.0
	return "\nmaking %s  [color=#8a93a0](%.0f%% of %s)[/color]" % [Readout.power(watts), eta * 100.0,
		Readout.irradiance(irr)]
