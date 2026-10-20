class_name Hud
extends Control
## Screen-space interface (design doc §16): assembles the parts and keeps them current.
## - TopBar: clock and sky, pause, speed and time jumps, money and the grid price, views.
## - ToolDock (bottom): Select, Build, Paint, Wire, Undo, Menu.
## - ToolPanel (left, above the dock): the build catalog, or Paint / Wire options.
## - InspectorPanel (top right): the selected or hovered object, or the tile under the pointer.
## - LegendPanel (bottom right): the Light / Heat view's color scale.
## - HelpMenu (F1): controls and options; the performance numbers are a toggle in the top bar.
## Reads sim state; actions go to Main, the ObjectTool and the CreativeBrush.

var world: SimWorld
var runner: Main
var brush: CreativeBrush
var tool: ObjectTool
var overlay: OverlayRenderer

var _light: LightSystem
var _heat: ThermalSystem
var _top: TopBar
var _dock: ToolDock
var _side: ToolPanel
var _inspector: InspectorPanel
var _legend: LegendPanel
var _menu: HelpMenu


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
	theme = UiTheme.build()
	_top = TopBar.new()
	add_child(_top)
	_top.setup(world, runner)
	_dock = ToolDock.new()
	add_child(_dock)
	_dock.setup(tool, toggle_help)
	_side = ToolPanel.new()
	add_child(_side)
	_side.setup(world, tool, brush)
	_inspector = InspectorPanel.new()
	add_child(_inspector)
	_inspector.setup(world, tool, brush)
	_legend = LegendPanel.new()
	add_child(_legend)
	_legend.setup(overlay)
	_menu = HelpMenu.new()
	add_child(_menu)
	_menu.setup(tool)
	_menu.perf_toggled.connect(_top.show_perf)
	refresh_view()


## Updates the view controls and the legend after the view or wavelength changed.
func refresh_view() -> void:
	_top.refresh_view()
	_legend.refresh()


## Whether screen point `p` (viewport pixels) is over a panel, where the map ignores the pointer.
func covers(p: Vector2) -> bool:
	for c: Control in [_top, _dock, _side, _inspector, _legend, _menu]:
		if c.visible and c.get_global_rect().has_point(p):
			return true
	return false


## Shows or hides the menu.
func toggle_help() -> void:
	_menu.toggle()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"toggle_help"):
		toggle_help()


func _process(_delta: float) -> void:
	if world == null:
		return
	_top.update()
	_dock.update()
	_side.update()
	_inspector.update()
	_menu.update()
	_top.set_perf_text(_perf_text())


func _perf_text() -> String:
	return "%d fps · sim %.1f ms · light %.0f ms (%d rays) · heat %.1f ms" % [Engine.get_frames_per_second(),
		runner.sim_ms, _light.last_trace_ms, _light.stats.get("rays", 0), _heat.last_step_ms]
