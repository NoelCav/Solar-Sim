class_name Hud
extends Control
## Screen-space interface (design doc §16): assembles the parts and keeps them current.
## - TopBar: clock and sky, pause, speed and time jumps, money and the grid price, views.
## - ToolRail (left edge): Select, Build, Paint, Wire, Undo, Help.
## - ToolPanel (beside the rail): the build catalog, or Paint / Wire options.
## - InspectorPanel (top right): the selected or hovered object, or the tile under the pointer.
## - LegendPanel (bottom right): the Light / Heat view's color scale.
## - The help line (bottom, F1) with performance numbers.
## Reads sim state; actions go to Main, the ObjectTool and the CreativeBrush.

var world: SimWorld
var runner: Main
var brush: CreativeBrush
var tool: ObjectTool
var overlay: OverlayRenderer

var _light: LightSystem
var _heat: ThermalSystem
var _top: TopBar
var _rail: ToolRail
var _side: ToolPanel
var _inspector: InspectorPanel
var _legend: LegendPanel
var _help: Label


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
	_top = TopBar.new()
	add_child(_top)
	_top.setup(world, runner)
	_rail = ToolRail.new()
	add_child(_rail)
	_rail.setup(tool, toggle_help)
	_side = ToolPanel.new()
	add_child(_side)
	_side.setup(world, tool, brush)
	_inspector = InspectorPanel.new()
	add_child(_inspector)
	_inspector.setup(world, tool, brush)
	_legend = LegendPanel.new()
	add_child(_legend)
	_legend.setup(overlay)
	_help = UiStyle.label("", 12, UiStyle.DIM)
	var help_box := UiStyle.panel(6, 6)
	help_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	help_box.add_child(_help)
	add_child(help_box)
	help_box.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	help_box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	help_box.grow_vertical = Control.GROW_DIRECTION_BEGIN
	help_box.offset_bottom = -UiStyle.GAP
	refresh_view()


## Updates the view controls and the legend after the view or wavelength changed.
func refresh_view() -> void:
	_top.refresh_view()
	_legend.refresh()


## Shows or hides the help line.
func toggle_help() -> void:
	_help.get_parent().visible = not _help.get_parent().visible


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_help"):
		toggle_help()


func _process(_delta: float) -> void:
	if world == null:
		return
	_top.update()
	_rail.update()
	_side.update()
	_inspector.update()
	_help.text = _help_text()


func _help_text() -> String:
	var line := ""
	match tool.mode:
		ObjectTool.Mode.SELECT:
			line = "Drag an object to move it · drag its ring handle to tilt (Ctrl snaps 15°) · " + \
				"R/F or Shift+wheel tilts · drag empty space to pan"
		ObjectTool.Mode.BUILD:
			line = "LMB place (R/F tilt first) · drag an item onto the map · RMB or Esc back to Select · 1–9 pick"
		ObjectTool.Mode.PAINT:
			line = "LMB paint · RMB erase · Q/E material · [ ] size"
		ObjectTool.Mode.WIRE:
			line = "LMB lay wire · RMB remove · [ ] size · objects connect at the foot of their stand"
	return line + "\nWheel zoom · WASD pan · H view · G/J wavelength · , . time · Space pause · Tab speed · " + \
		"Ctrl+Z undo · F1 help\n%d fps · sim %.1f ms/frame · light %.0f ms (%d rays) · heat %.1f ms" % [
		Engine.get_frames_per_second(), runner.sim_ms, _light.last_trace_ms,
		_light.stats.get("rays", 0), _heat.last_step_ms]
