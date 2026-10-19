class_name Tracer
extends RefCounted
## 2D spectral ray tracer over tile media and object polylines (design doc §6.4).
## Pure data: reads a TileGrid and SurfaceSet; writes per-tile absorbed power (total and per
## band), per-object readings, energy accounting, and line segments for the renderer.
##
## Two modes share one marching step (_march):
## - trace(): a ray tree. Interfaces split rays into reflected and transmitted children.
##   Used for secondary light (pooled Fresnel reflections) and tests.
## - trace_primary(): one path per call, always following the transmitted branch (or the
##   reflection under total internal reflection). Its deposits, probe crossings and
##   reflections are recorded as fractions of a unit input in a PathRec, so the beam tracer
##   can weight them once it knows how much light each sample ray stands for.
##
## Media: outside bodies a ray's medium is the material of the tile it is in (air, water,
## glass tiles); crossing into a different transparent tile is a refracting interface, into
## an opaque tile an absorbing hit. Inside a lens or prism the medium is the body material
## and tile boundaries are ignored.
## Every watt emitted ends up in exactly one of: absorbed, escaped, scattered, culled.

const EPS := 1e-7      ## Minimum hit distance, m
const NUDGE := 1e-5    ## Child rays start this far off the surface, m
const U_EPS := 1e-6    ## Along-segment tolerance for hits
const MAX_RENDER_SEGMENTS := 60000

enum Ev { MISS, EXIT, START_OPAQUE, OPAQUE, MEDIA, SURFACE }
enum Term { ESCAPE, OPAQUE, CULLED, PENDING }

## Result of trace_primary. Fractions are relative to the ray's unit input power.
class PathRec:
	var bin := 0
	var pts := PackedVector2Array()        ## Start, then every interaction point, then the end
	var frac := PackedFloat32Array()       ## Power leaving each point (arriving, for the end)
	var sig := PackedInt32Array()          ## Interaction keys; equal sig = same optical path
	var term := Term.ESCAPE
	var term_tile := -1
	var term_side := -1                    ## Face code of the opaque face hit (see face_code)
	var remain := 1.0                      ## Power arriving at the end
	var deps := PackedFloat64Array()       ## Absorption along the path: (tile, fraction, body, x, y)…
	var probes := PackedFloat64Array()     ## Probes crossed: (owner, power at the crossing)…
	var refls := PackedFloat64Array()      ## Fresnel reflections: (x, y, dx, dy, fraction, medium, body)…
	# Where to resume a path stopped as it left an object (Term.PENDING; see trace_primary).
	var cont_o := Vector2.ZERO
	var cont_d := Vector2.ZERO
	var cont_events := 0

var grid: TileGrid
var surfaces: SurfaceSet

# Per-material optical tables, indexed by material id.
var opaque := PackedByteArray()
var _dispersive := PackedByteArray()
var _has_bulk := PackedByteArray()
var _index: Array[PackedFloat32Array] = []
var _bulk: Array[PackedFloat32Array] = []
var surf_abs: Array[PackedFloat32Array] = []

# --- Results of the current pass ---
var tile_power := PackedFloat32Array()              ## W absorbed per tile
var band_power := PackedFloat32Array()              ## W absorbed per tile per band (3 per tile)
var lit_tiles := PackedInt32Array()                 ## Tiles with tile_power > 0, first-hit order
var object_absorbed: Dictionary[int, float] = {}    ## W absorbed inside / by each object
var object_incident: Dictionary[int, PackedFloat32Array] = {}   ## Probe readings, W per bin
var seg_from := PackedVector2Array()                ## Tree-traced (secondary) light, for rendering
var seg_to := PackedVector2Array()
var seg_power := PackedFloat32Array()               ## BIN_COUNT values per segment
var emitted_w := 0.0
var absorbed_w := 0.0
var escaped_w := 0.0
var scattered_w := 0.0     ## Diffuse remainder at opaque surfaces (not yet traced)
var culled_w := 0.0        ## Below-threshold light and over-deep paths
var ray_count := 0         ## Ray paths traced (tree paths + primary paths)

