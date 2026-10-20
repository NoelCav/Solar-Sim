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
var last_stage_ms := {}         ## Same, per stage (map, direct, beams)
var tile_power := PackedFloat32Array()     ## W absorbed per tile, at the traced DNI
var band_power := PackedFloat32Array()     ## Same, per Spectrum band (BAND_COUNT per tile)
## Surface strips light reached (D18; index layout in LightEngine.StripIds): W arriving and
## W absorbed (also counted in tile_power), at the traced DNI.
var strip_ids := PackedInt32Array()
var strip_arriving := PackedFloat32Array()
var strip_absorbed := PackedFloat32Array()
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
var _lit_power := PackedFloat32Array()     ## Absorbed inside the tile (bulk), not at its surface
var _skin_ids := PackedInt32Array()        ## Strips absorbing light at a surface (sim state)
var _skin_power := PackedFloat32Array()
var _skin_mapped := -1                     ## Skin version _skin_power was written into (-1: redo)
var _unskinned_tiles := PackedInt32Array() ## Tiles taking surface light their face has no skin for
var _unskinned_power := PackedFloat32Array()
var _strip_slot := {}                      ## Engine strip index -> slot in strip_ids
var _obj_power := {}            ## Object id -> W absorbed in its body, at _traced_dni (sim state)

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
	var obsolete := world.light_is_up and _pass.dir != Vector2.ZERO \
		and absf(world.light_direction.angle_to(_pass.dir)) > deg_to_rad(SimConst.RESTART_ANGLE_DEG)
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


## Runs a complete pass now (tests, benchmarks). `fresh` traces again on the current pass
## reusing no results (its geometry caches stay warm): what a full pass costs.
func retrace(world: SimWorld, fresh := false) -> void:
	if _pass == null:
		_setup(world)
	if fresh:
		_pass.start(world, null)
		_pass_active = true
	else:
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


## An engine set up on the current geometry for test rays (SimProbe), on the preview pass:
## the sim's own passes are untouched. Null before the first tick.
func probe_engine(world: SimWorld) -> LightEngine:
	if _preview == null:
		return null
	_preview.start(world, _shown)
	_preview.engine.Begin()
	return _preview.engine


## Factor from published `tile_power` (traced at an earlier DNI) to current watts.
func power_scale(world: SimWorld) -> float:
	return world.light_dni / shown_dni if shown_dni > 0.0 else 0.0


## Factor from published `tile_power`, `band_power` (W per tile) to current W/m² of a tile face;
## for a surface strip (a SKIN_STRIPS-th of a face) multiply by SKIN_STRIPS.
func irradiance_scale(world: SimWorld) -> float:
	return power_scale(world) / (SimConst.TILE_M * SimConst.DEPTH_M)


## True when published results lag behind the world (a pass is pending or running).
func is_stale(world: SimWorld) -> bool:
	return _pass_active or _needs_retrace(world)


## The engine holding the last complete pass (tests).
func tracer() -> LightEngine:
	return _pass.engine


func _start_pass(world: SimWorld, edit_only := false) -> void:
	# Two passes alternate: the new one reuses what it can from the last completed one.
	_pass = _passes[1] if _shown == _passes[0] else _passes[0]
	_pass.start(world, _shown, edit_only)
	_pass_active = true


func _publish(world: SimWorld, p: LightPass, sim_state: bool) -> void:
	var e := p.engine
	tile_power = e.TilePower()
	band_power = e.BandPower()
	strip_ids = e.StripIds()
	strip_arriving = e.StripArriving()
	strip_absorbed = e.StripAbsorbed()
	_strip_slot.clear()
	for k in strip_ids.size():
		_strip_slot[strip_ids[k]] = k
	shown_lit = e.LitTiles()
	sheet_from = p.sheet_from.duplicate()
	sheet_to = p.sheet_to.duplicate()
	beam_render = e.Render()
	ray_from = e.SegFrom()
	ray_to = e.SegTo()
	ray_power = e.SegPower()
	var absorbed: Dictionary = e.ObjectAbsorbed()
	var incident: Dictionary = e.ObjectIncident()
	for obj: SimObject in world.objects.values():
		obj.absorbed_w = absorbed.get(obj.id, 0.0)
		var split: PackedFloat32Array = incident.get(obj.id, PackedFloat32Array())
		obj.incident = Spectrum.make_zero()
		obj.incident_direct = Spectrum.make_zero()
		for b in Spectrum.BIN_COUNT if split.size() == 2 * Spectrum.BIN_COUNT else 0:
			obj.incident_direct[b] = split[b]
			obj.incident[b] = split[b] + split[Spectrum.BIN_COUNT + b]
	stats = e.Stats()
	stats.lanes = p.map.count if p.dir != Vector2.ZERO else 0
	shown_dni = p.dni
	trace_version += 1
	if not sim_state:
		return
	_pass_active = false
	_shown = p
	_obj_power = e.ObjectAbsorbed()
	# Light absorbed at a surface heats the skin (D18); the tile keeps what it absorbed inside.
	var bulk := tile_power.duplicate()
	var per_tile := 4 * SimConst.SKIN_STRIPS
	for k in strip_ids.size():
		bulk[strip_ids[k] / per_tile] -= strip_absorbed[k]
	_lit_tiles.clear()
	_lit_power.clear()
	for i in shown_lit:
		if bulk[i] > 1e-9:
			_lit_tiles.append(i)
			_lit_power.append(bulk[i])
	_skin_ids = strip_ids.duplicate()
	_skin_power = strip_absorbed.duplicate()
	_skin_mapped = -1
	_traced_structure = p.structure_version
	_traced_objects = p.objects_version
	_traced_dir = p.dir
	_traced_dni = p.dni
	last_trace_ms = p.ms
	last_stage_ms = p.stage_ms.duplicate()


