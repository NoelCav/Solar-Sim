class_name UiTheme
extends RefCounted
## The Godot Theme every part of the interface inherits (set once on the Hud): font, buttons,
## text fields, menus, sliders, scroll bars and tooltips in one dark, soft-cornered look.
## UiStyle holds the colors and the factories for one-off boxes; this is the default for
## controls nobody styled by hand.

const FONT_NAMES: PackedStringArray = ["Segoe UI", "Inter", "Roboto", "SF Pro Text", "Helvetica Neue", "Arial"]
const FONT_SIZE := 14

const BUTTON := Color(0.13, 0.16, 0.20)
const BUTTON_HOVER := Color(0.18, 0.22, 0.28)
const BUTTON_DOWN := Color(0.10, 0.12, 0.16)
const TEXT := Color(0.90, 0.93, 0.97)
const TEXT_DIM := Color(0.62, 0.68, 0.76)
const EDGE := Color(0.22, 0.26, 0.32)


## The theme.
static func build() -> Theme:
	var t := Theme.new()
	var font := SystemFont.new()
	font.font_names = FONT_NAMES
	font.antialiasing = TextServer.FONT_ANTIALIASING_LCD
	t.default_font = font
	t.default_font_size = FONT_SIZE
	_buttons(t)
	_fields(t)
	_menus(t)
	_sliders(t)
	_scrolls(t)
	_misc(t)
	return t


static func _flat(bg: Color, radius := 7, hmargin := 12, vmargin := 7, edge := Color.TRANSPARENT) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = hmargin
	sb.content_margin_right = hmargin
	sb.content_margin_top = vmargin
	sb.content_margin_bottom = vmargin
	if edge.a > 0.0:
		sb.border_color = edge
		sb.set_border_width_all(1)
	return sb


static func _buttons(t: Theme) -> void:
	for type: StringName in [&"Button", &"OptionButton", &"MenuButton"]:
		t.set_stylebox(&"normal", type, _flat(BUTTON, 7, 12, 7, EDGE))
		t.set_stylebox(&"hover", type, _flat(BUTTON_HOVER, 7, 12, 7, EDGE.lightened(0.2)))
		t.set_stylebox(&"pressed", type, _flat(UiStyle.ACCENT_BG, 7, 12, 7, UiStyle.ACCENT))
		t.set_stylebox(&"hover_pressed", type, _flat(UiStyle.ACCENT_BG.lightened(0.08), 7, 12, 7, UiStyle.ACCENT))
		t.set_stylebox(&"disabled", type, _flat(BUTTON.darkened(0.3), 7, 12, 7, EDGE.darkened(0.3)))
		t.set_stylebox(&"focus", type, StyleBoxEmpty.new())
		t.set_color(&"font_color", type, TEXT)
		t.set_color(&"font_hover_color", type, Color.WHITE)
		t.set_color(&"font_pressed_color", type, UiStyle.ACCENT)
		t.set_color(&"font_hover_pressed_color", type, UiStyle.ACCENT)
		t.set_color(&"font_disabled_color", type, TEXT_DIM.darkened(0.3))
	t.set_stylebox(&"normal", &"CheckBox", StyleBoxEmpty.new())
	t.set_color(&"font_color", &"CheckBox", TEXT)


static func _fields(t: Theme) -> void:
	t.set_stylebox(&"normal", &"LineEdit", _flat(Color(0.06, 0.08, 0.10), 7, 10, 7, EDGE))
	t.set_stylebox(&"focus", &"LineEdit", _flat(Color(0.06, 0.08, 0.10), 7, 10, 7, UiStyle.ACCENT))
	t.set_color(&"font_color", &"LineEdit", TEXT)
	t.set_color(&"font_placeholder_color", &"LineEdit", TEXT_DIM.darkened(0.2))
	t.set_color(&"caret_color", &"LineEdit", UiStyle.ACCENT)


static func _menus(t: Theme) -> void:
	var panel := _flat(UiStyle.PANEL_BG, 8, 6, 6, UiStyle.PANEL_EDGE)
	t.set_stylebox(&"panel", &"PopupMenu", panel)
	t.set_stylebox(&"panel", &"PopupPanel", panel)
	t.set_stylebox(&"hover", &"PopupMenu", _flat(BUTTON_HOVER, 5, 8, 4))
	t.set_color(&"font_color", &"PopupMenu", TEXT)
	t.set_color(&"font_hover_color", &"PopupMenu", Color.WHITE)
	t.set_color(&"font_separator_color", &"PopupMenu", TEXT_DIM)
	t.set_constant(&"v_separation", &"PopupMenu", 6)
	t.set_stylebox(&"panel", &"PanelContainer", _flat(UiStyle.PANEL_BG, 8, 8, 8, UiStyle.PANEL_EDGE))


static func _sliders(t: Theme) -> void:
	var track := _flat(Color(0.07, 0.09, 0.12), 3, 0, 0)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	var fill := _flat(UiStyle.ACCENT.darkened(0.25), 3, 0, 0)
	fill.content_margin_top = 3
	fill.content_margin_bottom = 3
	t.set_stylebox(&"slider", &"HSlider", track)
	t.set_stylebox(&"grabber_area", &"HSlider", fill)
	t.set_stylebox(&"grabber_area_highlight", &"HSlider", fill)


static func _scrolls(t: Theme) -> void:
	var grab := _flat(Color(0.3, 0.35, 0.42, 0.8), 4, 3, 3)
	t.set_stylebox(&"scroll", &"VScrollBar", _flat(Color(0, 0, 0, 0.0), 4, 3, 3))
	t.set_stylebox(&"grabber", &"VScrollBar", grab)
	t.set_stylebox(&"grabber_highlight", &"VScrollBar", _flat(Color(0.45, 0.5, 0.6, 0.9), 4, 3, 3))
	t.set_stylebox(&"grabber_pressed", &"VScrollBar", _flat(UiStyle.ACCENT.darkened(0.2), 4, 3, 3))
	t.set_stylebox(&"scroll", &"HScrollBar", _flat(Color(0, 0, 0, 0.0), 4, 3, 3))
	t.set_stylebox(&"grabber", &"HScrollBar", grab)


static func _misc(t: Theme) -> void:
	t.set_color(&"font_color", &"Label", TEXT)
	t.set_stylebox(&"panel", &"TooltipPanel", _flat(Color(0.04, 0.05, 0.07, 0.97), 6, 10, 8, EDGE))
	t.set_color(&"font_color", &"TooltipLabel", TEXT)
	t.set_constant(&"separation", &"HSeparator", 8)
	var line := StyleBoxLine.new()
	line.color = EDGE
	line.thickness = 1
	t.set_stylebox(&"separator", &"HSeparator", line)
	var vline := StyleBoxLine.new()
	vline.color = EDGE
	vline.thickness = 1
	vline.vertical = true
	t.set_stylebox(&"separator", &"VSeparator", vline)
