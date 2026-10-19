extends SceneTree
## Rough per-system timings on a full-size site at noon with the demo rig.
##   godot --headless --path . -s res://tests/bench.gd


func _initialize() -> void:
	var db := MaterialDB.new()
	db.load_dir()
	var objects := ObjectDB.new()
	objects.load_dir()
	var world := SimWorld.new(db, 300, 120, 1)
	WorldGen.generate(world)
	DemoRig.place(world, objects)
	world.time_s = 0.45 * SimConst.DAY_LENGTH_S
	world.tick()
	var light: LightSystem = world.get_system(&"light")
	var heat: ThermalSystem = world.get_system(&"heat")
	var trace_ms := 0.0
	for k in 5:
		light.retrace(world)
		trace_ms += light.last_trace_ms
	print("full re-trace: %.1f ms avg, %d lanes, %d ray paths, %d beam triangles, %.0f W emitted" % [
		trace_ms / 5.0, light.stats.lanes, light.stats.rays, light.beam_bin.size(), light.stats.emitted])
	var s := light.stats
	print("  balance: absorbed %.0f  escaped %.0f  scattered %.0f  culled %.1f  (sum/emitted %.6f)" % [
		s.absorbed, s.escaped, s.scattered, s.culled,
		(s.absorbed + s.escaped + s.scattered + s.culled) / s.emitted])
	var heat_ms := 0.0
	for k in 10:
		heat.tick(world, SimConst.DT)
		heat_ms += heat.last_step_ms
	print("heat band (one tick): %.1f ms avg (%d subcycles)" % [heat_ms / 10.0, heat.subcycles])
	var total := 0.0
	var worst := 0.0
	for k in 200:
		var start := Time.get_ticks_usec()
		world.tick()
		var ms := (Time.get_ticks_usec() - start) / 1000.0
		total += ms
		worst = maxf(worst, ms)
	print("tick: %.2f ms avg, %.2f ms worst over 200 ticks; light pass %.1f ms total" % [
		total / 200.0, worst, light.last_trace_ms])
	quit()
