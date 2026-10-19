class_name Tracer
extends RefCounted
## 2D spectral ray tracer over tile media and object polylines (design doc §6.4).
## Pure data: reads a TileGrid and SurfaceSet, writes per-tile absorbed power, per-object
## readings and a segment list for the renderer.
##
## Media: outside bodies, a ray's medium is the material of the tile it is in (air, water,
## glass tiles); crossing into a different transparent tile is a refracting interface, into
## an opaque tile an absorbing hit. Inside a lens or prism the medium is the body material
## and tile boundaries are ignored.
## Every watt emitted ends up in exactly one of: absorbed, escaped, scattered, culled.

const EPS := 1e-7      ## Minimum hit distance, m
const NUDGE := 1e-5    ## Child rays start this far off the surface, m
const MAX_RENDER_SEGMENTS := 60000

var grid: TileGrid
var surfaces: SurfaceSet

# Per-material optical tables, indexed by material id.
var _opaque := PackedByteArray()
var _dispersive := PackedByteArray()
var _has_bulk := PackedByteArray()
var _index: Array[PackedFloat32Array] = []
var _bulk: Array[PackedFloat32Array] = []
var _surf_abs: Array[PackedFloat32Array] = []

# --- Results of the last trace ---
var tile_power := PackedFloat32Array()              ## W absorbed per tile
var lit_tiles := PackedInt32Array()                 ## Tiles with tile_power > 0, first-hit order
var object_absorbed: Dictionary[int, float] = {}    ## W absorbed inside each object
var object_incident: Dictionary[int, PackedFloat32Array] = {}   ## Probe readings, W per bin
var seg_from := PackedVector2Array()
var seg_to := PackedVector2Array()
var seg_power := PackedFloat32Array()               ## BIN_COUNT values per segment
var emitted_w := 0.0
var absorbed_w := 0.0
var escaped_w := 0.0
var scattered_w := 0.0     ## Diffuse remainder at opaque surfaces (not yet traced)
var culled_w := 0.0        ## Below-threshold children and over-deep paths
var ray_count := 0

## Pending rays: [origin, dir, power, medium, body_owner, events].
var _stack: Array = []

## Coarse 8×8-tile blocks that are plain air with no surfaces; rays skip them whole.
const BLOCK_SHIFT := 3
var _block_empty := PackedByteArray()
var _blocks_w := 0
var _body_bounds: Dictionary[int, Rect2] = {}   ## Per object id, grown slightly

# Current sun bundle (see setup_sun).
var _sun_dir := Vector2.DOWN
var _sun_per_ray := PackedFloat32Array()
var _sun_x0 := 0.0
var _sun_step := 0.0
var _sun_y := 0.0


func _init(p_grid: TileGrid, materials: MaterialDB, p_surfaces: SurfaceSet) -> void:
	grid = p_grid
	surfaces = p_surfaces
	var n := materials.count()
	_opaque.resize(n)
	_dispersive.resize(n)
	_has_bulk.resize(n)
	for id in n:
		var def := materials.get_def(id)
		var idx := Spectrum.make_zero()
		var bulk := Spectrum.make_zero()
		var surf := Spectrum.make_zero()
		_opaque[id] = 1
		if def != null:
			_opaque[id] = 0 if def.transparent else 1
			_dispersive[id] = 1 if def.cauchy_b != 0.0 else 0
			for b in Spectrum.BIN_COUNT:
				idx[b] = def.refractive_index(Spectrum.WAVELENGTH_UM[b])
				bulk[b] = def.bulk_absorption[b]
				surf[b] = def.surface_absorptivity[b]
				if bulk[b] > 0.0:
					_has_bulk[id] = 1
		_index.append(idx)
		_bulk.append(bulk)
		_surf_abs.append(surf)


## Clears all results before a new trace.
func begin() -> void:
	tile_power.resize(grid.size())
	tile_power.fill(0.0)
	lit_tiles.clear()
	object_absorbed.clear()
	object_incident.clear()
	seg_from.clear()
	seg_to.clear()
	seg_power.clear()
	emitted_w = 0.0
	absorbed_w = 0.0
	escaped_w = 0.0
	scattered_w = 0.0
	culled_w = 0.0
	ray_count = 0
	if _block_empty.is_empty():
		build_blocks()


