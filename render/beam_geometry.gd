class_name BeamGeometry
extends RefCounted
## Turns beam render records (BeamTracer.render) into colored triangles.
## Record layout, all floats: STRIP, bin, watts, n, then n × (ax, ay, bx, by, frac_a, frac_b);
## SLIVER, bin, watts, n, width, then n × (x, y, frac).
## Irradiance goes as 1/width, so each leg is cut into slices, packed toward the point where
## the two rays cross (a focus), and brightness is evaluated per slice. Only bins with a
## non-zero color are built, so a view pays only for what it shows.

const STRIP := 0
const SLIVER := 1
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


## Appends triangles for every record in `buf`. `rgb[bin]` is the bin's color per unit of
## tone (zero = hidden); `px` converts meters to pixels; colors are divided by `vertex_scale`.
static func build(buf: PackedFloat32Array, rgb: Array[Vector3], reference_dni: float, px: float,
		vertex_scale: float, verts: PackedVector2Array, cols: PackedColorArray) -> void:
	var o := 0
	var size := buf.size()
	while o < size:
		var kind := int(buf[o])
		var bin := int(buf[o + 1])
		var watts := buf[o + 2]
		var n := int(buf[o + 3])
		if kind == STRIP:
			o += 4
			if rgb[bin] != Vector3.ZERO:
				_strip(buf, o, n, watts, rgb[bin] / vertex_scale, reference_dni * Spectrum.AM15_SHARE[bin],
					px, verts, cols)
			o += n * 6
		else:
			var width := buf[o + 4]
			o += 5
			if rgb[bin] != Vector3.ZERO:
				_sliver(buf, o, n, watts, width, rgb[bin] / vertex_scale,
					reference_dni * Spectrum.AM15_SHARE[bin], px, verts, cols)
			o += n * 3


## Strip record: n points, each (ax, ay, bx, by, frac_a, frac_b); legs join consecutive points.
static func _strip(buf: PackedFloat32Array, o: int, n: int, watts: float, rgb: Vector3, ref: float,
		px: float, verts: PackedVector2Array, cols: PackedColorArray) -> void:
	for k in n - 1:
		var q := o + k * 6
		var a0 := Vector2(buf[q], buf[q + 1])
		var b0 := Vector2(buf[q + 2], buf[q + 3])
		var a1 := Vector2(buf[q + 6], buf[q + 7])
		var b1 := Vector2(buf[q + 8], buf[q + 9])
		var leg := (a1 - a0).normalized()
		# Concentration per meter of width: divide by the local width to get C.
		var p := watts * 0.5 * (buf[q + 4] + buf[q + 5]) / (SimConst.DEPTH_M * ref)
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
			var m := clampi(ceili(log(ratio) / log(2.0)) + 1, 1, 6)
			for j in range(1, m + 1):
				ts.append(float(j) / m)
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


## Sliver record: width, then n points, each (x, y, frac).
static func _sliver(buf: PackedFloat32Array, o: int, n: int, watts: float, width: float, rgb: Vector3,
		ref: float, px: float, verts: PackedVector2Array, cols: PackedColorArray) -> void:
	for k in n - 1:
		var q := o + k * 3
		var a := Vector2(buf[q], buf[q + 1]) * px
		var b := Vector2(buf[q + 3], buf[q + 4]) * px
		var side := (b - a).normalized().orthogonal() * (width * 0.5 * px)
		var c := _color(rgb, tone(watts * buf[q + 2] / (maxf(width, MIN_WIDTH_M) * SimConst.DEPTH_M * ref)))
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
