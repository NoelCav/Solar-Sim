extends TestSuite
## Solar cell model checks (design doc §9.1, SolarCell), wires and selling power (§10).

const CELL_SI := preload("res://data/objects/cell_si.tres")


func _efficiency(def: ObjectDef, suns: float, temp_k: float = SolarCell.T_REF_K) -> float:
	var watts := suns * SimConst.REFERENCE_DNI
	return SolarCell.max_power(def, Spectrum.from_total(watts), temp_k, 1.0) / watts


## Crystalline silicon at 1 sun, 25 °C: ≈22 %, like a good commercial panel.
func test_silicon_at_one_sun() -> void:
	var eta := _efficiency(ObjectDef.new(), 1.0)
	check(eta > 0.21 and eta < 0.23, "Si efficiency %.3f" % eta)


## Photons below the bandgap make no power (they heat the cell).
func test_below_bandgap_makes_nothing() -> void:
	var s := Spectrum.make_zero()
	s[Spectrum.BIN_COUNT - 1] = 1000.0   # 0.83 eV infrared, below Si's 1.12 eV
	check_eq(SolarCell.max_power(ObjectDef.new(), s, SolarCell.T_REF_K, 1.0), 0.0, "IR below Eg")


## Concentration raises the voltage, then series resistance takes over (§9.1): better at
## 20 suns than at 1, nothing left by 500.
func test_concentration_helps_then_hurts() -> void:
	var def := ObjectDef.new()
	var one := _efficiency(def, 1.0)
	var twenty := _efficiency(def, 20.0)
	check(twenty > one, "20 suns %.3f > 1 sun %.3f" % [twenty, one])
	check_eq(_efficiency(def, 500.0), 0.0, "500 suns: series loss takes it all")


## A cell panel in the noon sun (§9.2): its front records all the light arriving on it, it
## absorbs what its coating doesn't reflect, and makes about a fifth of it as power. Turned
## over, its back takes the light and nothing is recorded.
func test_cell_reads_the_sun_on_its_front() -> void:
	var cell := CELL_SI
	for flipped in [false, true]:
		var world := SimWorld.new(load_materials(), 16, 16, 1)
		world.time_s = 0.5 * SimConst.DAY_LENGTH_S
		world.tick()
		world.enqueue(PlaceObjectCommand.new(cell, Vector2(2.0, 1.5), PI if flipped else 0.0))
		world.flush_commands()
		var light: LightSystem = world.get_system(&"light")
		light.retrace(world)
		var obj: SimObject = world.objects[world.next_object_id - 1]
		var area := cell.size_m * SimConst.DEPTH_M
		var arriving := world.light_dni * absf(world.light_direction.y) * area
		var reflected := 0.0
		for b in Spectrum.BIN_COUNT:
			reflected += obj.incident[b] * cell.reflectance[b]
		if flipped:
			check_eq(Spectrum.total(obj.incident), 0.0, "back: nothing recorded")
			check(obj.absorbed_w > 0.5 * arriving, "back absorbs %.0f of %.0f W" % [obj.absorbed_w, arriving])
			continue
		check_near(Spectrum.total(obj.incident), arriving, 0.02 * arriving, "front records the sun")
		check_near(obj.absorbed_w, Spectrum.total(obj.incident) - reflected, 0.01 * arriving, "absorbs 1 − R")
		var eta := SolarCell.object_power(obj, light.power_scale(world)) / arriving
		check(eta > 0.17 and eta < 0.24, "efficiency in the noon sun %.3f" % eta)


## A hot cell loses voltage: 50 K above 25 °C costs 20 % of its output (β = 0.004/K).
func test_hot_cell_loses_output() -> void:
	var def := ObjectDef.new()
	check_near(_efficiency(def, 1.0, SolarCell.T_REF_K + 50.0) / _efficiency(def, 1.0), 0.8, 1e-4, "η_temp at +50 K")