## Pending tree rays: [origin, dir, power, medium, body_owner, events].
var _stack: Array = []
## While tracing a primary path, deposits and probe crossings are recorded here.
var _rec: PathRec = null

## Per tile, Chebyshev distance (in tiles, capped) to the nearest tile that is not plain
## air or holds a surface; the site border counts as occupied. A ray in a tile with
## distance d can cross the whole (2d-1)² square of empty tiles around it in one jump.
const AIR_DIST_CAP := 16
var _air_dist := PackedByteArray()
var _body_bounds: Dictionary[int, Rect2] = {}   ## Per object id, grown slightly

# Output of _march.
var _ev_kind := Ev.MISS
var _ev_o := Vector2.ZERO      ## Origin actually used (clipped into the grid)
var _ev_t := 0.0
var _ev_tile := -1
var _ev_face := Vector2.ZERO   ## Face normal facing back at the ray (tile events)
var _ev_mat := 0               ## Material entered (tile events)
var _ev_prev_mat := 0
var _ev_seg := -1
var _ev_u := 0.0
var _ev_medium := 0
var _ev_body := -1


func _init(p_grid: TileGrid, materials: MaterialDB, p_surfaces: SurfaceSet) -> void:
	grid = p_grid
	surfaces = p_surfaces
	var n := materials.count()
	opaque.resize(n)
	_dispersive.resize(n)
	_has_bulk.resize(n)
	for id in n:
		var def := materials.get_def(id)
		var idx := Spectrum.make_zero()
		var bulk := Spectrum.make_zero()
		var surf := Spectrum.make_zero()
		opaque[id] = 1
		if def != null:
			opaque[id] = 0 if def.transparent else 1
			_dispersive[id] = 1 if def.cauchy_b != 0.0 else 0
			for b in Spectrum.BIN_COUNT:
				idx[b] = def.refractive_index(Spectrum.WAVELENGTH_UM[b])
				bulk[b] = def.bulk_absorption[b]
				surf[b] = def.surface_absorptivity[b]
				if bulk[b] > 0.0:
					_has_bulk[id] = 1
		_index.append(idx)
		_bulk.append(bulk)
		surf_abs.append(surf)


## Clears all results before a new pass.
func begin() -> void:
	tile_power.resize(grid.size())
	tile_power.fill(0.0)
	band_power.resize(grid.size() * Spectrum.BAND_COUNT)
	band_power.fill(0.0)
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
	if _air_dist.is_empty():
		build_blocks()


## Rebuilds the air distance field and body bounds; call after tiles or surfaces change.
func build_blocks() -> void:
	_body_bounds.clear()
	for s in surfaces.count():
		var id := surfaces.owner[s]
		var r: Rect2 = _body_bounds.get(id, Rect2(surfaces.a[s], Vector2.ZERO))
		_body_bounds[id] = r.expand(surfaces.a[s]).expand(surfaces.b[s])
	for id in _body_bounds:
		_body_bounds[id] = _body_bounds[id].grow(1e-3)
	var w := grid.width
	var h := grid.height
	var n := w * h
	var df := _air_dist
	df.resize(n)
	var mat := grid.material
	var cs := surfaces.cell_start
	var has_buckets := cs.size() == n + 1
	var air_clear := not _has_bulk[MaterialDB.AIR_ID]
	for i in n:
		var empty := air_clear and mat[i] == MaterialDB.AIR_ID and not (has_buckets and cs[i + 1] > cs[i])
		df[i] = AIR_DIST_CAP if empty else 0
	# Two-pass chamfer transform with 8-neighbours gives the chessboard distance.
	for y in h:
		for x in w:
			var i := y * w + x
			var v := df[i]
			if v == 0:
				continue
			if x == 0 or y == 0 or x == w - 1:
				v = 1
			else:
				v = mini(v, mini(mini(df[i - 1], df[i - w - 1]), mini(df[i - w], df[i - w + 1])) + 1)
			df[i] = v
	for y in range(h - 1, -1, -1):
		for x in range(w - 1, -1, -1):
			var i := y * w + x
			var v := df[i]
			if v <= 1:
				continue
			if y == h - 1:
				v = 1
			else:
				v = mini(v, mini(mini(df[i + 1], df[i + w + 1]), mini(df[i + w], df[i + w - 1])) + 1)
			df[i] = v


