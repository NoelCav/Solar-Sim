class_name LightLayer
extends RefCounted
## The light of one source (design doc §6.11): the sky (the sun, or the moon at night) or one lamp.
## Owns its passes (see LightPass), the results it publishes and the heat it deposits. Between
## passes the published results are scaled by the source's strength now over its strength when
## traced, so a dimming sun or lamp stays smooth. LightSystem keeps the sky layer and one layer
## per lamp, and consumers add the layers up.
##
## A pass (see LightPass) starts when the source has moved or changed strength enough, or
## geometry changed. Its direct-light stage runs at once; its beam stage traces a fixed number of
## ray paths per tick (deterministic, D7). Results are published when the pass completes; until
## then the previous results stay in use. A pass works on a snapshot of the geometry and always
## runs to completion, so continuous edits (dragging a lens) still publish every pass, lagging by
## at most one pass; only a sun jump (creative time skip) restarts a pass in progress.

# --- Published results (read by renderers, inspector) ---
var trace_version := 0          ## Bumped on every publish
var last_trace_ms := 0.0        ## CPU time of the last complete pass, summed over its ticks
var last_stage_ms := {}         ## Same, per stage (map, direct, beams)
var tile_power := PackedFloat32Array()     ## W absorbed per tile, at the traced strength
var band_power := PackedFloat32Array()     ## Same, per Spectrum band (BAND_COUNT per tile)
## Surface strips light reached (D18; index layout in LightEngine.StripIds): W arriving and
## W absorbed (also counted in tile_power), at the traced strength.
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
var shown_strength := 0.0       ## Strength of the source the published (displayed) results were traced at

## Object id -> W per bin arriving on its active face (direct bins, then the rest), as traced.
var incident := {}

## The lamp object this layer lights for (-1: the sky).
var lamp_id := -1

var _pass: LightPass             ## The pass in progress (or the last one, when idle)
var _shown: LightPass            ## The last completed sim pass (reused by the next one)
var _passes: Array[LightPass] = []
var _traced_structure := -1
var _traced_objects := -1
var _traced_source: LightSource  ## The source behind the deposits in use (sim state)
var _traced_strength := 0.0     ## Its strength
var _lit_tiles := PackedInt32Array()
var _lit_power := PackedFloat32Array()     ## Absorbed inside the tile (bulk), not at its surface
var _skin_ids := PackedInt32Array()        ## Strips absorbing light at a surface (sim state)
var _skin_power := PackedFloat32Array()
var _skin_mapped := -1                     ## Skin version _skin_power was written into (-1: redo)
var _unskinned_tiles := PackedInt32Array() ## Tiles taking surface light their face has no skin for
var _unskinned_power := PackedFloat32Array()
var _strip_slot := {}                      ## Engine strip index -> slot in strip_ids
var _obj_power := {}            ## Object id -> W absorbed in its body, at the traced strength (sim state)

var _pass_active := false


func _init(p_lamp_id := -1) -> void:
	lamp_id = p_lamp_id


func tick(world: SimWorld, dt: float) -> void:
	if _pass == null:
		_setup(world)
	# Restart a running pass if the sun jumped (creative time skip) far beyond normal drift.
	# Geometry edits are normally picked up by the next pass, but a long full pass (the sun
	# moved) that is less than half done gives way to a quick incremental pass at the sun
	# already shown, so edits appear promptly; the sun catches up once edits stop.
	var obsolete := lamp_id < 0 and world.light_is_up and _pass.source != null \
		and absf(world.light_direction.angle_to(_pass.source.direction)) > deg_to_rad(SimConst.RESTART_ANGLE_DEG)
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
		_pass.start(world, _wanted(world))
		_pass_active = true
	else:
		_start_pass(world)
	_pass.step(-1)
	_publish(world, _pass, true)


