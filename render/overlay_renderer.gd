class_name OverlayRenderer
extends Sprite2D
## Per-tile data layer under the beams (design doc §16), one texel per tile:
## - Normal view: lit surfaces glow (additively) with absorbed light, log scale, so it is
##   obvious where light lands and how concentrated it is.
## - Light view (all wavelengths): the light arriving on each surface strip, drawn as the surface
##   skin along the faces it lands on (like the heat view's skin), log scale; glass and water, which
##   take light inside them, are tinted tile by tile. A single wavelength shows absorbed irradiance
##   in that band, tile by tile (strips don't carry bands).
## - Heat view: every tile colored by its temperature (absolute °C): solids fully, air fainter;
##   the surface skin (D18) drawn over solids' faces in its own temperature, so a focal spot
##   shows on a cool block (heat_overlay.gdshader, strips as in surface_strips.gdshaderinc).
## Also tracks the peak value for the on-map marker and describes its legend.

const REFRESH_S := 0.2
const HEAT_COLD_C := -10.0    ## Bottom of the heat scale
const HEAT_WARM_C := 50.0     ## Linear up to here (everyday temperatures get half the scale)
const HEAT_HOT_C := 1500.0    ## Log above, up to here (melting glass)
const AIR_ALPHA := 0.45       ## Air shows fainter than solids in the heat view
const IRR_MIN := 10.0         ## W/m² at the bottom of the light scale
const IRR_MAX := 1e6          ## W/m² at the top
const GLOW_MIN := 300.0       ## Normal view: absorbed W/m² where the surface glow starts

var world: SimWorld
var view := ViewMode.NORMAL:
	set(value):
		view = value
		_timer = 0.0
		_apply_material()
var wavelength := -1:   ## Single bin to show, or -1 for all; tiles show that bin's band
	set(value):
		wavelength = value
		_timer = 0.0
		_apply_material()

## Peak of the current layer: tile index (-1 if none) and value (W/m² or K).
var peak_tile := -1
var peak_value := 0.0
var heat_gradient := Gradient.new()
var light_gradient := Gradient.new()

var _light: LightSystem
var _image: Image
var _texture: ImageTexture
var _bytes := PackedByteArray()
var _timer := 0.0
var _add_mat := CanvasItemMaterial.new()
var _heat_mat := ShaderMaterial.new()
var _skin_image: Image
var _skin_texture: ImageTexture
var _skin_bytes := PackedByteArray()
var _heat_lut := PackedByteArray()
var _light_lut := PackedByteArray()
var _solid_lut := PackedByteArray()   ## 1 per material id that is not a gas
var _opaque_lut := PackedByteArray()  ## 1 per material id that blocks light (its faces carry the light)
var _strip_irr := PackedFloat32Array()   ## Scratch: light on each strip, as drawn


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
	var n := SimConst.SKIN_STRIPS
	_skin_bytes.resize(g.size() * 4 * n * 4)
	_skin_image = Image.create_empty(g.width * n, g.height * 4, false, Image.FORMAT_RGBA8)
	_skin_texture = ImageTexture.create_from_image(_skin_image)
	_heat_mat.shader = preload("res://render/heat_overlay.gdshader")
	_heat_mat.set_shader_parameter(&"skin_tex", _skin_texture)
	_heat_mat.set_shader_parameter(&"strips", n)
	heat_gradient.offsets = PackedFloat32Array([0.0, 0.17, 0.33, 0.5, 0.62, 0.78, 1.0])
	heat_gradient.colors = PackedColorArray([Color(0.15, 0.1, 0.6, 0.9), Color(0.1, 0.45, 0.95, 0.9),
		Color(0.1, 0.75, 0.6, 0.9), Color(0.95, 0.85, 0.2, 0.9), Color(1.0, 0.45, 0.05, 0.92),
		Color(0.85, 0.05, 0.1, 0.95), Color(1.0, 1.0, 1.0, 0.97)])
	light_gradient.offsets = PackedFloat32Array([0.0, 0.3, 0.55, 0.8, 1.0])
	light_gradient.colors = PackedColorArray([Color(0.05, 0.1, 0.4, 0.55), Color(0.1, 0.55, 0.9, 0.75),
		Color(0.2, 0.9, 0.4, 0.85), Color(1.0, 0.85, 0.1, 0.9), Color(1.0, 1.0, 1.0, 0.95)])
	_heat_lut = _lut(heat_gradient)
	_light_lut = _lut(light_gradient)