## Bounds of an object's surfaces (grown slightly), or an empty rect.
func body_bounds(id: int) -> Rect2:
	return _body_bounds.get(id, Rect2())


# --- Deposits ---------------------------------------------------------------------------

## Adds absorbed power in one bin to a tile (and to an object's tally if body >= 0).
func apply_bin(i: int, bin: int, watts: float, body: int = -1) -> void:
	if watts <= 0.0:
		return
	if tile_power[i] == 0.0:
		lit_tiles.append(i)
	tile_power[i] += watts
	band_power[i * Spectrum.BAND_COUNT + Spectrum.BAND_OF[bin]] += watts
	absorbed_w += watts
	if body >= 0:
		object_absorbed[body] = object_absorbed.get(body, 0.0) + watts


## Absorbs `watts` of one bin at the opaque face of tile i; the rest scatters.
func absorb_opaque_bin(i: int, bin: int, watts: float) -> void:
	var a := watts * surf_abs[grid.material[i]][bin]
	apply_bin(i, bin, a)
	scattered_w += watts - a


## Absorbs `scale` × a whole spectrum (W per bin) at the opaque face of tile i.
func absorb_opaque_spectrum(i: int, spectrum: PackedFloat32Array, scale: float) -> void:
	var surf := surf_abs[grid.material[i]]
	var o := i * Spectrum.BAND_COUNT
	var total := 0.0
	var absorbed := 0.0
	for b in Spectrum.BIN_COUNT:
		var w := spectrum[b] * scale
		var a := w * surf[b]
		band_power[o + Spectrum.BAND_OF[b]] += a
		absorbed += a
		total += w
	if absorbed > 0.0:
		if tile_power[i] == 0.0:
			lit_tiles.append(i)
		tile_power[i] += absorbed
		absorbed_w += absorbed
	scattered_w += total - absorbed


func add_probe(owner: int, bin: int, watts: float) -> void:
	var acc: PackedFloat32Array = object_incident.get(owner, Spectrum.make_zero())
	acc[bin] += watts
	object_incident[owner] = acc


func _deposit_bin(i: int, bin: int, watts: float, body: int, at := Vector2.ZERO) -> void:
	if watts <= 0.0:
		return
	if _rec != null:
		_rec.deps.append_array([i, watts, body, at.x, at.y])
	else:
		apply_bin(i, bin, watts, body)


# --- Ray tree -----------------------------------------------------------------------------

## Traces one ray and all its children. `power` is W per bin and is consumed.
## `count_emitted` is false for light already counted when it entered the pass.
## `medium`/`body` give the starting medium inside a body; by default it is the tile's.
func trace(origin: Vector2, dir: Vector2, power: PackedFloat32Array, count_emitted := true,
		medium := -1, body := -1) -> void:
	if count_emitted:
		emitted_w += Spectrum.total(power)
	_stack.append([origin, dir.normalized(), power, medium, body, 0])
	while not _stack.is_empty():
		var r: Array = _stack.pop_back()
		_trace_path(r[0], r[1], r[2], r[3], r[4], r[5])


