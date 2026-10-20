extends "res://tests/optics_fixtures.gd"
## Beam splitters and dichroic mirrors (design §6.9): the engine forks a run at a splitter, so each
## branch is a traced beam carrying its share; what is neither reflected nor passed heats the plate;
## every watt is still accounted for.


## Probes are narrower than the beam, so they read the beam and none of the open sky around it.
const PROBE_M := 0.6


func _db() -> ObjectDB:
	var db := ObjectDB.new()
	db.load_dir()
	return db


## A pass of sunlight straight down with `spectrum` W/m² per bin over `world`.
func _sun_pass(world: SimWorld, spectrum: PackedFloat32Array) -> LightPass:
	var p := LightPass.new(world.grid, world.materials)
	p.start(world, LightSource.parallel(Vector2.DOWN, spectrum, Spectrum.total(spectrum)))
	p.step(-1)
	return p


## W of bin `bin` recorded on a probe (direct and through optics).
func _probe_bin(p: LightPass, id: int, bin: int) -> float:
	var inc: PackedFloat32Array = (p.engine.ObjectIncident() as Dictionary).get(id, PackedFloat32Array())
	return 0.0 if inc.is_empty() else inc[bin] + inc[Spectrum.BIN_COUNT + bin]


func _balance(p: LightPass) -> void:
	var s: Dictionary = p.engine.Stats()
	check_near(s.absorbed + s.escaped + s.scattered + s.culled, s.emitted, s.emitted * 1e-4, "every watt accounted for")


## The scene: sunlight straight down meets a splitter tilted 45° at (10, 4): what passes goes on down
## to a wide probe below, what is reflected leaves toward +x, to a tall probe at x = 14.
func _scene(def: ObjectDef, spectrum: PackedFloat32Array) -> Array:
	var world := _make_world()
	var splitter := _place(world, def, Vector2(10.0, 4.0), PI * 0.25)
	var passed := _place(world, _probe_def(PROBE_M), Vector2(10.0, 6.5))
	var reflected := _place(world, _probe_def(PROBE_M), Vector2(14.0, 4.0), PI * 0.5)
	return [world, splitter, passed, reflected, _sun_pass(world, spectrum)]


## A 50/50 plate: the transmitted and the reflected beam each carry their share of what it
## intercepts, and the 5 % it absorbs heats it.
func test_half_mirror_splits_the_light() -> void:
	var def := _db().get_by_key(&"splitter_half")
	var green := _single_bin(Spectrum.Bin.GREEN, 1000.0)
	var sc := _scene(def, green)
	var p: LightPass = sc[4]
	var bin := Spectrum.Bin.GREEN
	var arriving := 1000.0 * SimConst.DEPTH_M * PROBE_M   # The part of the beam the probes read
	var intercepted := 1000.0 * SimConst.DEPTH_M * def.size_m * cos(PI * 0.25)
	check_near(_probe_bin(p, sc[2].id, bin), 0.45 * arriving, 0.02 * arriving, "passes 45 %")
	check_near(_probe_bin(p, sc[3].id, bin), 0.50 * arriving, 0.02 * arriving, "reflects 50 %")
	check_near((p.engine.ObjectAbsorbed() as Dictionary).get(sc[1].id, 0.0), 0.05 * intercepted, 0.01 * intercepted,
		"absorbs 5 %, heating the plate")
	_balance(p)


## A hot mirror reflects infrared and passes visible light; a cold mirror does the opposite: per bin,
## which side the light leaves on.
func test_dichroic_mirrors_sort_by_color() -> void:
	var both := Spectrum.make_zero()
	both[Spectrum.Bin.RED] = 500.0
	both[Spectrum.Bin.NIR] = 500.0
	for key in [&"dichroic_hot", &"dichroic_cold"]:
		var def := _db().get_by_key(key)
		var sc := _scene(def, both)
		var p: LightPass = sc[4]
		var arriving := 500.0 * SimConst.DEPTH_M * PROBE_M
		for bin in [Spectrum.Bin.RED, Spectrum.Bin.NIR]:
			var t := def.transmittance[bin] * arriving
			var r := def.reflectance[bin] * arriving
			check_near(_probe_bin(p, sc[2].id, bin), t, 0.02 * arriving, "%s bin %d passes %.1f W" % [key, bin, t])
			check_near(_probe_bin(p, sc[3].id, bin), r, 0.02 * arriving, "%s bin %d reflects %.1f W" % [key, bin, r])
		_balance(p)
	var hot := _db().get_by_key(&"dichroic_hot")
	check(hot.reflectance[Spectrum.Bin.NIR] > 0.8 and hot.transmittance[Spectrum.Bin.RED] > 0.8, "hot mirror data")


## Two splitters in the path: four branches, the pass-pass one carries 0.45 × 0.45 of the input, and the
## energy is still all accounted for (the reflected branch of the first meets the second).
func test_two_splitters_in_series() -> void:
	var def := _db().get_by_key(&"splitter_half")
	var world := _make_world()
	_place(world, def, Vector2(10.0, 4.0), PI * 0.25)
	_place(world, def, Vector2(10.0, 5.5), -PI * 0.25)
	var below := _place(world, _probe_def(PROBE_M), Vector2(10.0, 7.5))
	var p := _sun_pass(world, _single_bin(Spectrum.Bin.GREEN, 1000.0))
	var arriving := 1000.0 * SimConst.DEPTH_M * PROBE_M
	check_near(_probe_bin(p, below.id, Spectrum.Bin.GREEN), 0.45 * 0.45 * arriving, 0.02 * arriving, "passes both: 0.45²")
	_balance(p)