## Light view with all wavelengths draws skins; every other view of the overlay draws tiles.
func _skins_in_light_view() -> bool:
	return ViewMode.overlay(view) == ViewMode.Overlay.ABSORBED and ViewMode.overlay_band(wavelength) < 0


func _apply_material() -> void:
	if view == ViewMode.NORMAL:
		material = _add_mat
	elif view == ViewMode.HEAT or _skins_in_light_view():
		material = _heat_mat
	else:
		material = null


## Legend for the current view: {title, gradient, lo, hi}, or {} when there is none.
func legend() -> Dictionary:
	match ViewMode.overlay(view):
		ViewMode.Overlay.TEMPERATURE:
			return {"title": "Temperature (linear to %.0f °C, then log)" % HEAT_WARM_C,
				"gradient": heat_gradient, "lo": "%.0f °C" % HEAT_COLD_C, "hi": "%.0f °C" % HEAT_HOT_C}
		ViewMode.Overlay.ABSORBED:
			var band := ViewMode.overlay_band(wavelength)
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
			if _skins_in_light_view():
				_fill_light(-1, false, true)
				_fill_light_skins()
			else:
				_fill_light(ViewMode.overlay_band(wavelength), false)
		_:
			_fill_light(ViewMode.overlay_band(wavelength), true)
	_image.set_data(world.grid.width, world.grid.height, false, Image.FORMAT_RGBA8, _bytes)
	_texture.update(_image)


func _fill_heat() -> void:
	var g := world.grid
	var temp := g.temperature
	var mat := g.material
	if _solid_lut.size() != world.materials.count():
		_solid_lut.resize(world.materials.count())
		for def in world.materials.placeable():
			_solid_lut[def.id] = 1 if def.phase != MaterialDef.Phase.GAS else 0
	var air_a := AIR_ALPHA
	var hottest := -INF
	for i in g.size():
		var t := temp[i]
		if t > hottest:
			hottest = t
			peak_tile = i
		var o := i * 4
		_put(_heat_lut, o, heat_x(SimConst.k_to_c(t)))
		if _solid_lut[mat[i]] == 0:
			_bytes[o + 3] = int(_bytes[o + 3] * air_a)
	peak_value = temp[peak_tile] if peak_tile >= 0 else 0.0
	_fill_skin()


## Skin strip colors for the heat view (one texel per strip, as in surface_strips.gdshaderinc);
## the hottest strip counts for the peak marker.
func _fill_skin() -> void:
	var skin := world.skin
	var g := world.grid
	var n := skin.strips
	var row := g.width * n
	_skin_bytes.fill(0)
	for f in skin.faces:
		var tile := skin.face_tile[f]
		var base := ((tile / g.width) * 4 + skin.face_side[f]) * row + (tile % g.width) * n
		for s in n:
			var t := skin.temperature[f * n + s]
			if t > peak_value:
				peak_value = t
				peak_tile = tile
			var at := (base + s) * 4
			_put_at(_skin_bytes, _heat_lut, at, heat_x(SimConst.k_to_c(t)))
	_skin_image.set_data(row, g.height * 4, false, Image.FORMAT_RGBA8, _skin_bytes)
	_skin_texture.update(_skin_image)


## The value at position x (0–1) along the current legend, as display text.
func legend_value(x: float) -> String:
	x = clampf(x, 0.0, 1.0)
	match ViewMode.overlay(view):
		ViewMode.Overlay.TEMPERATURE:
			return "%.0f °C" % heat_c(x)
		ViewMode.Overlay.ABSORBED:
			return Readout.irradiance(exp(log(IRR_MIN) + x * (log(IRR_MAX) - log(IRR_MIN))))
	return ""


## Position on the heat scale (0–1) of a temperature in °C: linear through everyday
## temperatures, logarithmic above so a 1000 °C focus still reads.
static func heat_x(c: float) -> float:
	if c <= HEAT_WARM_C:
		return clampf((c - HEAT_COLD_C) / (HEAT_WARM_C - HEAT_COLD_C), 0.0, 1.0) * 0.5
	return 0.5 + 0.5 * clampf(log(1.0 + c - HEAT_WARM_C) / log(1.0 + HEAT_HOT_C - HEAT_WARM_C), 0.0, 1.0)


