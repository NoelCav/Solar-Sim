extends TestSuite
## World checks: grid layers, ticking, sun and moon motion, commands and undo, determinism.


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



## The moon lags the sun by its phase, so it rises later each day: one rise every
## cycle / (cycle - 1) days.
func test_moon_rises_later_each_day() -> void:
	var world := _make_world()
	var step := SimConst.DAY_LENGTH_S / 2000.0
	var rises: Array[float] = []
	var was_up := true   # Don't count a moon already up at the start
	var t := 0.0
	while t < 4.0 * SimConst.DAY_LENGTH_S and rises.size() < 3:
		world.time_s = t
		world.refresh_environment()
		if world.moon_is_up and not was_up:
			rises.append(t)
		was_up = world.moon_is_up
		t += step
	check_eq(rises.size(), 3, "three moonrises")
	var cycle := SimConst.MOON_CYCLE_DAYS
	var expected := SimConst.DAY_LENGTH_S * cycle / (cycle - 1.0)
	for k in rises.size() - 1:
		check_near(rises[k + 1] - rises[k], expected, 2.0 * step, "moonrise to moonrise")


## At night the moon is the traced light: from its direction, at about MOON_FULL_RATIO of
## sunlight times the lit fraction cubed (less what the atmosphere takes). With the moon
## set, nothing is traced.
func test_moon_is_the_light_at_night() -> void:
	var world := _make_world()
	world.time_s = 1.0 * SimConst.DAY_LENGTH_S   # Midnight, moon a little past full and high
	world.refresh_environment()
	check(not world.sun_is_up and world.moon_is_up, "moon up at midnight")
	check(world.light_is_moon and world.light_is_up, "moon is the traced light")
	check(world.light_direction.is_equal_approx(world.moon_direction), "light comes from the moon")
	check(world.moon_illuminated > 0.9, "nearly full (%.2f lit)" % world.moon_illuminated)
	var top := SimConst.SOLAR_CONSTANT * SimConst.MOON_FULL_RATIO * pow(world.moon_illuminated, 3.0)
	check(world.light_dni < top and world.light_dni > 0.4 * top,
		"moonlight %s W/m² (above the atmosphere %s)" % [String.num_scientific(world.light_dni), String.num_scientific(top)])
	world.time_s = 4.0 * SimConst.DAY_LENGTH_S   # Midnight near new moon: moon down
	world.refresh_environment()
	check(not world.moon_is_up and not world.light_is_up, "no light with the moon set")


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
