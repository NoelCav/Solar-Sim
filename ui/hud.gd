class_name Hud
extends Control
## Screen-space interface (design doc §16): status and time controls (top left), views,
## wavelength filter and legend (top right), the tool bar with its item list (bottom), and
## an inspector that follows the cursor. Reads sim state; actions go back to Main, the
## ObjectTool and the CreativeBrush.

const PANEL_BG := Color(0.05, 0.07, 0.10, 0.92)
const DIM := Color(0.70, 0.75, 0.82)
const ACCENT := Color(1.0, 0.85, 0.45)
const TOOL_NAMES: Array[String] = ["Select", "Build", "Paint", "Wire"]
const TOOL_KEYS: Array[String] = ["Esc", "B", "T", "V"]
const TOOL_HINTS: Array[String] = [
	"Move and tilt objects; drag empty space to pan",
	"Place lenses, prisms, mirrors and probes",
	"Paint tiles: LMB paint, RMB erase",
	"Lay wire: LMB lay, RMB remove; objects connect at the foot of their stand",
]

var world: SimWorld
var runner: Main
var brush: CreativeBrush
var tool: ObjectTool
var overlay: OverlayRenderer

var _light: LightSystem
var _heat: ThermalSystem
var _power: PowerSystem
var _status: Label
var _perf: Label
var _pause_button: Button
var _speed_buttons: Array[Button] = []
var _view_buttons: Array[Button] = []
var _wave_slider: HSlider
var _wave_label: Label
var _legend_sep: HSeparator
var _legend_title: Label
var _legend_bar: TextureRect
var _legend_ends: HBoxContainer
var _legend_lo: Label
var _legend_hi: Label
var _legend_tip: PanelContainer
var _legend_tip_label: Label
var _view_hint: Label
var _tool_buttons: Array[Button] = []
var _context: HBoxContainer        ## Tool-specific row: item list, materials or selection
var _context_key := []
var _selection_label: Label
var _help_label: Label
var _inspector: PanelContainer
var _inspect_label: RichTextLabel
var _inspect_chart: SpectrumChart   ## Spectrum of a hovered probe


func setup(p_world: SimWorld, p_runner: Main, p_brush: CreativeBrush, p_tool: ObjectTool,
		p_overlay: OverlayRenderer) -> void:
	world = p_world
	runner = p_runner
	brush = p_brush
	tool = p_tool
	overlay = p_overlay
	_light = world.get_system(&"light")
	_heat = world.get_system(&"heat")
	_power = world.get_system(&"power")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_status()
	_build_view_panel()
	_build_toolbar()
	_build_inspector()
	refresh_view()


## Updates the view buttons, wavelength filter and legend after the view changed.
func refresh_view() -> void:
	for v in _view_buttons.size():
		_view_buttons[v].set_pressed_no_signal(v == runner.view)
	_view_hint.text = ViewMode.HINTS[runner.view]
	_wave_slider.set_value_no_signal(runner.wavelength)
	_wave_label.text = ViewMode.wavelength_name(runner.wavelength)
	var lg := overlay.legend()
	_legend_bar.visible = not lg.is_empty()
	_legend_ends.visible = not lg.is_empty()
	_legend_title.visible = not lg.is_empty()
	_legend_sep.visible = not lg.is_empty()
	if not lg.is_empty():
		_legend_title.text = lg.title
		var tex := GradientTexture2D.new()
		tex.gradient = lg.gradient
		tex.width = 256
		tex.height = 12
		_legend_bar.texture = tex
		_legend_lo.text = lg.lo
		_legend_hi.text = lg.hi


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_help"):
		_help_label.visible = not _help_label.visible


func _process(_delta: float) -> void:
	if world == null:
		return
	_update_status()
	_update_toolbar()
	_update_inspector()


# --- Status and time ------------------------------------------------------------------------

