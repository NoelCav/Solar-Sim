extends "res://tests/optics_fixtures.gd"
## Point sources (lamps, design doc §6.11): what a pass over a lamp's light must do.

const LAMP := preload("res://data/objects/lamp_led.tres")
const CELL_SI := preload("res://data/objects/cell_si.tres")


## A complete pass over `world` for one lamp, on a pass of its own (the sky is not involved).
func _lamp_pass(world: SimWorld, lamp: LightSource) -> LightPass:
	var p := LightPass.new(world.grid, world.materials)
	p.start(world, lamp)
	p.step(-1)
	return p


## W recorded on a probe (id), direct and through optics together.
func _probe_watts(p: LightPass, id: int) -> float:
	var inc: Dictionary = p.engine.ObjectIncident()
	var total := 0.0
	for v in inc.get(id, PackedFloat32Array()):
		total += v
	return total


func _probe_def(length: float) -> ObjectDef:
	var def := ObjectDef.new()
	def.key = &"test_probe"
	def.kind = ObjectDef.Kind.PROBE
	def.size_m = length
	return def


## An isotropic lamp over flat ground: every watt it emits (2π × W/rad) is absorbed, escapes,
## scatters or is culled, and the ground gets lit.
func test_lamp_conserves_energy() -> void:
	var world := _flat_world(80, 40, 30)
	var lamp := LightSource.point(Vector2(10.0, 4.0), _single_bin(Spectrum.Bin.GREEN, 10.0))
	var p := _lamp_pass(world, lamp)
	var s: Dictionary = p.engine.Stats()
	check_near(s.emitted, 10.0 * TAU, 10.0 * TAU * 2e-3, "emits 2π × intensity")
	_check_energy_balance(s)
	check(s.absorbed > 0.2 * s.emitted, "the ground below absorbs a good share (%.1f W)" % s.absorbed)
	check(s.escaped > 0.3 * s.emitted, "the upward half escapes (%.1f W)" % s.escaped)


## A probe in a lamp's light reads intensity × the angle it subtends: a line source's light falls
## as 1/r, so the same probe twice as far reads half as much.
func test_lamp_light_falls_as_one_over_r() -> void:
	var readings := []
	for r in [3.0, 6.0]:
		var world := _make_world()
		var probe := _place(world, _probe_def(1.0), Vector2(5.0 + r, 4.0), PI * 0.5)   # Vertical, 1 m long
		var lamp := LightSource.point(Vector2(5.0, 4.0), _single_bin(Spectrum.Bin.GREEN, 10.0))
		var p := _lamp_pass(world, lamp)
		var angle := 2.0 * atan(0.5 / r)
		var got := _probe_watts(p, probe.id)
		check_near(got, 10.0 * angle, 10.0 * SimConst.LANE_WIDTH_RAD * 2.0, "r = %.0f m: I × subtended angle" % r)
		readings.append(got)
	check_near(readings[1] / readings[0], 0.5, 0.02, "twice as far, half as much per metre of probe")


## A lamp emits only into its cone.
func test_lamp_cone_limits_emission() -> void:
	var world := _flat_world(80, 40, 30)
	var lamp := LightSource.point(Vector2(10.0, 4.0), _single_bin(Spectrum.Bin.GREEN, 10.0),
		0.5 * PI - 0.3, 0.5 * PI + 0.3)
	var s: Dictionary = _lamp_pass(world, lamp).engine.Stats()
	check_near(s.emitted, 10.0 * 0.6, 10.0 * SimConst.LANE_WIDTH_RAD * 2.0, "emits intensity × cone angle")
	_check_energy_balance(s)


## A lamp at a lens's front focal point sends a beam as wide as the lens that doesn't spread:
## the same irradiance a metre and three metres below, and none outside the lens's width.
func test_lamp_at_focus_makes_a_parallel_beam() -> void:
	var world := _make_world()
	var r := 2.0
	var t := 0.15
	var center := Vector2(10.0, 4.0)
	_place(world, _lens_def(r, r, t), center)   # 1 m wide
	var bin := Spectrum.Bin.GREEN
	var n := world.materials.get_by_key(&"crown_glass").refractive_index(Spectrum.WAVELENGTH_UM[bin])
	var f := 1.0 / ((n - 1.0) * (2.0 / r - (n - 1.0) * t / (n * r * r)))
	var ffd := f * (1.0 - (n - 1.0) * t / (n * r))
	var probes := {}
	for y in [5.0, 7.0]:
		for dx in [0.0, 0.15, 0.9]:
			probes[Vector2(dx, y)] = _place(world, _probe_def(0.1), Vector2(center.x + dx, y)).id
	var lamp := LightSource.point(Vector2(center.x, center.y - t * 0.5 - ffd), _single_bin(bin, 10.0))
	var p := _lamp_pass(world, lamp)
	var near_mid := _probe_watts(p, probes[Vector2(0.0, 5.0)])
	var far_mid := _probe_watts(p, probes[Vector2(0.0, 7.0)])
	check(near_mid > 0.0, "light comes through the lens (%.4f W)" % near_mid)
	check_near(far_mid / near_mid, 1.0, 0.08, "same irradiance 2 m further on")
	check_near(_probe_watts(p, probes[Vector2(0.15, 7.0)]) / far_mid, 1.0, 0.15, "even across the beam")
	check(_probe_watts(p, probes[Vector2(0.9, 7.0)]) < 0.03 * far_mid, "nothing outside the lens's width")


