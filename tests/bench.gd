extends SceneTree
## Benchmark and bug sweep over the test scenarios (Scenarios) on a full-size site:
##   godot --headless --path . -s res://tests/bench.gd [-- --baseline] [-- --only=name]
## (or `python tools/test.py --bench` / `--baseline`).
##
## For every scenario and benchmark hour it measures the light pass (fastest of three fresh
## passes, by stage), the beam mesh, 300 ticks (average, 95th percentile, worst; heat band and
## skin), dragging an object, and prints where the light went, temperatures and power. Two light
## checks look for the bugs that used to be found by eye:
## - **Ground truth:** dense plain rays (the engine's ray tree, no beams) across the whole site,
##   compared tile by tile with the beam pass: light on a wrong path, missing or smeared shows up.
## - **Steady:** the sun advanced in 0.1° steps; the biggest jump of any tile's light (popping).
## Once per scenario it also checks that an incremental pass matches a fresh one, that two runs
## are identical (determinism), that a save restores the same site, that probes block nothing,
## and (edge_optics) that a symmetric rig lights the ground symmetrically at noon.
##
## Five kinds of finding:
## - **Checks** (bugs): energy balance, no NaN or impossible values, light arriving straight
##   from the source never more than all of it, cells never making more than the light they get,
##   power and money adding up, the three comparisons above. Any failure: exit code 1.
## - **Results changed**: fingerprints (sums of light, temperatures, power) differ from the
##   baseline (tests/bench_baseline.json). Expected after a physics change: look, then accept
##   with `--baseline`. Unexplained: a bug.
## - **Less accurate**: the light checks' error measures (ground-truth spread, popping kinks,
##   symmetry, incremental-pass gap) have known, small limits; each is recorded in the baseline,
##   and getting more than ACCURACY_SLACK worse than it fails the run (a ratchet). Generous
##   sanity limits (the *_TOL constants) also hold on their own.
## - **More work**: machine-independent counts (ray paths, cache misses, lanes, lit tiles and
##   strips, secondary rays, beam memory, mesh vertices, passes completed in 300 ticks, heat
##   subcycles, memory) beyond WORK_TOL of the baseline. These don't depend on the machine, its
##   power plan or what else runs, so they are the reliable performance signal.
## - **Slower / faster**: timings beyond SLOWER × the baseline (and SLOW_MS apart). Advisory only:
##   timings are this machine's in its current state.

const BASELINE := "res://tests/bench_baseline.json"
const TICKS := 300               ## 15 s of sim time at 20 Hz
const DRAG_TICKS := 60
const SLOWER := 1.5
const SLOW_MS := 0.5
const RESULT_TOL := 1e-4         ## Relative difference that counts as a changed result
const WORK_TOL := 0.02           ## Relative change in a work count worth reporting
const REPLAY_TOL := 0.01         ## Incremental vs fresh pass: largest share a tile may differ (see _consistency)
const TRUTH_SPACING_M := 0.005   ## Ground truth: plain rays this far apart (50 per tile: no aliasing)
const TRUTH_TOTAL_TOL := 0.01    ## Beams and plain rays: total light on the compared tiles agrees this well
const TRUTH_L1_TOL := 0.05       ## and the light lands in the same tiles (sum |difference| / total)
const STEADY_STEPS := 8
const STEADY_TOL := 0.25         ## Largest kink (second difference) of a tile's light, share of the brightest
const SYMMETRY_TOL := 0.10
## Accuracy measures (lower is better), ratcheted against the baseline.
const ACCURACY := ["truth_l1", "steady_kink", "symmetry", "replay_worst_w"]
const ACCURACY_SLACK := 0.25     ## Fail when a measure is this much worse than its baseline (relative)
const ACCURACY_ABS := 0.002      ## plus this much (ignores noise around zero)
const T_MIN_K := 150.0           ## Plausible temperatures, K: outside them something is broken
const T_MAX_K := 3500.0

var _db := MaterialDB.new()
var _objects := ObjectDB.new()
var _results := {}               ## "scenario@hour" or "scenario" → {t: timings, w: work, f: fingerprints, a: accuracy}
var _failed: PackedStringArray = []
var _key := ""                   ## Entry the checks being run belong to