func _build_status() -> void:
	var panel := _panel()
	panel.position = Vector2(10, 10)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 4)
	panel.add_child(box)
	_status = Label.new()
	_status.add_theme_font_size_override(&"font_size", 15)
	box.add_child(_status)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 4)
	box.add_child(row)
	_pause_button = _button("Pause", "Pause or resume the simulation (Space)", runner.toggle_pause)
	_pause_button.custom_minimum_size.x = 64
	row.add_child(_pause_button)
	var group := ButtonGroup.new()
	for n in Main.SPEEDS:
		var b := _button("%d×" % n, "Run at %d× speed (Tab cycles)" % n, runner.set_speed.bind(n))
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size.x = 36
		row.add_child(b)
		_speed_buttons.append(b)
	# Jumps move the clock (and the sun) without simulating the time in between.
	var jumps := HBoxContainer.new()
	jumps.add_theme_constant_override(&"separation", 4)
	box.add_child(jumps)
	var label := _small_label()
	label.text = "Jump clock"
	jumps.add_child(label)
	for h: float in [-6.0, -1.0, -0.5, 0.5, 1.0, 6.0]:
		var text := "%+d h" % int(h) if absf(h) >= 1.0 else "%+d m" % int(h * 60.0)
		var keys := ""
		if absf(h) == 1.0:
			keys = " (%s)" % ("." if h > 0.0 else ",")
		elif absf(h) == 6.0:
			keys = " (Shift+%s)" % ("." if h > 0.0 else ",")
		jumps.add_child(_button(text, "Move the clock %s without simulating the time between%s"
			% [text, keys], runner.skip_hours.bind(h)))
	_perf = Label.new()
	_perf.add_theme_font_size_override(&"font_size", 11)
	_perf.add_theme_color_override(&"font_color", DIM)
	box.add_child(_perf)


func _update_status() -> void:
	var tod := world.time_of_day() * 24.0
	var clock := "Day %d   %02d:%02d" % [world.day_number() + 1, int(tod), int(fmod(tod, 1.0) * 60.0)]
	var air := "air %.1f °C" % SimConst.k_to_c(world.ambient_k)
	var sky := ""
	if world.sun_is_up:
		sky = "Sun %.0f°   %.0f W/m²" % [rad_to_deg(world.sun_elevation), world.sun_dni]
	elif world.moon_is_up:
		sky = "Moon %.0f°   %.0f%% lit   %s" % [rad_to_deg(world.moon_elevation),
			world.moon_illuminated * 100.0, Readout.irradiance(world.moon_dni)]
	else:
		sky = "Night   moon set (%.0f%% lit)" % (world.moon_illuminated * 100.0)
	var money := "%s   grid pays %.1f ¢/kWh" % [Readout.money(world.money), Market.price_per_kwh(world) * 100.0]
	_status.text = clock + "   " + money + "\n" + sky + "   " + air
	_pause_button.text = "Play" if runner.paused else "Pause"
	for k in _speed_buttons.size():
		_speed_buttons[k].set_pressed_no_signal(not runner.paused and Main.SPEEDS[k] == runner.speed)
	_perf.text = "%d fps · sim %.1f ms/frame · light %.0f ms (%d rays) · heat %.1f ms" % [
		Engine.get_frames_per_second(), runner.sim_ms, _light.last_trace_ms,
		_light.stats.get("rays", 0), _heat.last_step_ms]


# --- Views, wavelength and legend ---------------------------------------------------------

