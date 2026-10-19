class_name OverlayRenderer
extends Sprite2D
## Per-tile data layer under the beams (design doc §16), one texel per tile:
## - Normal view: lit surfaces glow (additively) with absorbed light, log scale, so it is
##   obvious where light lands and how concentrated it is.
## - Light / UV / Infrared views: absorbed irradiance in that band, log scale.
## - Heat view: temperature relative to the site's mean ambient (deep ground stays neutral).
## Also tracks the peak value for the on-map marker and describes its legend.

const REFRESH_S := 0.2
const HOT_SPAN_K := 600.0     ## ΔT above the site mean that maps to white
const COLD_SPAN_K := 25.0     ## ΔT below the site mean that maps to full blue
## ΔT hidden as unremarkable: the daily ambient swing plus a margin.
const HEAT_DEADZONE_K := SimConst.AMBIENT_SWING_K + 2.0
const IRR_MIN := 10.0         ## W/m² at the bottom of the light scale
const IRR_MAX := 1e6          ## W/m² at the top
const GLOW_MIN := 300.0       ## Normal view: absorbed W/m² where the surface glow starts

var world: SimWorld
var view := ViewMode.NORMAL:
	set(value):
		view = value
		_timer = 0.0
		material = _add_mat if view == ViewMode.NORMAL else null

## Peak of the current layer: tile index (-1 if none) and value (W/m² or K).
var peak_tile := -1
var peak_value := 0.0

var _light: LightSystem
var _image: Image
var _texture: ImageTexture
var _bytes := PackedByteArray()
var _timer := 0.0
var _add_mat := CanvasItemMaterial.new()
var heat_gradient := Gradient.new()
var light_gradient := Gradient.new()
var _heat_lut := PackedByteArray()
var _light_lut := PackedByteArray()


func setup(p_world: SimWorld) -> void:
	world = p_world
	_light = world.get_system(&"light")
	centered = false
	scale = Vector2.ONE * SimConst.TILE_PX
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	z_index = 3
	_add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = _add_mat
	var g := world.grid
	_bytes.resize(g.size() * 4)
	_image = Image.create_empty(g.width, g.height, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	texture = _texture
	heat_gradient.offsets = PackedFloat32Array([0.0, 0.25, 0.55, 0.8, 1.0])
	heat_gradient.colors = PackedColorArray([Color(0.1, 0.0, 0.2, 0.0), Color(0.6, 0.0, 0.4, 0.75),
		Color(1.0, 0.3, 0.0, 0.85), Color(1.0, 0.85, 0.1, 0.9), Color(1.0, 1.0, 1.0, 0.95)])
	light_gradient.offsets = PackedFloat32Array([0.0, 0.3, 0.55, 0.8, 1.0])
	light_gradient.colors = PackedColorArray([Color(0.05, 0.1, 0.4, 0.55), Color(0.1, 0.55, 0.9, 0.75),
		Color(0.2, 0.9, 0.4, 0.85), Color(1.0, 0.85, 0.1, 0.9), Color(1.0, 1.0, 1.0, 0.95)])
	_heat_lut = _lut(heat_gradient)
	_light_lut = _lut(light_gradient)


## Legend for the current view: {title, gradient, lo, hi}, or {} when there is none.
func legend() -> Dictionary:
	match ViewMode.overlay(view):
		ViewMode.Overlay.TEMPERATURE:
			var mean := SimConst.k_to_c(world.site_mean_ambient_k)
			return {"title": "Temperature (hidden within ±%.0f K of %.0f °C)" % [HEAT_DEADZONE_K, mean],
				"gradient": heat_gradient, "lo": "%.0f °C" % (mean + HEAT_DEADZONE_K),
				"hi": "%.0f °C" % (mean + HOT_SPAN_K)}
		ViewMode.Overlay.ABSORBED:
			var band := ViewMode.overlay_band(view)
			return {"title": "Absorbed %s" % ("light" if band < 0 else Spectrum.BAND_NAMES[band]),
				"gradient": light_gradient, "lo": "%.0f W/m²" % IRR_MIN, "hi": "1 MW/m²"}
	return {}


func _process(delta: float) -> void:
	if world == null:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = REFRESH_S
	peak_tile = -1
	peak_value = 0.0
	match ViewMode.overlay(view):
		ViewMode.Overlay.TEMPERATURE:
			_fill_heat()
		ViewMode.Overlay.ABSORBED:
			_fill_light(ViewMode.overlay_band(view), false)
		_:
			_fill_light(-1, true)
	_image.set_data(world.grid.width, world.grid.height, false, Image.FORMAT_RGBA8, _bytes)
	_texture.update(_image)


func _fill_heat() -> void:
	var g := world.grid
	var temp := g.temperature
	var mean := world.site_mean_ambient_k
	var dz := HEAT_DEADZONE_K
	var log_span := log(1.0 + HOT_SPAN_K - dz)
	var hottest := -INF
	for i in g.size():
		var d := temp[i] - mean
		var o := i * 4
		if d > hottest:
			hottest = d
			peak_tile = i
		if d < -dz:
			_bytes[o] = 40
			_bytes[o + 1] = 120
			_bytes[o + 2] = 255
			_bytes[o + 3] = int(clampf((-d - dz) / COLD_SPAN_K, 0.0, 1.0) * 200.0)
		elif d <= dz:
			_bytes[o + 3] = 0
		else:
			_put(_heat_lut, o, log(1.0 + d - dz) / log_span)
	peak_value = temp[peak_tile] if peak_tile >= 0 else 0.0


## Absorbed light from the published lit tiles only; `band` -1 = all light.
func _fill_light(band: int, glow: bool) -> void:
	_bytes.fill(0)
	var tp := _light.tile_power
	if tp.size() != world.grid.size():
		return
	var bp := _light.band_power
	var scale := _light.power_scale(world) / (SimConst.TILE_M * SimConst.DEPTH_M)
	var log_lo := log(IRR_MIN)
	var log_span := log(IRR_MAX) - log_lo
	var glow_lo := log(GLOW_MIN)
	for i in _light.shown_lit:
		var w := tp[i] if band < 0 else bp[i * Spectrum.BAND_COUNT + band]
		var irr := w * scale
		if irr > peak_value:
			peak_value = irr
			peak_tile = i
		var o := i * 4
		if glow:
			# Warm additive glow: invisible at ordinary sunlight, strong at a focus.
			var a := clampf((log(maxf(irr, 1.0)) - glow_lo) / (log(IRR_MAX) - glow_lo), 0.0, 1.0)
			_bytes[o] = int(255 * a)
			_bytes[o + 1] = int(190 * a)
			_bytes[o + 2] = int(110 * a)
			_bytes[o + 3] = 255
		elif irr >= IRR_MIN:
			_put(_light_lut, o, (log(irr) - log_lo) / log_span)


func _put(lut: PackedByteArray, o: int, x: float) -> void:
	var k := clampi(int(x * 255.0), 0, 255) * 4
	_bytes[o] = lut[k]
	_bytes[o + 1] = lut[k + 1]
	_bytes[o + 2] = lut[k + 2]
	_bytes[o + 3] = lut[k + 3]


static func _lut(gradient: Gradient) -> PackedByteArray:
	var lut := PackedByteArray()
	lut.resize(256 * 4)
	for k in 256:
		var c := gradient.sample(k / 255.0)
		lut[k * 4] = c.r8
		lut[k * 4 + 1] = c.g8
		lut[k * 4 + 2] = c.b8
		lut[k * 4 + 3] = c.a8
	return lut
