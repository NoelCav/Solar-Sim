class_name TileRenderer
extends Sprite2D
## Tile view: one texel per tile, scaled up and shaded per pixel by tiles.gdshader (grain,
## bevels, depth). Reads sim state only; rebuilds when the grid's structure_version changes.
##
## Also lights the world (DisplayLight): by day everything is lit; after dusk the ambient
## fades to nearly black and a block shows only where light lands on its exposed faces (from
## the published light pass, at the view's exposure: moonlit ground dimly, focused moonlight
## brightly). The backdrop shares the light texture; other items in `dimmed` are darkened
## by the ambient, down to their own floor.

const LIGHT_REFRESH_S := 0.25     ## How often the light texture follows the light's intensity

var world: SimWorld
var lit_materials: Array[ShaderMaterial] = []   ## Shader materials that take ambient + light_tex
var dimmed: Dictionary[CanvasItem, float] = {}   ## Items darkened at night -> brightness floor

var _image: Image
var _texture: ImageTexture
var _bytes := PackedByteArray()
var _palette := PackedByteArray()   ## RGBA8 per material id
var _seen_version := -1
var _light: LightSystem
var _light_image: Image
var _light_texture: ImageTexture
var _light_bytes := PackedByteArray()
var _light_seen := -1
var _light_timer := 0.0


func setup(p_world: SimWorld) -> void:
	world = p_world
	centered = false
	scale = Vector2.ONE * SimConst.TILE_PX
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://render/tiles.gdshader")
	material = mat
	_build_palette()
	var g := world.grid
	_bytes.resize(g.size() * 4)
	_image = Image.create_empty(g.width, g.height, false, Image.FORMAT_RGBA8)
	_texture = ImageTexture.create_from_image(_image)
	texture = _texture
	_rebuild()
	_light = world.get_system(&"light")
	_light_bytes.resize(g.size() * 4 * SimConst.SKIN_STRIPS)
	_light_image = Image.create_empty(g.width * SimConst.SKIN_STRIPS, g.height * 4, false, Image.FORMAT_R8)
	_light_texture = ImageTexture.create_from_image(_light_image)
	lit_materials.append(mat)


func _process(delta: float) -> void:
	if world == null:
		return
	if world.grid.structure_version != _seen_version:
		_rebuild()
	_light_timer -= delta
	if _light.trace_version != _light_seen or _light_timer <= 0.0:
		_rebuild_light()
	var ambient := DisplayLight.ambient(world)
	for m in lit_materials:
		m.set_shader_parameter(&"ambient", ambient)
		m.set_shader_parameter(&"light_tex", _light_texture)
		m.set_shader_parameter(&"strips", SimConst.SKIN_STRIPS)
	for item: CanvasItem in dimmed:
		var v := maxf(ambient, dimmed[item])
		item.modulate = Color(v, v, v, item.modulate.a)


func _rebuild_light() -> void:
	_light_seen = _light.trace_version
	_light_timer = LIGHT_REFRESH_S
	var g := world.grid
	_light_bytes = light_bytes(world, _light)
	_light_image.set_data(g.width * SimConst.SKIN_STRIPS, g.height * 4, false, Image.FORMAT_R8, _light_bytes)
	_light_texture.update(_light_image)


## Per surface strip (D18), how lit it is by the light arriving on it from every layer:
## irradiance at the layer's exposure, relative to plain sunlight, 0..255. One byte per strip:
## x = tile x · strips + strip, y = tile y · 4 + face.
static func light_bytes(world: SimWorld, light: LightSystem) -> PackedByteArray:
	var g := world.grid
	var n := SimConst.SKIN_STRIPS
	var row := g.width * n
	var bytes := PackedByteArray()
	bytes.resize(g.size() * 4 * n)
	for layer in light.layers():
		var exposure := DisplayLight.exposure(world) if layer.lamp_id < 0 else DisplayLight.lamp_exposure(world)
		var scale := layer.irradiance_scale(world) * n * exposure / SimConst.REFERENCE_DNI
		var ids := layer.strip_ids
		var arriving := layer.strip_arriving
		for k in ids.size():
			var face := ids[k] / n            # tile * 4 + side
			var tile := face / 4
			var at := ((tile / g.width) * 4 + face % 4) * row + (tile % g.width) * n + ids[k] % n
			bytes[at] = mini(bytes[at] + int(clampf(arriving[k] * scale, 0.0, 1.0) * 255.0), 255)
	return bytes


func _build_palette() -> void:
	var mats := world.materials
	_palette.resize(mats.count() * 4)
	_palette.fill(0)
	for def in mats.placeable():
		var c := def.color
		var o := def.id * 4
		_palette[o] = c.r8
		_palette[o + 1] = c.g8
		_palette[o + 2] = c.b8
		_palette[o + 3] = c.a8


func _rebuild() -> void:
	var g := world.grid
	var mat := g.material
	for i in g.size():
		var src := mat[i] * 4
		var dst := i * 4
		_bytes[dst] = _palette[src]
		_bytes[dst + 1] = _palette[src + 1]
		_bytes[dst + 2] = _palette[src + 2]
		_bytes[dst + 3] = _palette[src + 3]
	_image.set_data(g.width, g.height, false, Image.FORMAT_RGBA8, _bytes)
	_texture.update(_image)
	_seen_version = g.structure_version