func _build_view_panel() -> void:
	var panel := _panel()
	add_child(panel)
	panel.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	panel.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT, Control.PRESET_MODE_MINSIZE, 10)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 6)
	panel.add_child(box)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override(&"separation", 4)
	box.add_child(bar)
	var group := ButtonGroup.new()
	for v in ViewMode.COUNT:
		var b := _button(ViewMode.NAMES[v], ViewMode.HINTS[v] + "  (H cycles)", runner.set_view.bind(v))
		b.toggle_mode = true
		b.button_group = group
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		bar.add_child(b)
		_view_buttons.append(b)
	_view_hint = _small_label()
	box.add_child(_view_hint)
	box.add_child(HSeparator.new())
	var wave_head := HBoxContainer.new()
	box.add_child(wave_head)
	var wave_title := Label.new()
	wave_title.text = "Wavelength"
	wave_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wave_head.add_child(wave_title)
	_wave_label = Label.new()
	_wave_label.add_theme_color_override(&"font_color", ACCENT)
	wave_head.add_child(_wave_label)
	_wave_slider = HSlider.new()
	_wave_slider.min_value = -1
	_wave_slider.max_value = Spectrum.BIN_COUNT - 1
	_wave_slider.step = 1
	_wave_slider.tick_count = Spectrum.BIN_COUNT + 1
	_wave_slider.ticks_on_borders = true
	_wave_slider.focus_mode = Control.FOCUS_NONE
	_wave_slider.tooltip_text = "Show one band of the spectrum, or all of it at the far left (G / J)"
	_wave_slider.value_changed.connect(func(v: float) -> void: runner.set_wavelength(int(v)))
	box.add_child(_wave_slider)
	var stops := HBoxContainer.new()
	box.add_child(stops)
	for stop: String in ["All", "UV", "Blue", "Green", "Red", "NIR", "IR"]:
		var l := _small_label()
		l.text = stop
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.size_flags_stretch_ratio = 1.0
		stops.add_child(l)
	_legend_sep = HSeparator.new()
	box.add_child(_legend_sep)
	_legend_title = Label.new()
	_legend_title.add_theme_font_size_override(&"font_size", 12)
	box.add_child(_legend_title)
	_legend_bar = TextureRect.new()
	_legend_bar.custom_minimum_size = Vector2(256, 12)
	_legend_bar.stretch_mode = TextureRect.STRETCH_SCALE
	_legend_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_legend_bar.gui_input.connect(_on_legend_input)
	_legend_bar.mouse_exited.connect(func() -> void: _legend_tip.visible = false)
	box.add_child(_legend_bar)
	# Value under the cursor when hovering the color bar.
	_legend_tip = _panel()
	_legend_tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_legend_tip.visible = false
	_legend_tip_label = Label.new()
	_legend_tip_label.add_theme_color_override(&"font_color", ACCENT)
	_legend_tip.add_child(_legend_tip_label)
	add_child(_legend_tip)
	_legend_ends = HBoxContainer.new()
	box.add_child(_legend_ends)
	_legend_lo = _small_label()
	_legend_lo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_legend_ends.add_child(_legend_lo)
	_legend_hi = _small_label()
	_legend_ends.add_child(_legend_hi)


func _on_legend_input(event: InputEvent) -> void:
	if not event is InputEventMouseMotion:
		return
	var local := (event as InputEventMouseMotion).position
	var x := local.x / maxf(_legend_bar.size.x, 1.0)
	_legend_tip_label.text = overlay.legend_value(x)
	_legend_tip.visible = _legend_tip_label.text != ""
	_legend_tip.reset_size()
	var at := _legend_bar.get_global_transform() * local
	_legend_tip.position = Vector2(at.x - _legend_tip.size.x * 0.5, at.y + 18.0)


# --- Tool bar -------------------------------------------------------------------------------

func _build_toolbar() -> void:
	# A full-width strip that centers the bar whatever width its contents take.
	var strip := CenterContainer.new()
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(strip)
	strip.grow_vertical = Control.GROW_DIRECTION_BEGIN
	strip.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE, Control.PRESET_MODE_MINSIZE, 10)
	var panel := _panel()
	strip.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 6)
	panel.add_child(box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 6)
	box.add_child(row)
	var group := ButtonGroup.new()
	for m in TOOL_NAMES.size():
		var b := _button("%s  (%s)" % [TOOL_NAMES[m], TOOL_KEYS[m]], TOOL_HINTS[m], tool.set_mode.bind(m))
		b.toggle_mode = true
		b.button_group = group
		b.custom_minimum_size.x = 96
		row.add_child(b)
		_tool_buttons.append(b)
	row.add_child(VSeparator.new())
	_context = HBoxContainer.new()
	_context.add_theme_constant_override(&"separation", 4)
	_context.custom_minimum_size.y = 36
	row.add_child(_context)
	_help_label = _small_label()
	_help_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_help_label)


func _update_toolbar() -> void:
	for m in _tool_buttons.size():
		_tool_buttons[m].set_pressed_no_signal(m == tool.mode)
	var obj := tool.selected_object()
	var key := [tool.mode, tool.selected, obj.id if obj else -1, brush.selected_index, brush.brush_radius]
	if key != _context_key:
		_context_key = key
		_rebuild_context()
	if _selection_label != null and obj != null:
		_selection_label.text = "%s  %.1f°" % [obj.def.display_name, wrapf(rad_to_deg(obj.angle), -180.0, 180.0)]
	_help_label.text = _help_text()


