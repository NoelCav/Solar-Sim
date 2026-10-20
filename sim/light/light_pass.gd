class_name LightPass
extends RefCounted
## One complete trace of one source's light (the sun or moon, or a lamp) over the geometry at its
## start (design doc §6.4.1, §6.11): stage 1 settles direct light with the lane map in one go;
## stage 2 traces each optical run in each spectral bin as beams, a few tasks per call so it can be spread over ticks.
## The ray work runs in compiled code (LightEngine, C#); this class builds the geometry
## (SurfaceSet, LaneMap), decides what can be reused, and drives the engine.
## A pass owns a snapshot of the geometry (optical surfaces, tile materials), so edits made
## while it runs don't disturb it; they are picked up by the next pass.
##
## Incremental passes: every beam task keeps a log of what it contributed and the area its
## rays touched. A pass started because geometry changed (the sun having moved less than the
## re-trace threshold) keeps the previous pass's sun, and replays every task whose run is
## unchanged and whose rays came nowhere near the edit; only the rest are traced again.

const SHEET_STRIDE := 2   ## Draw the direct-light sheet from every Nth lane

var engine := LightEngine.new()
var map := LaneMap.new()
var surfaces := SurfaceSet.new()
var grid: TileGrid
var opaque := PackedByteArray()        ## Per material: blocks light (for the sun map)
var material := PackedInt32Array()     ## Tile materials as of this pass's geometry
var structure_version := -1            ## Geometry this pass traces
var objects_version := -1

var source: LightSource         ## What this pass traced (null: nothing was up)
var dir := Vector2.ZERO          ## Sky pass: sun direction this pass traced (ZERO = sun down)
var dni := 0.0
var done := true
var incremental := false         ## This pass reuses the previous one (geometry-only pass)
var ms := 0.0                    ## CPU time spent on this pass so far
var stage_ms := {"map": 0.0, "direct": 0.0, "beams": 0.0}   ## Breakdown of ms

## Direct-light sheet: where each drawn lane enters the site and where it stops.
## A lane that hits optics stops at the optic; the beam takes over from there.
var sheet_from := PackedVector2Array()
var sheet_to := PackedVector2Array()

var _objects: Dictionary = {}    ## Object id → [position, angle, definition] at the start
var _accel_key := Vector2i(-1, -1)   ## Geometry the engine's acceleration was built for
var _accel_objects: Dictionary = {}  ## Object id → [position, angle, definition] at that build
var _def_index: Dictionary = {}  ## ObjectDef → small int, for cache keys
var _cacheable: Dictionary = {}  ## Object id → first piece, for the surfaces version below
var _cacheable_version := -1


func _init(p_grid: TileGrid, materials: MaterialDB) -> void:
	grid = p_grid
	var n := materials.count()
	opaque.resize(n)
	var dispersive := PackedByteArray()
	var has_bulk := PackedByteArray()
	var index := PackedFloat32Array()
	var bulk := PackedFloat32Array()
	var surf := PackedFloat32Array()
	dispersive.resize(n)
	has_bulk.resize(n)
	for arr in [index, bulk, surf]:
		arr.resize(n * Spectrum.BIN_COUNT)
	for id in n:
		var def := materials.get_def(id)
		opaque[id] = 1
		if def == null:
			continue
		opaque[id] = 0 if def.transparent else 1
		dispersive[id] = 1 if def.cauchy_b != 0.0 else 0
		for b in Spectrum.BIN_COUNT:
			index[id * Spectrum.BIN_COUNT + b] = def.refractive_index(Spectrum.WAVELENGTH_UM[b])
			bulk[id * Spectrum.BIN_COUNT + b] = def.bulk_absorption[b]
			surf[id * Spectrum.BIN_COUNT + b] = def.surface_absorptivity[b]
			if def.bulk_absorption[b] > 0.0:
				has_bulk[id] = 1
	engine.Setup(grid.width, grid.height, SimConst.TILE_M, SimConst.DEPTH_M, SimConst.MAX_RAY_EVENTS,
		SimConst.MIN_CHILD_W, SimConst.MIN_RAY_W, SimConst.REFL_POOL_M, SimConst.BEAM_SPACING_M, opaque, dispersive, has_bulk,
		index, bulk, surf, SimConst.SKIN_STRIPS)


