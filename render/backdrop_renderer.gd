class_name BackdropRenderer
extends Sprite2D
## Background walls (Terraria-style): below the ground line the site had when generated,
## a darkened copy of the original material sits behind the tiles, so dug-out space shows
## earth, not sky. Shaded by the same tile shader (grain, depth). Beyond the site's edges
## below ground, plain dark earth continues. Visual only; the sim never reads it.

const DARKEN := 0.42
const OUTSIDE := 4000.0        ## How far the earth continues past the site, tiles

var world: SimWorld


func setup(p_world: SimWorld) -> void:
	world = p_world
	centered = false
	scale = Vector2.ONE * SimConst.TILE_PX
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	z_index = -5
	var mat := ShaderMaterial.new()
	mat.shader = preload("res://render/tiles.gdshader")
	material = mat
	var g := world.grid
	var img := Image.create_empty(g.width, g.height, false, Image.FORMAT_RGBA8)
	var surface := PackedInt32Array()
	surface.resize(g.width)
	for x in g.width:
		var top := g.height
		for y in g.height:
			if world.materials.is_gas[g.material[g.idx(x, y)]] == 0:
				top = y
				break
		surface[x] = top
		for y in range(top, g.height):
			var def := world.materials.get_def(g.material[g.idx(x, y)])
			var c := def.color if def != null and def.phase != MaterialDef.Phase.GAS else Color(0.4, 0.3, 0.2)
			img.set_pixel(x, y, Color(c.r * DARKEN, c.g * DARKEN, c.b * DARKEN, 1.0))
	texture = ImageTexture.create_from_image(img)
	# Earth beyond the site's edges and below its bottom, unshaded.
	var outside := Node2D.new()
	outside.z_index = -5
	outside.z_as_relative = false
	outside.draw.connect(func() -> void:
		var w := float(g.width)
		var h := float(g.height)
		var dirt := Color(0.42 * DARKEN, 0.29 * DARKEN, 0.18 * DARKEN)
		var deep := dirt.darkened(0.45)
		outside.draw_rect(Rect2(-OUTSIDE, surface[0], OUTSIDE, h - surface[0]), dirt)
		outside.draw_rect(Rect2(w, surface[g.width - 1], OUTSIDE, h - surface[g.width - 1]), dirt)
		outside.draw_rect(Rect2(-OUTSIDE, h, w + 2.0 * OUTSIDE, OUTSIDE), deep))
	add_child(outside)
