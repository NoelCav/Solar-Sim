extends "res://tests/optics_fixtures.gd"
## The optical parts (design §6.9): every lens in the catalog focuses (or diverges) where the
## lensmaker's equation says, concave lenses spread light, and filter plates pass each color as
## their glass does.


## Where a paraxial ray (a little off the axis, traveling down) meets the axis after `def`, m
## below the lens's back vertex; for a diverging lens its back-extension crosses ahead of the
## vertex, so the distance is negative. NAN when no ray left the lens.
func _back_crossing(def: ObjectDef, bin: int) -> float:
	var world := _make_world()
	var center := Vector2(10.0, 10.0)
	_place(world, def, center)
	var tr := _tracer(world)
	tr.Trace(Vector2(center.x + minf(def.size_m * 0.02, 0.01), 0.5), Vector2.DOWN, _single_bin(bin, 1.0))
	var from: PackedVector2Array = tr.SegFrom()
	var to: PackedVector2Array = tr.SegTo()
	var back := center.y + 0.5 * OpticsGen.center_thickness(def.size_m, def.radius_front_m, def.radius_back_m,
		def.thickness_m)
	for k in from.size():
		# The transmitted ray (going down; a Fresnel reflection leaving the back face goes up)
		if from[k].y > back - 0.02 and to[k].y > from[k].y and absf(to[k].x - from[k].x) > 1e-9:
			var s := (center.x - from[k].x) / (to[k].x - from[k].x)
			return from[k].y + s * (to[k].y - from[k].y) - back
	return NAN


## Every lens in the catalog: the paraxial back focal distance equals the lensmaker's equation (a
## plate has none).
func test_every_lens_focuses_where_its_data_says() -> void:
	var db := ObjectDB.new()
	db.load_dir()
	var world := _make_world()
	var bin := Spectrum.Bin.GREEN
	var checked := 0
	for def in db.defs:
		if def.kind != ObjectDef.Kind.LENS:
			continue
		var index := world.materials.get_by_key(def.material).refractive_index(Spectrum.WAVELENGTH_UM[bin])
		var f := OpticsGen.focal_length(def.size_m, def.radius_front_m, def.radius_back_m, def.thickness_m, index)
		if is_inf(f):
			continue
		var t := OpticsGen.center_thickness(def.size_m, def.radius_front_m, def.radius_back_m, def.thickness_m)
		var c1 := 1.0 / def.radius_front_m if def.radius_front_m != 0.0 else 0.0
		var expected := f * (1.0 - (index - 1.0) * t * c1 / index)
		var got := _back_crossing(def, bin)
		check(not is_nan(got), "%s: the ray was traced" % def.key)
		check_near(got, expected, absf(expected) * 0.03 + 0.003, "%s: back focus %.3f m (equation %.3f)" % [
			def.key, got, expected])
		checked += 1
	check(checked >= 8, "several lenses checked (%d)" % checked)


## A concave lens has a negative focal length and bends light away from the axis.
func test_concave_lens_diverges() -> void:
	var db := ObjectDB.new()
	db.load_dir()
	var def := db.get_by_key(&"lens_concave")
	var world := _make_world()
	var index := world.materials.get_by_key(def.material).refractive_index(0.54)
	check(OpticsGen.focal_length(def.size_m, def.radius_front_m, def.radius_back_m, def.thickness_m, index) < 0.0,
		"negative focal length")
	var got := _back_crossing(def, Spectrum.Bin.GREEN)
	check(got < 0.0, "the back-extension of the ray crosses ahead of the lens (%.3f m)" % got)
	_place(world, def, Vector2(10.0, 10.0))
	var tr := _tracer(world)
	tr.Trace(Vector2(10.2, 0.5), Vector2.DOWN, _single_bin(Spectrum.Bin.GREEN, 1.0))
	var from: PackedVector2Array = tr.SegFrom()
	var to: PackedVector2Array = tr.SegTo()
	var last := -1
	for k in from.size():
		if from[k].y > 10.0:
			last = k
	check(last >= 0 and to[last].x > from[last].x + 0.01, "a ray off the axis leaves bent away from it")


## Each filter passes a color as its glass does: two surfaces' reflection and absorption over the plate.
func test_filters_pass_colors_as_their_glass_does() -> void:
	var db := ObjectDB.new()
	db.load_dir()
	for key in [&"plate_red", &"plate_green", &"plate_blue", &"plate_ir_cut", &"plate_uv_cut", &"plate_smoked"]:
		var def := db.get_by_key(key)
		for bin in Spectrum.BIN_COUNT:
			var world := _make_world()
			_place(world, def, Vector2(10.0, 4.0))
			var probe := _place(world, _probe_def(2.0), Vector2(10.0, 6.0))
			var tr := _tracer(world)
			tr.Trace(Vector2(10.0, 0.5), Vector2.DOWN, _single_bin(bin, 1.0))
			var got := 0.0
			for v in (tr.ObjectIncident() as Dictionary).get(probe.id, PackedFloat32Array()):
				got += v
			var glass := world.materials.get_by_key(def.material)
			var index := glass.refractive_index(Spectrum.WAVELENGTH_UM[bin])
			var expected := OpticsGen.normal_transmission(index) * exp(-glass.bulk_absorption[bin] * def.thickness_m)
			check_near(got, expected, 0.02 + expected * 0.02, "%s, bin %d: passes %.3f" % [key, bin, expected])
