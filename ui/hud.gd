class_name Hud
extends Control
## Screen-space interface (design doc §16): status (top left), view bar and legend
## (top right), an inspector that follows the cursor, and a help bar (bottom, F1).
## Reads sim state only; view changes go back to Main.

const PANEL_BG := Color(0.05, 0.07, 0.10, 0.80)
const DIM := Color(0.70, 0.75, 0.82)
const ACCENT := Color(1.0, 0.85, 0.45)

var world: SimWorld
var runner: Main
var brush: CreativeBrush
var tool: ObjectTool
var overlay: OverlayRenderer

var _light: LightSystem
var _heat: ThermalSystem
var _status: Label
var _perf: Label
var _view_buttons: Array[Button] = []
var _view_panel: PanelContainer
var _legend_panel: PanelContainer
var _legend_title: Label
var _legend_bar: TextureRect
var _legend_lo: Label
var _legend_hi: Label
var _view_hint: Label
var _inspector: PanelContainer
var _inspect_label: RichTextLabel
var _help: PanelContainer
var _help_label: Label


func setup(p_world: SimWorld, p_runner: Main, p_brush: CreativeBrush, p_tool: ObjectTool,
		p_overlay: OverlayRenderer) -> void:
	world = p_world
	runner = p_runner
	brush = p_brush
	tool = p_tool
	overlay = p_overlay
	_light = world.get_system(&"light")
	_heat = world.get_system(&"heat")
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build_status()
	_build_view_bar()
	_build_inspector()
	_build_help()
	refresh_view()


## Updates the view bar and legend after the view changed.
func refresh_view() -> void:
	for v in _view_buttons.size():
		_view_buttons[v].set_pressed_no_signal(v == runner.view)
	_view_hint.text = ViewMode.HINTS[runner.view]
	var lg := overlay.legend()
	_legend_bar.visible = not lg.is_empty()
	_legend_lo.get_parent().visible = not lg.is_empty()
	_legend_title.visible = not lg.is_empty()
	if not lg.is_empty():
		_legend_title.text = lg.title
		var tex := GradientTexture2D.new()
		tex.gradient = lg.gradient
		tex.width = 220
		tex.height = 10
		_legend_bar.texture = tex
		_legend_lo.text = lg.lo
		_legend_hi.text = lg.hi


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_help"):
		_help.visible = not _help.visible


func _process(_delta: float) -> void:
	if world == null:
		return
	_update_status()
	_update_help()
	_update_inspector()


# --- Status -------------------------------------------------------------------------------

func _build_status() -> void:
	var panel := _panel()
	panel.position = Vector2(10, 10)
	add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override(&"separation", 2)
	panel.add_child(box)
	_status = Label.new()
	box.add_child(_status)
	_perf = Label.new()
	_perf.add_theme_font_size_override(&"font_size", 11)
	_perf.add_theme_color_override(&"font_color", DIM)
	box.add_child(_perf)


func _update_status() -> void:
	var tod := world.time_of_day() * 24.0
	var clock := "Day %d   %02d:%02d   %s" % [world.day_number() + 1, int(tod), int(fmod(tod, 1.0) * 60.0),
		"⏸ paused" if runner.paused else "▶ %d×" % runner.speed]
	var sun := "Sun %.0f°   %.0f W/m²   air %.1f °C" % [rad_to_deg(world.sun_elevation), world.sun_dni,
		SimConst.k_to_c(world.ambient_k)] if world.sun_is_up \
		else "Night   air %.1f °C" % SimConst.k_to_c(world.ambient_k)
	_status.text = clock + "\n" + sun
	_perf.text = "%d fps · sim %.1f ms/frame · light pass %.0f ms (%d rays) · heat %.1f ms" % [
		Engine.get_frames_per_second(), runner.sim_ms, _light.last_trace_ms,
		_light.stats.get("rays", 0), _heat.last_step_ms]


# --- View bar and legend --------------------------------------------------------------------

func _build_view_bar() -> void:
	var panel := _panel()
	_view_panel = panel
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
		var b := Button.new()
		b.text = ViewMode.NAMES[v]
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = ViewMode.HINTS[v] + "  (H cycles)"
		b.pressed.connect(runner.set_view.bind(v))
		bar.add_child(b)
		_view_buttons.append(b)
	_view_hint = Label.new()
	_view_hint.add_theme_font_size_override(&"font_size", 11)
	_view_hint.add_theme_color_override(&"font_color", DIM)
	box.add_child(_view_hint)
	_legend_title = Label.new()
	_legend_title.add_theme_font_size_override(&"font_size", 12)
	box.add_child(_legend_title)
	_legend_bar = TextureRect.new()
	_legend_bar.custom_minimum_size = Vector2(220, 10)
	_legend_bar.stretch_mode = TextureRect.STRETCH_SCALE
	box.add_child(_legend_bar)
	var ends := HBoxContainer.new()
	box.add_child(ends)
	_legend_lo = Label.new()
	_legend_lo.add_theme_font_size_override(&"font_size", 11)
	_legend_lo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ends.add_child(_legend_lo)
	_legend_hi = Label.new()
	_legend_hi.add_theme_font_size_override(&"font_size", 11)
	ends.add_child(_legend_hi)


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
	_inspector.add_child(_inspect_label)