func _initialize() -> void:
	_db.load_dir()
	_objects.load_dir()
	var args := OS.get_cmdline_user_args()
	var only := ""
	for a in args:
		if a.begins_with("--only="):
			only = a.trim_prefix("--only=")
	var start := Time.get_ticks_msec()
	for name: String in Scenarios.names():
		if only != "" and name != only:
			continue
		var hours: Array = Scenarios.LIST[name].bench
		for hour: float in (hours if not hours.is_empty() else [-1.0]):
			_run(name, hour)
		_consistency(name, hours[0] if not hours.is_empty() else -1.0)
	print("\n(%.0f s)" % ((Time.get_ticks_msec() - start) / 1000.0))
	if "--baseline" in args:
		_write_baseline()
	else:
		_compare()
	if not _failed.is_empty():
		print("\nCHECKS FAILED (%d):" % _failed.size())
		for f in _failed:
			print("  ", f)
	quit(1 if not _failed.is_empty() else 0)


func _make(name: String, hour: float) -> SimWorld:
	var world := SimWorld.new(_db, 300, 120, 1)
	WorldGen.generate(world)
	var err := Scenarios.build(world, _objects, name)
	if err != "":
		_check(false, err)
	if hour >= 0.0:
		world.time_s = hour / 24.0 * SimConst.DAY_LENGTH_S
		world.refresh_environment()
	return world


# --- One scenario at one hour -----------------------------------------------------------------

func _run(name: String, hour: float) -> void:
	var world := _make(name, hour)
	var tod := world.time_of_day() * 24.0
	_key = "%s@%s" % [name, Readout.clock(tod)]
	var t := {}
	var w := {}
	var f := {}
	print("\n%s @ %s (day %d, %s)" % [name, Readout.clock(tod), world.day_number() + 1,
		"moon" if world.light_is_moon else ("sun" if world.sun_is_up else "dark")])
	world.tick()
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	_light(world, light, t, w, f)
	_ground_truth(world, w, f)
	_steady(world, f)
	_mesh(world, t, w)
	_ticks(world, t, w, f)
	_power(world, f)
	_drag(world, t, w)
	print("  work    %s" % " · ".join(w.keys().map(func(k: String) -> String: return "%s %d" % [k, w[k]])))
	_store(_key, t, w, f)


func _light(world: SimWorld, light: LightSystem, t: Dictionary, w: Dictionary, f: Dictionary) -> void:
	# A full pass with nothing to reuse, fastest of three: desktop timings are noisy, the
	# minimum is repeatable.
	var best := INF
	var stages := {}
	for k in 3:
		light.retrace(world, true)
		if light.last_trace_ms < best:
			best = light.last_trace_ms
			stages = light.last_stage_ms.duplicate()
	var s := light.stats
	t.pass_ms = best
	t.map_ms = stages.get("map", 0.0)
	t.direct_ms = stages.get("direct", 0.0)
	t.beams_ms = stages.get("beams", 0.0)
	var emitted: float = s.get("emitted", 0.0)
	w.paths = s.get("rays", 0)
	w.cache_misses = s.get("cache_misses", 0)
	w.lanes = s.get("lanes", 0)
	w.beam_floats = s.get("render_floats", 0)
	w.lit_tiles = light.shown_lit.size()
	w.lit_strips = light.strip_ids.size()
	w.secondary_rays = light.ray_from.size()
	print(("  light   pass %.1f ms (map %.1f · direct %.1f · beams %.1f) · %d paths · cache %d/%d · %d lanes · "
		+ "%.0f KB beams") % [best, t.map_ms, t.direct_ms, t.beams_ms, s.get("rays", 0), s.get("cache_hits", 0),
		s.get("cache_hits", 0) + s.get("cache_misses", 0), s.get("lanes", 0), s.get("render_floats", 0) * 4 / 1024.0])
	if emitted > 0.0:
		var parts := ["absorbed", "escaped", "scattered", "culled"]
		var sum := 0.0
		var shares := PackedStringArray()
		for p: String in parts:
			sum += s.get(p, 0.0)
			shares.append("%s %.2f%%" % [p, s.get(p, 0.0) / emitted * 100.0])
		print("  energy  emitted %s: %s · balance %.7f" % [Readout.power(emitted), " · ".join(shares), sum / emitted])
		_check(absf(sum / emitted - 1.0) < 1e-5, "energy balance %.7f" % (sum / emitted))
	else:
		print("  energy  no light traced")
	var tiles := 0.0
	var bad := 0
	for i in light.tile_power.size():
		var watts := light.tile_power[i]
		if not is_finite(watts) or watts < -1e-6:
			bad += 1
		tiles += watts * float(i % 97 + 1)
	_check(bad == 0, "%d tiles with NaN or negative light" % bad)
	var strips := 0.0
	for watts in light.strip_absorbed:
		strips += watts
	var absorbed := 0.0
	var incident := 0.0
	var worst_direct := 0.0
	for obj: SimObject in world.objects.values():
		absorbed += obj.absorbed_w
		incident += Spectrum.total(obj.incident)
		for b in Spectrum.BIN_COUNT:
			worst_direct = maxf(worst_direct, obj.incident_direct[b] - obj.incident[b])
	_check(worst_direct <= 1e-6, "direct light exceeds all light on a face by %.6f W" % worst_direct)
	f.light_tiles = tiles
	f.light_strips = strips
	f.object_absorbed_w = absorbed
	f.object_incident_w = incident
	f.emitted_w = emitted
	f.absorbed_w = s.get("absorbed", 0.0)
	# Brightest light on a cell, in suns, right after the pass (fixed lenses lose their target as
	# the sun moves: in a 12-minute day a focus walks ~16 cm in 15 s).
	var best_c := 0.0
	for obj: SimObject in world.objects.values():
		if obj.def.kind == ObjectDef.Kind.CELL:
			var arriving := Spectrum.total(SolarCell.object_light(obj, light.power_scale(world)))
			best_c = maxf(best_c, arriving / obj.def.face_area_m2() / SimConst.REFERENCE_DNI)
	if best_c > 0.0:
		print("  cells   brightest %.2f× sun" % best_c)
		f.peak_concentration = best_c


