class_name ThermalSystem
extends SimSystem
## Tick step 7: folds `energy_in` into temperature, then conduction, convection and
## sky radiation over the tile grid (design doc §7).
##
## The grid is processed in HEAT_BANDS horizontal bands, one band per tick, each with
## dt × HEAT_BANDS. Every neighbour pair belongs to exactly one band (its upper/left tile),
## so each pair exchanges heat once per cycle and energy is conserved. Steps are subcycled
## when the explicit scheme would be unstable.
##
## Pair conductances G (W/K) between 4-neighbours:
## - solid/liquid ↔ solid/liquid: harmonic-mean conductivity × face area / spacing
## - liquid ↔ gas: convective film h in series with half a tile of the liquid
## - gas ↔ gas: eddy mixing, boosted when the lower tile is hotter (buoyancy)
## - solid ↔ gas/liquid: through the surface skin (D18, SurfaceSkin), solved steady each tick
##   before the band step; it carries the light that lands on solids and their sky radiation.
## Open gas tiles also relax toward ambient; sky-facing liquid surfaces radiate to the sky.
##
## Quiet rows: a row whose tiles all share one temperature, next to a row below at that same
## temperature, exchanges nothing (to within 1e-4 K), so its pairs are skipped. Deep rock
## and open sky are mostly quiet.
##
## This class builds the model (capacities, conductances, stability); the per-tile loops run
## in compiled code (HeatKernel, C#).

var conduction_enabled := true
var radiation_enabled := true
var ambient_enabled := true
var quiet_rows_enabled := true   ## Skip rows that exchange nothing (see above)

var last_step_ms := 0.0         ## CPU time of the last band (or full step)
var last_skin_ms := 0.0         ## CPU time of the last surface-skin solve
var subcycles := 1
var _max_rate := 0.0            ## max ΣG/C over tiles, 1/s

var _band := 0
var _built_version := -1
var _capacity := PackedFloat32Array()    ## Scaled heat capacity per material, J/K per tile
var _pair_g := PackedFloat32Array()      ## Conductance per material pair, n×n
var _mat_count := 0
var _inv_c := PackedFloat32Array()       ## Per tile 1/C
var _g_right := PackedFloat32Array()     ## Per tile, to the right neighbour (0 on the last column)
var _g_down := PackedFloat32Array()      ## Per tile, to the neighbour below (0 on the last row)
var _vert_gas := PackedByteArray()       ## Per tile: this tile and the one below are both gas
var _is_gas := PackedByteArray()         ## Per tile
var _kernel := HeatKernel.new()
var _skin_kernel := SkinKernel.new()
var _objects := ObjectThermal.new()


func system_name() -> StringName:
	return &"heat"


func tick(world: SimWorld, dt: float) -> void:
	var h := world.grid.height
	var bands := SimConst.HEAT_BANDS
	step_skin(world, dt)
	step_rows(world, dt * bands, _band * h / bands, (_band + 1) * h / bands)
	_band = (_band + 1) % bands
	_objects.step(world, dt)


## One heat step of `h` seconds over the whole grid and the skin.
func step(world: SimWorld, h: float) -> void:
	step_skin(world, h)
	step_rows(world, h, 0, world.grid.height)


## Solves the surface skin for `h` seconds: its light becomes heat in the tiles around it.
func step_skin(world: SimWorld, h: float) -> void:
	var start := Time.get_ticks_usec()
	var skin := world.skin
	skin.sync(world)
	if _capacity.is_empty():
		_setup(world.materials)
	if _built_version != world.grid.structure_version:
		_build(world)
	if skin.faces == 0:
		return
	var g := world.grid
	var out: Array = _skin_kernel.Solve(g.temperature, g.energy_in, skin.light_w, skin.light_scale,
		skin.face_energy_in, skin.temperature, h, world.ambient_k - SimConst.SKY_DEPRESSION_K, radiation_enabled)
	skin.temperature = out[0]
	g.energy_in = out[1]
	skin.face_energy_in = out[2]
	last_skin_ms = (Time.get_ticks_usec() - start) / 1000.0


