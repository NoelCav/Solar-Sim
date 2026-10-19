class_name BeamTracer
extends RefCounted
## Stage 2 of a light pass: sunlight that first meets an optical surface (design doc §6.4.1).
##
## A run of sun-map lanes is traced as a wavefront, one spectral bin at a time: sample rays
## start BASE_SPACING apart, and the interval between two neighbours is split in half until
## both follow the same optical path (same surfaces, same faces, landing on one stretch of
## surface) or the interval is MIN_SPACING wide. A coherent interval is a beam: its energy
## is spread exactly over where it lands and it is drawn as a filled strip whose brightness
## follows its width, so focal spots come out smooth and correctly concentrated from a few
## dozen rays. Incoherent slivers fall back to per-ray deposits.
## Each sample ray stands for half of each interval beside it; the deposits recorded along
## its path are applied with that weight, so energy is conserved exactly.
## Fresnel reflections are pooled across the run (one ray per REFL_POOL_M of wavefront per
## reflection along the path) and traced as ordinary rays.

const BASE_SPACING := 0.1      ## Initial sample spacing across a run, m (refinement finds edges)
const MIN_SPACING := 0.02      ## Narrowest interval worth refining, m (one lane; tiles are 0.25 m)
const LANDING_TOL_M := 0.35   ## Same-path rays landing this close count as one beam (~1 tile)
const REFL_POOL_M := 0.5       ## Pooled reflections: one secondary ray per this much wavefront

enum Span { SPLIT, EXACT, NEAR }

var tracer: Tracer
var map: SunMap
var grid: TileGrid
var irradiance := PackedFloat32Array()   ## Direct normal irradiance per bin, W/m²

## Render output: flat beam records (layout in BeamGeometry); triangles are built by the
## renderer, only for the bins a view shows.
var render := PackedFloat32Array()

var _intervals: Array = []   ## [ua, ra, ub, rb, Span, spread] in u order
var _last_spread: Array = []
## Pooled reflections per reflection index along the path: [watts, pos, dir, medium, body, u0].
var _refl: Dictionary = {}


func begin(p_tracer: Tracer, p_map: SunMap, p_grid: TileGrid, p_irradiance: PackedFloat32Array) -> void:
	tracer = p_tracer
	map = p_map
	grid = p_grid
	irradiance = p_irradiance
	render.clear()


## Traces one run ([first lane, last lane, min depth, key]) in one bin.
func trace_run(run: Array, bin: int) -> void:
	var irr := irradiance[bin]
	if irr <= 0.0:
		return
	var u_lo := map.u0 + int(run[0]) * map.lane_w
	var u_hi := map.u0 + (int(run[1]) + 1) * map.lane_w
	var s0: float = run[2] - 0.02
	var n := maxi(1, ceili((u_hi - u_lo) / BASE_SPACING))
	_intervals.clear()
	_refl.clear()
	var prev_u := u_lo
	var prev_r := _trace_at(prev_u, s0, bin)
	for i in range(1, n + 1):
		var u := u_lo + (u_hi - u_lo) * i / n
		var r := _trace_at(u, s0, bin)
		_refine(prev_u, prev_r, u, r, s0, bin)
		prev_u = u
		prev_r = r
	for iv in _intervals:
		_settle(iv, irr, bin)
	_flush_reflections(bin)
	_intervals.clear()   # Release the traced paths now rather than at the next run


func _trace_at(u: float, s0: float, bin: int) -> Tracer.PathRec:
	return tracer.trace_primary(map.perp * u + map.dir * s0, map.dir, bin)


func _refine(ua: float, ra: Tracer.PathRec, ub: float, rb: Tracer.PathRec, s0: float, bin: int) -> void:
	var kind := _classify(ra, rb)
	if kind != Span.SPLIT:
		_intervals.append([ua, ra, ub, rb, kind, _last_spread])
		return
	if ub - ua <= MIN_SPACING:
		_intervals.append([ua, ra, ub, rb, Span.SPLIT, []])
		return
	var um := (ua + ub) * 0.5
	var rm := _trace_at(um, s0, bin)
	_refine(ua, ra, um, rm, s0, bin)
	_refine(um, rm, ub, rb, s0, bin)


