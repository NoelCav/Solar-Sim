class_name HelpMenu
extends PanelContainer
## The menu (F1, or the dock's Menu button): what the mouse and keys do in the current tool, and
## options: whether the performance readout shows in the top bar. Replaces the help line that
## used to sit over the map.

signal perf_toggled(shown: bool)

const COMMON := "Wheel zoom  ·  WASD or middle-drag pan  ·  H cycles the view  ·  G / J wavelength  ·  " \
	+ ", . jump the clock  ·  Space pause  ·  Tab speed  ·  Ctrl+Z undo  ·  X / Delete remove  ·  " \
	+ "R / F or Shift+wheel tilt"

var tool: ObjectTool

var _hint: RichTextLabel
var _shown_mode := -1


func setup(p_tool: ObjectTool) -> void:
	tool = p_tool
	UiStyle.style_panel(self, 12, 16)
	set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BOTH
	custom_minimum_size.x = 520
	visible = false
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 10)
	add_child(col)
	var head := HBoxContainer.new()
	head.add_child(UiStyle.label("Controls", 18, UiStyle.ACCENT))
	head.add_child(UiStyle.spacer())
	head.add_child(UiStyle.button("Close", "Close the menu (F1)", func() -> void: visible = false))
	col.add_child(head)
	_hint = RichTextLabel.new()
	_hint.bbcode_enabled = true
	_hint.fit_content = true
	_hint.scroll_active = false
	col.add_child(_hint)
	col.add_child(HSeparator.new())
	var perf := CheckButton.new()
	perf.text = "Show performance numbers in the top bar"
	perf.focus_mode = Control.FOCUS_NONE
	perf.toggled.connect(func(on: bool) -> void: perf_toggled.emit(on))
	col.add_child(perf)


func update() -> void:
	if not visible or tool.mode == _shown_mode:
		return
	_shown_mode = tool.mode
	var line := ""
	match tool.mode:
		ObjectTool.Mode.SELECT:
			line = "[b]Select[/b]: drag an object to move it, drag its ring handle to tilt (Ctrl snaps 15°), " \
				+ "drag empty space or right-drag to pan"
		ObjectTool.Mode.BUILD:
			line = "[b]Build[/b]: click an item, then click the map to place it (again and again), or drag a card " \
				+ "onto the map. Drag lays a run of surface cells. Right-click drops the item; right-drag pans"
		ObjectTool.Mode.PAINT:
			line = "[b]Paint[/b]: left paint, right erase, Q / E material, [ ] brush size"
		ObjectTool.Mode.WIRE:
			line = "[b]Wire[/b]: drag a line (it bends once; Shift flips the bend), right-drag erases. Press on a " \
				+ "device to start at its foot. Surface cells conduct, so touching cells need one connection"
	_hint.text = line + "\n\n[color=#9aa4b2]" + COMMON + "[/color]"


func toggle() -> void:
	visible = not visible
	_shown_mode = -1
