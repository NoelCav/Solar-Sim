class_name WorldGen
extends RefCounted
## Builds a simple test site: gently rolling dirt over stone, with sand pockets.
## Deterministic for a given world seed.

const SURFACE_FRACTION := 0.68   ## Average ground height, fraction from top
const SURFACE_AMPLITUDE := 5.0   ## Tiles of rolling variation
const DIRT_DEPTH := 6


static func generate(world: SimWorld) -> void:
	var g := world.grid
	var mats := world.materials
	var dirt := mats.id_of(&"dirt")
	var stone := mats.id_of(&"stone")
	var sand := mats.id_of(&"sand")

	var surface_noise := FastNoiseLite.new()
	surface_noise.seed = world.seed_value
	surface_noise.frequency = 0.02
	var pocket_noise := FastNoiseLite.new()
	pocket_noise.seed = world.seed_value + 1
	pocket_noise.frequency = 0.08

	var base := g.height * SURFACE_FRACTION
	for x in g.width:
		var surface := int(round(base + surface_noise.get_noise_1d(x) * SURFACE_AMPLITUDE))
		for y in range(maxi(surface, 0), g.height):
			var depth := y - surface
			var mat := dirt if depth < DIRT_DEPTH else stone
			if depth < DIRT_DEPTH + 4 and pocket_noise.get_noise_2d(x, y) > 0.45:
				mat = sand
			var i := g.idx(x, y)
			g.material[i] = mat
			g.temperature[i] = world.ambient_k
	g.mark_structure_changed()