## Temperature in °C at position x (0–1) on the heat scale; the inverse of heat_x.
static func heat_c(x: float) -> float:
	if x <= 0.5:
		return HEAT_COLD_C + x / 0.5 * (HEAT_WARM_C - HEAT_COLD_C)
	return HEAT_WARM_C + exp((x - 0.5) / 0.5 * log(1.0 + HEAT_HOT_C - HEAT_WARM_C)) - 1.0


## Absorbed light from the published lit tiles only; `band` -1 = all light. With `media_only`,
## tiles that block light are left out (their faces are drawn as skins instead).
func _fill_light(band: int, glow: bool, media_only := false) -> void:
	_bytes.fill(0)
	if media_only and _opaque_lut.size() != world.materials.count():
		_opaque_lut.resize(world.materials.count())
		for def in world.materials.placeable():
			_opaque_lut[def.id] = 0 if def.transparent else 1
	var mat := world.grid.material
	if _light.sky.tile_power.size() != world.grid.size():
		return
	var log_lo := log(IRR_MIN)
	var log_span := log(IRR_MAX) - log_lo
	var glow_lo := log(GLOW_MIN)
	# Per tile, the light absorbed from every layer (physical W/m²), and as drawn (each layer at its exposure).
	var physical := {}
	var shown := {}
	for layer in _light.layers():
		var tp := layer.tile_power
		if tp.size() != world.grid.size():
			continue
		var bp := layer.band_power
		var scale := layer.irradiance_scale(world)
		var gain := DisplayLight.exposure(world) if layer.lamp_id < 0 else DisplayLight.lamp_exposure(world)
		for i in layer.shown_lit:
			if media_only and _opaque_lut[mat[i]] == 1:
				continue
			var w := tp[i] if band < 0 else bp[i * Spectrum.BAND_COUNT + band]
			physical[i] = physical.get(i, 0.0) + w * scale
			shown[i] = shown.get(i, 0.0) + w * scale * gain
	for i: int in physical:
		var irr: float = physical[i]
		if irr > peak_value:
			peak_value = irr
			peak_tile = i
		irr = shown[i]
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


## The light on each surface strip, from every layer at its exposure, as skin colors on the light
## scale (alpha 0 where nothing lands); the brightest strip counts for the peak marker.
func _fill_light_skins() -> void:
	var g := world.grid
	var n := SimConst.SKIN_STRIPS
	var row := g.width * n
	_strip_irr.resize(g.size() * 4 * n)
	_strip_irr.fill(0.0)
	var physical := PackedFloat32Array()
	physical.resize(_strip_irr.size())
	physical.fill(0.0)
	for layer in _light.layers():
		var gain := DisplayLight.exposure(world) if layer.lamp_id < 0 else DisplayLight.lamp_exposure(world)
		var scale := layer.irradiance_scale(world) * n
		var ids := layer.strip_ids
		var arriving := layer.strip_arriving
		for k in ids.size():
			var face := ids[k] / n
			var tile := face / 4
			var at := ((tile / g.width) * 4 + face % 4) * row + (tile % g.width) * n + ids[k] % n
			physical[at] += arriving[k] * scale
			_strip_irr[at] += arriving[k] * scale * gain
	_skin_bytes.fill(0)
	var log_lo := log(IRR_MIN)
	var log_span := log(IRR_MAX) - log_lo
	for at in _strip_irr.size():
		if physical[at] > peak_value:
			peak_value = physical[at]
			var face := (at / row) % 4
			var column := at % row / n
			peak_tile = (at / row / 4) * g.width + column
		if _strip_irr[at] >= IRR_MIN:
			_put_at(_skin_bytes, _light_lut, at * 4, (log(_strip_irr[at]) - log_lo) / log_span)
	_skin_image.set_data(row, g.height * 4, false, Image.FORMAT_RGBA8, _skin_bytes)
	_skin_texture.update(_skin_image)


func _put(lut: PackedByteArray, o: int, x: float) -> void:
	_put_at(_bytes, lut, o, x)


## Writes the color at position x (0-1) of `lut` into `bytes` at byte offset o.
static func _put_at(bytes: PackedByteArray, lut: PackedByteArray, o: int, x: float) -> void:
	var k := clampi(int(x * 255.0), 0, 255) * 4
	bytes[o] = lut[k]
	bytes[o + 1] = lut[k + 1]
	bytes[o + 2] = lut[k + 2]
	bytes[o + 3] = lut[k + 3]


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
