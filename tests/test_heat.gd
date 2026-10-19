extends TestSuite
## Heat field checks: conduction conserves energy and stays stable, absorbed light and the
## sky heat and cool surfaces, banded updates match full ones, objects own their heat (D13).


## Air above stone, the ground's top at row 10.
func _ground_world() -> SimWorld:
	var world := SimWorld.new(load_materials(), 16, 16, 1)
	var g := world.grid
	var stone := world.materials.id_of(&"stone")
	for i in g.size():
		g.material[i] = stone if i / g.width >= 10 else MaterialDB.AIR_ID
	g.mark_structure_changed()
	return world


func _stone_world() -> SimWorld:
	var world := SimWorld.new(load_materials(), 16, 16, 1)
	var g := world.grid
	g.material.fill(world.materials.id_of(&"stone"))
	g.mark_structure_changed()
	return world


## With radiation and ambient exchange off, conduction only moves energy around.
func test_conduction_conserves_energy_and_spreads() -> void:
	var world := _stone_world()
	var heat: ThermalSystem = world.get_system(&"heat")
	heat.radiation_enabled = false
	heat.ambient_enabled = false
	var g := world.grid
	var hot := g.idx(8, 8)
	g.temperature[hot] = 800.0
	var e0 := heat.total_energy(world)
	for k in 200:
		heat.step(world, 0.1)
	check_near(heat.total_energy(world) / e0, 1.0, 1e-5, "energy conserved")
	check(g.temperature[g.idx(9, 8)] > SimConst.DEFAULT_AMBIENT_K + 1.0, "neighbour warmed")
	check(g.temperature[hot] < 800.0, "hot spot cooled")


## A copper block sits at the stability limit's worst case and must not oscillate.
func test_conduction_is_stable_in_copper() -> void:
	var world := _stone_world()
	var g := world.grid
	g.material.fill(world.materials.id_of(&"copper"))
	g.mark_structure_changed()
	var heat: ThermalSystem = world.get_system(&"heat")
	heat.radiation_enabled = false
	heat.ambient_enabled = false
	g.temperature[g.idx(8, 8)] = 2000.0
	for k in 100:
		heat.step(world, 1.0)
	var lo := INF
	var hi := -INF
	for t in g.temperature:
		lo = minf(lo, t)
		hi = maxf(hi, t)
	check(lo >= SimConst.DEFAULT_AMBIENT_K - 0.01 and hi <= 2000.0, "bounded (%.1f..%.1f)" % [lo, hi])


## Deposited energy raises temperature by E / C.
func test_energy_in_raises_temperature() -> void:
	var world := _stone_world()
	var heat: ThermalSystem = world.get_system(&"heat")
	heat.conduction_enabled = false
	heat.radiation_enabled = false
	heat.ambient_enabled = false
	var g := world.grid
	var i := g.idx(3, 3)
	var c := world.materials.get_by_key(&"stone").tile_heat_capacity() * SimConst.HEAT_CAPACITY_SCALE_SOLID
	var t0 := g.temperature[i]
	g.energy_in[i] = 1000.0
	heat.step(world, 0.1)
	check_near(g.temperature[i] - t0, 1000.0 / c, 1e-3, "ΔT = E/C")
	check_eq(g.energy_in[i], 0.0, "energy consumed")


## Midday sun warms the ground surface; it is the surface, not the deep rock, that heats.
func test_sun_heats_ground_surface() -> void:
	var world := SimWorld.new(load_materials(), 32, 32, 5)
	WorldGen.generate(world)
	world.time_s = 0.45 * SimConst.DAY_LENGTH_S
	var g := world.grid
	var sky := g.sky_tiles(world.materials.is_gas)
	var surface := sky[sky.size() / 2]
	var deep := g.size() - g.width / 2
	var t_surface := g.temperature[surface]
	var t_deep := g.temperature[deep]
	for k in SimConst.TICK_RATE * 30:
		world.tick()
	check(g.temperature[surface] > t_surface + 0.5, "surface warmed %.2f K" % (g.temperature[surface] - t_surface))
	check(absf(g.temperature[deep] - t_deep) < 0.1, "deep rock unchanged")


## At night, sky-facing surfaces cool below ambient by radiating to the cold sky.
func test_night_sky_cools_surface() -> void:
	var world := SimWorld.new(load_materials(), 32, 32, 5)
	WorldGen.generate(world)
	world.time_s = 0.0
	var g := world.grid
	var sky := g.sky_tiles(world.materials.is_gas)
	var surface := sky[sky.size() / 2]
	var t0 := g.temperature[surface]
	for k in SimConst.TICK_RATE * 60:
		world.tick()
	check(g.temperature[surface] < t0 - 0.2, "surface cooled %.2f K" % (t0 - g.temperature[surface]))