## Traces the current state on `scratch` (a pass shared by the layers, so lamps don't each keep
## one) and publishes only what renderers and the inspector read. Sim state (deposits, the pass
## in progress) is untouched, so edits made while paused can be shown without affecting
## determinism (D7).
func preview(world: SimWorld, scratch: LightPass) -> void:
	if _pass == null:
		_setup(world)
	scratch.start(world, _source_to_trace(world, false), _shown)
	scratch.step(-1)
	_publish(world, scratch, false)


## An engine set up on the current geometry for test rays (SimProbe), on `scratch`: the sim's own
## passes are untouched.
func probe_engine(world: SimWorld, scratch: LightPass) -> LightEngine:
	scratch.start(world, _source_to_trace(world, false), _shown)
	scratch.engine.Begin()
	return scratch.engine


## Strength of the source now: the sky's DNI, a lamp's watts of light (0 when off).
func strength_now(world: SimWorld) -> float:
	if lamp_id < 0:
		return world.light_dni
	var lamp := _lamp_source(world)
	return lamp.strength() if lamp != null else 0.0


## Factor from published `tile_power` (traced at an earlier strength) to current watts.
func power_scale(world: SimWorld) -> float:
	return strength_now(world) / shown_strength if shown_strength > 0.0 else 0.0


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


## Factor from the traced deposits (heat, skin) to the strength now.
func deposit_scale(world: SimWorld) -> float:
	return strength_now(world) / _traced_strength if _traced_strength > 0.0 else 0.0


## Adds the light this layer puts on surface strips to `target` (the skin's per-strip watts), at
## the traced strength, or with `current` at the strength now.
func write_skin(world: SimWorld, target: PackedFloat32Array, current: bool) -> void:
	var scale := 1.0
	if current:
		scale = strength_now(world) / _traced_strength if _traced_strength > 0.0 else 0.0
	var skin := world.skin
	skin.sync(world)
	for k in _skin_ids.size():
		var local := skin.local_strip(_skin_ids[k])
		if local >= 0:
			target[local] += _skin_power[k] * scale


## The source to trace for the sky or the lamp now; null while it gives no light.
func _wanted(world: SimWorld) -> LightSource:
	if lamp_id >= 0:
		return _lamp_source(world)
	if world.light_is_up and world.light_dni > 0.0 and world.light_direction.y > 1e-3:
		return LightSource.parallel(world.light_direction, world.light_spectrum, world.light_dni)
	return null


## The lamp's light now (null: no such lamp, or it gives none).
func _lamp_source(world: SimWorld) -> LightSource:
	var obj: SimObject = world.objects.get(lamp_id)
	if obj == null:
		return null
	var def := obj.def
	var watts := def.lamp_light_w() * obj.lamp_level
	if watts <= 0.0:
		return null
	var spread := minf(deg_to_rad(def.lamp_spread_deg), TAU)
	var shares := Spectrum.make_zero()
	for b in Spectrum.BIN_COUNT:
		shares[b] = watts * def.lamp_spectrum[b] / spread
	var aim := obj.angle + PI * 0.5
	return LightSource.point(obj.position, shares, aim - spread * 0.5, aim + spread * 0.5)


func _setup(world: SimWorld) -> void:
	_passes = [LightPass.new(world.grid, world.materials), LightPass.new(world.grid, world.materials)]
	_pass = _passes[0]


func _start_pass(world: SimWorld, edit_only := false) -> void:
	# Two passes alternate: the new one reuses what it can from the last completed one.
	_pass = _passes[1] if _shown == _passes[0] else _passes[0]
	_pass.start(world, _source_to_trace(world, edit_only), _shown)
	_pass_active = true


