class_name StackBar
extends Control
## A labeled stacked bar for the inspector: a title, one bar split into colored parts by value,
## and a legend of the parts underneath (wrapping across rows). Parts are [label, value, color,
## text]; `text` is what the legend shows after the label (a share, watts…).

const BAR_H := 10.0
const ROW_H := 15.0
const SWATCH := 8.0
const GAP := 10.0
const FONT := 11
const TITLE := Color(0.54, 0.58, 0.63)
const LABEL := Color(0.86, 0.88, 0.9)
const TRACK := Color(1, 1, 1, 0.08)

var title := ""
var parts := []

var _font: Font
var _rows := 1


func _init(width: float) -> void:
	custom_minimum_size.x = width
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


## Shows `p_parts` under `p_title`; parts with no value are left out.
func show_parts(p_title: String, p_parts: Array) -> void:
	title = p_title
	parts = p_parts.filter(func(p: Array) -> bool: return p[1] > 0.0)
	_rows = _layout().size()
	custom_minimum_size.y = ROW_H + BAR_H + 4.0 + _rows * ROW_H
	queue_redraw()


func _draw() -> void:
	var w := custom_minimum_size.x
	draw_string(_font, Vector2(0, _font.get_ascent(FONT)), title, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT, TITLE)
	var bar := Rect2(0, ROW_H, w, BAR_H)
	draw_rect(bar, TRACK)
	var total := 0.0
	for p: Array in parts:
		total += p[1]
	var x := 0.0
	for p: Array in parts:
		var pw: float = p[1] / total * w if total > 0.0 else 0.0
		draw_rect(Rect2(x, bar.position.y, pw, BAR_H), p[2])
		x += pw
	var y := bar.end.y + 4.0
	for row: Array in _layout():
		var lx := 0.0
		for p: Array in row:
			draw_rect(Rect2(lx, y + (ROW_H - SWATCH) * 0.5, SWATCH, SWATCH), p[2])
			var text := _legend_text(p)
			draw_string(_font, Vector2(lx + SWATCH + 4.0, y + _font.get_ascent(FONT)), text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, FONT, LABEL)
			lx += _item_width(p) + GAP
		y += ROW_H


## The parts split into legend rows that fit the width.
func _layout() -> Array:
	var rows := [[]]
	var x := 0.0
	for p: Array in parts:
		var iw := _item_width(p)
		if x > 0.0 and x + iw > custom_minimum_size.x:
			rows.append([])
			x = 0.0
		rows[-1].append(p)
		x += iw + GAP
	return rows


func _legend_text(p: Array) -> String:
	return "%s %s" % [p[0], p[3]]


func _item_width(p: Array) -> float:
	return SWATCH + 4.0 + _font.get_string_size(_legend_text(p), HORIZONTAL_ALIGNMENT_LEFT, -1, FONT).x