# --- Lamp objects (the lamp layer) -----------------------------------------------------------------

## Stone ground below row 15; an LED lamp on a stand 1.5 m above it at x = 5 m and a cell panel
## 0.75 m above it right under the lamp.
func _lamp_world() -> SimWorld:
	var world := _flat_world(40, 20, 15)
	world.tick()
	world.enqueue(PlaceObjectCommand.new(LAMP, Vector2(5.0, 2.25), 0.0, true))
	world.enqueue(PlaceObjectCommand.new(CELL_SI, Vector2(5.0, 3.0), 0.0, true))
	world.flush_commands()
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	return world


func _object_of_kind(world: SimWorld, kind: ObjectDef.Kind) -> SimObject:
	for obj: SimObject in world.objects.values():
		if obj.def.kind == kind:
			return obj
	return null


## A lamp object lights the world through a layer of its own: all the light it gives is emitted,
## and the cell below it receives intensity × the angle the cell subtends.
func test_lamp_object_lights_a_cell() -> void:
	var world := _lamp_world()
	var light: LightSystem = world.get_system(&"light")
	var lamp := _object_of_kind(world, ObjectDef.Kind.LAMP)
	var cell := _object_of_kind(world, ObjectDef.Kind.CELL)
	check(light.lamps.has(lamp.id), "the lamp has a layer")
	var layer: LightLayer = light.lamps[lamp.id]
	_check_energy_balance(layer.stats)
	check_near(layer.stats.emitted, LAMP.lamp_light_w(), LAMP.lamp_light_w() * 3e-3, "emits its light")
	var dist := absf(lamp.position.y - cell.position.y)
	var arriving := LAMP.lamp_light_w() / TAU * 2.0 * atan(0.5 * CELL_SI.size_m / dist)
	check_near(Spectrum.total(cell.lamp_light), arriving, arriving * 0.03,
		"the cell gets I × the angle it subtends")


## Dimming scales a lamp's light: half the level, half the light on the cell, after its next pass.
func test_dimmed_lamp_gives_less() -> void:
	var world := _lamp_world()
	var light: LightSystem = world.get_system(&"light")
	var lamp := _object_of_kind(world, ObjectDef.Kind.LAMP)
	var cell := _object_of_kind(world, ObjectDef.Kind.CELL)
	var full := Spectrum.total(cell.lamp_light)
	lamp.lamp_level = 0.5
	world.tick()   # Within the re-trace threshold the layer rescales its traced light
	world.tick()
	light.retrace(world)
	check_near(Spectrum.total(cell.lamp_light), 0.5 * full, 0.02 * full,
		"half the level, half the light")
	lamp.lamp_level = 0.0
	light.retrace(world)
	check_eq(Spectrum.total(cell.lamp_light), 0.0, "off: dark")


## Light from a lamp is heat where it lands: what the layer deposits in a tick (tiles, the skin,
## the cell's body) is what it absorbed.
func test_lamp_light_heats_the_ground() -> void:
	var world := _lamp_world()
	var light: LightSystem = world.get_system(&"light")
	var lamp := _object_of_kind(world, ObjectDef.Kind.LAMP)
	var cell := _object_of_kind(world, ObjectDef.Kind.CELL)
	var layer: LightLayer = light.lamps[lamp.id]
	world.grid.energy_in.fill(0.0)
	cell.heat_in = 0.0
	layer.tick(world, SimConst.DT)
	var deposited: float = cell.heat_in
	for i in world.grid.size():
		deposited += world.grid.energy_in[i]
	var skin_w := PackedFloat32Array()
	skin_w.resize(world.skin.faces * world.skin.strips)
	layer.write_skin(world, skin_w, true)
	for w in skin_w:
		deposited += w * SimConst.DT
	var absorbed: float = layer.stats.absorbed
	check(absorbed > 0.2 * LAMP.lamp_light_w(), "the lamp's light is absorbed (%.2f W)" % absorbed)
	check_near(deposited, absorbed * SimConst.DT, absorbed * SimConst.DT * 1e-3, "light absorbed = heat deposited")