## Configures a bundle of parallel sun rays travelling along `dir` (y > 0), starting on the
## horizontal line y = `y_start` (m) above which nothing interacts. `irradiance` is W/m²
## per bin across the beam; each ray carries irradiance × spacing × slice depth.
## Returns the number of rays; trace them with sun_ray(k).
func setup_sun(dir: Vector2, irradiance: PackedFloat32Array, spacing: float, y_start: float) -> int:
	if dir.y <= 1e-3:
		return 0
	_sun_dir = dir
	_sun_y = y_start
	_sun_per_ray = Spectrum.make_zero()
	for b in Spectrum.BIN_COUNT:
		_sun_per_ray[b] = irradiance[b] * spacing * SimConst.DEPTH_M
	var gw := grid.width * SimConst.TILE_M
	var gh := grid.height * SimConst.TILE_M
	# Extend the start line so rays that enter through the side walls are included.
	var drift := (gh - y_start) * dir.x / dir.y
	_sun_x0 = minf(0.0, -drift)
	var x_hi := maxf(gw, gw - drift)
	_sun_step = spacing / dir.y
	return ceili((x_hi - _sun_x0) / _sun_step)


func sun_ray(k: int) -> void:
	var start := Vector2(_sun_x0 + (k + 0.5) * _sun_step, _sun_y)
	if _sun_y > 0.0:
		# Render-only stretch from the top of the site down to the start line.
		_emit(start - _sun_dir * (_sun_y / _sun_dir.y), start, _sun_per_ray)
	trace(start, _sun_dir, _sun_per_ray.duplicate())


## Traces a whole sun bundle at once (see setup_sun).
func trace_sun(dir: Vector2, irradiance: PackedFloat32Array, spacing: float, y_start: float) -> void:
	for k in setup_sun(dir, irradiance, spacing, y_start):
		sun_ray(k)


## Rebuilds the empty-block table and body bounds; call after tiles or surfaces change.
func build_blocks() -> void:
	_body_bounds.clear()
	for s in surfaces.count():
		var id := surfaces.owner[s]
		var r: Rect2 = _body_bounds.get(id, Rect2(surfaces.a[s], Vector2.ZERO))
		_body_bounds[id] = r.expand(surfaces.a[s]).expand(surfaces.b[s])
	for id in _body_bounds:
		_body_bounds[id] = _body_bounds[id].grow(0.01)
	var bs := 1 << BLOCK_SHIFT
	_blocks_w = (grid.width + bs - 1) >> BLOCK_SHIFT
	var blocks_h := (grid.height + bs - 1) >> BLOCK_SHIFT
	_block_empty.resize(_blocks_w * blocks_h)
	_block_empty.fill(0 if _has_bulk[MaterialDB.AIR_ID] else 1)
	var mat := grid.material
	var cs := surfaces.cell_start
	var has_buckets := cs.size() == grid.size() + 1
	for i in grid.size():
		if mat[i] != MaterialDB.AIR_ID or (has_buckets and cs[i + 1] > cs[i]):
			var x := i % grid.width
			var y := i / grid.width
			_block_empty[(y >> BLOCK_SHIFT) * _blocks_w + (x >> BLOCK_SHIFT)] = 0


## Traces one ray and all its children. `power` is W per bin and is consumed.
func trace(origin: Vector2, dir: Vector2, power: PackedFloat32Array) -> void:
	emitted_w += Spectrum.total(power)
	_stack.append([origin, dir.normalized(), power, -1, -1, 0])
	while not _stack.is_empty():
		var r: Array = _stack.pop_back()
		_trace_path(r[0], r[1], r[2], r[3], r[4], r[5])