## How an interval between two neighbouring rays is settled:
## EXACT - same optical path, landing on one straight stretch of surface (or both escape);
## NEAR  - same optical path, landing within LANDING_TOL_M of each other on uneven ground:
##         drawn as one beam, energy split between the two landing tiles;
## SPLIT - different paths: refine, or settle per ray once the interval is MIN_SPACING wide.
func _classify(ra: Tracer.PathRec, rb: Tracer.PathRec) -> Span:
	if ra.term != rb.term or ra.term == Tracer.Term.CULLED:
		return Span.SPLIT
	if ra.pts.size() != rb.pts.size() or ra.sig != rb.sig:
		return Span.SPLIT
	_last_spread = [] if ra.term != Tracer.Term.OPAQUE else _spread(ra, rb)
	if ra.term != Tracer.Term.OPAQUE or not _last_spread.is_empty():
		return Span.EXACT
	var end_a := ra.pts[ra.pts.size() - 1]
	var end_b := rb.pts[rb.pts.size() - 1]
	return Span.NEAR if end_a.distance_to(end_b) <= LANDING_TOL_M else Span.SPLIT


## Tiles (and weights) a coherent beam lands on between the two rays' end points:
## the same tile, or a straight run of exposed faces of the same orientation.
## Returns [] when the landing area isn't one such stretch.
func _spread(ra: Tracer.PathRec, rb: Tracer.PathRec) -> Array:
	var ta := ra.term_tile
	var tb := rb.term_tile
	if ta == tb:
		return [PackedInt32Array([ta]), PackedFloat32Array([1.0])]
	var code := ra.term_side
	if code != rb.term_side or code < 0:
		return []
	var w := grid.width
	var tm := SimConst.TILE_M
	var pa := ra.pts[ra.pts.size() - 1]
	var pb := rb.pts[rb.pts.size() - 1]
	var horizontal := code <= 1
	var line := ta / w if horizontal else ta % w
	if line != (tb / w if horizontal else tb % w):
		return []
	var c0 := mini(ta % w, tb % w) if horizontal else mini(ta / w, tb / w)
	var c1 := maxi(ta % w, tb % w) if horizontal else maxi(ta / w, tb / w)
	var lo := minf(pa.x, pb.x) if horizontal else minf(pa.y, pb.y)
	var hi := maxf(pa.x, pb.x) if horizontal else maxf(pa.y, pb.y)
	var length := hi - lo
	var tiles := PackedInt32Array()
	var weights := PackedFloat32Array()
	var mat := grid.material
	var opaque := tracer.opaque
	for c in range(c0, c1 + 1):
		var t := line * w + c if horizontal else c * w + line
		# The face must be exposed: an opaque tile with a transparent neighbour on that side.
		var nb := t - w if code == 0 else (t + w if code == 1 else (t - 1 if code == 2 else t + 1))
		if not opaque[mat[t]] or (nb >= 0 and nb < mat.size() and opaque[mat[nb]]):
			return []
		var overlap := minf(hi, (c + 1) * tm) - maxf(lo, c * tm)
		tiles.append(t)
		weights.append(overlap / length if length > 1e-9 else 1.0 / (c1 - c0 + 1))
	return [tiles, weights]


func _settle(iv: Array, irr: float, bin: int) -> void:
	var ua: float = iv[0]
	var ra: Tracer.PathRec = iv[1]
	var ub: float = iv[2]
	var rb: Tracer.PathRec = iv[3]
	var half := irr * (ub - ua) * SimConst.DEPTH_M * 0.5   # W each ray carries for this interval
	_apply_path(ra, half, bin, ua)
	_apply_path(rb, half, bin, ub)
	match iv[4]:
		Span.EXACT:
			var arriving := half * (ra.remain + rb.remain)
			if ra.term == Tracer.Term.ESCAPE:
				tracer.escaped_w += arriving
			else:
				var sp: Array = iv[5]
				var tiles: PackedInt32Array = sp[0]
				var weights: PackedFloat32Array = sp[1]
				for k in tiles.size():
					tracer.absorb_opaque_bin(tiles[k], bin, arriving * weights[k])
			_render_strip(ra, rb, half * 2.0, bin)
		Span.NEAR:
			_terminal(ra, half, bin)
			_terminal(rb, half, bin)
			_render_strip(ra, rb, half * 2.0, bin)
		_:
			_terminal(ra, half, bin)
			_terminal(rb, half, bin)
			if ra.sig == rb.sig and ra.pts.size() == rb.pts.size():
				# Same path, landing split by an occluding edge: one beam up to the last leg.
				_render_strip(ra, rb, half * 2.0, bin, ra.pts.size() - 2)
				_render_ray(ra, half, (ub - ua) * 0.5, bin, ra.pts.size() - 2)
				_render_ray(rb, half, (ub - ua) * 0.5, bin, rb.pts.size() - 2)
			else:
				_render_ray(ra, half, (ub - ua) * 0.5, bin)
				_render_ray(rb, half, (ub - ua) * 0.5, bin)


