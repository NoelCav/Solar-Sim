class_name LightPass
extends RefCounted
## One complete trace of sunlight for the current sun and geometry (design doc §6.4.1):
## stage 1 settles direct light with the sun map in one go; stage 2 traces each optical run
## in each spectral bin with the beam tracer, a few tasks per call so it can be spread over
## ticks. Results accumulate in `tracer`; render data in `sheet_*` and `beams`.

const SHEET_STRIDE := 2   ## Draw the direct-light sheet from every Nth lane

var tracer: Tracer
var map := SunMap.new()
var beams := BeamTracer.new()
var surfaces: SurfaceSet
var grid: TileGrid

var dir := Vector2.ZERO          ## Sun direction this pass traced (ZERO = sun down)
var dni := 0.0
var spectrum := Spectrum.make_zero()
var done := true
var ms := 0.0                    ## CPU time spent on this pass so far
var stage_ms := {"map": 0.0, "direct": 0.0, "beams": 0.0}   ## Breakdown of ms

## Direct-light sheet: where each drawn lane enters the site and where it stops.
## A lane that hits optics stops at the optic; the beam takes over from there.
var sheet_from := PackedVector2Array()
var sheet_to := PackedVector2Array()

var _tasks: Array = []           ## [run, bin]
var _next := 0


func _init(p_grid: TileGrid, materials: MaterialDB, p_surfaces: SurfaceSet) -> void:
	grid = p_grid
	surfaces = p_surfaces
	tracer = Tracer.new(grid, materials, surfaces)


## Begins a pass. Call tracer.build_blocks() (air distance field) first if tiles or surfaces changed.
func start(world: SimWorld) -> void:
	var t0 := Time.get_ticks_usec()
	tracer.begin()
	_tasks.clear()
	_next = 0
	sheet_from.clear()
	sheet_to.clear()
	done = false
	stage_ms = {"map": 0.0, "direct": 0.0, "beams": 0.0}
	dir = Vector2.ZERO
	dni = 0.0
	spectrum = Spectrum.make_zero()
	if world.sun_is_up and world.sun_dni > 0.0 and world.sun_direction.y > 1e-3:
		dir = world.sun_direction
		dni = world.sun_dni
		spectrum = world.sun_spectrum.duplicate()
		map.build(grid, tracer.opaque, surfaces, dir, SimConst.LANE_WIDTH_M)
		var t1 := Time.get_ticks_usec()
		stage_ms.map = (t1 - t0) / 1000.0
		beams.begin(tracer, map, grid, spectrum)
		_direct()
		stage_ms.direct = (Time.get_ticks_usec() - t1) / 1000.0
		for run in map.runs:
			for b in Spectrum.BIN_COUNT:
				if spectrum[b] > 0.0:
					_tasks.append([run, b])
	ms = (Time.get_ticks_usec() - t0) / 1000.0
	done = _tasks.is_empty()


## Runs tasks until about `max_paths` more ray paths are traced (-1 = finish). Returns done.
func step(max_paths: int) -> bool:
	var t0 := Time.get_ticks_usec()
	var limit := tracer.ray_count + max_paths if max_paths >= 0 else 1 << 62
	while _next < _tasks.size() and tracer.ray_count < limit:
		var task: Array = _tasks[_next]
		beams.trace_run(task[0], task[1])
		_next += 1
	done = _next >= _tasks.size()
	var spent := (Time.get_ticks_usec() - t0) / 1000.0
	ms += spent
	stage_ms.beams += spent
	return done


## Stage 1: lanes that end on opaque faces deposit directly; lanes that hit nothing escape.
## Probes read the lanes that cross them before their first hit.
func _direct() -> void:
	var lane_area := map.lane_w * SimConst.DEPTH_M
	var total := Spectrum.total(spectrum)
	tracer.emitted_w += total * lane_area * map.count
	# Lanes landing on the same tile are consecutive; settle each stretch in one call.
	var kind := map.kind
	var ref := map.ref
	var run_tile := -1
	var run_lanes := 0
	var none_lanes := 0
	for k in map.count:
		var t := ref[k] if kind[k] == SunMap.Hit.OPAQUE else -1
		if t != run_tile:
			if run_tile >= 0:
				tracer.absorb_opaque_spectrum(run_tile, spectrum, run_lanes * lane_area)
			run_tile = t
			run_lanes = 0
		run_lanes += 1
		if kind[k] == SunMap.Hit.NONE:
			none_lanes += 1
	if run_tile >= 0:
		tracer.absorb_opaque_spectrum(run_tile, spectrum, run_lanes * lane_area)
	tracer.escaped_w += total * lane_area * none_lanes
	for s in surfaces.count():
		if surfaces.coating[s] == SurfaceSet.Coating.PROBE:
			var n := map.lanes_reaching(surfaces.a[s], surfaces.b[s]).size()
			for b in Spectrum.BIN_COUNT:
				tracer.add_probe(surfaces.owner[s], b, spectrum[b] * lane_area * n)
	var far := (grid.width + grid.height) * SimConst.TILE_M
	for k in range(0, map.count, SHEET_STRIDE):
		var s_in := map.entry_s(k)
		var s_end := map.depth[k] if map.kind[k] != SunMap.Hit.NONE else s_in + far
		sheet_from.append(map.lane_point(k, s_in))
		sheet_to.append(map.lane_point(k, s_end))
