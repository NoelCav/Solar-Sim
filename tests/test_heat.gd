extends TestSuite


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