func _mesh(world: SimWorld, t: Dictionary, w: Dictionary) -> void:
	var r := BeamRenderer.new()
	r.setup(world)
	var best := INF
	for k in 3:
		var t0 := Time.get_ticks_usec()
		r.rebuild()
		best = minf(best, (Time.get_ticks_usec() - t0) / 1000.0)
	t.mesh_ms = best
	w.mesh_vertices = (r.mesh as ArrayMesh).surface_get_array_len(0) if r.mesh != null else 0
	r.free()
	print("  mesh    %.1f ms · %d vertices" % [best, w.mesh_vertices])


func _ticks(world: SimWorld, t: Dictionary, w: Dictionary, f: Dictionary) -> void:
	var heat: ThermalSystem = world.get_system(&"heat")
	var light: LightSystem = world.get_system(&"light")
	var v0 := light.trace_version
	var subcycles := 0
	var times := PackedFloat32Array()
	var band := 0.0
	var skin := 0.0
	var money0 := world.money
	var expected := 0.0
	for k in TICKS:
		var t0 := Time.get_ticks_usec()
		world.tick()
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
		band += heat.last_step_ms
		skin += heat.last_skin_ms
		subcycles += heat.subcycles
		var delivered := 0.0   # What the tick sold: its cells' power_w (zero off a selling network)
		for obj: SimObject in world.objects.values():
			delivered += obj.power_w
		expected += Market.earnings(world, delivered, SimConst.DT)
	var sorted := times.duplicate()
	sorted.sort()
	var avg := 0.0
	for x in times:
		avg += x
	avg /= TICKS
	t.tick_ms = avg
	t.tick_p95_ms = sorted[int(TICKS * 0.95)]
	t.tick_worst_ms = sorted[TICKS - 1]
	t.heat_band_ms = band / TICKS
	t.skin_ms = skin / TICKS
	w.passes = light.trace_version - v0
	w.skin_faces = world.skin.faces
	w.heat_subcycles = subcycles
	print("  ticks   %d: avg %.2f · p95 %.2f · worst %.2f ms · heat band %.2f · skin %.2f ms (%d faces)" % [
		TICKS, avg, t.tick_p95_ms, t.tick_worst_ms, t.heat_band_ms, t.skin_ms, world.skin.faces])
	# Temperatures: finite and plausible everywhere.
	var g := world.grid
	var lo := INF
	var hi := -INF
	var mean := 0.0
	var bad := 0
	for i in g.size():
		var tk := g.temperature[i]
		if not is_finite(tk) or tk < T_MIN_K or tk > T_MAX_K or not is_finite(g.energy_in[i]):
			bad += 1
			continue
		lo = minf(lo, tk)
		hi = maxf(hi, tk)
		mean += tk
	mean /= g.size()
	_check(bad == 0, "%d tiles with NaN or implausible temperature or energy" % bad)
	var skin_hi := 0.0
	bad = 0
	for tk in world.skin.temperature:
		if not is_finite(tk) or tk > T_MAX_K:
			bad += 1
		else:
			skin_hi = maxf(skin_hi, tk)
	_check(bad == 0, "%d skin strips with NaN or implausible temperature" % bad)
	var obj_hi := 0.0
	bad = 0
	for obj: SimObject in world.objects.values():
		if not is_finite(obj.temperature_k) or obj.temperature_k > T_MAX_K or not is_finite(obj.heat_in):
			bad += 1
		else:
			obj_hi = maxf(obj_hi, obj.temperature_k)
	_check(bad == 0, "%d objects with NaN or implausible temperature" % bad)
	print("  heat    tiles %.1f to %.1f °C (mean %.2f) · skin max %.0f °C · objects max %.1f °C" % [
		SimConst.k_to_c(lo), SimConst.k_to_c(hi), SimConst.k_to_c(mean), SimConst.k_to_c(skin_hi),
		SimConst.k_to_c(obj_hi)])
	f.tile_mean_k = mean
	f.tile_max_k = hi
	f.skin_max_k = skin_hi
	f.object_max_k = obj_hi
	var earned := world.money - money0
	_check(absf(earned - expected) <= 1e-9 + 1e-3 * absf(expected),
		"money earned %.9f, power sold says %.9f" % [earned, expected])
	f.money = world.money