func _deposit(world: SimWorld, dt: float) -> void:
	var g := world.grid
	var energy := g.energy_in
	if _traced_dni > 0.0:
		var scale := world.light_dni / _traced_dni * dt
		for k in _lit_tiles.size():
			energy[_lit_tiles[k]] += _lit_power[k] * scale
		_map_surface_light(world)
		world.skin.light_scale = world.light_dni / _traced_dni
		for k in _unskinned_tiles.size():
			energy[_unskinned_tiles[k]] += _unskinned_power[k] * scale
		for id in _obj_power:
			var obj: SimObject = world.objects.get(id)
			if obj != null:
				obj.heat_in += _obj_power[id] * scale
	else:
		world.skin.light_scale = 0.0
	if world.diffuse_irradiance > 0.0:
		# Diffuse sky light on each column's top surface: into its skin (spread evenly over the
		# face), or the tile itself when it has none (a liquid surface).
		var per_tile := world.diffuse_irradiance * SimConst.TILE_M * SimConst.DEPTH_M * dt
		var mat := g.material
		var absorptivity := world.materials.sun_absorptivity
		var skin := world.skin
		skin.sync(world)
		for i in g.sky_tiles(world.materials.is_gas):
			var f := skin.face_of[i * 4]
			if f >= 0:
				skin.face_energy_in[f] += per_tile * absorptivity[mat[i]]
			else:
				energy[i] += per_tile * absorptivity[mat[i]]


## Writes the traced surface light into the skin's per-strip rate (when a pass published or the
## skin was rebuilt); a strip whose face has no skin heats its tile instead.
func _map_surface_light(world: SimWorld) -> void:
	var skin := world.skin
	skin.sync(world)
	if _skin_mapped == skin.version:
		return
	skin.light_w.fill(0.0)
	_unskinned_tiles.clear()
	_unskinned_power.clear()
	var per_tile := 4 * SimConst.SKIN_STRIPS
	for k in _skin_ids.size():
		var local := skin.local_strip(_skin_ids[k])
		if local >= 0:
			skin.light_w[local] += _skin_power[k]
		else:
			_unskinned_tiles.append(_skin_ids[k] / per_tile)
			_unskinned_power.append(_skin_power[k])
	_skin_mapped = skin.version


## Light arriving now on surface strip `index` (LightEngine.StripIds layout), W/m².
func strip_irradiance(index: int, world: SimWorld) -> float:
	var slot: int = _strip_slot.get(index, -1)
	return strip_arriving[slot] * irradiance_scale(world) * SimConst.SKIN_STRIPS if slot >= 0 else 0.0


## Light arriving now on the brightest surface strip of tile i, W/m² (0 if none).
func strip_irradiance_max(i: int, world: SimWorld) -> float:
	var best := 0.0
	var base := i * 4 * SimConst.SKIN_STRIPS
	for k in 4 * SimConst.SKIN_STRIPS:
		best = maxf(best, strip_irradiance(base + k, world))
	return best


func _setup(world: SimWorld) -> void:
	_passes = [LightPass.new(world.grid, world.materials), LightPass.new(world.grid, world.materials)]
	_pass = _passes[0]
	_preview = LightPass.new(world.grid, world.materials)


func _needs_retrace(world: SimWorld) -> bool:
	if world.grid.structure_version != _traced_structure or world.objects_version != _traced_objects:
		return true
	var up := world.light_is_up and world.light_dni > 0.0
	if up != (_traced_dni > 0.0):
		return true
	if not up:
		return false
	if absf(world.light_direction.angle_to(_traced_dir)) > deg_to_rad(SimConst.RETRACE_ANGLE_DEG):
		return true
	# The spectrum reddens as DNI falls; re-trace on large intensity changes.
	return absf(world.light_dni / _traced_dni - 1.0) > 0.1