func _rebuild_context() -> void:
	for c in _context.get_children():
		_context.remove_child(c)
		c.queue_free()
	_selection_label = null
	match tool.mode:
		ObjectTool.Mode.SELECT:
			var obj := tool.selected_object()
			if obj == null:
				var l := Label.new()
				l.text = "Click an object to select it"
				l.add_theme_color_override(&"font_color", DIM)
				_context.add_child(l)
				return
			_selection_label = Label.new()
			_selection_label.add_theme_color_override(&"font_color", ACCENT)
			_selection_label.custom_minimum_size.x = 170
			_context.add_child(_selection_label)
			_context.add_child(_button("Tilt −5°", "Rotate counterclockwise (R, Shift for 1°)", tool.rotate_by.bind(-5.0)))
			_context.add_child(_button("Tilt +5°", "Rotate clockwise (F, Shift for 1°)", tool.rotate_by.bind(5.0)))
			_context.add_child(_button("Level", "Reset the tilt to 0°",
				func() -> void:
					var o := tool.selected_object()
					if o != null:
						world.enqueue(TransformObjectCommand.new(o.id, o.position, 0.0))))
			_context.add_child(_button("Delete", "Remove the object (X / Delete)", tool.delete_target))
		ObjectTool.Mode.BUILD:
			var group := ButtonGroup.new()
			for k in tool.defs.size():
				var def := tool.defs[k]
				var b := _button("", "%s  (%d)" % [def.display_name, k + 1], tool.pick_item.bind(k))
				b.toggle_mode = true
				b.button_group = group
				b.set_pressed_no_signal(k == tool.selected)
				var inner := HBoxContainer.new()
				inner.mouse_filter = Control.MOUSE_FILTER_IGNORE
				inner.add_child(ItemIcon.new(def))
				var l := Label.new()
				l.text = def.display_name
				l.mouse_filter = Control.MOUSE_FILTER_IGNORE
				inner.add_child(l)
				b.add_child(inner)
				inner.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 4)
				b.custom_minimum_size = inner.get_combined_minimum_size() + Vector2(8, 4)
				_context.add_child(b)
		ObjectTool.Mode.PAINT:
			var group := ButtonGroup.new()
			for k in brush.palette.size():
				var def := brush.palette[k]
				var b := _button("", def.display_name, func() -> void: brush.selected_index = k)
				b.toggle_mode = true
				b.button_group = group
				b.set_pressed_no_signal(k == brush.selected_index)
				var icon := ItemIcon.new(null, def.color, Vector2(24, 24))
				b.add_child(icon)
				icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 3)
				b.custom_minimum_size = Vector2(32, 32)
				_context.add_child(b)
			var picked := Label.new()
			picked.text = brush.selected().display_name if brush.selected() else ""
			picked.add_theme_color_override(&"font_color", ACCENT)
			picked.custom_minimum_size.x = 100
			_context.add_child(picked)
			_context.add_child(VSeparator.new())
			_add_brush_size()
		ObjectTool.Mode.WIRE:
			_add_brush_size()


## Brush size buttons (Paint and Wire tools).
func _add_brush_size() -> void:
	_context.add_child(_button("−", "Smaller brush ([)",
		func() -> void: brush.brush_radius = maxi(brush.brush_radius - 1, 0)))
	var size_label := Label.new()
	size_label.text = "%d" % (brush.brush_radius * 2 + 1)
	size_label.custom_minimum_size.x = 24
	size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_context.add_child(size_label)
	_context.add_child(_button("+", "Bigger brush (])",
		func() -> void: brush.brush_radius = mini(brush.brush_radius + 1, 8)))


func _help_text() -> String:
	var line := ""
	match tool.mode:
		ObjectTool.Mode.SELECT:
			line = "Drag an object to move it · drag its ring handle to tilt (Ctrl snaps 15°) · " + \
				"Shift+wheel or R/F tilts · drag empty space to pan"
		ObjectTool.Mode.BUILD:
			line = "LMB place (R/F tilt first) · drag existing objects · RMB or Esc back to Select · 1–%d pick" \
				% tool.defs.size()
		ObjectTool.Mode.PAINT:
			line = "LMB paint · RMB erase · Q/E material · [ ] size"
		ObjectTool.Mode.WIRE:
			line = "LMB lay wire · RMB remove · [ ] size · objects connect at the foot of their stand"
	return line + "\nWheel zoom · WASD / middle drag pan · H view · G/J wavelength · , . time · " + \
		"Space pause · Tab speed · Ctrl+Z undo · F1 hide help"