## Begins a pass over the world as it is now, for the sky (sun or moon) or, with `lamp`, for
## that source. With `prev` (the last completed pass), tasks the edits since then can't have
## affected are replayed from it instead of traced. An `edit_only` sky pass keeps prev's sun
## even if the sun has since drifted a little further (up to RESTART_ANGLE_DEG), so edits show
## quickly; a later pass catches up with the sun.
func start(world: SimWorld, prev: LightPass = null, edit_only := false, lamp: LightSource = null) -> void:
	var t0 := Time.get_ticks_usec()
	structure_version = world.grid.structure_version
	if objects_version != world.objects_version:
		_sync_surfaces(world)
	var key := Vector2i(structure_version, objects_version)
	if _accel_key != key:
		_update_accel(world)
		_accel_key = key
	engine.Begin()
	incremental = false
	sheet_from.clear()
	sheet_to.clear()
	done = false
	stage_ms = {"map": 0.0, "direct": 0.0, "beams": 0.0}
	dir = Vector2.ZERO
	dni = 0.0
	source = null
	var objects_now := _object_states(world)
	var reuse := false
	if lamp != null:
		source = lamp
		reuse = prev != null and lamp.same_as(prev.source)
	elif world.light_is_up and world.light_dni > 0.0 and world.light_direction.y > 1e-3:
		var max_drift := SimConst.RESTART_ANGLE_DEG if edit_only else SimConst.RETRACE_ANGLE_DEG
		reuse = prev != null and prev.dir != Vector2.ZERO \
			and absf(world.light_direction.angle_to(prev.dir)) < deg_to_rad(max_drift) \
			and absf(world.light_dni / prev.dni - 1.0) < (0.25 if edit_only else 0.1)
		if reuse:
			# A geometry-only pass keeps the sun the previous pass traced, so unaffected tasks
			# can be replayed exactly; the next sun-triggered pass catches up.
			source = prev.source
		else:
			source = LightSource.parallel(world.light_direction, world.light_spectrum, world.light_dni)
		dir = source.direction
		dni = source.dni
	if source != null:
		incremental = reuse
		engine.SetCullScale(source.cull_scale())
		map.build(grid, opaque, surfaces, source)
		if source.kind == LightSource.Kind.POINT:
			engine.SetPointSource(source.spectrum, map.u0, map.lane_w, source.position)
		else:
			engine.SetParallelSource(source.spectrum, map.u0, map.lane_w, map.perp, map.dir)
		var t1 := Time.get_ticks_usec()
		stage_ms.map = (t1 - t0) / 1000.0
		_direct()
		stage_ms.direct = (Time.get_ticks_usec() - t1) / 1000.0
		var runs := PackedInt32Array()
		var s_mins := PackedFloat64Array()
		for run in map.runs:
			runs.append_array([run[0], run[1], run[3]])
			s_mins.append(run[2])
		var areas := PackedFloat32Array()
		if reuse:
			for r: Rect2 in _changed_areas(prev, objects_now):
				areas.append_array([r.position.x, r.position.y, r.size.x, r.size.y])
		engine.StartBeams(runs, s_mins, _object_cache_info(world), prev.engine if prev != null else null, areas, reuse)
	_objects = objects_now
	ms = (Time.get_ticks_usec() - t0) / 1000.0
	done = engine.TaskCount() == 0


## Fraction of tasks done.
func progress() -> float:
	return engine.Progress()


## Runs tasks until about `max_paths` more ray paths' worth of work is done (-1 = finish).
## Returns done.
func step(max_paths: int) -> bool:
	var t0 := Time.get_ticks_usec()
	done = engine.Step(max_paths)
	var spent := (Time.get_ticks_usec() - t0) / 1000.0
	ms += spent
	stage_ms.beams += spent
	return done


## Object id → [position, angle, definition] of every optical object now (machines are behind the
## play plane, D19): what changed between two passes shows as a difference.
func _object_states(world: SimWorld) -> Dictionary:
	var states := {}
	for obj: SimObject in world.objects.values():
		if not obj.def.is_machine():
			states[obj.id] = [obj.position, obj.angle, obj.def]
	return states


## Brings the material snapshot and the engine's acceleration up to date, recomputing only
## around what changed since this pass object last built them.
func _update_accel(world: SimWorld) -> void:
	var now := _object_states(world)
	var tile_areas := []
	var objs := PackedInt32Array()
	var full := _accel_key.x < 0
	if not full:
		if _accel_key.x != structure_version:
			tile_areas = _changed_tiles(material)
		for id in _accel_objects:
			if now.get(id, []) != _accel_objects[id]:
				objs.append(id)
		for id in now:
			if not _accel_objects.has(id):
				objs.append(id)
	material = grid.material.duplicate()
	engine.SetMaterial(material)
	if full:
		engine.BuildAccel()
	else:
		var areas := PackedFloat32Array()
		for r: Rect2 in tile_areas:
			areas.append_array([r.position.x, r.position.y, r.size.x, r.size.y])
		engine.UpdateAccel(areas, objs)
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
func _changed_areas(prev: LightPass, objects_now: Dictionary) -> Array:
	var areas := []
	if structure_version != prev.structure_version or prev.material.size() != grid.size():
		areas.append_array(_changed_tiles(prev.material))
	for id in prev._objects:
		var now: Array = objects_now.get(id, [])
		if now != prev._objects[id]:
			areas.append(prev.engine.BodyBounds(id))
			if not now.is_empty():
				areas.append(engine.BodyBounds(id))
	for id in objects_now:
		if not prev._objects.has(id):
			areas.append(engine.BodyBounds(id))
	return areas


