extends "res://tests/optics_fixtures.gd"
## Point sources (lamps, design doc §6.11): what a pass over a lamp's light must do.


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
