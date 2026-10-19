class_name TileRenderer
extends Sprite2D
## Tile view: one texel per tile, scaled up and shaded per pixel by tiles.gdshader (grain,
## bevels, depth). Reads sim state only; rebuilds when the grid's structure_version changes.

var world: SimWorld

var _image: Image
var _texture: ImageTexture
var _bytes := PackedByteArray()
var _palette := PackedByteArray()   ## RGBA8 per material id
var _seen_version := -1


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


func _process(_delta: float) -> void:
	if world != null and world.grid.structure_version != _seen_version:
		_rebuild()


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