func _trace_path(o: Vector2, d: Vector2, p: PackedFloat32Array, medium: int, body: int, events: int) -> void:
	ray_count += 1
	if events > SimConst.MAX_RAY_EVENTS:
		culled_w += Spectrum.total(p)
		return
	var tm := SimConst.TILE_M
	var w := grid.width
	var h := grid.height
	var gw := w * tm
	var gh := h * tm
	if o.x < 0.0 or o.y < 0.0 or o.x >= gw or o.y >= gh:
		var t_in := _enter_t(o, d, gw, gh)
		if t_in < 0.0:
			escaped_w += Spectrum.total(p)
			return
		o += d * (t_in + NUDGE)
	var p0 := p.duplicate()
	var mat := grid.material

	# DDA setup over tiles.
	var cx := clampi(floori(o.x / tm), 0, w - 1)
	var cy := clampi(floori(o.y / tm), 0, h - 1)
	var step_x := 1 if d.x > 0.0 else -1
	var step_y := 1 if d.y > 0.0 else -1
	var t_delta_x := tm / absf(d.x) if d.x != 0.0 else INF
	var t_delta_y := tm / absf(d.y) if d.y != 0.0 else INF
	var t_max_x := ((cx + (1 if d.x > 0.0 else 0)) * tm - o.x) / d.x if d.x != 0.0 else INF
	var t_max_y := ((cy + (1 if d.y > 0.0 else 0)) * tm - o.y) / d.y if d.y != 0.0 else INF
	var t0 := 0.0
	var face := Vector2.ZERO   # Normal of the face we entered through, facing back at the ray
	var prev_mat := mat[cy * w + cx]
	if body < 0:
		if _opaque[prev_mat]:   # Started in (or entered the site through) a solid tile
			_absorb_opaque(cy * w + cx, prev_mat, p)
			return
		medium = prev_mat

	var seg_a := surfaces.a
	var seg_b := surfaces.b
	var cell_start := surfaces.cell_start
	var cell_items := surfaces.cell_items

	while true:
		if cx < 0 or cy < 0 or cx >= w or cy >= h:
			_emit(o, o + d * t0, p0)
			escaped_w += Spectrum.total(p)
			return
		var i := cy * w + cx
		var t1 := minf(t_max_x, t_max_y)

		# A body ray that walks out of its body's bounds slipped past a corner
		# (grazing hit, nudge): it is in the tile medium again.
		if body >= 0 and not _body_bounds.get(body, Rect2()).has_point(o + d * t0):
			body = -1
			medium = mat[i]
			prev_mat = medium
		# Tile medium boundary.
		if body < 0 and face != Vector2.ZERO:
			var m := mat[i]
			if m != prev_mat:
				var hit := o + d * t0
				_emit(o, hit, p0)
				if _opaque[m]:
					_absorb_opaque(i, m, p)
				else:
					_interface(hit, d, face, prev_mat, m, p, -1, -1, events)
				return

		# Optical surfaces bucketed in this tile.
		var best_t := INF
		var best_s := -1
		var best_u := 0.0
		for k in range(cell_start[i], cell_start[i + 1]):
			var s := cell_items[k]
			var e := seg_b[s] - seg_a[s]
			var denom := d.x * e.y - d.y * e.x
			if absf(denom) < 1e-12:
				continue
			var q := seg_a[s] - o
			var t := (q.x * e.y - q.y * e.x) / denom
			if t <= EPS or t >= best_t:
				continue
			var u := (q.x * d.y - q.y * d.x) / denom
			if u < 0.0 or u > 1.0:
				continue
			best_t = t
			best_s = s
			best_u = u
		if best_s >= 0 and best_t <= t1 + EPS:
			_absorb_leg(p, medium, best_t - t0, i, body)
			var hit := o + d * best_t
			_emit(o, hit, p0)
			_surface_hit(best_s, best_u, hit, d, p, medium, body, events)
			return

		_absorb_leg(p, medium, t1 - t0, i, body)
		var bx := cx >> BLOCK_SHIFT
		var by := cy >> BLOCK_SHIFT
		if body < 0 and _block_empty[by * _blocks_w + bx] == 1:
			# Whole block is plain air with no surfaces: jump to where the ray leaves it.
			var ex := (((bx + 1) << BLOCK_SHIFT) * tm - o.x) / d.x if d.x > 0.0 \
				else (((bx << BLOCK_SHIFT) * tm - o.x) / d.x if d.x < 0.0 else INF)
			var ey := (((by + 1) << BLOCK_SHIFT) * tm - o.y) / d.y if d.y > 0.0 \
				else (((by << BLOCK_SHIFT) * tm - o.y) / d.y if d.y < 0.0 else INF)
			if ex < ey:
				t0 = ex
				cx = ((bx + 1) << BLOCK_SHIFT) if step_x > 0 else (bx << BLOCK_SHIFT) - 1
				cy = clampi(floori((o.y + d.y * t0) / tm), by << BLOCK_SHIFT, ((by + 1) << BLOCK_SHIFT) - 1)
				face = Vector2(-step_x, 0)
			else:
				t0 = ey
				cy = ((by + 1) << BLOCK_SHIFT) if step_y > 0 else (by << BLOCK_SHIFT) - 1
				cx = clampi(floori((o.x + d.x * t0) / tm), bx << BLOCK_SHIFT, ((bx + 1) << BLOCK_SHIFT) - 1)
				face = Vector2(0, -step_y)
			t_max_x = ((cx + (1 if d.x > 0.0 else 0)) * tm - o.x) / d.x if d.x != 0.0 else INF
			t_max_y = ((cy + (1 if d.y > 0.0 else 0)) * tm - o.y) / d.y if d.y != 0.0 else INF
			prev_mat = MaterialDB.AIR_ID
			continue
		# Advance to the next tile.
		if t_max_x < t_max_y:
			cx += step_x
			t0 = t_max_x
			t_max_x += t_delta_x
			face = Vector2(-step_x, 0)
		else:
			cy += step_y
			t0 = t_max_y
			t_max_y += t_delta_y
			face = Vector2(0, -step_y)
		prev_mat = mat[i]