func _trace_path(o: Vector2, d: Vector2, p: PackedFloat32Array, medium: int, body: int, events: int) -> void:
	ray_count += 1
	if events > SimConst.MAX_RAY_EVENTS:
		culled_w += Spectrum.total(p)
		return
	var p0 := p.duplicate()
	_march(o, d, p, medium, body)
	var start := _ev_o
	var hit := start + d * _ev_t
	match _ev_kind:
		Ev.MISS:
			escaped_w += Spectrum.total(p)
		Ev.EXIT:
			_emit(start, hit, p0)
			escaped_w += Spectrum.total(p)
		Ev.START_OPAQUE:
			_absorb_opaque(_ev_tile, p)
		Ev.OPAQUE:
			_emit(start, hit, p0)
			_absorb_opaque(_ev_tile, p)
		Ev.MEDIA:
			_emit(start, hit, p0)
			_interface(hit, d, _ev_face, _ev_prev_mat, _ev_mat, p, -1, -1, events)
		Ev.SURFACE:
			_emit(start, hit, p0)
			_surface_hit(_ev_seg, _ev_u, hit, d, p, _ev_medium, _ev_body, events)


func _absorb_opaque(i: int, p: PackedFloat32Array) -> void:
	for b in Spectrum.BIN_COUNT:
		if p[b] > 0.0:
			absorb_opaque_bin(i, b, p[b])


func _surface_hit(s: int, u: float, hit: Vector2, d: Vector2, p: PackedFloat32Array,
		medium: int, body: int, events: int) -> void:
	var n := surfaces.normal[s]
	var from_front := d.dot(n) < 0.0
	var owner := surfaces.owner[s]
	match surfaces.coating[s]:
		SurfaceSet.Coating.PROBE:
			for b in Spectrum.BIN_COUNT:
				add_probe(owner, b, p[b])
			_stack.append([hit + d * NUDGE, d, p, medium, body, events + 1])
		SurfaceSet.Coating.MIRROR:
			var refl := surfaces.reflectance[s]
			var out := Spectrum.make_zero()
			var tile := _tile_at(hit)
			for b in Spectrum.BIN_COUNT:
				out[b] = p[b] * refl[b]
				_deposit_bin(tile, b, p[b] - out[b], owner, hit)
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
	var split := (_dispersive[m1] or _dispersive[m2]) and _nonzero_bins(p) > 1
	var refl := Spectrum.make_zero()
	var trans := Spectrum.make_zero()
	var t_dir := d
	for b in Spectrum.BIN_COUNT:
		if p[b] <= 0.0:
			continue
		var fr := _fresnel(cos_i, _index[m1][b], _index[m2][b])
		refl[b] = p[b] * fr
		if fr >= 1.0:
			continue   # Total internal reflection
		t_dir = _refract(d, nrm, cos_i, _index[m1][b] / _index[m2][b])
		if split:
			var single := Spectrum.make_zero()
			single[b] = p[b] - refl[b]
			_push_child(hit, t_dir, single, m2, body_trans, events, SimConst.MIN_RAY_W)
		else:
			trans[b] = p[b] - refl[b]
	if not split:
		_push_child(hit, t_dir, trans, m2, body_trans, events, SimConst.MIN_RAY_W)
	_push_child(hit, d + nrm * (2.0 * cos_i), refl, m1, body_refl, events, SimConst.MIN_CHILD_W)


func _push_child(hit: Vector2, dir: Vector2, p: PackedFloat32Array, medium: int, body: int,
		events: int, min_w: float) -> void:
	var total := Spectrum.total(p)
	if total <= 0.0:
		return
	if total < min_w:
		culled_w += total
		return
	_stack.append([hit + dir * NUDGE, dir, p, medium, body, events + 1])


# --- Primary paths --------------------------------------------------------------------------