## Cells and networks after the ticks: what each delivers is within what reaches it, unwired
## cells deliver nothing, and the networks sell what their cells deliver.
func _power(world: SimWorld, f: Dictionary) -> void:
	var power: PowerSystem = world.get_system(&"power")
	var light: LightSystem = world.get_system(&"light")
	power.sync(world)
	var cells := 0
	var selling := 0
	var delivered := 0.0
	var cell_hi := 0.0
	for obj: SimObject in world.objects.values():
		if obj.def.kind != ObjectDef.Kind.CELL:
			continue
		cells += 1
		var arriving := Spectrum.total(SolarCell.object_light(obj, light.power_scale(world)))
		cell_hi = maxf(cell_hi, obj.temperature_k)
		_check(obj.power_w >= 0.0 and obj.power_w <= arriving + 1e-6,
			"cell %d delivers %.3f W of %.3f W arriving" % [obj.id, obj.power_w, arriving])
		if power.sells(world, obj):
			selling += 1
			delivered += obj.power_w
		else:
			_check(obj.power_w == 0.0, "unwired cell %d delivers %.3f W" % [obj.id, obj.power_w])
	if cells == 0:
		return
	# The networks' readout reads the light and cell temperatures now, as the next tick will; the
	# cells delivered at the temperature before this tick's heat step, so they agree closely only.
	var sold := _sold_w(world)
	_check(absf(sold - delivered) <= 1e-3 + 2e-3 * sold, "networks sell %.4f W, cells deliver %.4f W" % [sold, delivered])
	var grids := 0
	for n in power.networks.count:
		grids += power.network_grid[n]
	print("  power   selling %s from %d of %d cells (%d networks, %d with a grid connection) "
		% [Readout.power(sold), selling, cells, power.networks.count, grids]
		+ "· cells max %.1f °C · $%.6f" % [SimConst.k_to_c(cell_hi), world.money])
	f.sold_w = sold
	f.cell_max_k = cell_hi


func _sold_w(world: SimWorld) -> float:
	var power: PowerSystem = world.get_system(&"power")
	var total := 0.0
	for n in power.networks.count:
		total += power.output_w(world, n)
	return total