## The source for a new pass. A geometry-only pass keeps the sun the previous pass traced when
## the sun has moved less than the re-trace threshold, so unaffected tasks can be replayed
## exactly; the next sun-triggered pass catches up. An `edit_only` pass keeps prev's sun even if
## the sun has since drifted a little further (up to RESTART_ANGLE_DEG), so edits show quickly.
func _source_to_trace(world: SimWorld, edit_only: bool) -> LightSource:
	var now := _wanted(world)
	var prev := _shown.source if _shown != null else null
	if now == null or prev == null or lamp_id >= 0:
		return now
	var max_drift := SimConst.RESTART_ANGLE_DEG if edit_only else SimConst.RETRACE_ANGLE_DEG
	if absf(now.direction.angle_to(prev.direction)) < deg_to_rad(max_drift) \
			and absf(now.dni / prev.dni - 1.0) < (0.25 if edit_only else 0.1):
		return prev
	return now


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
	incident = e.ObjectIncident()
	if lamp_id < 0:
		for obj: SimObject in world.objects.values():
			obj.absorbed_w = absorbed.get(obj.id, 0.0)
			var split: PackedFloat32Array = incident.get(obj.id, PackedFloat32Array())
			obj.incident = Spectrum.make_zero()
			obj.incident_direct = Spectrum.make_zero()
			for b in Spectrum.BIN_COUNT if split.size() == 2 * Spectrum.BIN_COUNT else 0:
				obj.incident_direct[b] = split[b]
				obj.incident[b] = split[b] + split[Spectrum.BIN_COUNT + b]
	stats = e.Stats()
	stats.lanes = p.map.count if p.source != null else 0
	shown_strength = p.source.strength() if p.source != null else 0.0
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
	_traced_source = p.source
	_traced_strength = shown_strength
	last_trace_ms = p.ms
	last_stage_ms = p.stage_ms.duplicate()


## Light absorbed in tiles and objects becomes heat (energy_in, heat_in); light at surfaces goes
## to the skin (see skin_light and LightSystem).
func _deposit(world: SimWorld, dt: float) -> void:
	if _traced_strength <= 0.0:
		return
	var energy := world.grid.energy_in
	var scale := strength_now(world) / _traced_strength * dt
	for k in _lit_tiles.size():
		energy[_lit_tiles[k]] += _lit_power[k] * scale
	_map_unskinned(world)
	for k in _unskinned_tiles.size():
		energy[_unskinned_tiles[k]] += _unskinned_power[k] * scale
	for id in _obj_power:
		var obj: SimObject = world.objects.get(id)
		if obj != null:
			obj.heat_in += _obj_power[id] * scale


## Finds the strips whose face has no skin (a strip there heats its tile instead), when a pass
## published or the skin was rebuilt.
func _map_unskinned(world: SimWorld) -> void:
	var skin := world.skin
	skin.sync(world)
	if _skin_mapped == skin.version:
		return
	_unskinned_tiles.clear()
	_unskinned_power.clear()
	var per_tile := 4 * SimConst.SKIN_STRIPS
	for k in _skin_ids.size():
		if skin.local_strip(_skin_ids[k]) < 0:
			_unskinned_tiles.append(_skin_ids[k] / per_tile)
			_unskinned_power.append(_skin_power[k])
	_skin_mapped = skin.version


func _needs_retrace(world: SimWorld) -> bool:
	if world.grid.structure_version != _traced_structure or world.objects_version != _traced_objects:
		return true
	if lamp_id >= 0:
		return _lamp_needs_retrace(world)
	var up := world.light_is_up and world.light_dni > 0.0
	if up != (_traced_strength > 0.0):
		return true
	if not up:
		return false
	if absf(world.light_direction.angle_to(_traced_source.direction)) > deg_to_rad(SimConst.RETRACE_ANGLE_DEG):
		return true
	# The spectrum reddens as DNI falls; re-trace on large intensity changes.
	return absf(world.light_dni / _traced_strength - 1.0) > 0.1


func _lamp_needs_retrace(world: SimWorld) -> bool:
	var now := _lamp_source(world)
	if (now != null) != (_traced_strength > 0.0):
		return true
	return now != null and (not now.same_light(_traced_source) or absf(now.strength() / _traced_strength - 1.0) > 0.1)