# --- Inspector ------------------------------------------------------------------------------

func _build_inspector() -> void:
	_inspector = _panel()
	_inspector.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_inspector)
	_inspect_label = RichTextLabel.new()
	_inspect_label.bbcode_enabled = true
	_inspect_label.fit_content = true
	_inspect_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_inspect_label.scroll_active = false
	_inspect_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inspect_label.add_theme_font_size_override(&"normal_font_size", 13)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_inspector.add_child(box)
	box.add_child(_inspect_label)
	_inspect_chart = SpectrumChart.new()
	box.add_child(_inspect_chart)


func _update_inspector() -> void:
	var cell := brush.hovered_cell()
	var g := world.grid
	var mouse := get_viewport().get_mouse_position()
	var over_ui := get_viewport().gui_get_hovered_control() != null
	if not g.in_bounds(cell.x, cell.y) or over_ui:
		_inspector.visible = false
		return
	_inspector.visible = true
	var lines := PackedStringArray()
	var obj: SimObject = world.objects.get(tool.hovered_id)
	if obj != null:
		lines.append(_object_text(obj))
	_inspect_chart.visible = obj != null and obj.def.kind == ObjectDef.Kind.PROBE and obj.incident_irradiance() > 0.0
	if _inspect_chart.visible:
		_inspect_chart.show_spectrum(obj.incident_spectrum(), world.light_spectrum)
	lines.append(_tile_text(g.idx(cell.x, cell.y), cell))
	_inspect_label.text = "\n".join(lines)
	_inspector.reset_size()
	var pos := mouse + Vector2(18, 18)
	var vp := get_viewport_rect().size
	if pos.x + _inspector.size.x > vp.x - 4:
		pos.x = mouse.x - 18 - _inspector.size.x
	if pos.y + _inspector.size.y > vp.y - 4:
		pos.y = mouse.y - 18 - _inspector.size.y
	_inspector.position = pos


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
	else:
		if obj.def.kind == ObjectDef.Kind.CELL:
			s += _cell_text(obj)
		elif obj.def.kind == ObjectDef.Kind.GRID_TIE:
			var n := _power.network_of(world, obj)
			if n < 0:
				return s + "\n[color=#8a93a0]not wired: run wire to its foot[/color]\n"
			return s + "\nselling %s at %.1f ¢/kWh\n" % [Readout.power(_power.network_power_w[n]),
				Market.price_per_kwh(world) * 100.0]
		s += "\nabsorbing %.1f W" % obj.absorbed_w
		if obj.temperature_k > 0.0:
			s += " · %.1f °C" % SimConst.k_to_c(obj.temperature_k)
	return s + "\n"


## What a cell makes (wired to a grid connection) or could make, and why not.
func _cell_text(obj: SimObject) -> String:
	var irr := obj.incident_irradiance() * _light.power_scale(world)
	var area := obj.def.size_m * SimConst.DEPTH_M
	if obj.power_w > 0.0:
		return "\nmaking %s  [color=#8a93a0](%.0f%% of %s)[/color]" % [Readout.power(obj.power_w),
			obj.power_w / (irr * area) * 100.0, Readout.irradiance(irr)]
	var n := _power.network_of(world, obj)
	var why := "not wired to a grid connection" if n < 0 or _power.network_grid[n] == 0 else "no light"
	return "\ncould make %s  [color=#8a93a0](%s)[/color]" % [
		Readout.power(SolarCell.object_power(obj, _light.power_scale(world))), why]


# --- Helpers --------------------------------------------------------------------------------

func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	p.add_theme_stylebox_override(&"panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_STOP   # Clicks on a panel never reach the world
	return p


func _button(text: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(action)
	return b


func _small_label() -> Label:
	var l := Label.new()
	l.add_theme_font_size_override(&"font_size", 11)
	l.add_theme_color_override(&"font_color", DIM)
	return l
