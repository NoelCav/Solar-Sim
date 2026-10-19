class_name ObjectThermal
extends RefCounted
## Objects' own thermal nodes (D13): each lens, prism and mirror has one temperature and heat
## capacity. It gains the light absorbed in it (LightSystem → SimObject.heat_in), exchanges
## heat with the tiles its outline touches by convection (energy goes into those tiles), and
## radiates to the surroundings when hot. Probes have no mass to speak of and stay at air
## temperature. Later systems (cells, lens slices in M7) refine this node, not replace it.

const SIGMA := 5.670374e-8
const SHEET_THICKNESS_M := 0.003   ## Mirrors and probes: a thin sheet of their material
const CONTACT_STEP_M := 0.05       ## Outline sampling for the tiles an object touches

## Per object id: [capacity J/K, surface m², emissivity, contact tiles, transform key]
var _cache := {}


func step(world: SimWorld, dt: float) -> void:
	var g := world.grid
	var temp := g.temperature
	var energy := g.energy_in
	for id in _cache.keys():
		if not world.objects.has(id):
			_cache.erase(id)
	for obj: SimObject in world.objects.values():
		var info: Array = _info(world, obj)
		var tiles: PackedInt32Array = info[3]
		if tiles.is_empty():
			continue
		var air := 0.0
		for i in tiles:
			air += temp[i]
		air /= tiles.size()
		if obj.temperature_k <= 0.0:
			obj.temperature_k = air
		var capacity: float = info[0]
		if capacity <= 0.0:   # Massless (probe): follows the air, passes its light on
			obj.temperature_k = air
			for i in tiles:
				energy[i] += obj.heat_in / tiles.size()
			obj.heat_in = 0.0
			continue
		var area: float = info[1]
		var t := obj.temperature_k
		var conv := SimConst.CONVECTION_H * area * (t - air)
		var t_env := world.ambient_k
		var rad := float(info[2]) * SIGMA * area * (t * t * t * t - t_env * t_env * t_env * t_env)
		var t_new := t + (obj.heat_in - (conv + rad) * dt) / capacity
		# Losses alone can't take it past what it is cooling toward (guards tiny objects).
		var floor_k := minf(air, t_env)
		if t > floor_k and t_new < floor_k and obj.heat_in <= 0.0:
			t_new = floor_k
		obj.temperature_k = t_new
		obj.heat_in = 0.0
		# Convection heats (or cools) the air it touches; radiation leaves the slice.
		var share := conv * dt / tiles.size()
		for i in tiles:
			energy[i] += share


## Total object heat relative to 0 K, J (conservation checks).
func total_energy(world: SimWorld) -> float:
	var e := 0.0
	for obj: SimObject in world.objects.values():
		var info: Array = _info(world, obj)
		e += float(info[0]) * obj.temperature_k
	return e


func _info(world: SimWorld, obj: SimObject) -> Array:
	var key := Vector3(obj.position.x, obj.position.y, obj.angle)
	var info: Array = _cache.get(obj.id, [])
	if not info.is_empty() and info[4] == key:
		return info
	var def := obj.def
	var mat := world.materials.get_by_key(def.material)
	var pieces := obj.world_pieces()
	var capacity := 0.0
	var area := 0.0
	var outline := PackedVector2Array()
	var volume := 0.0
	if def.is_body():
		outline = OpticsGen.outline(pieces)
		volume = absf(_polygon_area(outline)) * SimConst.DEPTH_M
	else:
		for piece in pieces:
			outline.append_array(piece[0])
		if def.kind == ObjectDef.Kind.MIRROR:
			volume = def.size_m * SHEET_THICKNESS_M * SimConst.DEPTH_M
	var perimeter := 0.0
	for k in outline.size() - 1:
		perimeter += outline[k].distance_to(outline[k + 1])
	if def.is_body() and outline.size() > 2:
		perimeter += outline[outline.size() - 1].distance_to(outline[0])
	# A sheet loses heat from both faces.
	area = perimeter * SimConst.DEPTH_M * (1.0 if def.is_body() else 2.0)
	if mat != null and volume > 0.0:
		capacity = volume * mat.density * mat.specific_heat * SimConst.HEAT_CAPACITY_SCALE_SOLID
	var tiles := {}
	var g := world.grid
	for k in outline.size() - 1:
		var a := outline[k]
		var b := outline[k + 1]
		var n := maxi(1, ceili(a.distance_to(b) / CONTACT_STEP_M))
		for j in n + 1:
			var p := a.lerp(b, float(j) / n)
			var c := Vector2i(floori(p.x / SimConst.TILE_M), floori(p.y / SimConst.TILE_M))
			if g.in_bounds(c.x, c.y):
				tiles[g.idx(c.x, c.y)] = true
	var list := PackedInt32Array(tiles.keys())
	list.sort()
	info = [capacity, area, mat.emissivity if mat != null else 0.9, list, key]
	_cache[obj.id] = info
	return info


static func _polygon_area(p: PackedVector2Array) -> float:
	var s := 0.0
	for k in p.size():
		var a := p[k]
		var b := p[(k + 1) % p.size()]
		s += a.x * b.y - b.x * a.y
	return s * 0.5