## Follows one ray of unit power in `bin` along its dominant path: transmission at every
## interface (reflection under TIR). Reflected fractions, absorption along the way and probe
## crossings are recorded, not applied; the terminal hit is left to the caller.
## With `stop_owner` >= 0, a path whose first interaction is entering that (convex) object
## stops as it transmits back out of it (Term.PENDING); continue_primary() resumes it.
## That object part depends only on the object, so it can be cached and reused.
func trace_primary(origin: Vector2, dir: Vector2, bin: int, stop_owner := -1) -> PathRec:
	ray_count += 1
	var rec := PathRec.new()
	rec.bin = bin
	rec.pts.append(origin)
	rec.frac.append(1.0)
	_run_primary(rec, origin, dir.normalized(), -1, -1, 0, stop_owner)
	return rec


## Resumes a path stopped as it left an object (see trace_primary).
func continue_primary(rec: PathRec) -> void:
	_run_primary(rec, rec.cont_o, rec.cont_d, -1, -1, rec.cont_events, -1)


func _run_primary(rec: PathRec, o: Vector2, d: Vector2, medium: int, body: int, first_event: int,
		stop_owner: int) -> void:
	var bin := rec.bin
	var p := Spectrum.make_zero()
	p[bin] = rec.remain
	rec.term = Term.CULLED
	_rec = rec
	for events in range(first_event, SimConst.MAX_RAY_EVENTS + 1):
		_march(o, d, p, medium, body)
		medium = _ev_medium
		body = _ev_body
		var hit := _ev_o + d * _ev_t
		var leaving := false
		if stop_owner >= 0 and events == first_event \
				and (_ev_kind != Ev.SURFACE or surfaces.owner[_ev_seg] != stop_owner):
			stop_owner = -1   # Didn't meet the object first: nothing to stop at
		match _ev_kind:
			Ev.MISS:
				rec.term = Term.ESCAPE
				break
			Ev.EXIT:
				_rec_point(rec, hit, p[bin])
				rec.term = Term.ESCAPE
				break
			Ev.START_OPAQUE, Ev.OPAQUE:
				_rec_point(rec, hit, p[bin])
				rec.term = Term.OPAQUE
				rec.term_tile = _ev_tile
				rec.term_side = face_code(_ev_face)
				break
			Ev.MEDIA:
				rec.sig.append(-1 - ((_ev_prev_mat * 1024 + _ev_mat) * 4 + face_code(_ev_face)))
				d = _primary_interface(rec, hit, d, _ev_face, _ev_prev_mat, _ev_mat, p, -1)
				if d.dot(_ev_face) > 0.0:   # Total internal reflection: stays in the old medium
					medium = _ev_prev_mat
				else:
					medium = _ev_mat
				body = -1
			Ev.SURFACE:
				var s := _ev_seg
				var n := surfaces.normal[s]
				var from_front := d.dot(n) < 0.0
				var owner := surfaces.owner[s]
				rec.sig.append(surfaces.piece[s] * 2 + (0 if from_front else 1))
				match surfaces.coating[s]:
					SurfaceSet.Coating.PROBE:
						rec.probes.append_array([owner, p[bin]])
					SurfaceSet.Coating.MIRROR:
						var keep := p[bin] * surfaces.reflectance[s][bin]
						_deposit_bin(_tile_at(hit), bin, p[bin] - keep, owner, hit)
						p[bin] = keep
						d = d - 2.0 * d.dot(n) * n
					_:
						var ns := surfaces.shading_normal(s, _ev_u)
						var nrm := ns if from_front else -ns
						var m1 := surfaces.front_mat[s] if from_front else surfaces.back_mat[s]
						var m2 := surfaces.back_mat[s] if from_front else surfaces.front_mat[s]
						var refl_body := -1 if from_front else owner
						d = _primary_interface(rec, hit, d, nrm, m1, m2, p, refl_body)
						if d.dot(nrm) > 0.0:   # TIR
							medium = m1
							body = refl_body
						else:
							medium = m2
							body = owner if from_front else -1
							leaving = not from_front and owner == stop_owner
		rec.pts.append(hit)
		rec.frac.append(p[bin])
		o = hit + d * NUDGE
		if p[bin] < 1e-9:
			rec.term = Term.CULLED
			break
		if leaving:
			rec.term = Term.PENDING
			rec.cont_o = o
			rec.cont_d = d
			rec.cont_events = events + 1
			break
	rec.remain = p[bin]
	_rec = null


