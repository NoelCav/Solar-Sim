class_name DemoRig
extends RefCounted
## A starter set of optics near the middle of the site, placed through commands (D6) on
## stands (Mounting): a crown lens over a probe at its focus, a prism, a tilted mirror, a
## long-focus acrylic lens burning a spot into the ground, and a silicon cell panel wired along
## the ground to a grid connection.

## [object key, x offset from site center (m), height above ground (m), angle (deg)]
const LAYOUT := [
	[&"lens_crown", -5.0, 3.5, 0.0],
	[&"probe", -5.0, 2.4, 0.0],
	[&"prism_flint", -1.0, 2.0, 0.0],
	[&"mirror_aluminum", 3.0, 1.5, 30.0],
	[&"lens_acrylic", 8.0, 5.0, 0.0],
	[&"cell_si", 12.0, 1.0, 0.0],
	[&"grid_tie", 14.0, 0.0, 0.0],
]
## Wire runs along the ground between these offsets (m): the cell's foot to the grid connection's.
const WIRE := [12.0, 14.0]


static func place(world: SimWorld, objects: ObjectDB) -> void:
	var g := world.grid
	var center_x := g.width * SimConst.TILE_M * 0.5
	for entry in LAYOUT:
		var def := objects.get_by_key(entry[0])
		if def == null:
			push_warning("DemoRig: unknown object '%s'" % entry[0])
			continue
		var x: float = center_x + entry[1]
		var pos := Vector2(x, Mounting.ground_y(world, floori(x / SimConst.TILE_M), 0.0) - entry[2])
		world.enqueue(PlaceObjectCommand.new(def, pos, deg_to_rad(entry[3]), true))
	world.enqueue(PaintWiresCommand.new(_along_ground(world, center_x + WIRE[0], center_x + WIRE[1])))
	world.flush_commands()


## Tiles just above the ground from x0 to x1 (m), joined up and down where the ground steps.
static func _along_ground(world: SimWorld, x0: float, x1: float) -> PackedInt32Array:
	var g := world.grid
	var cells := PackedInt32Array()
	var prev := -1
	for col in range(floori(x0 / SimConst.TILE_M), floori(x1 / SimConst.TILE_M) + 1):
		var row := roundi(Mounting.ground_y(world, col, 0.0) / SimConst.TILE_M) - 1
		var from := row if prev < 0 else prev
		for r in range(mini(from, row), maxi(from, row) + 1):
			cells.append(g.idx(col, r))
		prev = row
	return cells
