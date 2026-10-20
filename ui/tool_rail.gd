class_name ToolRail
extends PanelContainer
## The column of tool buttons down the left edge (Select, Build, Paint, Wire), then Undo and
## Help. Each shows a small drawing and its key; the current tool is highlighted.

## Per ObjectTool.Mode: glyph, key, tooltip.
const TOOLS := [
	[&"select", "Esc", "Select: move and tilt objects; drag empty space to pan"],
	[&"build", "B", "Build: place optics, cells and machines from the catalog"],
	[&"paint", "T", "Paint terrain: LMB paint, RMB erase"],
	[&"wire", "V", "Wire: LMB lay, RMB remove; objects connect at the foot of their stand"],
]

var tool: ObjectTool

var _buttons: Array[Button] = []


func setup(p_tool: ObjectTool, toggle_help: Callable) -> void:
	tool = p_tool
	UiStyle.style_panel(self, 0, 8)
	set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	offset_top = UiStyle.TOP_BAR_H
	custom_minimum_size.x = UiStyle.RAIL_W
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 8)
	add_child(col)
	var group := ButtonGroup.new()
	for m in TOOLS.size():
		var b := _rail_button(TOOLS[m][0], TOOLS[m][1], TOOLS[m][2], tool.set_mode.bind(m))
		b.toggle_mode = true
		b.button_group = group
		col.add_child(b)
		_buttons.append(b)
	col.add_child(HSeparator.new())
	col.add_child(_rail_button(&"undo", "", "Undo (Ctrl+Z)",
		func() -> void: tool.world.enqueue(UndoCommand.new())))
	col.add_child(UiStyle.spacer(true))
	col.add_child(_rail_button(&"help", "F1", "Show or hide the help line", toggle_help))


func update() -> void:
	for m in _buttons.size():
		_buttons[m].set_pressed_no_signal(m == tool.mode)


func _rail_button(glyph: StringName, key: String, tip: String, action: Callable) -> Button:
	var b := UiStyle.button("", tip, action)
	b.custom_minimum_size = Vector2(48, 48)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override(&"separation", 1)
	var icon := ToolIcon.new(glyph)
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(icon)
	if key != "":
		var l := UiStyle.small_label(key)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		l.add_theme_font_size_override(&"font_size", 10)
		col.add_child(l)
	b.add_child(col)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return b
