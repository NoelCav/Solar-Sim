extends SceneTree
## Performance benchmark on a full-size site (300×120) at mid-morning and noon:
##   godot --headless --path . -s res://tests/bench.gd
## Scenarios: the demo rig, and a field of identical lenses ("lots of light").
## Prints a per-stage breakdown and a location-weighted checksum of absorbed light, so an
## optimization can be checked for unchanged results (same checksum to ~1e-4).


func _initialize() -> void:
	var db := MaterialDB.new()
	db.load_dir()
	var objects := ObjectDB.new()
	objects.load_dir()
	for scenario in ["demo rig", "lens field (30)"]:
		for hour in [9.0, 12.0]:
			_run(db, objects, scenario, hour)
	quit()


func _make(db: MaterialDB, objects: ObjectDB, scenario: String) -> SimWorld:
	var world := SimWorld.new(db, 300, 120, 1)
	WorldGen.generate(world)
	if scenario == "demo rig":
		DemoRig.place(world, objects)
	else:
		var lens := objects.get_by_key(&"lens_crown")
		for k in 30:
			var x := 8.0 + k * 2.0
			world.enqueue(PlaceObjectCommand.new(lens, Vector2(x, DemoRig.ground_y(world, x) - 3.0), 0.0))
		world.flush_commands()
	return world


func _run(db: MaterialDB, objects: ObjectDB, scenario: String, hour: float) -> void:
	# A full pass on a fresh world (nothing to replay), fastest of three: desktop timings are
	# noisy, the minimum is repeatable.
	var world: SimWorld
	var light: LightSystem
	var stages := {}
	var total := INF
	for k in 3:
		world = _make(db, objects, scenario)
		world.time_s = hour / 24.0 * SimConst.DAY_LENGTH_S
		world.tick()
		light = world.get_system(&"light")
		light.retrace(world)
		# A full pass on the same state, with nothing to reuse (retrace would replay it).
		light.retrace(world, true)
		if light.last_trace_ms < total:
			total = light.last_trace_ms
			stages = light.last_stage_ms
	var heat: ThermalSystem = world.get_system(&"heat")
	var s := light.stats
	var balance: float = (s.absorbed + s.escaped + s.scattered + s.culled) / s.emitted
	var checksum := 0.0
	for i in light.tile_power.size():
		checksum += light.tile_power[i] * float(i % 97 + 1)
	print(("%s @ %02.0fh: pass %.1f ms (map %.1f, direct %.1f, beams %.1f) · %d paths (cache %d/%d) "
		+ "· %.0f KB beams · balance %.6f · checksum %.4f") % [
		scenario, hour, total, stages.map, stages.direct, stages.beams, s.rays, s.cache_hits,
		s.cache_hits + s.cache_misses, s.render_floats * 4 / 1024.0,
		balance, checksum])
	var r := BeamRenderer.new()
	r.setup(world)
	var render_ms := INF
	for k in 3:
		var t := Time.get_ticks_usec()
		r.rebuild()
		render_ms = minf(render_ms, (Time.get_ticks_usec() - t) / 1000.0)
	r.free()
	var heat_ms := 0.0
	for k in 12:
		heat.tick(world, SimConst.DT)
		heat_ms += heat.last_step_ms / 12.0
	var tick_total := 0.0
	var worst := 0.0
	for k in 200:
		var t0 := Time.get_ticks_usec()
		world.tick()
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		tick_total += ms
		worst = maxf(worst, ms)
	print("    beam mesh build %.1f ms · heat band %.2f ms · tick %.2f avg / %.2f worst ms · %s" % [
		render_ms, heat_ms, tick_total / 200.0, worst, _drag(world)])


## Interaction: drag the first object a little every tick for 3 s at 1×; how long ticks take
## and how often the light catches up.
func _drag(world: SimWorld) -> String:
	var light: LightSystem = world.get_system(&"light")
	var obj: SimObject = world.objects.values()[0]
	var total := 0.0
	var worst := 0.0
	var publishes := 0
	for k in 60:
		var v0 := light.trace_version
		world.enqueue(TransformObjectCommand.new(obj.id, obj.position + Vector2(0.01, 0), obj.angle, false))
		var t := Time.get_ticks_usec()
		world.tick()
		var ms := (Time.get_ticks_usec() - t) / 1000.0
		total += ms
		worst = maxf(worst, ms)
		if light.trace_version != v0:
			publishes += 1
	return "drag: tick %.1f avg / %.1f worst ms, light updated %d× in 60 ticks" % [total / 60.0, worst, publishes]
