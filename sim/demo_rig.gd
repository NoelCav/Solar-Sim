class_name DemoRig
extends RefCounted
## A starter set of optics near the middle of the site, placed through commands (D6):
## a crown lens over a probe at its focus, a prism, a tilted mirror, and a long-focus
## acrylic lens burning a spot into the ground.

## [object key, x offset from site center (m), height above ground (m), angle (deg)]
const LAYOUT := [
	[&"lens_crown", -5.0, 3.5, 0.0],
	[&"probe", -5.0, 2.4, 0.0],
	[&"prism_flint", -1.0, 2.0, 0.0],
	[&"mirror_aluminum", 3.0, 1.5, 30.0],
	[&"lens_acrylic", 8.0, 5.0, 0.0],
]


static func place(world: SimWorld, objects: ObjectDB) -> void:
	var g := world.grid
	var center_x := g.width * SimConst.TILE_M * 0.5
	for entry in LAYOUT:
		var def := objects.get_by_key(entry[0])
		if def == null:
			push_warning("DemoRig: unknown object '%s'" % entry[0])
			continue
		var x: float = center_x + entry[1]
		var pos := Vector2(x, ground_y(world, x) - entry[2])
		world.enqueue(PlaceObjectCommand.new(def, pos, deg_to_rad(entry[3])))
	world.flush_commands()


## Top of the first non-gas tile in the column at world x (m).
static func ground_y(world: SimWorld, x: float) -> float:
	var g := world.grid
	var col := clampi(floori(x / SimConst.TILE_M), 0, g.width - 1)
	for y in g.height:
		if not world.materials.is_gas[g.material[g.idx(col, y)]]:
			return y * SimConst.TILE_M
	return g.height * SimConst.TILE_M
