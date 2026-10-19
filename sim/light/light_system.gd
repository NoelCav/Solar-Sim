class_name LightSystem
extends SimSystem
## Tick step 3: traces sunlight and deposits absorbed power into `energy_in` every tick
## (design doc §5.3, §6).
##
## A re-trace ("pass") starts when the sun has moved or dimmed enough, or geometry changed.
## It traces a fixed number of rays per tick (deterministic, D7) and publishes its results
## when complete; until then the previous results stay in use, scaled by the current DNI so
## intensity stays smooth. Geometry changes restart a pass in progress.
## Diffuse sky light is not traced: it lands on each column's first non-gas tile (§6.2).

var surfaces := SurfaceSet.new()
var tracer: Tracer

# --- Published results (read by renderers, inspector) ---
var trace_version := 0          ## Bumped on every publish
var last_trace_ms := 0.0        ## CPU time of the last complete pass, summed over its ticks
var render_from := PackedVector2Array()
var render_to := PackedVector2Array()
var render_power := PackedFloat32Array()   ## BIN_COUNT values per segment
var tile_power := PackedFloat32Array()     ## W absorbed per tile, at the traced DNI
var stats := {}                 ## emitted/absorbed/escaped/scattered/culled W, rays

var _traced_structure := -1
var _traced_objects := -1
var _traced_dir := Vector2.ZERO
var _traced_dni := 0.0
var _lit_tiles := PackedInt32Array()
var _lit_power := PackedFloat32Array()
var _diffuse_absorptivity := PackedFloat32Array()   ## AM1.5-weighted, per material

# Pass in progress.
var _pass_active := false
var _pass_rays := 0
var _pass_next := 0
var _pass_ms := 0.0
var _pass_structure := -1
var _pass_objects := -1
var _pass_dir := Vector2.ZERO
var _pass_dni := 0.0
var _surfaces_objects := -1
var _blocks_key := Vector2i(-1, -1)
var _preview_tracer: Tracer


func system_name() -> StringName:
	return &"light"


func tick(world: SimWorld, dt: float) -> void:
	if tracer == null:
		_setup(world)
	# Restart a running pass if its inputs are obsolete: geometry changed, or the sun jumped
	# (creative time skip) far beyond normal drift during a pass.
	var obsolete := world.grid.structure_version != _pass_structure \
		or world.objects_version != _pass_objects \
		or (world.sun_is_up and _pass_dir != Vector2.ZERO \
			and absf(world.sun_direction.angle_to(_pass_dir)) > deg_to_rad(SimConst.RESTART_ANGLE_DEG))
	if (_pass_active and obsolete) or (not _pass_active and _needs_retrace(world)):
		_start_pass(world)
	if _pass_active:
		_continue_pass(world, SimConst.RAY_PATHS_PER_TICK)
	_deposit(world, dt)


## Runs a complete pass now (tests, and previews while paused).
func retrace(world: SimWorld) -> void:
	if tracer == null:
		_setup(world)
	_start_pass(world)
	_continue_pass(world, -1)


## Factor from published `tile_power` (traced at an earlier DNI) to current watts.
func power_scale(world: SimWorld) -> float:
	return world.sun_dni / _traced_dni if _traced_dni > 0.0 else 0.0


## True when published results lag behind the world (a pass is pending or running).
func is_stale(world: SimWorld) -> bool:
	return _pass_active or _needs_retrace(world)


## Traces the current state on a separate tracer and publishes only what renderers and
## the inspector read. Sim state (deposits, the pass in progress) is untouched, so edits
## made while paused can be shown without affecting determinism (D7).
func preview(world: SimWorld) -> void:
	if tracer == null:
		_setup(world)
	if _preview_tracer == null:
		_preview_tracer = Tracer.new(world.grid, world.materials, surfaces)
	if _surfaces_objects != world.objects_version:
		_rebuild_surfaces(world)
	var pt := _preview_tracer
	pt.build_blocks()
	pt.begin()
	if world.sun_is_up and world.sun_dni > 0.0:
		pt.trace_sun(world.sun_direction, world.sun_spectrum, SimConst.RAY_SPACING_M, _y_start(world))
	render_from = pt.seg_from.duplicate()
	render_to = pt.seg_to.duplicate()
	render_power = pt.seg_power.duplicate()
	for obj: SimObject in world.objects.values():
		obj.absorbed_w = pt.object_absorbed.get(obj.id, 0.0)
		obj.incident = pt.object_incident.get(obj.id, Spectrum.make_zero())
	trace_version += 1


## Sun rays start just above the highest tile or surface (nothing above interacts).
func _y_start(world: SimWorld) -> float:
	var top := mini(world.grid.top_nonair_row(), surfaces.top_row())
	return maxf(0.0, top * SimConst.TILE_M - 0.01)