## One heat step of `h` seconds for the pairs owned by rows [row0, row1).
func step_rows(world: SimWorld, h: float, row0: int, row1: int) -> void:
	var start := Time.get_ticks_usec()
	var g := world.grid
	if _capacity.is_empty():
		_setup(world.materials)
	if _built_version != g.structure_version:
		_build(world)
	subcycles = maxi(1, ceili(h * _max_rate / 0.45))
	var out: Array = _kernel.StepRows(g.temperature, g.energy_in, h, row0, row1, subcycles,
		conduction_enabled, radiation_enabled, ambient_enabled, quiet_rows_enabled,
		world.ambient_k, world.ambient_k - SimConst.SKY_DEPRESSION_K, SimConst.BUOYANCY_BOOST,
		SimConst.AIR_RELAX_PER_S)
	g.temperature = out[0]
	g.energy_in = out[1]
	last_step_ms = (Time.get_ticks_usec() - start) / 1000.0


## The tiles object `obj`'s thermal node exchanges heat with (ObjectThermal.contact_tiles).
func object_contact_tiles(world: SimWorld, obj: SimObject) -> PackedInt32Array:
	return _objects.contact_tiles(world, obj)


## Total thermal energy relative to 0 K, J (for conservation checks).
func total_energy(world: SimWorld) -> float:
	if _built_version != world.grid.structure_version:
		if _capacity.is_empty():
			_setup(world.materials)
		_build(world)
	var e := 0.0
	var temp := world.grid.temperature
	for i in temp.size():
		e += temp[i] / _inv_c[i]
	return e


func _setup(mats: MaterialDB) -> void:
	_mat_count = mats.count()
	_capacity.resize(_mat_count)
	_capacity.fill(1.0)
	for def in mats.placeable():
		var scale := SimConst.HEAT_CAPACITY_SCALE_SOLID
		if def.phase == MaterialDef.Phase.LIQUID:
			scale = SimConst.HEAT_CAPACITY_SCALE_LIQUID
		elif def.phase == MaterialDef.Phase.GAS:
			scale = SimConst.HEAT_CAPACITY_SCALE_GAS
		_capacity[def.id] = maxf(def.tile_heat_capacity() * scale, 1e-3)
	var solid := mats.is_solid
	var depth := SimConst.DEPTH_M
	var film := SimConst.CONVECTION_H * SimConst.TILE_M * depth
	_pair_g.resize(_mat_count * _mat_count)
	for a in _mat_count:
		for b in _mat_count:
			var ga := mats.is_gas[a] == 1
			var gb := mats.is_gas[b] == 1
			var ka := mats.conductivity[a]
			var kb := mats.conductivity[b]
			var c := 0.0
			if solid[a] != solid[b]:
				c = 0.0   # Through the surface skin (step_skin)
			elif ga and gb:
				c = SimConst.AIR_EDDY_K * depth
			elif ga or gb:
				var k_surface := kb if ga else ka
				var half_tile := 2.0 * k_surface * depth   # k·A / (dx/2)
				c = 1.0 / (1.0 / film + 1.0 / half_tile) if half_tile > 0.0 else 0.0
			elif ka + kb > 0.0:
				c = 2.0 * ka * kb / (ka + kb) * depth
			_pair_g[a * _mat_count + b] = c


