class_name ToolPanel
extends PanelContainer
## The side panel next to the tool rail, holding the current tool's options:
## - Build: the catalog, with search and category tabs; each item is a card with its
##   at-a-glance number (Readout.item_stats; all of them in its tooltip). Click a card to pick
##   the item and click the map to place as many as you like (click the card again or RMB to
##   drop it); or drag a card onto the map to place one (R / F tilt it on the way).
## - Paint: material swatches and brush size. Wire: brush size and how wiring works.
## Hidden for Select.

const CATEGORY_NAMES := ["Optics", "Power", "Machines", "Tools"]

var world: SimWorld
var tool: ObjectTool
var brush: CreativeBrush

var _content: VBoxContainer
var _cards: VBoxContainer
var _card_items := {}          ## Card button -> index into tool.defs
var _search: LineEdit
var _category := ObjectDef.Category.OPTICS
var _key := []                 ## What the panel was built for; rebuilt when it changes
var _shown_selected := -2      ## Item the cards were last styled for
var _followed := -2            ## Item whose category the tabs last switched to
var _dragging := false         ## A card is held: letting go over the map places the item
var _was_picked := false       ## The held card's item was already picked when it was pressed


func setup(p_world: SimWorld, p_tool: ObjectTool, p_brush: CreativeBrush) -> void:
	world = p_world
	tool = p_tool
	brush = p_brush
	UiStyle.style_panel(self, 0, 12)
	set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	offset_left = UiStyle.RAIL_W
	offset_top = UiStyle.TOP_BAR_H
	offset_right = UiStyle.RAIL_W + UiStyle.SIDE_W
	_content = VBoxContainer.new()
	_content.add_theme_constant_override(&"separation", 10)
	add_child(_content)


func update() -> void:
	visible = tool.mode != ObjectTool.Mode.SELECT
	if not visible:
		return
	# A newly picked item (1–9, entering Build) brings its category into view, once: after that
	# the tabs browse freely.
	var building := tool.mode == ObjectTool.Mode.BUILD
	if building and tool.selected != _followed and tool.selected >= 0 and tool.selected < tool.defs.size() \
			and (_search == null or _search.text == ""):
		_category = tool.defs[tool.selected].category
	_followed = tool.selected if building else -2
	# Picking an item only restyles the cards: rebuilding would free the card being dragged.
	var key := [tool.mode, brush.selected_index, brush.brush_radius, _category]
	if key != _key:
		_key = key
		_rebuild()
	if tool.selected != _shown_selected:
		_style_cards()


func _rebuild() -> void:
	var keep_search := _search.text if _search != null else ""
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	_search = null
	_cards = null
	_card_items.clear()
	match tool.mode:
		ObjectTool.Mode.BUILD:
			_build_catalog(keep_search)
		ObjectTool.Mode.PAINT:
			_build_paint()
		ObjectTool.Mode.WIRE:
			_content.add_child(UiStyle.label("Wire", 16))
			_add_brush_size()
			_add_hint("LMB lay wire · RMB remove · [ ] size\nObjects connect at the foot of their stand. "
				+ "Run wire from cells to a Grid Connection to sell their power.")


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
	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override(&"separation", 4)
	var group := ButtonGroup.new()
	for c in CATEGORY_NAMES.size():
		if _items(c, "").is_empty():
			continue
		var b := UiStyle.toggle(CATEGORY_NAMES[c], "", func() -> void:
			_category = c as ObjectDef.Category
			_search.clear(), group)
		b.set_pressed_no_signal(c == _category)
		UiStyle.pill(b)
		tabs.add_child(b)
	_content.add_child(tabs)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_content.add_child(scroll)
	_cards = VBoxContainer.new()
	_cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_cards.add_theme_constant_override(&"separation", 6)
	scroll.add_child(_cards)
	_fill_cards()
	_add_hint("Click an item, then click the map to place it (again and again) · or drag one onto the "
		+ "map\nR / F tilt · Alt floats · RMB or the card again drops it · 1–9 pick")


## The cards for the current category, or for the search across all categories.
func _fill_cards() -> void:
	for c in _cards.get_children():
		_cards.remove_child(c)
		c.queue_free()
	_card_items.clear()
	for k: int in _items(_category, _search.text):
		var card := _card(k)
		_card_items[card] = k
		_cards.add_child(card)
	_style_cards()


func _style_cards() -> void:
	_shown_selected = tool.selected
	for card: Button in _card_items:
		UiStyle.card(card, tool.mode == ObjectTool.Mode.BUILD and _card_items[card] == tool.selected)


## Indices into tool.defs in `category`, or matching `search` in any category when it isn't empty.
func _items(category: int, search: String) -> Array[int]:
	var out: Array[int] = []
	var needle := search.strip_edges().to_lower()
	for k in tool.defs.size():
		var def := tool.defs[k]
		if needle != "":
			if needle in def.display_name.to_lower() or needle in CATEGORY_NAMES[def.category].to_lower():
				out.append(k)
		elif def.category == category:
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
