class_name LightSystem
extends SimSystem
## Tick step 3: traces sunlight and deposits absorbed power into `energy_in` every tick
## (design doc §5.3, §6).
##
## A pass (see LightPass) starts when the sun has moved or dimmed enough, or geometry
## changed. Its direct-light stage runs at once; its beam stage traces a fixed number of
## ray paths per tick (deterministic, D7). Results are published when the pass completes;
## until then the previous results stay in use, scaled by the current DNI so intensity
## stays smooth. Geometry changes or a sun jump restart a pass in progress.
## Diffuse sky light is not traced: it lands on each column's first non-gas tile (§6.2).

var surfaces := SurfaceSet.new()

# --- Published results (read by renderers, inspector) ---
var trace_version := 0          ## Bumped on every publish
var last_trace_ms := 0.0        ## CPU time of the last complete pass, summed over its ticks
var tile_power := PackedFloat32Array()     ## W absorbed per tile, at the traced DNI
var band_power := PackedFloat32Array()     ## Same, per Spectrum band (BAND_COUNT per tile)
var shown_lit := PackedInt32Array()        ## Tiles with tile_power > 0
var sheet_from := PackedVector2Array()     ## Direct-light sheet (see LightPass)
var sheet_to := PackedVector2Array()
var beam_pts := PackedVector2Array()       ## Beam triangles (see BeamTracer)
var beam_irr := PackedFloat32Array()
var beam_bin := PackedByteArray()
var ray_from := PackedVector2Array()       ## Secondary rays (pooled reflections)
var ray_to := PackedVector2Array()
var ray_power := PackedFloat32Array()
var stats := {}                 ## emitted/absorbed/escaped/scattered/culled W, rays
var shown_dni := 0.0            ## DNI the published (displayed) results were traced at

var _pass: LightPass
var _preview: LightPass
var _traced_structure := -1
var _traced_objects := -1
var _traced_dir := Vector2.ZERO
var _traced_dni := 0.0          ## DNI behind the deposits in use (sim state)
var _lit_tiles := PackedInt32Array()
var _lit_power := PackedFloat32Array()
var _diffuse_absorptivity := PackedFloat32Array()   ## AM1.5-weighted, per material

var _pass_active := false
var _pass_structure := -1
var _pass_objects := -1
var _surfaces_objects := -1
var _blocks_key := Vector2i(-1, -1)
var _preview_blocks_key := Vector2i(-1, -1)


func system_name() -> StringName:
	return &"light"


func tick(world: SimWorld, dt: float) -> void:
	if _pass == null:
		_setup(world)
	# Restart a running pass if its inputs are obsolete: geometry changed, or the sun jumped
	# (creative time skip) far beyond normal drift during a pass.
	var obsolete := world.grid.structure_version != _pass_structure \
		or world.objects_version != _pass_objects \
		or (world.sun_is_up and _pass.dir != Vector2.ZERO \
			and absf(world.sun_direction.angle_to(_pass.dir)) > deg_to_rad(SimConst.RESTART_ANGLE_DEG))
	if (_pass_active and obsolete) or (not _pass_active and _needs_retrace(world)):
		_start_pass(world)
	if _pass_active and _pass.step(SimConst.RAY_PATHS_PER_TICK):
		_publish(world, _pass, true)
	_deposit(world, dt)


## Runs a complete pass now (tests, benchmarks).
func retrace(world: SimWorld) -> void:
	if _pass == null:
		_setup(world)
	_start_pass(world)
	_pass.step(-1)
	_publish(world, _pass, true)


## Traces the current state on a separate pass and publishes only what renderers and the
## inspector read. Sim state (deposits, the pass in progress) is untouched, so edits made
## while paused can be shown without affecting determinism (D7).
func preview(world: SimWorld) -> void:
	if _pass == null:
		_setup(world)
	_sync_surfaces(world)
	var key := Vector2i(world.grid.structure_version, world.objects_version)
	if _preview_blocks_key != key:
		_preview.tracer.build_blocks()
		_preview_blocks_key = key
	_preview.start(world)
	_preview.step(-1)
	_publish(world, _preview, false)


## Factor from published `tile_power` (traced at an earlier DNI) to current watts.
func power_scale(world: SimWorld) -> float:
	return world.sun_dni / shown_dni if shown_dni > 0.0 else 0.0


## True when published results lag behind the world (a pass is pending or running).
func is_stale(world: SimWorld) -> bool:
	return _pass_active or _needs_retrace(world)


## The tracer holding the last complete pass's accounting (tests).
func tracer() -> Tracer:
	return _pass.tracer


func _start_pass(world: SimWorld) -> void:
	_sync_surfaces(world)
	var key := Vector2i(world.grid.structure_version, world.objects_version)
	if _blocks_key != key:
		_pass.tracer.build_blocks()
		_blocks_key = key
	_pass.start(world)
	_pass_active = true
	_pass_structure = world.grid.structure_version
	_pass_objects = world.objects_version


func _publish(world: SimWorld, p: LightPass, sim_state: bool) -> void:
	var tr := p.tracer
	tile_power = tr.tile_power.duplicate()
	band_power = tr.band_power.duplicate()
	shown_lit = tr.lit_tiles.duplicate()
	sheet_from = p.sheet_from.duplicate()
	sheet_to = p.sheet_to.duplicate()
	beam_pts = p.beams.tri_pts.duplicate()
	beam_irr = p.beams.tri_irr.duplicate()
	beam_bin = p.beams.tri_bin.duplicate()
	ray_from = tr.seg_from.duplicate()
	ray_to = tr.seg_to.duplicate()
	ray_power = tr.seg_power.duplicate()
	for obj: SimObject in world.objects.values():
		obj.absorbed_w = tr.object_absorbed.get(obj.id, 0.0)
		obj.incident = tr.object_incident.get(obj.id, Spectrum.make_zero())
	stats = {
		"emitted": tr.emitted_w, "absorbed": tr.absorbed_w, "escaped": tr.escaped_w,
		"scattered": tr.scattered_w, "culled": tr.culled_w, "rays": tr.ray_count,
		"lanes": p.map.count if p.dir != Vector2.ZERO else 0,
	}
	shown_dni = p.dni
	trace_version += 1
	if not sim_state:
		return
	_pass_active = false
	_lit_tiles = tr.lit_tiles.duplicate()
	_lit_power.resize(_lit_tiles.size())
	for k in _lit_tiles.size():
		_lit_power[k] = tile_power[_lit_tiles[k]]
	_traced_structure = _pass_structure
	_traced_objects = _pass_objects
	_traced_dir = p.dir
	_traced_dni = p.dni
	last_trace_ms = p.ms


func _deposit(world: SimWorld, dt: float) -> void:
	var g := world.grid
	var energy := g.energy_in
	if _traced_dni > 0.0 and not _lit_tiles.is_empty():
		var scale := world.sun_dni / _traced_dni * dt
		for k in _lit_tiles.size():
			energy[_lit_tiles[k]] += _lit_power[k] * scale
	if world.diffuse_irradiance > 0.0:
		var per_tile := world.diffuse_irradiance * SimConst.TILE_M * SimConst.DEPTH_M * dt
		var mat := g.material
		for i in g.sky_tiles(world.materials.is_gas):
			energy[i] += per_tile * _diffuse_absorptivity[mat[i]]


func _setup(world: SimWorld) -> void:
	_pass = LightPass.new(world.grid, world.materials, surfaces)
	_preview = LightPass.new(world.grid, world.materials, surfaces)
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


func _sync_surfaces(world: SimWorld) -> void:
	if _surfaces_objects == world.objects_version:
		return
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