## Interaction: drag the first optic for 3 s at 1× as a mouse would: it tilts 0.5° every tick and
## steps one tile column every 6 (stands snap to columns, D21); how long ticks take and how often
## the light catches up.
func _drag(world: SimWorld, t: Dictionary, w: Dictionary) -> void:
	var light: LightSystem = world.get_system(&"light")
	var obj: SimObject = null
	for o: SimObject in world.objects.values():
		if not o.def.is_machine():
			obj = o
			break
	if obj == null:
		return
	var total := 0.0
	var worst := 0.0
	var publishes := 0
	for k in DRAG_TICKS:
		var v0 := light.trace_version
		var step := Vector2(SimConst.TILE_M, 0.0) if k % 6 == 5 else Vector2.ZERO
		world.enqueue(TransformObjectCommand.new(obj.id, obj.position + step, obj.angle + deg_to_rad(0.5), false))
		var t0 := Time.get_ticks_usec()
		world.tick()
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		total += ms
		worst = maxf(worst, ms)
		if light.trace_version != v0:
			publishes += 1
	t.drag_tick_ms = total / DRAG_TICKS
	t.drag_worst_ms = worst
	w.drag_passes = publishes
	print("  drag    tick %.1f avg / %.1f worst ms · light updated %d× in %d ticks" % [
		t.drag_tick_ms, worst, publishes, DRAG_TICKS])


## Ground truth and popping (LightChecks): where plain rays put the light vs the beams, and the
## largest kink in a tile's light as the sun steps on.
func _ground_truth(world: SimWorld, w: Dictionary, f: Dictionary) -> void:
	var r := LightChecks.ground_truth(world, TRUTH_SPACING_M)
	if r.has("error"):
		return
	var at: Array = r.tiles[0].tile if not r.tiles.is_empty() else [-1, -1]
	print("  truth   %d plain rays: beams/rays %.4f · tiles differ %.2f%% (sum) · worst bright tile %.1f%% · "
		% [r.rays, r.ratio, r.l1 * 100.0, r.worst * 100.0] + "largest gap at %s" % [at])
	w.truth_ray_paths = r.ray_paths
	f.truth_ratio = r.ratio
	f.truth_l1 = r.l1
	_check(absf(r.ratio - 1.0) <= TRUTH_TOTAL_TOL, "beams put %.2f%% of the plain rays' light on the ground"
		% (r.ratio * 100.0))
	_check(r.l1 <= TRUTH_L1_TOL, "beams and plain rays light different tiles (%.2f%% of the light)" % (r.l1 * 100.0))


func _steady(world: SimWorld, f: Dictionary) -> void:
	var r := LightChecks.steady(world, STEADY_STEPS)
	if r.has("error"):
		return
	print("  steady  %d sun steps of 0.1°: biggest step %.2f%%, biggest kink %.2f%% of the brightest tile (at %s)"
		% [STEADY_STEPS, r.jump * 100.0, r.kink * 100.0, r.kink_tile])
	f.steady_kink = r.kink
	_check(r.kink <= STEADY_TOL, "a tile's light kinks by %.1f%% of the brightest tile within 0.2° of sun: %s"
		% [r.kink * 100.0, r.kink_series_w])


## "+12" or "-3": a percentage with its sign (GDScript's format has no + flag).
func _signed(x: float) -> String:
	return ("+%.0f" if x >= 0.0 else "%.0f") % x


## Whether two captured values match: dictionaries and arrays element by element, numbers to
## 1e-12 (Godot's JSON reads the last digit of a 17-digit float back slightly differently).
func _same(a: Variant, b: Variant) -> bool:
	if a is Dictionary and b is Dictionary:
		return a.size() == b.size() and a.keys().all(func(k: Variant) -> bool: return b.has(k) and _same(a[k], b[k]))
	if a is Array and b is Array:
		return a.size() == b.size() and range(a.size()).all(func(k: int) -> bool: return _same(a[k], b[k]))
	if (a is float or a is int) and (b is float or b is int):
		return absf(float(a) - float(b)) <= 1e-12 * maxf(1.0, absf(float(a)))
	return a == b


# --- Once per scenario: incremental = fresh, determinism, save round trip -----------------------