## Interface along a primary path: returns the new direction and scales p[bin] by the
## transmitted fraction; the reflected fraction is recorded (unless TIR keeps it all).
func _primary_interface(rec: PathRec, hit: Vector2, d: Vector2, nrm: Vector2, m1: int, m2: int,
		p: PackedFloat32Array, refl_body: int) -> Vector2:
	var bin := rec.bin
	var cos_i := clampf(-d.dot(nrm), 0.0, 1.0)
	var fr := _fresnel(cos_i, _index[m1][bin], _index[m2][bin])
	var r_dir := d + nrm * (2.0 * cos_i)
	if fr >= 1.0:
		return r_dir
	rec.refls.append_array([hit.x, hit.y, r_dir.x, r_dir.y, p[bin] * fr, m1, refl_body])
	p[bin] *= 1.0 - fr
	return _refract(d, nrm, cos_i, _index[m1][bin] / _index[m2][bin])


func _rec_point(rec: PathRec, hit: Vector2, power: float) -> void:
	rec.pts.append(hit)
	rec.frac.append(power)


## 0 top, 1 bottom, 2 left, 3 right: which face of a tile, from the normal facing the ray.
static func face_code(face: Vector2) -> int:
	if face.y < 0.0:
		return 0
	if face.y > 0.0:
		return 1
	return 2 if face.x < 0.0 else 3


static func _fresnel(cos_i: float, n1: float, n2: float) -> float:
	var eta := n1 / n2
	var sin2_t := eta * eta * (1.0 - cos_i * cos_i)
	if sin2_t >= 1.0:
		return 1.0
	var cos_t := sqrt(1.0 - sin2_t)
	var r0 := (n1 - n2) / (n1 + n2)
	r0 *= r0
	var c := cos_i if n1 <= n2 else cos_t
	return r0 + (1.0 - r0) * pow(1.0 - c, 5.0)


static func _refract(d: Vector2, nrm: Vector2, cos_i: float, eta: float) -> Vector2:
	var cos_t := sqrt(maxf(0.0, 1.0 - eta * eta * (1.0 - cos_i * cos_i)))
	return (d * eta + nrm * (eta * cos_i - cos_t)).normalized()


# --- Marching -------------------------------------------------------------------------------

