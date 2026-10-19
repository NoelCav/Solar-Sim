class_name LightPass
extends RefCounted
## One complete trace of sunlight for the sun and geometry at its start (design doc §6.4.1):
## stage 1 settles direct light with the sun map in one go; stage 2 traces each optical run
## in each spectral bin with the beam tracer, a few tasks per call so it can be spread over
## ticks. Results accumulate in `tracer`; render data in `sheet_*` and `beams`.
## A pass owns a snapshot of the geometry (optical surfaces, tile materials), so edits made
## while it runs don't disturb it; they are picked up by the next pass.
##
## Incremental passes: every beam task keeps a log of what it contributed and the area its
## rays touched. A pass started because geometry changed (the sun having moved less than the
## re-trace threshold) keeps the previous pass's sun, and replays every task whose run is
## unchanged and whose rays came nowhere near the edit; only the rest are traced again.

const SHEET_STRIDE := 2   ## Draw the direct-light sheet from every Nth lane
const REPLAY_DEPS_PER_PATH := 30     ## A replay costs about one ray path per this many deposits

var tracer: Tracer
var map := SunMap.new()
var beams := BeamTracer.new()
var surfaces := SurfaceSet.new()
var grid: TileGrid
var structure_version := -1      ## Geometry this pass traces
var objects_version := -1

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

var _tasks: Array = []           ## [run, bin, TaskLog to replay or null]
var _next := 0
var logs: Dictionary = {}        ## Vector4i task key → TaskLog, for the next pass to reuse
var replayed := 0                ## Tasks reused from the previous pass (stats)
var incremental := false         ## This pass reuses the previous one (geometry-only pass)
var _objects: Dictionary = {}    ## Object id → [position, angle, definition] at the start
var _accel_key := Vector2i(-1, -1)   ## Geometry the tracer's acceleration was built for
var _accel_objects: Dictionary = {}  ## Object id → [position, angle, definition] at that build
var _def_index: Dictionary = {}  ## ObjectDef → small int, for cache keys
var _cacheable: Dictionary = {}  ## Object id → bool, for the surfaces version below
var _cacheable_version := -1


func _init(p_grid: TileGrid, materials: MaterialDB) -> void:
	grid = p_grid
	tracer = Tracer.new(grid, materials, surfaces)


## Begins a pass over the world as it is now. With `prev` (the last completed pass), tasks
## the edits since then can't have affected are replayed from it instead of traced. An
## `edit_only` pass keeps prev's sun even if the sun has since drifted a little further
## (up to RESTART_ANGLE_DEG), so edits show quickly; a later pass catches up with the sun.
func start(world: SimWorld, prev: LightPass = null, edit_only := false) -> void:
	var t0 := Time.get_ticks_usec()
	var prev_material := prev.tracer.material if prev != null else PackedInt32Array()
	structure_version = world.grid.structure_version
	if objects_version != world.objects_version:
		_sync_surfaces(world)
	var key := Vector2i(structure_version, objects_version)
	if _accel_key != key:
		_update_accel(world)
		_accel_key = key
	tracer.begin()
	_tasks.clear()
	_next = 0
	logs = {}
	replayed = 0
	incremental = false
	sheet_from.clear()
	sheet_to.clear()
	done = false
	stage_ms = {"map": 0.0, "direct": 0.0, "beams": 0.0}
	dir = Vector2.ZERO
	dni = 0.0
	spectrum = Spectrum.make_zero()
	var objects_now := {}
	for obj: SimObject in world.objects.values():
		objects_now[obj.id] = [obj.position, obj.angle, obj.def]
	if world.sun_is_up and world.sun_dni > 0.0 and world.sun_direction.y > 1e-3:
		var max_drift := SimConst.RESTART_ANGLE_DEG if edit_only else SimConst.RETRACE_ANGLE_DEG
		var reuse := prev != null and prev.dir != Vector2.ZERO \
			and absf(world.sun_direction.angle_to(prev.dir)) < deg_to_rad(max_drift) \
			and absf(world.sun_dni / prev.dni - 1.0) < (0.25 if edit_only else 0.1)
		incremental = reuse
		if reuse:
			# A geometry-only pass keeps the sun the previous pass traced, so unaffected tasks
			# can be replayed exactly; the next sun-triggered pass catches up.
			dir = prev.dir
			dni = prev.dni
			spectrum = prev.spectrum.duplicate()
		else:
			dir = world.sun_direction
			dni = world.sun_dni
			spectrum = world.sun_spectrum.duplicate()
		map.build(grid, tracer.opaque, surfaces, dir, SimConst.LANE_WIDTH_M)
		var t1 := Time.get_ticks_usec()
		stage_ms.map = (t1 - t0) / 1000.0
		beams.begin(tracer, map, grid, spectrum)
		beams.objects = _object_cache_info(world)
		_direct()
		stage_ms.direct = (Time.get_ticks_usec() - t1) / 1000.0
		var changed := _changed_areas(prev, prev_material, objects_now) if reuse else []
		for run in map.runs:
			for b in Spectrum.BIN_COUNT:
				if spectrum[b] <= 0.0:
					continue
				var old: Tracer.TaskLog = null
				if reuse:
					old = prev.logs.get(Vector4i(run[0], run[1], run[3], b))
					if old != null and (old.s_min != run[2] or _touches(old, changed)):
						old = null
				_tasks.append([run, b, old])
	_objects = objects_now
	ms = (Time.get_ticks_usec() - t0) / 1000.0
	done = _tasks.is_empty()


