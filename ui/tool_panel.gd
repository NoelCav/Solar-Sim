class_name ToolPanel
extends PanelContainer
## The panel at the left, above the tool dock, holding the current tool's options:
## - Build: the catalog: every item, in sections (optics, power, machines, tools) with a button
##   per section that jumps down to it, and a search; each item is a card with its drawing and
##   at-a-glance number (Readout.item_stats; all of them in its tooltip). Click a card to pick
##   the item and click the map to place as many as you like (click the card again or RMB to
##   drop it); or drag a card onto the map to place one (R / F tilt it on the way).
## - Paint: material swatches and brush size. Wire: brush size and how wiring works.
## Hidden for Select.

const CATEGORY_NAMES := ["Optics", "Power", "Machines", "Tools"]
const CATEGORY_GLYPHS := [&"optics", &"power", &"machines", &"tools"]

var world: SimWorld
var tool: ObjectTool
var brush: CreativeBrush

var _content: VBoxContainer
var _cards: VBoxContainer
var _card_items := {}          ## Card button -> index into tool.defs
var _search: LineEdit
var _scroll: ScrollContainer
var _headers := {}             ## Category -> its section header in the card list
var _key := []                 ## What the panel was built for; rebuilt when it changes
var _shown_selected := -2      ## Item the cards were last styled for
var _followed := -2            ## Item whose section the list last jumped to
var _dragging := false         ## A card is held: letting go over the map places the item
var _was_picked := false       ## The held card's item was already picked when it was pressed


func setup(p_world: SimWorld, p_tool: ObjectTool, p_brush: CreativeBrush) -> void:
	world = p_world
	tool = p_tool
	brush = p_brush
	UiStyle.style_panel(self, 12, 12)
	set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	offset_left = UiStyle.GAP
	offset_top = UiStyle.TOP_BAR_H + UiStyle.GAP
	offset_right = UiStyle.GAP + UiStyle.SIDE_W
	offset_bottom = -(UiStyle.DOCK_H + 2.0 * UiStyle.GAP)
	_content = VBoxContainer.new()
	_content.add_theme_constant_override(&"separation", 10)
	add_child(_content)


func update() -> void:
	visible = tool.mode != ObjectTool.Mode.SELECT
	if not visible:
		return
	# Picking an item only restyles the cards: rebuilding would free the card being dragged.
	var key := [tool.mode, brush.selected_index, brush.brush_radius]
	if key != _key:
		_key = key
		_rebuild()
	# A newly picked item (1–9, entering Build) brings its section into view, once.
	var building := tool.mode == ObjectTool.Mode.BUILD
	if building and tool.selected != _followed and tool.selected >= 0 and tool.selected < tool.defs.size() \
			and (_search == null or _search.text == ""):
		_jump(tool.defs[tool.selected].category)
	_followed = tool.selected if building else -2
	if tool.selected != _shown_selected:
		_style_cards()


func _rebuild() -> void:
	var keep_search := _search.text if _search != null else ""
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	_search = null
	_scroll = null
	_cards = null
	_card_items.clear()
	match tool.mode:
		ObjectTool.Mode.BUILD:
			_build_catalog(keep_search)
		ObjectTool.Mode.PAINT:
			_build_paint()
		ObjectTool.Mode.WIRE:
			_content.add_child(UiStyle.label("Wire", 16))
			_build_wire_palette()
			_add_hint("Drag a line: it bends once (Shift flips the bend). Right-drag erases. Press on a device "
				+ "to start at its foot. Surface cells conduct, so touching cells need one connection.")


# --- Build catalog --------------------------------------------------------------------------

func _build_catalog(search: String) -> void:
	var head := HBoxContainer.new()
	head.add_child(UiStyle.label("Build", 16))
	head.add_child(UiStyle.spacer())
	head.add_child(UiStyle.small_label("Creative: free" if world.creative else ""))
	_content.add_child(head)
	_search = LineEdit.new()
	_search.placeholder_text = "Search: lens, cell, wire…"
	_search.text = search
	_search.clear_button_enabled = true
	_search.text_changed.connect(func(_t: String) -> void: _fill_cards())
	_content.add_child(_search)
	var jumps := HFlowContainer.new()
	jumps.add_theme_constant_override(&"h_separation", 4)
	jumps.add_theme_constant_override(&"v_separation", 4)
	for c in CATEGORY_NAMES.size():
		jumps.add_child(UiStyle.icon_button(CATEGORY_GLYPHS[c], CATEGORY_NAMES[c], "Jump to " + CATEGORY_NAMES[c],
			_jump.bind(c)))
	_content.add_child(jumps)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_content.add_child(_scroll)
	_cards = VBoxContainer.new()
	_cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards.add_theme_constant_override(&"separation", 6)
	_scroll.add_child(_cards)
	_fill_cards()
	_add_hint("Click an item, then click the map to place it (again and again), or drag one onto the map. "
		+ "Drag lays a run of surface cells. Right-click drops the item.")


## Every item, in sections; a search keeps the items whose name or section matches.
func _fill_cards() -> void:
	for c in _cards.get_children():
		_cards.remove_child(c)
		c.queue_free()
	_card_items.clear()
	_headers.clear()
	for c in CATEGORY_NAMES.size():
		var items := _items(c, _search.text)
		if items.is_empty():
			continue
		var head := _section_header(c)
		_headers[c] = head
		_cards.add_child(head)
		for k: int in items:
			var card := _card(k)
			_card_items[card] = k
			_cards.add_child(card)
	_style_cards()


