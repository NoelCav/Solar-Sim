class_name SurfaceSet
extends RefCounted
## Every optical surface in the world as flat segment arrays (design doc §6.3, D4).
## A segment's geometric normal points to its *front* side; `front_mat` / `back_mat`
## name the media a ray crosses between. Per-vertex normals are interpolated along the
## segment for smooth refraction. Segments are bucketed per tile for the tracer.

enum Coating { NONE, MIRROR, PROBE, CELL }

var a := PackedVector2Array()
var b := PackedVector2Array()
var normal := PackedVector2Array()      ## Geometric (flat) normal, front side
var normal_a := PackedVector2Array()    ## Shading normal at a
var normal_b := PackedVector2Array()    ## Shading normal at b
var front_mat := PackedInt32Array()
var back_mat := PackedInt32Array()
var coating := PackedInt32Array()
var owner := PackedInt32Array()         ## Object id
var piece := PackedInt32Array()         ## Index of the add_polyline call that made the segment
var reflectance: Array[PackedFloat32Array] = []   ## Per-bin, mirrors only
## Each face of an object is one piece; segments of a smooth face share it, so rays hitting
## neighbouring segments of the same face still count as following the same path.
var piece_count := 0

# Tile buckets, CSR layout: segments of tile i are cell_items[cell_start[i] .. cell_start[i+1]).
var cell_start := PackedInt32Array()
var cell_items := PackedInt32Array()
## Flat copies of each segment's start and edge vector for the tracer's inner loop
## (float64: positions span tens of meters and rays are nudged by 1e-5 m).
var ax := PackedFloat64Array()
var ay := PackedFloat64Array()
var ex := PackedFloat64Array()
var ey := PackedFloat64Array()
var _width := 0
var _height := 0


func clear() -> void:
	for arr in [a, b, normal, normal_a, normal_b, front_mat, back_mat, coating, owner, piece]:
		arr.clear()
	reflectance.clear()
	piece_count = 0


func count() -> int:
	return a.size()


## Adds an open polyline. `normals` are per-vertex and point to the front side.
func add_polyline(points: PackedVector2Array, normals: PackedVector2Array, p_front: int,
		p_back: int, p_coating: int, p_owner: int, p_reflectance := PackedFloat32Array()) -> void:
	for k in points.size() - 1:
		var pa := points[k]
		var pb := points[k + 1]
		var e := pb - pa
		if e.length_squared() < 1e-14:
			continue
		var g := Vector2(-e.y, e.x).normalized()
		if g.dot(normals[k] + normals[k + 1]) < 0.0:
			g = -g
		a.append(pa)
		b.append(pb)
		normal.append(g)
		normal_a.append(normals[k])
		normal_b.append(normals[k + 1])
		front_mat.append(p_front)
		back_mat.append(p_back)
		coating.append(p_coating)
		owner.append(p_owner)
		piece.append(piece_count)
		reflectance.append(p_reflectance)
	piece_count += 1


## Shading normal at parameter u along segment s, on the same side as the geometric normal.
func shading_normal(s: int, u: float) -> Vector2:
	var n := normal_a[s].lerp(normal_b[s], u).normalized()
	return n if n.dot(normal[s]) > 0.0 else normal[s]


## Buckets segments into every tile their bounding box touches.
func build_buckets(width: int, height: int) -> void:
	_width = width
	_height = height
	var count_s := count()
	for arr in [ax, ay, ex, ey]:
		arr.resize(count_s)
	for s in count_s:
		ax[s] = a[s].x
		ay[s] = a[s].y
		ex[s] = b[s].x - a[s].x
		ey[s] = b[s].y - a[s].y
	var n := width * height
	var counts := PackedInt32Array()
	counts.resize(n + 1)
	counts.fill(0)
	var ranges := PackedInt32Array()   # x0, y0, x1, y1 per segment
	ranges.resize(count() * 4)
	var inv := 1.0 / SimConst.TILE_M
	for s in count():
		var x0 := clampi(floori(minf(a[s].x, b[s].x) * inv), 0, width - 1)
		var x1 := clampi(floori(maxf(a[s].x, b[s].x) * inv), 0, width - 1)
		var y0 := clampi(floori(minf(a[s].y, b[s].y) * inv), 0, height - 1)
		var y1 := clampi(floori(maxf(a[s].y, b[s].y) * inv), 0, height - 1)
		ranges[s * 4] = x0
		ranges[s * 4 + 1] = y0
		ranges[s * 4 + 2] = x1
		ranges[s * 4 + 3] = y1
		for y in range(y0, y1 + 1):
			for x in range(x0, x1 + 1):
				counts[y * width + x + 1] += 1
	for i in n:
		counts[i + 1] += counts[i]
	cell_start = counts
	cell_items.resize(cell_start[n])
	var fill := cell_start.duplicate()
	for s in count():
		for y in range(ranges[s * 4 + 1], ranges[s * 4 + 3] + 1):
			for x in range(ranges[s * 4], ranges[s * 4 + 2] + 1):
				var i := y * width + x
				cell_items[fill[i]] = s
				fill[i] += 1


## Tile rows covered by any segment: the topmost one, or `height` if there are none.
func top_row() -> int:
	var top := _height
	var inv := 1.0 / SimConst.TILE_M
	for s in count():
		top = mini(top, floori(minf(a[s].y, b[s].y) * inv))
	return maxi(top, 0)