## Fraction of tasks done.
func progress() -> float:
	return float(_next) / _tasks.size() if not _tasks.is_empty() else 1.0


## Runs tasks until about `max_paths` more ray paths' worth of work is done (-1 = finish);
## a replayed task counts by the size of its log. Returns done.
func step(max_paths: int) -> bool:
	var t0 := Time.get_ticks_usec()
	var budget := max_paths if max_paths >= 0 else 1 << 62
	var start_paths := tracer.ray_count
	var replay_work := 0.0
	while _next < _tasks.size() and tracer.ray_count - start_paths + replay_work < budget:
		var task: Array = _tasks[_next]
		var log: Tracer.TaskLog = task[2]
		if log != null:
			beams.replay(log)
			replayed += 1
			replay_work += float(log.deps.size() / 4) / REPLAY_DEPS_PER_PATH
		else:
			log = beams.trace_run(task[0], task[1])
		if log != null:
			logs[log.key] = log
		_next += 1
	done = _next >= _tasks.size()
	var spent := (Time.get_ticks_usec() - t0) / 1000.0
	ms += spent
	stage_ms.beams += spent
	return done


## Brings the tracer's material snapshot and acceleration up to date, recomputing only around
## what changed since this pass object last built them.
func _update_accel(world: SimWorld) -> void:
	var now := {}
	for obj: SimObject in world.objects.values():
		now[obj.id] = [obj.position, obj.angle, obj.def]
	if _accel_key.x < 0:
		tracer.material = grid.material.duplicate()
		tracer.build_blocks()
	else:
		var tile_areas := []
		if _accel_key.x != structure_version:
			tile_areas = _changed_tiles(tracer.material)
		var objs := []
		for id in _accel_objects:
			if now.get(id, []) != _accel_objects[id]:
				objs.append(id)
		for id in now:
			if not _accel_objects.has(id):
				objs.append(id)
		tracer.material = grid.material.duplicate()
		tracer.update_accel(tile_areas, objs)
	_accel_objects = now


## Areas (m) covering tiles whose material differs from `old`, gathered per 16×16 block so
## separate edits stay separate areas.
func _changed_tiles(old: PackedInt32Array) -> Array:
	var tm := SimConst.TILE_M
	if old.size() != grid.size():
		return [Rect2(Vector2.ZERO, Vector2(grid.width, grid.height) * tm)]
	var mat := grid.material
	var w := grid.width
	var blocks := {}
	for i in mat.size():
		if mat[i] != old[i]:
			var x := i % w
			var y := i / w
			var key := Vector2i(x >> 4, y >> 4)
			var r: Rect2 = blocks.get(key, Rect2(Vector2(x, y) * tm, Vector2.ZERO))
			blocks[key] = r.expand(Vector2(x + 1, y + 1) * tm).expand(Vector2(x, y) * tm)
	return blocks.values()


## Areas (m) that changed since `prev` started: tiles whose material differs, and the old and
## new bounds of objects that moved, changed, appeared or disappeared.
func _changed_areas(prev: LightPass, prev_material: PackedInt32Array, objects_now: Dictionary) -> Array:
	var areas := []
	var tm := SimConst.TILE_M
	if structure_version != prev.structure_version or prev_material.size() != grid.size():
		areas.append_array(_changed_tiles(prev_material))
	for id in prev._objects:
		var now: Array = objects_now.get(id, [])
		if now != prev._objects[id]:
			areas.append(prev.tracer.body_bounds(id))
			if not now.is_empty():
				areas.append(tracer.body_bounds(id))
	for id in objects_now:
		if not prev._objects.has(id):
			areas.append(tracer.body_bounds(id))
	return areas


