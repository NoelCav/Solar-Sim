class_name LightSystem
extends SimSystem
## Tick step 3: traces light and deposits absorbed power into `energy_in` every tick (design doc
## §5.3, §6, §6.11). The light is kept in layers (LightLayer): the sky (the sun, or the moon at
## night) and one per lamp. Each layer runs its own passes, publishes its own results, scaled
## between passes by its source's strength, and deposits its own heat. The fields below are the
## sky layer's, for the consumers that only care about the sun; anything that must count lamps
## goes through `layers()`.
## Diffuse sky light is not traced: it lands on each column's first non-gas tile (§6.2).

## The sun's (or moon's) layer, and the lamps' by object id.
var sky := LightLayer.new()
var lamps := {}

# --- The sky layer's results (read by renderers, inspector, tests) ---
var last_trace_ms: float:
	get: return sky.last_trace_ms
var last_stage_ms: Dictionary:
	get: return sky.last_stage_ms
var tile_power: PackedFloat32Array:
	get: return sky.tile_power
var band_power: PackedFloat32Array:
	get: return sky.band_power
var strip_ids: PackedInt32Array:
	get: return sky.strip_ids
var strip_arriving: PackedFloat32Array:
	get: return sky.strip_arriving
var strip_absorbed: PackedFloat32Array:
	get: return sky.strip_absorbed
var shown_lit: PackedInt32Array:
	get: return sky.shown_lit
var sheet_from: PackedVector2Array:
	get: return sky.sheet_from
var sheet_to: PackedVector2Array:
	get: return sky.sheet_to
var beam_render: PackedFloat32Array:
	get: return sky.beam_render
var ray_from: PackedVector2Array:
	get: return sky.ray_from
var ray_to: PackedVector2Array:
	get: return sky.ray_to
var ray_power: PackedFloat32Array:
	get: return sky.ray_power
var stats: Dictionary:
	get: return sky.stats
## DNI the published (displayed) sky results were traced at.
var shown_dni: float:
	get: return sky.shown_strength
## Bumped whenever any layer publishes: renderers rebuild what they draw when it changes.
var trace_version: int:
	get:
		var v := sky.trace_version
		for l: LightLayer in lamps.values():
			v += l.trace_version
		return v

var _scratch: LightPass          ## Shared by the layers for previews and probe rays
var _skin_key := Vector3i(-1, -1, -1)   ## (sky publish, skin version, lamp count) behind skin.light_w
var _lamps_version := -1         ## objects_version the lamp layers were synced to
var _lamp_lit := []              ## Ids of objects with lamp light on them


func system_name() -> StringName:
	return &"light"


func tick(world: SimWorld, dt: float) -> void:
	_sync_lamps(world)
	sky.tick(world, dt)
	for l: LightLayer in lamps.values():
		l.tick(world, dt)
	_write_skin(world)
	_write_lamp_light(world)
	_deposit_diffuse(world, dt)


## Every layer: the sky first, then the lamps.
func layers() -> Array[LightLayer]:
	var out: Array[LightLayer] = [sky]
	for l: LightLayer in lamps.values():
		out.append(l)
	return out


## Runs a complete pass now on every layer (tests, benchmarks). `fresh` traces again reusing no
## results (the geometry caches stay warm): what a full pass costs.
func retrace(world: SimWorld, fresh := false) -> void:
	_sync_lamps(world)
	for l in layers():
		l.retrace(world, fresh)
	_write_skin(world)
	_write_lamp_light(world)


## Traces the current state on a separate pass and publishes only what renderers and the
## inspector read. Sim state (deposits, the passes in progress) is untouched, so edits made
## while paused can be shown without affecting determinism (D7).
func preview(world: SimWorld) -> void:
	_sync_lamps(world)
	for l in layers():
		l.preview(world, _scratch_pass(world))


## An engine set up on the current geometry for the sky's test rays (SimProbe), on the scratch
## pass: the sim's own passes are untouched.
func probe_engine(world: SimWorld) -> LightEngine:
	return sky.probe_engine(world, _scratch_pass(world))


## Factor from published `tile_power` (traced at an earlier DNI) to current watts.
func power_scale(world: SimWorld) -> float:
	return sky.power_scale(world)


## Factor from published `tile_power`, `band_power` (W per tile) to current W/m² of a tile face;
## for a surface strip (a SKIN_STRIPS-th of a face) multiply by SKIN_STRIPS.
func irradiance_scale(world: SimWorld) -> float:
	return sky.irradiance_scale(world)