## Walks from o along d until the next event, applying bulk absorption to p on the way.
## Results land in the _ev_* fields.
func _march(o: Vector2, d: Vector2, p: PackedFloat32Array, medium: int, body: int) -> void:
	var tm := SimConst.TILE_M
	var w := grid.width
	var h := grid.height
	var gw := w * tm
	var gh := h * tm
	_ev_t = 0.0
	_ev_body = body
	_ev_medium = medium
	if o.x < 0.0 or o.y < 0.0 or o.x >= gw or o.y >= gh:
		var t_in := _enter_t(o, d, gw, gh)
		if t_in < 0.0:
			_ev_o = o
			_ev_kind = Ev.MISS
			return
		o += d * (t_in + NUDGE)
	_ev_o = o
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
		if opaque[prev_mat]:   # Started in (or entered the site through) a solid tile
			_ev_kind = Ev.START_OPAQUE
			_ev_tile = cy * w + cx
			_ev_mat = prev_mat
			_ev_face = Vector2.ZERO
			return
		medium = prev_mat

	var sax := surfaces.ax
	var say := surfaces.ay
	var sex := surfaces.ex
	var sey := surfaces.ey
	var ox := o.x
	var oy := o.y
	var dx := d.x
	var dy := d.y
	var cell_start := surfaces.cell_start
	var cell_items := surfaces.cell_items
	var air_dist := _air_dist

	while true:
		if cx < 0 or cy < 0 or cx >= w or cy >= h:
			_ev_kind = Ev.EXIT
			_ev_t = t0
			_ev_medium = medium
			_ev_body = body
			return
		var i := cy * w + cx
		var t1 := minf(t_max_x, t_max_y)

		# A body ray whose stretch through this tile lies outside its body's bounds slipped past
		# a corner (grazing hit, nudge): it is in the tile medium again.
		if body >= 0 and not _body_bounds.get(body, Rect2()).has_point(o + d * (0.5 * (t0 + t1))):
			body = -1
			medium = mat[i]
			prev_mat = medium
		# Tile medium boundary.
		if body < 0 and face != Vector2.ZERO:
			var m := mat[i]
			if m != prev_mat:
				_ev_kind = Ev.OPAQUE if opaque[m] else Ev.MEDIA
				_ev_t = t0
				_ev_tile = i
				_ev_face = face
				_ev_mat = m
				_ev_prev_mat = prev_mat
				_ev_medium = medium
				_ev_body = body
				return

		# Optical surfaces bucketed in this tile.
		var best_t := INF
		var best_s := -1
		var best_u := 0.0
		for k in range(cell_start[i], cell_start[i + 1]):
			var s := cell_items[k]
			var sx := sex[s]
			var sy := sey[s]
			var denom := dx * sy - dy * sx
			if denom > -1e-12 and denom < 1e-12:
				continue
			var qx := sax[s] - ox
			var qy := say[s] - oy
			var t := (qx * sy - qy * sx) / denom
			if t <= EPS or t >= best_t:
				continue
			var u := (qx * dy - qy * dx) / denom
			if u < -U_EPS or u > 1.0 + U_EPS:   # Tolerance keeps shared vertices watertight
				continue
			best_t = t
			best_s = s
			best_u = u
		if best_s >= 0 and best_t <= t1 + EPS:
			_absorb_leg(p, medium, best_t - t0, i, body, o + d * (0.5 * (t0 + best_t)))
			_ev_kind = Ev.SURFACE
			_ev_t = best_t
			_ev_seg = best_s
			_ev_u = best_u
			_ev_tile = i
			_ev_medium = medium
			_ev_body = body
			return

		_absorb_leg(p, medium, t1 - t0, i, body, o + d * (0.5 * (t0 + t1)))
		var r := air_dist[i] - 1
		if body < 0 and r >= 1:
			# Every tile within r of this one is plain air with no surfaces: jump to where
			# the ray leaves that square.
			var ex := ((cx + r + 1) * tm - o.x) / d.x if d.x > 0.0 \
				else (((cx - r) * tm - o.x) / d.x if d.x < 0.0 else INF)
			var ey := ((cy + r + 1) * tm - o.y) / d.y if d.y > 0.0 \
				else (((cy - r) * tm - o.y) / d.y if d.y < 0.0 else INF)
			if ex < ey:
				t0 = ex
				var ny := clampi(floori((o.y + d.y * t0) / tm), cy - r, cy + r)
				cx = cx + r + 1 if step_x > 0 else cx - r - 1
				cy = ny
				face = Vector2(-step_x, 0)
			else:
				t0 = ey
				var nx := clampi(floori((o.x + d.x * t0) / tm), cx - r, cx + r)
				cy = cy + r + 1 if step_y > 0 else cy - r - 1
				cx = nx
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
## `mid` (the leg's midpoint) is kept with recorded deposits so cached paths can re-place them.
func _absorb_leg(p: PackedFloat32Array, medium: int, length: float, i: int, body: int,
		mid: Vector2) -> void:
	if length <= 0.0 or not _has_bulk[medium]:
		return
	var bulk := _bulk[medium]
	for b in Spectrum.BIN_COUNT:
		if p[b] > 0.0 and bulk[b] > 0.0:
			var keep := exp(-bulk[b] * length)
			_deposit_bin(i, b, p[b] * (1.0 - keep), body, mid)
			p[b] *= keep


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