## Beer–Lambert absorption over `length` m inside `medium`; heat goes to tile `i`.
func _absorb_leg(p: PackedFloat32Array, medium: int, length: float, i: int, body: int) -> void:
	if length <= 0.0 or not _has_bulk[medium]:
		return
	var bulk := _bulk[medium]
	var lost := 0.0
	for b in Spectrum.BIN_COUNT:
		if p[b] > 0.0 and bulk[b] > 0.0:
			var keep := exp(-bulk[b] * length)
			lost += p[b] * (1.0 - keep)
			p[b] *= keep
	_deposit(i, lost, body)


func _absorb_opaque(i: int, m: int, p: PackedFloat32Array) -> void:
	var surf := _surf_abs[m]
	var absorbed := 0.0
	var total := 0.0
	for b in Spectrum.BIN_COUNT:
		absorbed += p[b] * surf[b]
		total += p[b]
	_deposit(i, absorbed, -1)
	scattered_w += total - absorbed


func _deposit(i: int, watts: float, body: int) -> void:
	if watts <= 0.0:
		return
	if tile_power[i] == 0.0:
		lit_tiles.append(i)
	tile_power[i] += watts
	absorbed_w += watts
	if body >= 0:
		object_absorbed[body] = object_absorbed.get(body, 0.0) + watts


func _surface_hit(s: int, u: float, hit: Vector2, d: Vector2, p: PackedFloat32Array,
		medium: int, body: int, events: int) -> void:
	var n := surfaces.normal[s]
	var from_front := d.dot(n) < 0.0
	var owner := surfaces.owner[s]
	match surfaces.coating[s]:
		SurfaceSet.Coating.PROBE:
			var acc: PackedFloat32Array = object_incident.get(owner, Spectrum.make_zero())
			for b in Spectrum.BIN_COUNT:
				acc[b] += p[b]
			object_incident[owner] = acc
			_stack.append([hit + d * NUDGE, d, p, medium, body, events + 1])
		SurfaceSet.Coating.MIRROR:
			var refl := surfaces.reflectance[s]
			var out := Spectrum.make_zero()
			var lost := 0.0
			for b in Spectrum.BIN_COUNT:
				out[b] = p[b] * refl[b]
				lost += p[b] - out[b]
			_deposit(_tile_at(hit), lost, -1)
			object_absorbed[owner] = object_absorbed.get(owner, 0.0) + lost
			var r := d - 2.0 * d.dot(n) * n
			_stack.append([hit + r * NUDGE, r, out, medium, body, events + 1])
		_:
			# Which side we hit decides inside/outside, rather than the ray's carried state,
			# so a ray that slipped past a corner can't stay flagged as inside a body.
			var ns := surfaces.shading_normal(s, u)
			if from_front:
				_interface(hit, d, ns, surfaces.front_mat[s], surfaces.back_mat[s], p, -1, owner, events)
			else:
				_interface(hit, d, -ns, surfaces.back_mat[s], surfaces.front_mat[s], p, owner, -1, events)


