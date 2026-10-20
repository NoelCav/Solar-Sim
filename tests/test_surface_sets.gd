extends TestSuite
## Surface cells (design §16.2): a cell conducts, so cells that touch are one network and one set
## with one meter; one wire connection serves the whole set.

const SURFACE := preload("res://data/objects/cell_si_surface.tres")
const GRID := preload("res://data/objects/grid_tie.tres")


## Stone ground below row 10 at noon; surface cells in columns 4, 5, 6 (touching) and 9 (alone),
## a wire from column 7 to a grid connection at column 14, one row above the ground.
func _farm() -> SimWorld:
	var world := SimWorld.new(load_materials(), 24, 16, 1)
	var g := world.grid
	var stone := world.materials.id_of(&"stone")
	for i in g.size():
		g.material[i] = stone if i / g.width >= 10 else MaterialDB.AIR_ID
	g.mark_structure_changed()
	world.time_s = 0.5 * SimConst.DAY_LENGTH_S
	world.tick()
	for col in [4, 5, 6, 9]:
		world.enqueue(PlaceObjectCommand.new(SURFACE, Vector2((col + 0.5) * SimConst.TILE_M, 2.0), 0.0, true))
	world.enqueue(PlaceObjectCommand.new(GRID, Vector2(14.5 * SimConst.TILE_M, 2.0), 0.0, true))
	var wire := PackedInt32Array()
	for col in range(7, 15):
		wire.append(g.idx(col, 9))
	world.enqueue(PaintWiresCommand.new(wire))
	world.flush_commands()
	(world.get_system(&"light") as LightSystem).retrace(world)
	return world


## Touching cells are one set; the lone cell is its own; all of them are on the grid's network
## although no wire touches the first three but through their neighbour.
func test_touching_cells_are_one_network() -> void:
	var world := _farm()
	var power: PowerSystem = world.get_system(&"power")
	power.sync(world)
	check_eq(power.sets.size(), 2, "a set of three and a cell alone")
	var sizes := [power.sets[0].size(), power.sets[1].size()]
	sizes.sort()
	check_eq(sizes, [1, 3], "set sizes")
	var nets := {}
	for obj: SimObject in world.objects.values():
		nets[power.network_of(world, obj)] = true
	check_eq(nets.size(), 1, "one network: no cell needs a wire of its own")
	world.tick()
	for obj: SimObject in world.objects.values():
		if obj.def.kind == ObjectDef.Kind.CELL:
			check(obj.power_w > 0.5, "cell %d delivers %.2f W" % [obj.id, obj.power_w])


## One meter per set: it reads the set's total and rated power and sits by the rightmost cell.
func test_a_set_has_one_meter() -> void:
	var world := _farm()
	var power: PowerSystem = world.get_system(&"power")
	power.sync(world)
	var set: Array = []
	for s: Array in power.sets:
		if s.size() == 3:
			set = s
	var shown := 0
	var total := 0.0
	for id: int in set:
		var obj: SimObject = world.objects[id]
		if PowerMeters.meter_rect(world, obj).has_area():
			shown += 1
		total += SolarCell.object_power(obj, (world.get_system(&"light") as LightSystem).power_scale(world))
	var r := PowerMeters.reading(world, world.objects[set[0]])
	check_near(r.watts, total, 1e-6, "the meter reads the whole set")
	check_near(r.rated, 3.0 * SolarCell.rated_power(SURFACE), 1e-6, "rated power of the three")
	check_eq(PowerMeters.reading(world, world.objects[set[2]]).center, r.center, "the same meter whichever cell you ask")
	var rightmost: SimObject = world.objects[set.back()]
	check(r.center.x > rightmost.position.x, "it sits right of the rightmost cell")
	check_eq(shown, 3, "each cell finds the same meter when hovered")


## Wires of different channels (colors) cross: on a shared tile they stay separate networks, and a
## device joins the network at its foot.
func test_wires_of_different_colors_cross() -> void:
	var world := SimWorld.new(load_materials(), 16, 8, 1)
	var g := world.grid
	var across := PackedInt32Array()
	var down := PackedInt32Array()
	for k in range(2, 9):
		across.append(g.idx(k, 4))
		down.append(g.idx(5, k - 1))
	world.enqueue(PaintWiresCommand.new(across, 1, 0))
	world.enqueue(PaintWiresCommand.new(down, 1, 1))
	world.flush_commands()
	var nets := ConduitNetworks.new()
	nets.sync(g, g.wire)
	check_eq(nets.count, 2, "two wires, two networks, though they share a tile")
	var tile := g.idx(5, 4)
	check(nets.at(tile, 0) >= 0 and nets.at(tile, 1) >= 0 and nets.at(tile, 0) != nets.at(tile, 1), "the shared tile is in both")
	check_eq(g.wire[tile], 3, "both channels in one byte")
	world.enqueue(UndoCommand.new())
	world.flush_commands()
	check_eq(g.wire[tile], 1, "undo takes the blue wire off the shared tile and leaves the copper")
	var same := PaintWiresCommand.new(across, 1, 0)
	world.enqueue(same)
	world.flush_commands()
	nets.sync(g, g.wire, 99)
	check_eq(nets.count, 1, "painting the same channel again changes nothing")