## Rebuilds this pass's optical surfaces from the world's objects and hands them to the engine.
func _sync_surfaces(world: SimWorld) -> void:
	surfaces.clear()
	var mats := world.materials
	for obj: SimObject in world.objects.values():
		var def := obj.def
		if def.is_machine():
			continue   # Behind the play plane (D19)
		var coating := SurfaceSet.Coating.NONE
		var back := MaterialDB.AIR_ID
		match def.kind:
			ObjectDef.Kind.MIRROR:
				coating = SurfaceSet.Coating.MIRROR
			ObjectDef.Kind.PROBE:
				coating = SurfaceSet.Coating.PROBE
			ObjectDef.Kind.CELL:
				coating = SurfaceSet.Coating.CELL
			_:
				back = mats.id_of(def.material)
		for piece in obj.world_pieces():
			surfaces.add_polyline(piece[0], piece[1], MaterialDB.AIR_ID, back, coating, obj.id,
				def.reflectance)
	surfaces.build_buckets(world.grid.width, world.grid.height)
	var reflectance := PackedFloat32Array()
	for r in surfaces.reflectance:
		reflectance.append_array(r if r.size() == Spectrum.BIN_COUNT else Spectrum.make_zero())
	engine.SetSurfaces(surfaces.ax, surfaces.ay, surfaces.ex, surfaces.ey, surfaces.normal,
		surfaces.normal_a, surfaces.normal_b, surfaces.front_mat, surfaces.back_mat, surfaces.coating,
		surfaces.owner, surfaces.piece, reflectance, surfaces.cell_start, surfaces.cell_items)
	objects_version = world.objects_version


## Cache info for the engine's object cache: convex optical bodies whose bounds hold no other
## object's surfaces (tiles inside a body don't matter: rays inside ignore them).
## id → [definition index, angle key, first piece, position, u of its center, s of its start line]
func _object_cache_info(world: SimWorld) -> Dictionary:
	if source.kind == LightSource.Kind.POINT:
		return {}   # The cache needs identical incoming rays: parallel light only
	if _cacheable_version != world.objects_version:
		_cacheable.clear()
		var first_piece := {}
		for s in surfaces.count():
			var owner := surfaces.owner[s]
			first_piece[owner] = mini(first_piece.get(owner, 1 << 30), surfaces.piece[s])
		var w := grid.width
		for obj: SimObject in world.objects.values():
			if not obj.def.is_body():
				continue
			var ok := true
			var rect := engine.BodyBounds(obj.id)
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
		_cacheable_version = world.objects_version
	var info := {}
	for id in _cacheable:
		var obj: SimObject = world.objects[id]
		if not _def_index.has(obj.def):
			_def_index[obj.def] = _def_index.size()
		# Sample rays start before the object's bounding box along the light: everything in
		# front of an object along its run is empty, so starting earlier is safe.
		var r := engine.BodyBounds(id)
		var s_min := minf(minf(r.position.dot(dir), r.end.dot(dir)),
			minf(Vector2(r.end.x, r.position.y).dot(dir), Vector2(r.position.x, r.end.y).dot(dir)))
		info[id] = [_def_index[obj.def], roundi(obj.angle * 1e6), _cacheable[id], obj.position,
			obj.position.dot(map.perp), s_min - 0.02]
	return info


## Stage 1: lanes that end on opaque faces deposit directly; lanes that hit nothing escape.
## Probes read the lanes that cross them before their first hit.
func _direct() -> void:
	engine.DirectDeposit(map.kind, map.ref, map.side, map.depth, LaneMap.Hit.OPAQUE, LaneMap.Hit.NONE)
	for s in surfaces.count():
		if surfaces.coating[s] == SurfaceSet.Coating.PROBE:
			var n := map.lanes_reaching(surfaces.a[s], surfaces.b[s]).size()
			for b in Spectrum.BIN_COUNT:
				engine.AddIncident(surfaces.owner[s], b, engine.LaneWatts(b) * n, true)
	var far := (grid.width + grid.height) * SimConst.TILE_M
	for k in range(0, map.count, SHEET_STRIDE):
		var s_in := map.entry_s(k)
		var s_end := map.depth[k] if map.kind[k] != LaneMap.Hit.NONE else s_in + far
		sheet_from.append(map.lane_point(k, s_in))
		sheet_to.append(map.lane_point(k, s_end))