## Fresnel (Schlick) + Snell at an interface from m1 into m2. `nrm` faces the incoming ray.
## Reflections stay in body_refl; transmitted rays enter body_trans (-1 = tile medium).
## Multi-bin rays split per bin when either side is dispersive (§6.4 ray tree rules).
func _interface(hit: Vector2, d: Vector2, nrm: Vector2, m1: int, m2: int, p: PackedFloat32Array,
		body_refl: int, body_trans: int, events: int) -> void:
	var cos_i := clampf(-d.dot(nrm), 0.0, 1.0)
	var n1 := _index[m1]
	var n2 := _index[m2]
	var split := (_dispersive[m1] or _dispersive[m2]) and _nonzero_bins(p) > 1
	var refl := Spectrum.make_zero()
	var trans := Spectrum.make_zero()
	var t_dir := d
	for b in Spectrum.BIN_COUNT:
		if p[b] <= 0.0:
			continue
		var eta := n1[b] / n2[b]
		var sin2_t := eta * eta * (1.0 - cos_i * cos_i)
		if sin2_t >= 1.0:
			refl[b] = p[b]   # Total internal reflection
			continue
		var cos_t := sqrt(1.0 - sin2_t)
		var r0 := (n1[b] - n2[b]) / (n1[b] + n2[b])
		r0 *= r0
		var c := cos_i if n1[b] <= n2[b] else cos_t
		var fr := r0 + (1.0 - r0) * pow(1.0 - c, 5.0)
		refl[b] = p[b] * fr
		t_dir = (d * eta + nrm * (eta * cos_i - cos_t)).normalized()
		if split:
			var single := Spectrum.make_zero()
			single[b] = p[b] - refl[b]
			_push_child(hit, t_dir, single, m2, body_trans, events, SimConst.MIN_RAY_W)
		else:
			trans[b] = p[b] - refl[b]
	if not split:
		_push_child(hit, t_dir, trans, m2, body_trans, events, SimConst.MIN_RAY_W)
	var r_dir := d + nrm * (2.0 * cos_i)
	_push_child(hit, r_dir, refl, m1, body_refl, events, SimConst.MIN_CHILD_W)


func _push_child(hit: Vector2, dir: Vector2, p: PackedFloat32Array, medium: int, body: int,
		events: int, min_w: float) -> void:
	var total := Spectrum.total(p)
	if total <= 0.0:
		return
	if total < min_w:
		culled_w += total
		return
	_stack.append([hit + dir * NUDGE, dir, p, medium, body, events + 1])


func _emit(from: Vector2, to: Vector2, p: PackedFloat32Array) -> void:
	if seg_from.size() >= MAX_RENDER_SEGMENTS:
		return
	seg_from.append(from)
	seg_to.append(to)
	seg_power.append_array(p)


func _tile_at(pos: Vector2) -> int:
	var x := clampi(floori(pos.x / SimConst.TILE_M), 0, grid.width - 1)
	var y := clampi(floori(pos.y / SimConst.TILE_M), 0, grid.height - 1)
	return y * grid.width + x


static func _nonzero_bins(p: PackedFloat32Array) -> int:
	var c := 0
	for v in p:
		if v > 0.0:
			c += 1
	return c


## Distance along the ray to enter the box [0,w]×[0,h], or -1 if it misses.
static func _enter_t(o: Vector2, d: Vector2, w: float, h: float) -> float:
	var t_near := -INF
	var t_far := INF
	for axis in 2:
		var lo := 0.0
		var hi := w if axis == 0 else h
		var oc := o[axis]
		var dc := d[axis]
		if absf(dc) < 1e-12:
			if oc < lo or oc > hi:
				return -1.0
			continue
		var ta := (lo - oc) / dc
		var tb := (hi - oc) / dc
		t_near = maxf(t_near, minf(ta, tb))
		t_far = minf(t_far, maxf(ta, tb))
	if t_near > t_far or t_far < 0.0:
		return -1.0
	return maxf(t_near, 0.0)