func _build(world: SimWorld) -> void:
	var g := world.grid
	var n := g.size()
	var w := g.width
	var mat := g.material
	var is_gas := world.materials.is_gas
	for arr in [_inv_c, _g_right, _g_down]:
		arr.resize(n)
		arr.fill(0.0)
	_vert_gas.resize(n)
	_vert_gas.fill(0)
	_is_gas.resize(n)
	_is_gas.fill(0)
	var row_sum := PackedFloat32Array()
	row_sum.resize(n)
	row_sum.fill(0.0)
	for i in n:
		var m := mat[i]
		_inv_c[i] = 1.0 / _capacity[m]
		if is_gas[m]:
			_is_gas[i] = 1
		if (i % w) != w - 1:
			var c := _pair_g[m * _mat_count + mat[i + 1]]
			_g_right[i] = c
			row_sum[i] += c
			row_sum[i + 1] += c
		if i + w < n:
			var m2 := mat[i + w]
			var c := _pair_g[m * _mat_count + m2]
			if is_gas[m] and is_gas[m2]:
				_vert_gas[i] = 1
				_add_pair(row_sum, i, w, c * SimConst.BUOYANCY_BOOST)
			else:
				_add_pair(row_sum, i, w, c)
			_g_down[i] = c
	# Explicit stability: each subcycle must satisfy hs · ΣG / C < 0.5.
	_max_rate = 0.0
	for i in n:
		_max_rate = maxf(_max_rate, row_sum[i] * _inv_c[i])
	_built_version = g.structure_version
	# Solid tops radiate through their skin; only liquid surfaces radiate here.
	var sky := PackedInt32Array()
	var sky_emissivity := PackedFloat32Array()
	for i in g.sky_tiles(world.materials.is_gas):
		if not world.materials.is_solid[mat[i]]:
			sky.append(i)
			sky_emissivity.append(world.materials.emissivity[mat[i]])
	_kernel.Build(w, g.height, _inv_c, _g_right, _g_down, _vert_gas, _is_gas, sky,
		sky_emissivity, SimConst.TILE_M * SimConst.DEPTH_M)
	_build_skin(world)


## Per-strip conductances of the surface skin (see SurfaceSkin for the model).
func _build_skin(world: SimWorld) -> void:
	var skin := world.skin
	skin.sync(world)
	var g := world.grid
	var mats := world.materials
	var mat := g.material
	var n := skin.faces * skin.strips
	var strip_w := SimConst.TILE_M / skin.strips
	var area := strip_w * SimConst.DEPTH_M
	var half_tile := area / (SimConst.TILE_M * 0.5)   # × k: half a tile of conduction for one strip
	var sky := {}
	for i in g.sky_tiles(mats.is_gas):
		sky[i] = true
	var g_body := PackedFloat32Array()
	var g_next := PackedFloat32Array()
	var g_lat := PackedFloat32Array()
	var emissivity := PackedFloat32Array()
	for arr in [g_body, g_next, g_lat, emissivity]:
		arr.resize(n)
	var face_sky := PackedByteArray()
	face_sky.resize(skin.faces)
	var run_end := {}   # Faces that end a run: no lateral conduction past them
	for r in range(1, skin.run_start.size()):
		run_end[skin.run_start[r] - 1] = true
	for f in skin.faces:
		var m := mat[skin.face_tile[f]]
		var m_next := mat[skin.face_next[f]]
		var k := mats.conductivity[m]
		var next := mats.conductivity[m_next] * half_tile   # Liquid: half a tile of it
		if mats.is_gas[m_next]:
			next = SimConst.CONVECTION_H * area
		face_sky[f] = 1 if skin.face_side[f] == 0 and sky.has(skin.face_tile[f]) else 0
		for s in skin.strips:
			var i := f * skin.strips + s
			g_body[i] = k * half_tile
			g_next[i] = next
			emissivity[i] = mats.emissivity[m]
			# To the next strip: a near-surface layer as deep as a strip is wide (k · depth).
			g_lat[i] = k * SimConst.DEPTH_M
		# Across the border to the next face in the run: harmonic mean of the two solids.
		var last := f * skin.strips + skin.strips - 1
		if not run_end.has(f):
			var k2 := mats.conductivity[mat[skin.face_tile[f + 1]]]
			g_lat[last] = 2.0 * k * k2 / (k + k2) * SimConst.DEPTH_M if k + k2 > 0.0 else 0.0
		else:
			g_lat[last] = 0.0
	_skin_kernel.Build(skin.strips, skin.face_tile, skin.face_next, face_sky, skin.run_start, g_body, g_next,
		g_lat, emissivity, area)


static func _add_pair(sums: PackedFloat32Array, i: int, w: int, c: float) -> void:
	sums[i] += c
	sums[i + w] += c