func _update_inspector() -> void:
	var cell := brush.hovered_cell()
	var g := world.grid
	var mouse := get_viewport().get_mouse_position()
	var over_ui := _view_panel.get_global_rect().has_point(mouse) or (_help.visible \
		and _help.get_global_rect().has_point(mouse))
	if not g.in_bounds(cell.x, cell.y) or over_ui:
		_inspector.visible = false
		return
	_inspector.visible = true
	var lines := PackedStringArray()
	var obj: SimObject = world.objects.get(tool.hovered_id)
	if obj != null:
		lines.append(_object_text(obj))
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
	if def == null or not def.is_solid() and def.phase != MaterialDef.Phase.LIQUID:
		return s
	var light := _light_text(i, def)
	return s + ("\n" + light if light != "" else "")


func _light_text(i: int, def: MaterialDef) -> String:
	var tp := _light.tile_power
	if tp.size() != world.grid.size():
		return ""
	var area := SimConst.TILE_M * SimConst.DEPTH_M
	var scale := _light.power_scale(world) / area
	var irr := tp[i] * scale
	if irr <= 0.0:
		return "[color=#8a93a0]in shadow[/color]" if world.sun_is_up else ""
	var absorptivity := 0.0
	for b in Spectrum.BIN_COUNT:
		absorptivity += def.surface_absorptivity[b] * Spectrum.AM15_SHARE[b]
	var suns := irr / maxf(world.sun_dni * maxf(absorptivity, 0.05), 1.0)
	var o := i * Spectrum.BAND_COUNT
	var bp := _light.band_power
	var head := "[color=#ffd873]≈%.0f× sun[/color]" % suns if suns >= 1.5 else "in sun"
	return "%s · absorbing %s\n[color=#8a93a0]UV %s · visible %s · IR %s[/color]" % [head, _irr(irr),
		_irr(bp[o] * scale), _irr(bp[o + 1] * scale), _irr(bp[o + 2] * scale)]


func _object_text(obj: SimObject) -> String:
	var s := "[b][color=#ffd873]%s[/color][/b]  [color=#8a93a0]%.0f°[/color]" % [obj.def.display_name,
		rad_to_deg(obj.angle)]
	if obj.def.kind == ObjectDef.Kind.PROBE:
		var irr := obj.probe_irradiance()
		s += "\nreads %s  (%.1f× sun)" % [_irr(irr), irr / maxf(world.sun_dni, 1.0)]
		var area := obj.def.size_m * SimConst.DEPTH_M
		var bands := PackedFloat32Array([0, 0, 0])
		for b in Spectrum.BIN_COUNT:
			bands[Spectrum.BAND_OF[b]] += obj.incident[b] / area
		s += "\n[color=#8a93a0]UV %s · visible %s · IR %s[/color]" % [_irr(bands[0]), _irr(bands[1]), _irr(bands[2])]
	else:
		s += "\nabsorbing %.1f W" % obj.absorbed_w
	return s + "\n"


static func _irr(w_m2: float) -> String:
	if w_m2 >= 1e6:
		return "%.1f MW/m²" % (w_m2 / 1e6)
	if w_m2 >= 1e4:
		return "%.0f kW/m²" % (w_m2 / 1e3)
	if w_m2 >= 1e3:
		return "%.1f kW/m²" % (w_m2 / 1e3)
	return "%.0f W/m²" % w_m2


# --- Help -----------------------------------------------------------------------------------

func _build_help() -> void:
	_help = _panel()
	add_child(_help)
	_help.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_help.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_MINSIZE, 10)
	_help_label = Label.new()
	_help_label.add_theme_font_size_override(&"font_size", 12)
	_help.add_child(_help_label)


func _update_help() -> void:
	var tool_line := "Tile brush: %s (size %d) — LMB paint · RMB erase · Q/E material · [ ] size" % [
		brush.selected().display_name, brush.brush_radius * 2 + 1] if tool.selected < 0 \
		else "Placing %s — LMB place or drag · RMB remove" % tool.selected_def().display_name
	_help_label.text = tool_line + "\n" + \
		"1–%d objects · 0 brush · R/F rotate (Shift fine) · X delete · H view · , . time ±1 h · " % tool.defs.size() + \
		"Space pause · Tab speed · Ctrl+Z undo · F1 hide"


func _panel() -> PanelContainer:
	var p := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.set_corner_radius_all(6)
	sb.set_content_margin_all(8)
	p.add_theme_stylebox_override(&"panel", sb)
	p.mouse_filter = Control.MOUSE_FILTER_PASS
	return p