func _section_header(category: int) -> Control:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override(&"separation", 8)
	var icon := ToolIcon.new(CATEGORY_GLYPHS[category], Vector2(20, 20))
	icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(icon)
	row.add_child(UiStyle.label(CATEGORY_NAMES[category], 15, UiStyle.ACCENT))
	var rule := HSeparator.new()
	rule.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(rule)
	return row


## Scrolls the catalog to a section.
func _jump(category: int) -> void:
	if _scroll == null or not _headers.has(category):
		return
	await get_tree().process_frame   # The list may have just been built: wait for its layout
	if _scroll != null and _headers.has(category):
		_scroll.scroll_vertical = int((_headers[category] as Control).position.y)


func _style_cards() -> void:
	_shown_selected = tool.selected
	for card: Button in _card_items:
		UiStyle.card(card, tool.mode == ObjectTool.Mode.BUILD and _card_items[card] == tool.selected)


## Indices into tool.defs in `category` that match `search` (all of them for an empty one).
func _items(category: int, search: String) -> Array[int]:
	var out: Array[int] = []
	var needle := search.strip_edges().to_lower()
	for k in tool.defs.size():
		var def := tool.defs[k]
		if def.category != category:
			continue
		if needle == "" or needle in def.display_name.to_lower() or needle in CATEGORY_NAMES[category].to_lower():
			out.append(k)
	return out


func _card(k: int) -> Button:
	var def := tool.defs[k]
	var b := Button.new()
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = "%s%s\n%s" % [def.display_name, "  (%d)" % (k + 1) if k < 9 else "",
		Readout.item_stats(def, world.materials, true)]
	b.gui_input.connect(_on_card_input.bind(k))
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override(&"separation", 10)
	row.add_child(ItemIcon.new(def, Color.TRANSPARENT, Vector2(44, 36)))
	var text := VBoxContainer.new()
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override(&"separation", 2)
	text.add_child(UiStyle.label(def.display_name, 14))
	var stats := UiStyle.small_label(Readout.item_stats(def, world.materials))
	stats.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.add_child(stats)
	row.add_child(text)
	b.add_child(row)
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 8)
	b.custom_minimum_size.y = 58
	return b


## Press picks the item up (its ghost follows the pointer over the map). Letting go over the
## map places one there (a drag); letting go on the panel keeps it picked for clicking onto the
## map (a click), or drops it if it was already picked.
func _on_card_input(event: InputEvent, k: int) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT:
		return
	if mb.pressed:
		_was_picked = tool.selected == k
		tool.pick_item(k)
		_dragging = true
	elif _dragging:
		_dragging = false
		if not get_global_rect().has_point(mb.global_position):
			tool.place_selected()
			tool.selected = -1
		elif _was_picked:
			tool.selected = -1


# --- Paint and wire -------------------------------------------------------------------------

func _build_paint() -> void:
	_content.add_child(UiStyle.label("Paint terrain", 16))
	var grid := GridContainer.new()
	grid.columns = 7
	grid.add_theme_constant_override(&"h_separation", 4)
	grid.add_theme_constant_override(&"v_separation", 4)
	var group := ButtonGroup.new()
	for k in brush.palette.size():
		var def := brush.palette[k]
		var b := UiStyle.toggle("", def.display_name, func() -> void: brush.selected_index = k, group)
		b.set_pressed_no_signal(k == brush.selected_index)
		b.custom_minimum_size = Vector2(36, 36)
		var icon := ItemIcon.new(null, def.color, Vector2(28, 28))
		b.add_child(icon)
		icon.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 4)
		grid.add_child(b)
	_content.add_child(grid)
	_content.add_child(UiStyle.label(brush.selected().display_name if brush.selected() else "", 14, UiStyle.ACCENT))
	_add_brush_size()
	_add_hint("LMB paint · RMB erase · Q / E material · [ ] size")


## The colors wire can be drawn in: wires of different colors cross without touching.
func _build_wire_palette() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 6)
	var group := ButtonGroup.new()
	for c in ConduitNetworks.CHANNELS:
		var tip := "%s wire: wires of different colors cross without touching" % WireRenderer.CHANNEL_NAMES[c]
		var b := UiStyle.toggle("", tip, func() -> void: brush.wire_channel = c, group)
		b.set_pressed_no_signal(c == brush.wire_channel)
		b.custom_minimum_size = Vector2(44, 34)
		var chip := ColorRect.new()
		chip.color = WireRenderer.CHANNEL_COLORS[c]
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(chip)
		chip.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT, Control.PRESET_MODE_MINSIZE, 8)
		row.add_child(b)
	_content.add_child(row)


func _add_brush_size() -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 6)
	row.add_child(UiStyle.label("Brush"))
	row.add_child(UiStyle.button("−", "Smaller brush ([)",
		func() -> void: brush.brush_radius = maxi(brush.brush_radius - 1, 0)))
	var size_label := UiStyle.label("%d" % (brush.brush_radius * 2 + 1))
	size_label.custom_minimum_size.x = 24
	size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	row.add_child(size_label)
	row.add_child(UiStyle.button("+", "Bigger brush (])",
		func() -> void: brush.brush_radius = mini(brush.brush_radius + 1, 8)))
	_content.add_child(row)


func _add_hint(text: String) -> void:
	if tool.mode != ObjectTool.Mode.BUILD:   # Pins the hint to the bottom (the catalog fills Build)
		_content.add_child(UiStyle.spacer(true))
	var l := UiStyle.small_label(text)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_content.add_child(l)
