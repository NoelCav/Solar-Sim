class_name BeamGeometry
extends RefCounted
## Turns beam render records (BeamTracer.strips / slivers) into colored triangles.
## Irradiance goes as 1/width, so each leg is cut into slices, packed toward the point where
## the two rays cross (a focus), and brightness is evaluated per slice. Only bins with a
## non-zero color are built, so a view pays only for what it shows.

const MIN_WIDTH_M := 0.001     ## Width floor where rays cross at a focus
const SUN_LEVEL := 0.12        ## Brightness of plain sunlight (concentration 1)
const LOG_GAIN := 3.5          ## How fast brightness grows with concentration
const CROSS_STEPS: Array[float] = [0.5, 0.25, 0.1, 0.03]


## Brightness for a concentration ratio c (1 = plain sunlight): linear up to 1, then
## logarithmic, so 1× is faint, 10× bright and a focus blooms through the HDR glow.
static func tone(c: float) -> float:
	if c <= 1.0:
		return SUN_LEVEL * c
	return SUN_LEVEL * (1.0 + LOG_GAIN * log(c))


## Appends triangles for all strips and slivers. `rgb[bin]` is the bin's color per unit of
## tone (zero = hidden); `px` converts meters to pixels; colors are divided by `vertex_scale`.
static func build(strips: Array, slivers: Array, rgb: Array[Vector3],
		reference_dni: float, px: float, vertex_scale: float,
		verts: PackedVector2Array, cols: PackedColorArray) -> void:
	for st in strips:
		var bin: int = st[3]
		if rgb[bin] == Vector3.ZERO:
			continue
		_strip(st[0], st[1], st[2], st[4], rgb[bin] / vertex_scale,
			reference_dni * Spectrum.AM15_SHARE[bin], px, verts, cols)
	for sl in slivers:
		var bin: int = sl[3]
		if rgb[bin] == Vector3.ZERO:
			continue
		_sliver(sl[0], sl[1], sl[2], sl[4], rgb[bin] / vertex_scale,
			reference_dni * Spectrum.AM15_SHARE[bin], px, verts, cols)


static func _strip(ra: Tracer.PathRec, rb: Tracer.PathRec, watts: float, last: int, rgb: Vector3,
		ref: float, px: float, verts: PackedVector2Array, cols: PackedColorArray) -> void:
	var end := ra.pts.size() - 1 if last < 0 else last
	for k in range(1, end):
		var a0 := ra.pts[k]
		var a1 := ra.pts[k + 1]
		var b0 := rb.pts[k]
		var b1 := rb.pts[k + 1]
		var leg := (a1 - a0).normalized()
		# Concentration per meter of width: divide by the local width to get C.
		var p := watts * 0.5 * (ra.frac[k] + rb.frac[k]) / (SimConst.DEPTH_M * ref)
		# Signed width along the leg is linear in t; a sign change is the crossing.
		var w0 := leg.cross(b0 - a0)
		var w1 := leg.cross(b1 - a1)
		var ts := PackedFloat32Array([0.0])
		var t_cross := -1.0
		if w0 * w1 < 0.0:
			t_cross = w0 / (w0 - w1)
			var reach := maxf(t_cross, 1.0 - t_cross)
			ts.append(t_cross)
			for d in CROSS_STEPS:
				var span: float = d * reach
				if t_cross - span > 0.0:
					ts.append(t_cross - span)
				if t_cross + span < 1.0:
					ts.append(t_cross + span)
			ts.append(1.0)
			ts.sort()
		else:
			# Slices grow with how strongly the leg converges or diverges.
			var ratio := maxf(absf(w0), absf(w1)) / maxf(minf(absf(w0), absf(w1)), MIN_WIDTH_M)
			var n := clampi(ceili(log(ratio) / log(2.0)) + 1, 1, 6)
			for j in range(1, n + 1):
				ts.append(float(j) / n)
		var prev_a := a0 * px
		var prev_b := b0 * px
		var prev_c := _color(rgb, tone(p / maxf(absf(w0), MIN_WIDTH_M)))
		for j in range(1, ts.size()):
			var t := ts[j]
			var pa := a0.lerp(a1, t) * px
			var pb := b0.lerp(b1, t) * px
			var c := _color(rgb, tone(p / maxf(absf(lerpf(w0, w1, t)), MIN_WIDTH_M)))
			if ts[j - 1] == t_cross:
				_tri(prev_a, pa, pb, prev_c, c, c, verts, cols)
			elif t == t_cross:
				_tri(prev_a, pa, prev_b, prev_c, c, prev_c, verts, cols)
			else:
				_tri(prev_a, pa, pb, prev_c, c, c, verts, cols)
				_tri(prev_a, pb, prev_b, prev_c, c, prev_c, verts, cols)
			prev_a = pa
			prev_b = pb
			prev_c = c


static func _sliver(r: Tracer.PathRec, watts: float, width: float, first: int, rgb: Vector3,
		ref: float, px: float, verts: PackedVector2Array, cols: PackedColorArray) -> void:
	for k in range(first, r.pts.size() - 1):
		var a := r.pts[k] * px
		var b := r.pts[k + 1] * px
		var side := (b - a).normalized().orthogonal() * (width * 0.5 * px)
		var c := _color(rgb, tone(watts * r.frac[k] / (maxf(width, MIN_WIDTH_M) * SimConst.DEPTH_M * ref)))
		_tri(a - side, b - side, b + side, c, c, c, verts, cols)
		_tri(a - side, b + side, a + side, c, c, c, verts, cols)


static func _color(rgb: Vector3, level: float) -> Color:
	return Color(rgb.x * level, rgb.y * level, rgb.z * level, 1.0)


static func _tri(a: Vector2, b: Vector2, c: Vector2, ca: Color, cb: Color, cc: Color,
		verts: PackedVector2Array, cols: PackedColorArray) -> void:
	verts.append(a)
	verts.append(b)
	verts.append(c)
	cols.append(ca)
	cols.append(cb)
	cols.append(cc)
