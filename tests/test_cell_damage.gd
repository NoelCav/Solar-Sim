extends TestSuite
## Heat damage to solar cells (design §9.1): health falls above the degrade temperature, fast near
## failure, never recovers, takes output with it and shows in the analysis.

const CELL := preload("res://data/objects/cell_si.tres")


func test_damage_rate_grows_toward_failure() -> void:
	var k := func(c: float) -> float: return SolarCell.damage_rate(CELL, 273.15 + c)
	check_eq(k.call(60.0), 0.0, "nothing at 60 °C")
	check_eq(k.call(85.0), 0.0, "nothing at the degrade temperature")
	check(k.call(94.0) > 0.0 and k.call(94.0) < 0.005, "a slow wear just above it (%.4f/s)" % k.call(94.0))
	check(k.call(132.0) > k.call(94.0) * 10.0, "much faster at 132 °C")
	check_near(1.0 / k.call(180.0), 5.0, 1e-6, "lost in 5 s at the failure temperature")


func test_a_hot_cell_wears_and_a_cool_one_does_not() -> void:
	var world := SimWorld.new(load_materials(), 16, 16, 1)
	var cool := _cell_in(world, 1.0)
	var hot := _cell_in(world, 3.0)
	var power: PowerSystem = world.get_system(&"power")
	for k in int(10.0 / SimConst.DT):
		cool.temperature_k = 273.15 + 70.0
		hot.temperature_k = 273.15 + 150.0
		power.tick(world, SimConst.DT)
	check_eq(cool.health, 1.0, "70 °C: untouched")
	check(hot.health < 0.2 and hot.health > 0.0, "150 °C for 10 s: nearly gone (%.2f)" % hot.health)
	var before := hot.health
	hot.temperature_k = 273.15 + 20.0
	for k in 100:
		power.tick(world, SimConst.DT)
	check_eq(hot.health, before, "wear is permanent")


func _cell_in(world: SimWorld, x: float) -> SimObject:
	var g := world.grid
	var stone := world.materials.id_of(&"stone")
	for i in g.size():
		g.material[i] = stone if i / g.width >= 10 else MaterialDB.AIR_ID
	g.mark_structure_changed()
	world.time_s = 0.5 * SimConst.DAY_LENGTH_S
	world.tick()
	world.enqueue(PlaceObjectCommand.new(CELL, Vector2(x, 1.5), 0.0, true))
	world.flush_commands()
	(world.get_system(&"light") as LightSystem).retrace(world)
	return world.objects[world.next_object_id - 1]


## Health takes output: half the health, half the power, the rest shown as damage in the breakdown; a
## failed cell makes nothing.
func test_health_takes_output() -> void:
	var world := SimWorld.new(load_materials(), 16, 16, 1)
	var cell := _cell_in(world, 2.0)
	var light: LightSystem = world.get_system(&"light")
	var scale := light.power_scale(world)
	var full := SolarCell.object_power(cell, scale)
	cell.health = 0.5
	var a := SolarCell.object_analysis(cell, scale)
	check_near(a.power_w, 0.5 * full, 1e-6, "half the power")
	check_near(a.damage_w, 0.5 * full, 1e-6, "the other half is damage")
	check_near(Spectrum.total(a.power_bin_w), a.power_w, 1e-6, "per band adds up")
	cell.health = 0.0
	check_eq(SolarCell.object_power(cell, scale), 0.0, "a failed cell makes nothing")


func test_health_saves() -> void:
	var world := SimWorld.new(load_materials(), 16, 16, 1)
	var cell := _cell_in(world, 2.0)
	cell.health = 0.37
	var data: Dictionary = JSON.parse_string(SiteSave.to_text(world))
	var defs := ObjectDB.new()
	defs.load_dir()
	var fresh := SimWorld.new(load_materials(), 16, 16, 1)
	check_eq(SiteSave.restore(fresh, data, defs), "", "restores")
	for obj: SimObject in fresh.objects.values():
		check_eq(obj.health, 0.37, "health kept")
