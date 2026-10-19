extends TestSuite


func _make_world(seed_value: int = 7) -> SimWorld:
	var world := SimWorld.new(load_materials(), 64, 32, seed_value)
	WorldGen.generate(world)
	return world


func test_grid_allocates_every_layer() -> void:
	var g := TileGrid.new(10, 5)
	for layer in [g.material, g.temperature, g.integrity, g.flags, g.object_id,
			g.liquid_amount, g.liquid_type, g.smoke, g.steam, g.energy_in]:
		check_eq(layer.size(), 50, "layer size")
	check_eq(g.idx(3, 2), 23, "index")
	check_eq(g.coords(23), Vector2i(3, 2), "coords")


func test_ticks_advance_time() -> void:
	var world := _make_world()
	var t0 := world.time_s
	for i in SimConst.TICK_RATE:
		world.tick()
	check_eq(world.tick_count, SimConst.TICK_RATE, "tick count")
	check_near(world.time_s - t0, 1.0, 1e-6, "one second")


func test_sun_rises_east_and_sets_west() -> void:
	var world := _make_world()
	world.time_s = 0.30 * SimConst.DAY_LENGTH_S
	world.tick()
	check(world.sun_is_up and world.sun_direction.x > 0.0, "morning light travels west→east (+x)")
	world.time_s = 0.70 * SimConst.DAY_LENGTH_S
	world.tick()
	check(world.sun_is_up and world.sun_direction.x < 0.0, "evening light travels -x")
	world.time_s = 0.0
	world.tick()
	check(not world.sun_is_up, "midnight")


func test_paint_command_applies_and_undoes() -> void:
	var world := _make_world()
	var g := world.grid
	var i := g.idx(5, 2)
	var before := g.material[i]
	var steel := world.materials.id_of(&"steel")
	world.enqueue(PaintTilesCommand.new(PackedInt32Array([i]), steel))
	world.tick()
	check_eq(g.material[i], steel, "painted")
	world.enqueue(UndoCommand.new())
	world.tick()
	check_eq(g.material[i], before, "undone")


func test_same_seed_and_commands_are_deterministic() -> void:
	var a := _make_world(42)
	var b := _make_world(42)
	var copper := a.materials.id_of(&"copper")
	for w in [a, b]:
		w.enqueue(PaintTilesCommand.new(PackedInt32Array([10, 11, 12]), copper, 500.0))
		for i in 100:
			w.tick()
	check_eq(a.state_hash(), b.state_hash(), "state hash")
	check(a.state_hash() != _make_world(43).state_hash(), "different seed differs")
