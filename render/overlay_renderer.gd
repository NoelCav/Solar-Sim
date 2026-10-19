class_name OverlayRenderer
extends Sprite2D
## Per-tile data overlays (design doc §16): heat (temperature relative to the site's mean
## ambient, so deep ground stays neutral as the day warms) and light (absorbed irradiance,
## log scale). One texel per tile, refreshed a few times a second.

enum Mode { NONE, HEAT, LIGHT }

const REFRESH_S := 0.2
const HOT_SPAN_K := 600.0     ## ΔT above the site mean that maps to white
const COLD_SPAN_K := 25.0     ## ΔT below the site mean that maps to full blue

var world: SimWorld
var mode := Mode.NONE:
	set(value):
		mode = value
		visible = mode != Mode.NONE
		_timer = 0.0

var _light: LightSystem
var _image: Image
var _texture: ImageTexture
var _bytes := PackedByteArray()
var _timer := 0.0
var _hot := Gradient.new()
var _lut := PackedByteArray()   ## 256 RGBA entries sampled from _hot


func setup(p_world: SimWorld) -> void:
	world = p_world
	_light = world.get_system(&"light")
	centered = false
	scale = Vector2.ONE * SimConst.TILE_PX
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	z_index = 6
	visible = false
	var g := world.grid
	_bytes.resize(g.size() * 4)
	_image = Image.create_empty(g.width, g.height, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	texture = _texture
	_hot.offsets = PackedFloat32Array([0.0, 0.25, 0.55, 0.8, 1.0])
	_hot.colors = PackedColorArray([Color(0.1, 0.0, 0.2, 0.0), Color(0.6, 0.0, 0.4, 0.75),
		Color(1.0, 0.3, 0.0, 0.85), Color(1.0, 0.85, 0.1, 0.9), Color(1.0, 1.0, 1.0, 0.95)])
	_lut.resize(256 * 4)
	for k in 256:
		var c := _hot.sample(k / 255.0)
		_lut[k * 4] = c.r8
		_lut[k * 4 + 1] = c.g8
		_lut[k * 4 + 2] = c.b8
		_lut[k * 4 + 3] = c.a8


func cycle() -> void:
	mode = ((mode + 1) % Mode.size()) as Mode


func mode_name() -> String:
	return ["normal", "heat", "light"][mode]


func _process(delta: float) -> void:
	if world == null or mode == Mode.NONE:
		return
	_timer -= delta
	if _timer > 0.0:
		return
	_timer = REFRESH_S
	if mode == Mode.HEAT:
		_fill_heat()
	else:
		_fill_light()
	_image.set_data(world.grid.width, world.grid.height, false, Image.FORMAT_RGBA8, _bytes)
	_texture.update(_image)


func _fill_heat() -> void:
	var g := world.grid
	var temp := g.temperature
	var amb := world.site_mean_ambient_k
	var log_span := log(1.0 + HOT_SPAN_K)
	for i in g.size():
		var d := temp[i] - amb
		var o := i * 4
		if d < -0.5:
			var a := clampf(-d / COLD_SPAN_K, 0.0, 1.0)
			_bytes[o] = 40
			_bytes[o + 1] = 120
			_bytes[o + 2] = 255
			_bytes[o + 3] = int(a * 200.0)
		elif d < 0.5:
			_bytes[o + 3] = 0
		else:
			_put_lut(o, log(1.0 + d) / log_span)


func _fill_light() -> void:
	var g := world.grid
	var tp := _light.tile_power
	if tp.size() != g.size():
		_bytes.fill(0)
		return
	var scale := _light.power_scale(world)
	var inv_area := 1.0 / (SimConst.TILE_M * SimConst.DEPTH_M)
	for i in g.size():
		var o := i * 4
		var irr := tp[i] * scale * inv_area
		if irr < 1.0:
			_bytes[o + 3] = 0
		else:
			# 1 W/m² .. 1 MW/m² across the gradient.
			_put_lut(o, log(irr) / log(1e6))


func _put_lut(o: int, x: float) -> void:
	var k := clampi(int(x * 255.0), 0, 255) * 4
	_bytes[o] = _lut[k]
	_bytes[o + 1] = _lut[k + 1]
	_bytes[o + 2] = _lut[k + 2]
	_bytes[o + 3] = _lut[k + 3]