func _consistency(name: String, hour: float) -> void:
	_key = name
	var f := {}
	# Incremental pass vs a fresh trace of the same edited site.
	var a := _make(name, hour)
	var b := _make(name, hour)
	for w in [a, b]:
		w.tick()
	var la: LightSystem = a.get_system(&"light")
	la.retrace(a)
	for w in [a, b]:
		_edit(w)
	la.retrace(a)
	var lb: LightSystem = b.get_system(&"light")
	lb.retrace(b)
	# Known approximation (design §18.13): pooled secondary reflections an edit changes can be
	# replayed from before it, so tiles they reach may differ by a fraction of a percent until the
	# next full pass. Totals must agree; each tile within RELAY_TOL; the worst gap is a result.
	var worst := 0.0
	var worst_share := 0.0
	for i in la.tile_power.size():
		var d := absf(la.tile_power[i] - lb.tile_power[i])
		worst = maxf(worst, d)
		if d > 1e-3:
			worst_share = maxf(worst_share, d / maxf(lb.tile_power[i], 1e-9))
	var replayed: int = la.stats.get("replayed", 0)
	var total: float = lb.stats.get("absorbed", 0.0)
	_check(absf(la.stats.get("absorbed", 0.0) - total) <= 1e-5 * maxf(total, 1.0),
		"incremental pass absorbs %.6f W, a fresh one %.6f W" % [la.stats.get("absorbed", 0.0), total])
	_check(worst_share <= REPLAY_TOL,
		"incremental pass differs from a fresh one by %.3f%% on a tile" % (worst_share * 100.0))
	f.replay_worst_w = worst
	# Determinism: the same site and edits, run twice, end identical.
	var c := _make(name, hour)
	var d := _make(name, hour)
	for w in [c, d]:
		for k in 100:
			if k == 10:
				_edit(w)
			w.tick()
	_check(c.state_hash() == d.state_hash(), "two identical runs ended in different states")
	# Save round trip: capture, restore on fresh terrain, capture again.
	var e := SimWorld.new(_db, 300, 120, 1)
	WorldGen.generate(e)
	var err := SiteSave.restore(e, JSON.parse_string(SiteSave.to_text(c)), _objects)
	var before := SiteSave.capture(c)
	var after := SiteSave.capture(e)
	var differs := PackedStringArray()
	for k: String in before:
		if not _same(before[k], after.get(k)):
			differs.append(k)
	_check(err == "" and differs.is_empty(), "save round trip changed the site (%s%s)" % [err, ", ".join(differs)])
	var probes := _probes_block_nothing(name, hour)
	if Scenarios.LIST[name].has("symmetric_about"):
		_symmetric(name, Scenarios.LIST[name].symmetric_about, f)
	print("  %s: incremental ≈ fresh (worst tile %.4f W, %.3f%%; %d tasks replayed) · deterministic · save round trip%s"
		% [name, worst, worst_share * 100.0, replayed, " · probes block nothing" if probes else ""])
	f.state_hash = float(c.state_hash() % 1000000007)
	_store(name, {}, {"replayed": replayed}, f)


## Probes read light and block nothing: removing them leaves every tile's light as it was.
## Returns whether the scenario has probes.
func _probes_block_nothing(name: String, hour: float) -> bool:
	var world := _make(name, hour)
	var ids := []
	for o: SimObject in world.objects.values():
		if o.def.kind == ObjectDef.Kind.PROBE:
			ids.append(o.id)
	if ids.is_empty():
		return false
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world, true)
	var with := light.tile_power.duplicate()
	for id: int in ids:
		world.enqueue(RemoveObjectCommand.new(id))
	world.flush_commands()
	light.retrace(world, true)
	var worst := 0.0
	for i in with.size():
		worst = maxf(worst, absf(with[i] - light.tile_power[i]))
	_check(worst <= 1e-4, "removing the probes changes a tile's light by %.5f W" % worst)
	return true


## At noon (sun straight down) a rig centred on a tile column on flat ground lights the tiles on
## either side of its column alike (LightChecks.symmetry).
func _symmetric(name: String, about: float, f: Dictionary) -> void:
	var world := _make(name, 12.0)
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world, true)
	var r := LightChecks.symmetry(world, about)
	f.symmetry = r.share
	_check(r.peak_w > 0.0 and r.share <= SYMMETRY_TOL, "symmetric rig lights its two sides %.2f%% differently (%s)"
		% [r.share * 100.0, r])
	print("  %s: symmetric rig at noon: sides differ by %.3f%% of the brightest tile" % [name, r.share * 100.0])


## The same small edit for every comparison: move the first optic 30 cm right and tilt it,
## and paint a stone tile on the ground near the middle.
func _edit(world: SimWorld) -> void:
	for o: SimObject in world.objects.values():
		if not o.def.is_machine():
			world.enqueue(TransformObjectCommand.new(o.id, o.position + Vector2(0.3, 0.0), o.angle + 0.1))
			break
	var col := world.grid.width / 2
	var row := roundi(Mounting.ground_y(world, col, 0.0) / SimConst.TILE_M) - 1
	world.enqueue(PaintTilesCommand.new(PackedInt32Array([world.grid.idx(col, row)]), world.materials.id_of(&"stone")))
	world.flush_commands()


