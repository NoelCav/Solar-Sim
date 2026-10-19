class_name LightSystem
extends SimSystem
## Tick step 3: traces sunlight and deposits absorbed power into `energy_in` every tick
## (design doc §5.3, §6).
##
## A pass (see LightPass) starts when the sun has moved or dimmed enough, or geometry
## changed. Its direct-light stage runs at once; its beam stage traces a fixed number of
## ray paths per tick (deterministic, D7). Results are published when the pass completes;
## until then the previous results stay in use, scaled by the current DNI so intensity
## stays smooth. A pass works on a snapshot of the geometry and always runs to completion,
## so continuous edits (dragging a lens) still publish every pass, lagging by at most one
## pass; only a sun jump (creative time skip) restarts a pass in progress.
## Diffuse sky light is not traced: it lands on each column's first non-gas tile (§6.2).

# --- Published results (read by renderers, inspector) ---
var trace_version := 0          ## Bumped on every publish
var last_trace_ms := 0.0        ## CPU time of the last complete pass, summed over its ticks
var tile_power := PackedFloat32Array()     ## W absorbed per tile, at the traced DNI
var band_power := PackedFloat32Array()     ## Same, per Spectrum band (BAND_COUNT per tile)
var shown_lit := PackedInt32Array()        ## Tiles with tile_power > 0
var sheet_from := PackedVector2Array()     ## Direct-light sheet (see LightPass)
var sheet_to := PackedVector2Array()
var beam_render := PackedFloat32Array()    ## Beam render records (layout in BeamGeometry)
var ray_from := PackedVector2Array()       ## Secondary rays (pooled reflections)
var ray_to := PackedVector2Array()
var ray_power := PackedFloat32Array()
var stats := {}                 ## emitted/absorbed/escaped/scattered/culled W, rays
var shown_dni := 0.0            ## DNI the published (displayed) results were traced at

var _pass: LightPass             ## The pass in progress (or the last one, when idle)
var _shown: LightPass            ## The last completed sim pass (reused by the next one)
var _passes: Array[LightPass] = []
var _preview: LightPass
var _traced_structure := -1
var _traced_objects := -1
var _traced_dir := Vector2.ZERO
var _traced_dni := 0.0          ## DNI behind the deposits in use (sim state)
var _lit_tiles := PackedInt32Array()
var _lit_power := PackedFloat32Array()
var _diffuse_absorptivity := PackedFloat32Array()   ## AM1.5-weighted, per material

var _pass_active := false


func system_name() -> StringName:
	return &"light"


func tick(world: SimWorld, dt: float) -> void:
	if _pass == null:
		_setup(world)
	# Restart a running pass if the sun jumped (creative time skip) far beyond normal drift.
	# Geometry edits are normally picked up by the next pass, but a long full pass (the sun
	# moved) that is less than half done gives way to a quick incremental pass at the sun
	# already shown, so edits appear promptly; the sun catches up once edits stop.
	var obsolete := world.sun_is_up and _pass.dir != Vector2.ZERO \
		and absf(world.sun_direction.angle_to(_pass.dir)) > deg_to_rad(SimConst.RESTART_ANGLE_DEG)
	var edited := _pass_active and (world.grid.structure_version != _pass.structure_version \
		or world.objects_version != _pass.objects_version)
	if _pass_active and obsolete:
		_start_pass(world)
	elif edited and not _pass.incremental and _pass.progress() < 0.5 and _shown != null:
		_start_pass(world, true)
	elif not _pass_active and _needs_retrace(world):
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
	_preview.start(world, _shown)
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


func _start_pass(world: SimWorld, edit_only := false) -> void:
	# Two passes alternate: the new one reuses what it can from the last completed one.
	_pass = _passes[1] if _shown == _passes[0] else _passes[0]
	_pass.start(world, _shown, edit_only)
	_pass_active = true


func _publish(world: SimWorld, p: LightPass, sim_state: bool) -> void:
	var tr := p.tracer
	tile_power = tr.tile_power.duplicate()
	band_power = tr.band_power.duplicate()
	shown_lit = tr.lit_tiles.duplicate()
	sheet_from = p.sheet_from.duplicate()
	sheet_to = p.sheet_to.duplicate()
	beam_render = p.beams.render.duplicate()
	ray_from = tr.seg_from.duplicate()
	ray_to = tr.seg_to.duplicate()
	ray_power = tr.seg_power.duplicate()
	for obj: SimObject in world.objects.values():
		obj.absorbed_w = tr.object_absorbed.get(obj.id, 0.0)
		obj.incident = tr.object_incident.get(obj.id, Spectrum.make_zero())
	stats = {
		"emitted": tr.emitted_w, "absorbed": tr.absorbed_w, "escaped": tr.escaped_w,
		"scattered": tr.scattered_w, "culled": tr.culled_w, "rays": tr.ray_count,
		"lanes": p.map.count if p.dir != Vector2.ZERO else 0, "replayed": p.replayed,
	}
	shown_dni = p.dni
	trace_version += 1
	if not sim_state:
		return
	_pass_active = false
	_shown = p
	_lit_tiles = tr.lit_tiles.duplicate()
	_lit_power.resize(_lit_tiles.size())
	for k in _lit_tiles.size():
		_lit_power[k] = tile_power[_lit_tiles[k]]
	_traced_structure = p.structure_version
	_traced_objects = p.objects_version
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
	_passes = [LightPass.new(world.grid, world.materials), LightPass.new(world.grid, world.materials)]
	_pass = _passes[0]
	_preview = LightPass.new(world.grid, world.materials)
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
