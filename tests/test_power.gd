extends TestSuite
## Solar cell model checks (design doc §9.1, SolarCell).


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
	var cell: ObjectDef = load("res://data/objects/cell_si.tres")
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
