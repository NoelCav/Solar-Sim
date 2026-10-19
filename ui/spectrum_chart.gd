class_name SpectrumChart
extends Control
## A small spectrum plot for the inspector: irradiance per micrometer for each spectral bin,
## drawn across its wavelength range (log axis, Spectrum.BIN_EDGES_UM), colored by bin. A
## thin outline shows the plain light from the source (sun or moon) scaled to the same total,
## so what optics removed or added stands out.

const SIZE := Vector2(230, 96)
const PAD := Vector2(6, 16)                  ## Room for the top label and bin names
const AXIS := Color(0.55, 0.6, 0.66)
const OUTLINE := Color(1, 1, 1, 0.75)
## Bar colors per bin: the display colors, with near IR and IR made visible.
const BAR_COLOR: Array[Color] = [
	Color(0.55, 0.20, 1.00), Color(0.15, 0.35, 1.00), Color(0.20, 1.00, 0.30),
	Color(1.00, 0.20, 0.10), Color(0.65, 0.12, 0.10), Color(0.42, 0.08, 0.07),
]
const BIN_LABELS: Array[String] = ["UV", "B", "G", "R", "NIR", "IR"]

var spectrum := Spectrum.make_zero()    ## W/m² per bin
var reference := Spectrum.make_zero()   ## Plain light from the source, W/m² per bin (any scale)

var _font: Font


func _init() -> void:
	custom_minimum_size = SIZE
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_font = ThemeDB.fallback_font


## Shows `p_spectrum` (W/m² per bin) against the source's plain spectrum `p_reference`.
func show_spectrum(p_spectrum: PackedFloat32Array, p_reference: PackedFloat32Array) -> void:
	spectrum = p_spectrum
	reference = p_reference
	queue_redraw()


func _draw() -> void:
	var plot := Rect2(PAD, size - PAD * Vector2(2, 2))
	var density := _density(spectrum)
	var total := Spectrum.total(spectrum)
	var ref_total := Spectrum.total(reference)
	var ref_density := _density(reference)
	var ref_scale := total / ref_total if ref_total > 0.0 else 0.0
	var top := 0.0
	for b in Spectrum.BIN_COUNT:
		top = maxf(top, maxf(density[b], ref_density[b] * ref_scale))
	if top <= 0.0:
		return
	var base_y := plot.end.y
	for b in Spectrum.BIN_COUNT:
		var x0 := _x(plot, Spectrum.BIN_EDGES_UM[b])
		var x1 := _x(plot, Spectrum.BIN_EDGES_UM[b + 1])
		var h := density[b] / top * plot.size.y
		draw_rect(Rect2(x0 + 1, base_y - h, x1 - x0 - 2, h), BAR_COLOR[b])
		var rh := ref_density[b] * ref_scale / top * plot.size.y
		draw_line(Vector2(x0 + 1, base_y - rh), Vector2(x1 - 1, base_y - rh), OUTLINE, 1.5)
		var label := BIN_LABELS[b]
		var w := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
		draw_string(_font, Vector2((x0 + x1 - w) * 0.5, base_y + 12), label, HORIZONTAL_ALIGNMENT_LEFT, -1,
			10, AXIS)
	draw_line(Vector2(plot.position.x, base_y), Vector2(plot.end.x, base_y), AXIS, 1.0)
	draw_string(_font, Vector2(plot.position.x, 10), "%s per µm (peak)" % Readout.irradiance(top),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 10, AXIS)


## W/m² per µm in each bin.
static func _density(s: PackedFloat32Array) -> PackedFloat32Array:
	var d := Spectrum.make_zero()
	for b in Spectrum.BIN_COUNT:
		d[b] = s[b] / (Spectrum.BIN_EDGES_UM[b + 1] - Spectrum.BIN_EDGES_UM[b])
	return d


## Screen x of wavelength `um` on the log axis across the bins' full range.
static func _x(plot: Rect2, um: float) -> float:
	var lo := log(Spectrum.BIN_EDGES_UM[0])
	var hi := log(Spectrum.BIN_EDGES_UM[Spectrum.BIN_COUNT])
	return plot.position.x + (log(um) - lo) / (hi - lo) * plot.size.x