## Light put into the surface skin (D18) leaves it as heat in the tiles around it, exactly
## (radiation off, so nothing leaves the world).
func test_skin_passes_light_into_tiles() -> void:
	var world := _ground_world()
	var heat: ThermalSystem = world.get_system(&"heat")
	heat.radiation_enabled = false
	heat.ambient_enabled = false
	var skin := world.skin
	skin.sync(world)
	check(skin.faces >= world.grid.width, "the ground's top faces have skin (%d faces)" % skin.faces)
	var e0 := heat.total_energy(world)
	var face := skin.face_of[world.grid.idx(8, 10) * 4]
	skin.light_w[face * skin.strips + 4] = 4000.0   # 400 J over the step, on one strip
	skin.light_scale = 1.0
	skin.face_energy_in[face] = 100.0             # 100 J spread over the face (diffuse)
	heat.step(world, 0.1)
	check_near(heat.total_energy(world) - e0, 500.0, 0.5, "all 500 J reach the tiles")
	check_eq(skin.face_energy_in[face], 0.0, "diffuse energy consumed")


## A lens focused on the ground heats a spot on the surface (D18): the focal strip runs far
## hotter than the block under it and than plain sunlit ground nearby.
func test_focus_heats_a_spot_on_the_surface() -> void:
	var world := _ground_world()
	world.time_s = 0.5 * SimConst.DAY_LENGTH_S
	world.tick()
	var lens: ObjectDef = load("res://data/objects/lens_crown.tres")
	var top := 10 * SimConst.TILE_M
	world.enqueue(PlaceObjectCommand.new(lens, Vector2(2.0, top - 1.1)))
	world.flush_commands()
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	for k in SimConst.TICK_RATE * 10:
		world.tick()
	# The sun moves while it runs, so find the focus among the tiles under the lens (x 1.5-2.5 m).
	var g := world.grid
	var spot := g.idx(6, 10)
	for x in range(6, 10):
		if world.skin.max_temperature(g.idx(x, 10)) > world.skin.max_temperature(spot):
			spot = g.idx(x, 10)
	var t_spot := world.skin.max_temperature(spot)
	var t_plain := world.skin.max_temperature(g.idx(13, 10))
	check(t_spot > g.temperature[spot] + 50.0, "focal strip %.0f K above its block" % (t_spot - g.temperature[spot]))
	check(t_spot > t_plain + 40.0, "and %.0f K above plain sunlit ground" % (t_spot - t_plain))


## Skipping quiet rows (uniform rows next to an equal row) leaves the simulation unchanged.
func test_quiet_rows_match_full_conduction() -> void:
	var temps: Array[PackedFloat32Array] = []
	for quiet in [true, false]:
		var world := SimWorld.new(load_materials(), 48, 40, 5)
		WorldGen.generate(world)
		world.time_s = 0.45 * SimConst.DAY_LENGTH_S
		var heat: ThermalSystem = world.get_system(&"heat")
		heat.quiet_rows_enabled = quiet
		for k in SimConst.TICK_RATE * 60:
			world.tick()
		temps.append(world.grid.temperature.duplicate())
	var worst := 0.0
	for i in temps[0].size():
		worst = maxf(worst, absf(temps[0][i] - temps[1][i]))
	check(worst < 0.01, "max temperature difference %.5f K" % worst)


## Light absorbed inside a lens heats the lens's own thermal node (D13), not the air tiles
## it sits in; the lens then warms that air by convection.
func test_lens_heats_itself_not_its_tiles() -> void:
	var world := SimWorld.new(load_materials(), 40, 30, 1)
	world.time_s = 0.5 * SimConst.DAY_LENGTH_S
	world.tick()
	var lens: ObjectDef = load("res://data/objects/lens_acrylic.tres")
	world.enqueue(PlaceObjectCommand.new(lens, Vector2(5.0, 3.0), 0.0))
	world.flush_commands()
	var obj: SimObject = world.objects[world.next_object_id - 1]
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	check(obj.absorbed_w > 1.0, "lens absorbs light (%.1f W)" % obj.absorbed_w)
	var g := world.grid
	var host := 0.0
	for i in obj.footprint(g):
		host += light.tile_power[i]
	check_near(host, 0.0, 1e-6, "no light deposited in the tiles under the lens")
	for k in 400:
		world.tick()
	var air := 0.0
	var tiles := obj.footprint(g)
	for i in tiles:
		air += g.temperature[i]
	air /= tiles.size()
	check(obj.temperature_k > air + 0.5, "lens warms above the air around it (%.2f K over)"
		% (obj.temperature_k - air))