## Wires (D14): runs of wire joined through tile edges form networks (diagonals don't join);
## a bridge merges two networks, undo splits them again.
func test_wires_form_networks() -> void:
	var world := SimWorld.new(load_materials(), 16, 8, 1)
	var g := world.grid
	var nets := ConduitNetworks.new()
	world.enqueue(PaintWiresCommand.new(PackedInt32Array([g.idx(1, 2), g.idx(2, 2), g.idx(3, 2)])))
	world.enqueue(PaintWiresCommand.new(PackedInt32Array([g.idx(6, 2), g.idx(6, 3), g.idx(7, 4)])))
	world.flush_commands()
	nets.sync(g, g.wire)
	check_eq(nets.count, 3, "two runs and a diagonal neighbour")
	check_eq(nets.at(g.idx(1, 2)), nets.at(g.idx(3, 2)), "a run is one network")
	check(nets.at(g.idx(6, 3)) != nets.at(g.idx(7, 4)), "diagonals don't join")
	check_eq(nets.at(g.idx(0, 0)), -1, "no wire, no network")
	world.enqueue(PaintWiresCommand.new(PackedInt32Array([g.idx(4, 2), g.idx(5, 2)])))
	world.flush_commands()
	nets.sync(g, g.wire)
	check_eq(nets.count, 2, "bridged")
	check_eq(nets.at(g.idx(1, 2)), nets.at(g.idx(6, 3)), "one network across the bridge")
	world.enqueue(UndoCommand.new())
	world.flush_commands()
	nets.sync(g, g.wire)
	check_eq(nets.count, 3, "undo splits them")


## A ground of stone (rows 10+) at noon with a cell panel on a 1 m stand (column 8) and a grid
## connection (column 12); `wired` lays wire along the ground between their feet.
func _array_world(wired: bool) -> SimWorld:
	var world := SimWorld.new(load_materials(), 16, 16, 1)
	var g := world.grid
	var stone := world.materials.id_of(&"stone")
	for i in g.size():
		g.material[i] = stone if i / g.width >= 10 else MaterialDB.AIR_ID
	g.mark_structure_changed()
	world.time_s = 0.5 * SimConst.DAY_LENGTH_S
	world.tick()
	world.enqueue(PlaceObjectCommand.new(CELL_SI, Vector2(2.1, 1.5), 0.0, true))
	world.enqueue(PlaceObjectCommand.new(load("res://data/objects/grid_tie.tres"), Vector2(3.1, 2.0), 0.0, true))
	if wired:
		var cells := PackedInt32Array()
		for x in range(8, 13):
			cells.append(g.idx(x, 9))
		world.enqueue(PaintWiresCommand.new(cells))
	world.flush_commands()
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	return world


## A cell wired to a grid connection sells what it makes (§10); unwired, it sells nothing.
## Delivered energy leaves the cell's heat, so a working cell runs cooler than an idle one.
func test_wired_cell_sells_power() -> void:
	var temps := []
	for wired in [true, false]:
		var world := _array_world(wired)
		check_eq(world.objects.size(), 2, "cell and grid connection placed")
		var cell: SimObject = world.objects[1]
		var tie: SimObject = world.objects[2]
		check_near(tie.position.y + tie.def.thickness_m * 0.5, 2.5 - Mounting.GROUND_LIFT_M, 1e-4,
			"grid connection rests on the ground")
		var light: LightSystem = world.get_system(&"light")
		var could := SolarCell.object_power(cell, light.power_scale(world))   # Power runs before heat
		# Before any tick (as while paused) the power system already knows who sells what.
		var power: PowerSystem = world.get_system(&"power")
		check_eq(power.sells(world, cell), wired, "sells before a tick")
		check_near(power.output_w(world, power.network_of(world, tie)), could if wired else 0.0, 1e-3,
			"network output before a tick")
		world.tick()
		if wired:
			check(cell.power_w > 30.0, "wired cell delivers %.1f W" % cell.power_w)
			check_near(cell.power_w, could, 1e-3, "all it can make")
			check(world.money > 0.0, "money earned %.6f" % world.money)
		else:
			check_eq(cell.power_w, 0.0, "unwired: open circuit")
			check_eq(world.money, 0.0, "nothing sold")
		for k in SimConst.TICK_RATE * 30:
			world.tick()
		temps.append(cell.temperature_k)
	check(temps[0] < temps[1] - 0.5, "working cell cooler: %.2f vs %.2f K" % [temps[0], temps[1]])


## The duck curve (§10): power is cheap at noon, dear in the evening, continuous over midnight.
func test_duck_curve() -> void:
	var world := SimWorld.new(load_materials(), 4, 4, 1)
	var at := func(hour: float) -> float:
		world.time_s = hour / 24.0 * SimConst.DAY_LENGTH_S
		return Market.price_per_kwh(world)
	check(at.call(12.0) < at.call(8.0) and at.call(12.0) < at.call(19.0), "midday dip")
	check(at.call(19.0) > at.call(17.0) and at.call(19.0) > at.call(21.0), "evening peak")
	check_near(at.call(23.999), at.call(0.0), 1e-3, "continuous at midnight")
