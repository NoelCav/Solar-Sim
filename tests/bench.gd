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
	var world := _make(db, objects, scenario)
	world.time_s = hour / 24.0 * SimConst.DAY_LENGTH_S
	world.tick()
	var light: LightSystem = world.get_system(&"light")
	var heat: ThermalSystem = world.get_system(&"heat")
	light.retrace(world)   # Warm-up (builds faces, buckets, blocks)
	# Fastest of several runs: timings on a desktop are noisy, the minimum is repeatable.
	var stages := {}
	var total := INF
	for k in 4:
		light.retrace(world)
		var p: LightPass = light._pass
		if p.ms < total:
			total = p.ms
			stages = p.stage_ms.duplicate()
	var s := light.stats
	var bt: BeamTracer = light._pass.beams
	var balance: float = (s.absorbed + s.escaped + s.scattered + s.culled) / s.emitted
	var checksum := 0.0
	for i in light.tile_power.size():
		checksum += light.tile_power[i] * float(i % 97 + 1)
	print("%s @ %02.0fh: pass %.1f ms (map %.1f, direct %.1f, beams %.1f) · %d paths (cache %d/%d) · %.0f KB beams · balance %.6f · checksum %.4f" % [
		scenario, hour, total, stages.map, stages.direct, stages.beams, s.rays, bt.cache_hits,
		bt.cache_hits + bt.cache_misses, light.beam_render.size() * 4 / 1024.0,
		balance, checksum])
	var r := BeamRenderer.new()
	r.setup(world)
	var render_ms := INF
	for k in 3:
		var t := Time.get_ticks_usec()
		r._rebuild()
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
	print("    beam mesh build %.1f ms · heat band %.2f ms · tick %.2f avg / %.2f worst ms" % [
		render_ms, heat_ms, tick_total / 200.0, worst])
