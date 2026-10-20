class_name LegendPanel
extends PanelContainer
## The color scale of the Light and Heat views (bottom right; hidden in the Normal view): its
## title, the color bar with its end values, and the value under the pointer on the bar.

var overlay: OverlayRenderer

var _title: Label
var _bar: TextureRect
var _lo: Label
var _hi: Label
var _tip: Label


func setup(p_overlay: OverlayRenderer) -> void:
	overlay = p_overlay
	UiStyle.style_panel(self, 8, 10)
	set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	grow_horizontal = Control.GROW_DIRECTION_BEGIN
	grow_vertical = Control.GROW_DIRECTION_BEGIN
	offset_right = -UiStyle.GAP
	offset_bottom = -UiStyle.GAP
	var col := VBoxContainer.new()
	col.add_theme_constant_override(&"separation", 4)
	add_child(col)
	var head := HBoxContainer.new()
	_title = UiStyle.label("", 12)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(_title)
	_tip = UiStyle.label("", 12, UiStyle.ACCENT)
	head.add_child(_tip)
	col.add_child(head)
	_bar = TextureRect.new()
	_bar.custom_minimum_size = Vector2(280, 12)
	_bar.stretch_mode = TextureRect.STRETCH_SCALE
	_bar.mouse_filter = Control.MOUSE_FILTER_STOP
	_bar.gui_input.connect(_on_bar_input)
	_bar.mouse_exited.connect(func() -> void: _tip.text = "")
	col.add_child(_bar)
	var ends := HBoxContainer.new()
	_lo = UiStyle.small_label()
	_lo.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ends.add_child(_lo)
	_hi = UiStyle.small_label()
	ends.add_child(_hi)
	col.add_child(ends)


## Shows the current view's scale (or hides the panel when it has none).
func refresh() -> void:
	var lg := overlay.legend()
	visible = not lg.is_empty()
	if not visible:
		return
	_title.text = lg.title
	var tex := GradientTexture2D.new()
	tex.gradient = lg.gradient
	tex.width = 256
	tex.height = 12
	_bar.texture = tex
	_lo.text = lg.lo
	_hi.text = lg.hi


func _on_bar_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		_tip.text = overlay.legend_value((event as InputEventMouseMotion).position.x / maxf(_bar.size.x, 1.0))