## Applies a path's recorded deposits, probe crossings and reflections for `watts` of input.
func _apply_path(r: Tracer.PathRec, watts: float, bin: int, u: float) -> void:
	var deps := r.deps
	for k in range(0, deps.size(), 3):
		tracer.apply_bin(int(deps[k]), bin, watts * deps[k + 1], int(deps[k + 2]))
	var probes := r.probes
	for k in range(0, probes.size(), 2):
		tracer.add_probe(int(probes[k]), bin, watts * probes[k + 1])
	var refls := r.refls
	for k in range(0, refls.size(), 7):
		var acc: Array = _refl.get(k, [0.0, Vector2.ZERO, Vector2.ZERO, 0, -1, u])
		acc[0] += watts * refls[k + 4]
		acc[1] = Vector2(refls[k], refls[k + 1])
		acc[2] = Vector2(refls[k + 2], refls[k + 3])
		acc[3] = int(refls[k + 5])
		acc[4] = int(refls[k + 6])
		_refl[k] = acc
		if u - acc[5] >= REFL_POOL_M and acc[0] >= SimConst.MIN_CHILD_W:
			_emit_reflection(acc, bin)
			acc[0] = 0.0
			acc[5] = u


func _terminal(r: Tracer.PathRec, watts: float, bin: int) -> void:
	var arriving := watts * r.remain
	match r.term:
		Tracer.Term.ESCAPE:
			tracer.escaped_w += arriving
		Tracer.Term.OPAQUE:
			tracer.absorb_opaque_bin(r.term_tile, bin, arriving)
		_:
			tracer.culled_w += arriving


func _flush_reflections(bin: int) -> void:
	for k in _refl:
		var acc: Array = _refl[k]
		if acc[0] >= SimConst.MIN_RAY_W:
			_emit_reflection(acc, bin)
		else:
			tracer.culled_w += acc[0]
	_refl.clear()


## Traces pooled reflected light as an ordinary ray tree (already counted as emitted).
func _emit_reflection(acc: Array, bin: int) -> void:
	var p := Spectrum.make_zero()
	p[bin] = acc[0]
	var dir: Vector2 = acc[2]
	tracer.trace(acc[1] + dir * Tracer.NUDGE, dir, p, false, acc[3], acc[4])


# --- Render records ---------------------------------------------------------------------
# Written into one flat buffer (see BeamGeometry for the layout) as each interval settles,
# so traced paths are released right after their run and publishing is one array copy.

## A coherent beam between two rays, drawn up to (not including) leg `last` (-1 = all).
func _render_strip(ra: Tracer.PathRec, rb: Tracer.PathRec, watts: float, bin: int, last := -1) -> void:
	var end := ra.pts.size() - 1 if last < 0 else last
	if end < 2:
		return
	render.append_array([BeamGeometry.STRIP, bin, watts, end])   # points 1..end
	for k in range(1, end + 1):
		var a := ra.pts[k]
		var b := rb.pts[k]
		render.append_array([a.x, a.y, b.x, b.y, ra.frac[k], rb.frac[k]])


## A lone ray drawn as a beam of fixed width from leg `first` on (incoherent slivers).
func _render_ray(r: Tracer.PathRec, watts: float, width: float, bin: int, first := 1) -> void:
	var n := r.pts.size() - first
	if n < 2:
		return
	render.append_array([BeamGeometry.SLIVER, bin, watts, n, width])
	for k in range(first, r.pts.size()):
		var a := r.pts[k]
		render.append_array([a.x, a.y, r.frac[k]])
