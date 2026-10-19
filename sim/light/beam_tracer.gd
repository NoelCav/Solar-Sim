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
const MIN_SPACING := 0.01      ## Narrowest interval worth refining, m (tiles are 0.25 m)
const MIN_WIDTH_M := 0.001     ## Rendering: beam width floor where rays cross at a focus
const LANDING_TOL_M := 0.35   ## Same-path rays landing this close count as one beam (~1 tile)
const REFL_POOL_M := 0.5       ## Pooled reflections: one secondary ray per this much wavefront

enum Span { SPLIT, EXACT, NEAR }

var tracer: Tracer
var map: SunMap
var grid: TileGrid
var irradiance := PackedFloat32Array()   ## Direct normal irradiance per bin, W/m²

# Render output: triangles (3 points each) with per-vertex irradiance and one bin each.
var tri_pts := PackedVector2Array()
var tri_irr := PackedFloat32Array()
var tri_bin := PackedByteArray()

var _intervals: Array = []
## Pooled reflections per reflection index along the path: [watts, pos, dir, medium, body, u0].
var _refl: Dictionary = {}


func begin(p_tracer: Tracer, p_map: SunMap, p_grid: TileGrid, p_irradiance: PackedFloat32Array) -> void:
	tracer = p_tracer
	map = p_map
	grid = p_grid
	irradiance = p_irradiance
	tri_pts.clear()
	tri_irr.clear()
	tri_bin.clear()


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


func _trace_at(u: float, s0: float, bin: int) -> Tracer.PathRec:
	return tracer.trace_primary(map.perp * u + map.dir * s0, map.dir, bin)


func _refine(ua: float, ra: Tracer.PathRec, ub: float, rb: Tracer.PathRec, s0: float, bin: int) -> void:
	var kind := _classify(ra, rb)
	if kind != Span.SPLIT:
		_intervals.append([ua, ra, ub, rb, kind])
		return
	if ub - ua <= MIN_SPACING:
		_intervals.append([ua, ra, ub, rb, Span.SPLIT])
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
	if ra.term != Tracer.Term.OPAQUE or not _spread(ra, rb).is_empty():
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
				var sp := _spread(ra, rb)
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
	for k in r.dep_tile.size():
		tracer.apply_bin(r.dep_tile[k], bin, watts * r.dep_frac[k], r.dep_body[k])
	for k in r.probe_owner.size():
		tracer.add_probe(r.probe_owner[k], bin, watts * r.probe_frac[k])
	for k in r.refl_pos.size():
		var acc: Array = _refl.get(k, [0.0, Vector2.ZERO, Vector2.ZERO, 0, -1, u])
		acc[0] += watts * r.refl_frac[k]
		acc[1] = r.refl_pos[k]
		acc[2] = r.refl_dir[k]
		acc[3] = r.refl_medium[k]
		acc[4] = r.refl_body[k]
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


# --- Rendering ------------------------------------------------------------------------------

## A coherent beam between two rays, leg by leg after the first interaction. Irradiance
## goes as 1/width, so each leg is cut into slices (packed toward the point where the rays
## cross, at a focus) and brightness is interpolated per slice rather than across the leg.
## Draws legs after the first interaction, stopping before leg `last` (-1 = all legs).
func _render_strip(ra: Tracer.PathRec, rb: Tracer.PathRec, watts: float, bin: int, last := -1) -> void:
	for k in range(1, ra.pts.size() - 1 if last < 0 else last):
		var a0 := ra.pts[k]
		var a1 := ra.pts[k + 1]
		var b0 := rb.pts[k]
		var b1 := rb.pts[k + 1]
		var leg := (a1 - a0).normalized()
		var p := watts * 0.5 * (ra.frac[k] + rb.frac[k])
		# Signed width along the leg is linear in t; a sign change is the crossing.
		var w0 := leg.cross(b0 - a0)
		var w1 := leg.cross(b1 - a1)
		var ts := PackedFloat32Array([0.0, 1.0])
		var t_cross := -1.0
		if w0 * w1 < 0.0:
			t_cross = w0 / (w0 - w1)
			ts.append(t_cross)
			for d in [0.5, 0.25, 0.12, 0.06, 0.03, 0.015]:
				var span: float = d * maxf(t_cross, 1.0 - t_cross)
				if t_cross - span > 0.0:
					ts.append(t_cross - span)
				if t_cross + span < 1.0:
					ts.append(t_cross + span)
		else:
			var ratio := maxf(absf(w0), absf(w1)) / maxf(minf(absf(w0), absf(w1)), MIN_WIDTH_M)
			var n := clampi(int(ratio), 1, 8)   # Strongly converging legs get more slices
			for j in range(1, n):
				ts.append(float(j) / n)
		ts.sort()
		for j in ts.size() - 1:
			var t0 := ts[j]
			var t1 := ts[j + 1]
			var pa0 := a0.lerp(a1, t0)
			var pa1 := a0.lerp(a1, t1)
			var pb0 := b0.lerp(b1, t0)
			var pb1 := b0.lerp(b1, t1)
			var irr0 := _irr(p, absf(lerpf(w0, w1, t0)))
			var irr1 := _irr(p, absf(lerpf(w0, w1, t1)))
			if t0 == t_cross:
				_tri(pa0, pa1, pb1, irr0, irr1, irr1, bin)
			elif t1 == t_cross:
				_tri(pa0, pa1, pb0, irr0, irr1, irr0, bin)
			else:
				_tri(pa0, pa1, pb1, irr0, irr1, irr1, bin)
				_tri(pa0, pb1, pb0, irr0, irr1, irr0, bin)


## A lone ray drawn as a beam of fixed width (incoherent slivers).
func _render_ray(r: Tracer.PathRec, watts: float, width: float, bin: int, first := 1) -> void:
	for k in range(first, r.pts.size() - 1):
		var a := r.pts[k]
		var b := r.pts[k + 1]
		var side := (b - a).normalized().orthogonal() * (width * 0.5)
		var irr := _irr(watts * r.frac[k], width)
		_tri(a - side, b - side, b + side, irr, irr, irr, bin)
		_tri(a - side, b + side, a + side, irr, irr, irr, bin)


func _irr(watts: float, width: float) -> float:
	return watts / (maxf(width, MIN_WIDTH_M) * SimConst.DEPTH_M)


func _tri(a: Vector2, b: Vector2, c: Vector2, ia: float, ib: float, ic: float, bin: int) -> void:
	tri_pts.append(a)
	tri_pts.append(b)
	tri_pts.append(c)
	tri_irr.append(ia)
	tri_irr.append(ib)
	tri_irr.append(ic)
	tri_bin.append(bin)