## True when any layer's published results lag behind the world (a pass is pending or running).
func is_stale(world: SimWorld) -> bool:
	for l in layers():
		if l.is_stale(world):
			return true
	return false


## The sky's engine holding the last complete pass (tests).
func tracer() -> LightEngine:
	return sky.tracer()


## Light arriving now on surface strip `index` (LightEngine.StripIds layout), from every layer, W/m².
func strip_irradiance(index: int, world: SimWorld) -> float:
	var total := 0.0
	for l in layers():
		total += l.strip_irradiance(index, world)
	return total


## Light arriving now on the brightest surface strip of tile i, from every layer, W/m² (0 if none).
func strip_irradiance_max(i: int, world: SimWorld) -> float:
	var best := 0.0
	var base := i * 4 * SimConst.SKIN_STRIPS
	for k in 4 * SimConst.SKIN_STRIPS:
		best = maxf(best, strip_irradiance(base + k, world))
	return best


## Light absorbed by tile i now, from every layer, W/m² of its face.
func tile_irradiance(i: int, world: SimWorld) -> float:
	var total := 0.0
	for l in layers():
		if l.tile_power.size() > i:
			total += l.tile_power[i] * l.irradiance_scale(world)
	return total


## The same split by Spectrum band (UV, visible, infrared), W/m².
func tile_band_irradiance(i: int, world: SimWorld) -> PackedFloat32Array:
	var out := PackedFloat32Array([0.0, 0.0, 0.0])
	for l in layers():
		if l.band_power.size() > (i + 1) * Spectrum.BAND_COUNT - 1:
			var scale := l.irradiance_scale(world)
			for band in Spectrum.BAND_COUNT:
				out[band] += l.band_power[i * Spectrum.BAND_COUNT + band] * scale
	return out


func _scratch_pass(world: SimWorld) -> LightPass:
	if _scratch == null:
		_scratch = LightPass.new(world.grid, world.materials)
	return _scratch


## Keeps one layer per lamp object.
func _sync_lamps(world: SimWorld) -> void:
	if world.objects_version == _lamps_version:
		return
	for id: int in lamps.keys():
		if not world.objects.has(id) or world.objects[id].def.kind != ObjectDef.Kind.LAMP:
			lamps.erase(id)
	for obj: SimObject in world.objects.values():
		if obj.def.kind == ObjectDef.Kind.LAMP and not lamps.has(obj.id):
			lamps[obj.id] = LightLayer.new(obj.id)
	_lamps_version = world.objects_version


## Light from lamps arriving on the active faces of cells and probes now, W per bin.
func _write_lamp_light(world: SimWorld) -> void:
	for id: int in _lamp_lit:
		var obj: SimObject = world.objects.get(id)
		if obj != null:
			obj.lamp_light = Spectrum.make_zero()
			obj.lamp_direct = Spectrum.make_zero()
	_lamp_lit.clear()
	for l: LightLayer in lamps.values():
		var scale := l.power_scale(world)
		for id: int in l.incident:
			var obj: SimObject = world.objects.get(id)
			var split: PackedFloat32Array = l.incident[id]
			if obj == null or split.size() != 2 * Spectrum.BIN_COUNT:
				continue
			for b in Spectrum.BIN_COUNT:
				obj.lamp_direct[b] += split[b] * scale
				obj.lamp_light[b] += (split[b] + split[Spectrum.BIN_COUNT + b]) * scale
			_lamp_lit.append(id)


## Writes the traced surface light into the skin's per-strip rate: the sky's at its traced
## strength (the skin scales it by `light_scale`, so this runs only when something changed), the
## lamps' at their strength now, every tick.
func _write_skin(world: SimWorld) -> void:
	var skin := world.skin
	skin.sync(world)
	var key := Vector3i(sky.trace_version, skin.version, lamps.size())
	if key != _skin_key:
		skin.light_w.fill(0.0)
		sky.write_skin(world, skin.light_w, false)
		_skin_key = key
	skin.light_scale = sky.deposit_scale(world)
	if lamps.is_empty():
		return
	skin.extra_w.fill(0.0)
	for l: LightLayer in lamps.values():
		l.write_skin(world, skin.extra_w, true)


## Diffuse sky light on each column's top surface: into its skin (spread evenly over the face),
## or the tile itself when it has none (a liquid surface).
func _deposit_diffuse(world: SimWorld, dt: float) -> void:
	if world.diffuse_irradiance <= 0.0:
		return
	var g := world.grid
	var energy := g.energy_in
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