## Whether a logged task's rays came near any changed area: its beam bounds, or any of its
## secondary rays (as segments).
static func _touches(log: Tracer.TaskLog, areas: Array) -> bool:
	var b := log.bbox.grow(0.01)
	for area: Rect2 in areas:
		var a := area.grow(0.01)
		if b.intersects(a, true):
			return true
		for k in log.seg_from.size():
			if _segment_hits_rect(log.seg_from[k], log.seg_to[k], a):
				return true
	return false


## Liang–Barsky: does segment p0–p1 pass through rect r?
static func _segment_hits_rect(p0: Vector2, p1: Vector2, r: Rect2) -> bool:
	var d := p1 - p0
	var t0 := 0.0
	var t1 := 1.0
	for axis in 2:
		var lo: float = r.position[axis]
		var hi: float = r.end[axis]
		if absf(d[axis]) < 1e-12:
			if p0[axis] < lo or p0[axis] > hi:
				return false
			continue
		var ta := (lo - p0[axis]) / d[axis]
		var tb := (hi - p0[axis]) / d[axis]
		t0 = maxf(t0, minf(ta, tb))
		t1 = minf(t1, maxf(ta, tb))
		if t0 > t1:
			return false
	return true


## Rebuilds this pass's optical surfaces from the world's objects.
func _sync_surfaces(world: SimWorld) -> void:
	surfaces.clear()
	var mats := world.materials
	for obj: SimObject in world.objects.values():
		var def := obj.def
		var coating := SurfaceSet.Coating.NONE
		var back := MaterialDB.AIR_ID
		match def.kind:
			ObjectDef.Kind.MIRROR:
				coating = SurfaceSet.Coating.MIRROR
			ObjectDef.Kind.PROBE:
				coating = SurfaceSet.Coating.PROBE
			_:
				back = mats.id_of(def.material)
		for piece in obj.world_pieces():
			surfaces.add_polyline(piece[0], piece[1], MaterialDB.AIR_ID, back, coating, obj.id,
				def.reflectance)
	surfaces.build_buckets(world.grid.width, world.grid.height)
	objects_version = world.objects_version


## Cache info for the beam tracer's object cache: convex optical bodies whose bounds hold no
## other object's surfaces (tiles inside a body don't matter: rays inside ignore them).
func _object_cache_info(world: SimWorld) -> Dictionary:
	var key := world.objects_version
	if _cacheable_version != key:
		_cacheable.clear()
		var foreign := {}   # Object id → true if another owner's segment shares its tiles
		var first_piece := {}
		for s in surfaces.count():
			var owner := surfaces.owner[s]
			first_piece[owner] = mini(first_piece.get(owner, 1 << 30), surfaces.piece[s])
		var w := grid.width
		for obj: SimObject in world.objects.values():
			if not obj.def.is_body():
				continue
			var ok := true
			var rect := tracer.body_bounds(obj.id)
			for y in range(floori(rect.position.y / SimConst.TILE_M), floori(rect.end.y / SimConst.TILE_M) + 1):
				for x in range(floori(rect.position.x / SimConst.TILE_M), floori(rect.end.x / SimConst.TILE_M) + 1):
					if not grid.in_bounds(x, y):
						ok = false
						continue
					var i := y * w + x
					for k in range(surfaces.cell_start[i], surfaces.cell_start[i + 1]):
						if surfaces.owner[surfaces.cell_items[k]] != obj.id:
							ok = false
			if ok:
				_cacheable[obj.id] = first_piece.get(obj.id, 0)
		_cacheable_version = key
	var info := {}
	if _cacheable.is_empty():
		return info
	for id in _cacheable:
		var obj: SimObject = world.objects[id]
		if not _def_index.has(obj.def):
			_def_index[obj.def] = _def_index.size()
		# Sample rays start before the object's bounding box along the light: everything in
		# front of an object along its run is empty, so starting earlier is safe.
		var r := tracer.body_bounds(id)
		var s_min := minf(minf(r.position.dot(dir), r.end.dot(dir)),
			minf(Vector2(r.end.x, r.position.y).dot(dir), Vector2(r.position.x, r.end.y).dot(dir)))
		info[id] = [_def_index[obj.def], roundi(obj.angle * 1e6), _cacheable[id], obj.position,
			obj.position.dot(map.perp), s_min - 0.02]
	return info


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