func _start_pass(world: SimWorld) -> void:
	var start := Time.get_ticks_usec()
	var g := world.grid
	if _surfaces_objects != world.objects_version:
		_rebuild_surfaces(world)
	var key := Vector2i(g.structure_version, world.objects_version)
	if _blocks_key != key:
		tracer.build_blocks()
		_blocks_key = key
	tracer.begin()
	_pass_rays = 0
	if world.sun_is_up and world.sun_dni > 0.0:
		_pass_rays = tracer.setup_sun(world.sun_direction, world.sun_spectrum, SimConst.RAY_SPACING_M,
			_y_start(world))
	_pass_next = 0
	_pass_active = true
	_pass_structure = g.structure_version
	_pass_objects = world.objects_version
	_pass_dir = world.sun_direction if world.sun_is_up else Vector2.ZERO
	_pass_dni = world.sun_dni if world.sun_is_up else 0.0
	_pass_ms = (Time.get_ticks_usec() - start) / 1000.0


## Traces sun rays until `max_paths` ray paths (children included) have been traced this
## call, or the pass is done; -1 = no limit. Ray-path counts are deterministic.
func _continue_pass(world: SimWorld, max_paths: int) -> void:
	var start := Time.get_ticks_usec()
	var limit := tracer.ray_count + max_paths if max_paths >= 0 else 1 << 62
	while _pass_next < _pass_rays and tracer.ray_count < limit:
		tracer.sun_ray(_pass_next)
		_pass_next += 1
	_pass_ms += (Time.get_ticks_usec() - start) / 1000.0
	if _pass_next >= _pass_rays:
		_publish(world)


func _publish(world: SimWorld) -> void:
	_pass_active = false
	tile_power = tracer.tile_power.duplicate()
	_lit_tiles = tracer.lit_tiles.duplicate()
	_lit_power.resize(_lit_tiles.size())
	for k in _lit_tiles.size():
		_lit_power[k] = tile_power[_lit_tiles[k]]
	render_from = tracer.seg_from.duplicate()
	render_to = tracer.seg_to.duplicate()
	render_power = tracer.seg_power.duplicate()
	for obj: SimObject in world.objects.values():
		obj.absorbed_w = tracer.object_absorbed.get(obj.id, 0.0)
		obj.incident = tracer.object_incident.get(obj.id, Spectrum.make_zero())
	stats = {
		"emitted": tracer.emitted_w, "absorbed": tracer.absorbed_w, "escaped": tracer.escaped_w,
		"scattered": tracer.scattered_w, "culled": tracer.culled_w, "rays": tracer.ray_count,
	}
	_traced_structure = _pass_structure
	_traced_objects = _pass_objects
	_traced_dir = _pass_dir
	_traced_dni = _pass_dni
	last_trace_ms = _pass_ms
	trace_version += 1


func _deposit(world: SimWorld, dt: float) -> void:
	var g := world.grid
	var energy := g.energy_in
	if _traced_dni > 0.0:
		var scale := world.sun_dni / _traced_dni * dt
		for k in _lit_tiles.size():
			energy[_lit_tiles[k]] += _lit_power[k] * scale
	if world.diffuse_irradiance > 0.0:
		var per_tile := world.diffuse_irradiance * SimConst.TILE_M * SimConst.DEPTH_M * dt
		var mat := g.material
		for i in g.sky_tiles(world.materials.is_gas):
			energy[i] += per_tile * _diffuse_absorptivity[mat[i]]


func _setup(world: SimWorld) -> void:
	tracer = Tracer.new(world.grid, world.materials, surfaces)
	var mats := world.materials
	_diffuse_absorptivity.resize(mats.count())
	_diffuse_absorptivity.fill(0.0)
	for def in mats.placeable():
		var a := 0.0
		for b in Spectrum.BIN_COUNT:
			a += def.surface_absorptivity[b] * Spectrum.AM15_SHARE[b]
		_diffuse_absorptivity[def.id] = a


func _needs_retrace(world: SimWorld) -> bool:
	if world.grid.structure_version != _traced_structure or world.objects_version != _traced_objects:
		return true
	var up := world.sun_is_up and world.sun_dni > 0.0
	if up != (_traced_dni > 0.0):
		return true
	if not up:
		return false
	if absf(world.sun_direction.angle_to(_traced_dir)) > deg_to_rad(SimConst.RETRACE_ANGLE_DEG):
		return true
	# The spectrum reddens as DNI falls; re-trace on large intensity changes.
	return absf(world.sun_dni / _traced_dni - 1.0) > 0.1


func _rebuild_surfaces(world: SimWorld) -> void:
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
	_surfaces_objects = world.objects_version