## Files an entry's measures, the accuracy ones (ACCURACY) apart from the fingerprints.
func _store(key: String, t: Dictionary, w: Dictionary, f: Dictionary) -> void:
	var a := {}
	for k: String in ACCURACY:
		if f.has(k):
			a[k] = f[k]
			f.erase(k)
	_results[key] = {"t": t, "w": w, "f": f, "a": a}


func _check(ok: bool, what: String) -> void:
	if not ok:
		_failed.append("%s: %s" % [_key, what])
		print("  FAIL    ", what)


# --- Baseline ---------------------------------------------------------------------------------

func _write_baseline() -> void:
	var data := {"recorded": Time.get_datetime_string_from_system(), "engine": Engine.get_version_info().string,
		"results": _results}
	var file := FileAccess.open(BASELINE, FileAccess.WRITE)
	file.store_string(JSON.stringify(data, "\t", true))
	print("\nBaseline written: %s (%d entries)" % [BASELINE, _results.size()])


func _compare() -> void:
	if not FileAccess.file_exists(BASELINE):
		print("\nNo baseline yet: run with --baseline to record one.")
		return
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(BASELINE))
	var base: Dictionary = data.get("results", {}) if data is Dictionary else {}
	var changed := PackedStringArray()
	var more := PackedStringArray()
	var less := PackedStringArray()
	var slower := PackedStringArray()
	var faster := PackedStringArray()
	for key: String in _results:
		if not base.has(key):
			changed.append("%s: not in the baseline" % key)
			continue
		var now: Dictionary = _results[key]
		var then: Dictionary = base[key]
		for k: String in now.f:
			var v: float = now.f[k]
			var w: float = then.get("f", {}).get(k, NAN)
			if is_nan(w) or absf(v - w) > RESULT_TOL * maxf(absf(w), 1e-9):
				changed.append("%s %s: %s (baseline %s)" % [key, k, str(v), str(w)])
		for k: String in now.a:
			var v: float = now.a[k]
			var b: float = then.get("a", {}).get(k, NAN)
			if not is_nan(b) and v > b * (1.0 + ACCURACY_SLACK) + ACCURACY_ABS:
				_failed.append("%s: less accurate: %s %.4f (baseline %.4f)" % [key, k, v, b])
		for k: String in now.w:
			var v: float = now.w[k]
			var b: float = then.get("w", {}).get(k, NAN)
			if is_nan(b):
				continue
			if v > b * (1.0 + WORK_TOL) and v - b > 1.0:
				more.append("%s %s: %d (baseline %d, %s%%)" % [key, k, v, b, _signed((v / maxf(b, 1.0) - 1.0) * 100.0)])
			elif v < b * (1.0 - WORK_TOL) and b - v > 1.0:
				less.append("%s %s: %d (baseline %d, %s%%)" % [key, k, v, b, _signed((v / maxf(b, 1.0) - 1.0) * 100.0)])
		for k: String in now.t:
			var v: float = now.t[k]
			var w: float = then.get("t", {}).get(k, NAN)
			if is_nan(w):
				continue
			if v > w * SLOWER and v - w > SLOW_MS:
				slower.append("%s %s: %.2f ms (baseline %.2f)" % [key, k, v, w])
			elif v * SLOWER < w and w - v > SLOW_MS:
				faster.append("%s %s: %.2f ms (baseline %.2f)" % [key, k, v, w])
	print("\nAgainst the baseline (%s):" % data.get("recorded", "?"))
	print("  results: %s" % ("unchanged" if changed.is_empty() else "%d CHANGED" % changed.size()))
	for c in changed:
		print("    ", c)
	if not changed.is_empty():
		print("    (expected after a physics change: check, then accept with --baseline)")
	print("  more work: %s" % ("none" if more.is_empty() else ""))
	for m in more:
		print("    ", m)
	if not less.is_empty():
		print("  less work:")
		for m in less:
			print("    ", m)
	print("  slower (advisory, machine-dependent): %s" % ("none" if slower.is_empty() else ""))
	for s in slower:
		print("    ", s)
	if not faster.is_empty():
		print("  faster:")
		for s in faster:
			print("    ", s)
