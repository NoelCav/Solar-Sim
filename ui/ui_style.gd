class_name UiStyle
extends RefCounted
## The interface's look in one place: colors, sizes of the fixed bars, and factories for the
## panels, buttons and labels every UI part builds with (top bar, tool rail, side panel,
## inspector, legend).

const PANEL_BG := Color(0.05, 0.07, 0.10, 0.94)
const PANEL_EDGE := Color(0.16, 0.19, 0.23)
const CARD_BG := Color(0.10, 0.12, 0.15)
const CARD_EDGE := Color(0.20, 0.23, 0.28)
const DIM := Color(0.70, 0.75, 0.82)
const ACCENT := Color(1.0, 0.85, 0.45)
const ACCENT_BG := Color(0.23, 0.20, 0.13)
const POWER := Color(0.56, 0.78, 1.0)     ## Electricity
const WARM := Color(1.0, 0.70, 0.48)      ## Prices, heat
const TOP_BAR_H := 56.0
const RAIL_W := 64.0
const SIDE_W := 320.0
const GAP := 10.0


## A flat box: background, rounded corners, inner margin and an optional 1 px border.
static func box(bg: Color, radius := 6, margin := 8, border := Color.TRANSPARENT) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.set_corner_radius_all(radius)
	sb.set_content_margin_all(margin)
	if border.a > 0.0:
		sb.border_color = border
		sb.set_border_width_all(1)
	return sb


## A panel that stops clicks from reaching the world.
static func panel(radius := 6, margin := 8) -> PanelContainer:
	var p := PanelContainer.new()
	style_panel(p, radius, margin)
	return p


## Gives `p` the panel look and makes it stop clicks from reaching the world.
static func style_panel(p: PanelContainer, radius := 6, margin := 8) -> void:
	p.add_theme_stylebox_override(&"panel", box(PANEL_BG, radius, margin, PANEL_EDGE))
	p.mouse_filter = Control.MOUSE_FILTER_STOP


## An invisible filler that takes the spare room in a box row (or column when `vertical`).
static func spacer(vertical := false) -> Control:
	var c := Control.new()
	if vertical:
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func button(text: String, tip: String, action: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(action)
	return b


## A toggle in a group (one of several, like view or speed).
static func toggle(text: String, tip: String, action: Callable, group: ButtonGroup) -> Button:
	var b := button(text, tip, action)
	b.toggle_mode = true
	b.button_group = group
	return b


static func label(text := "", font_size := 13, color := Color.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override(&"font_size", font_size)
	if color != Color.WHITE:
		l.add_theme_color_override(&"font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


static func small_label(text := "") -> Label:
	return label(text, 11, DIM)


## Styles a toggle as a pill (tabs): the pressed one in the accent color.
static func pill(b: Button) -> void:
	var off := box(CARD_BG, 14, 6, CARD_EDGE)
	off.content_margin_left = 12
	off.content_margin_right = 12
	var on := box(ACCENT_BG, 14, 6, ACCENT)
	on.content_margin_left = 12
	on.content_margin_right = 12
	for state: StringName in [&"normal", &"hover", &"focus", &"disabled"]:
		b.add_theme_stylebox_override(state, off)
	b.add_theme_stylebox_override(&"pressed", on)
	b.add_theme_stylebox_override(&"hover_pressed", on)
	b.add_theme_color_override(&"font_pressed_color", ACCENT)
	b.add_theme_color_override(&"font_hover_pressed_color", ACCENT)


## Styles a button as a card (catalog items): dark, with an accent border when `selected`.
static func card(b: Button, selected: bool) -> void:
	var normal := box(ACCENT_BG if selected else CARD_BG, 8, 8, ACCENT if selected else CARD_EDGE)
	var hover := box(ACCENT_BG if selected else Color(0.14, 0.16, 0.2), 8, 8, ACCENT if selected else DIM)
	for state: StringName in [&"normal", &"pressed", &"focus", &"disabled"]:
		b.add_theme_stylebox_override(state, normal)
	b.add_theme_stylebox_override(&"hover", hover)
	b.add_theme_stylebox_override(&"hover_pressed", hover)
