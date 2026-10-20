class_name ToolDock
extends PanelContainer
## The tool bar along the bottom of the screen: Select, Build, Paint and Wire, then Undo, and the
## Menu (controls and options). Each button is a drawing over its name and key; the current tool is
## highlighted. The catalog and the other options open above it (ToolPanel).

## Per ObjectTool.Mode: glyph, label, key, tooltip.
const TOOLS := [
	[&"select", "Select", "Esc", "Select: move and tilt objects; drag empty space to pan"],
	[&"build", "Build", "B", "Build: pick optics, cells and machines from the catalog and place them"],
	[&"paint", "Paint", "T", "Paint terrain: LMB paint, RMB erase"],
	[&"wire", "Wire", "V", "Wire: drag a line; objects connect at the foot of their stand"],
]

var tool: ObjectTool

var _buttons: Array[Button] = []


func setup(p_tool: ObjectTool, toggle_menu: Callable) -> void:
	tool = p_tool
	UiStyle.style_panel(self, 12, 8)
	set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	grow_horizontal = Control.GROW_DIRECTION_BOTH
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_bottom = -UiStyle.GAP
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 6)
	add_child(row)
	var group := ButtonGroup.new()
	for m in TOOLS.size():
		var b := _dock_button(TOOLS[m][0], TOOLS[m][1], TOOLS[m][2], TOOLS[m][3], tool.set_mode.bind(m))
		b.toggle_mode = true
		b.button_group = group
		row.add_child(b)
		_buttons.append(b)
	row.add_child(VSeparator.new())
	row.add_child(_dock_button(&"undo", "Undo", "Ctrl+Z", "Undo the last gesture",
		func() -> void: tool.world.enqueue(UndoCommand.new())))
	row.add_child(VSeparator.new())
	row.add_child(_dock_button(&"menu", "Menu", "F1", "Controls and options", toggle_menu))


func update() -> void:
	for m in _buttons.size():
		_buttons[m].set_pressed_no_signal(m == tool.mode)


func _dock_button(glyph: StringName, label: String, key: String, tip: String, action: Callable) -> Button:
	var b := UiStyle.button("", tip, action)
	b.custom_minimum_size = Vector2(72, UiStyle.DOCK_H - 16.0)
	var col := VBoxContainer.new()
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.alignment = BoxContainer.ALIGNMENT_CENTER
	col.add_theme_constant_override(&"separation", 2)
	var icon := ToolIcon.new(glyph, Vector2(26, 26))
	icon.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	col.add_child(icon)
	var name_label := UiStyle.label(label, 12)
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(name_label)
	var key_label := UiStyle.small_label(key)
	key_label.add_theme_font_size_override(&"font_size", 10)
	key_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	col.add_child(key_label)
	b.add_child(col)
	col.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 4)
	return b
