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
## - surface ↔ gas: convective film h in series with half a tile of the solid
## - gas ↔ gas: eddy mixing, boosted when the lower tile is hotter (buoyancy)
## Open gas tiles also relax toward ambient; sky-facing surfaces radiate to the sky.
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


func system_name() -> StringName:
	return &"heat"


func tick(world: SimWorld, dt: float) -> void:
	var h := world.grid.height
	var bands := SimConst.HEAT_BANDS
	step_rows(world, dt * bands, _band * h / bands, (_band + 1) * h / bands)
	_band = (_band + 1) % bands


## One heat step of `h` seconds over the whole grid.
func step(world: SimWorld, h: float) -> void:
	step_rows(world, h, 0, world.grid.height)


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
			if ga and gb:
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
	var sky := g.sky_tiles(world.materials.is_gas)
	var sky_emissivity := PackedFloat32Array()
	for i in sky:
		sky_emissivity.append(world.materials.emissivity[mat[i]])
	_kernel.Build(w, g.height, _inv_c, _g_right, _g_down, _vert_gas, _is_gas, sky,
		sky_emissivity, SimConst.TILE_M * SimConst.DEPTH_M)


static func _add_pair(sums: PackedFloat32Array, i: int, w: int, c: float) -> void:
	sums[i] += c
	sums[i + w] += c
