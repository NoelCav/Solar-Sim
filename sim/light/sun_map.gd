class_name SunMap
extends RefCounted
## Stage 1 of a light pass: direct sunlight as a 1D shadow map (design doc §6.4.1).
##
## Sunlight is parallel, so the site is cut into lanes LANE_WIDTH_M wide across the sun's
## direction. Every sun-facing tile face and every optical surface is projected onto the
## lanes, keeping the nearest along the light. Lanes whose first hit is an opaque face are
## settled directly (no rays); lanes whose first hit is an optical surface or a transparent
## tile face (water, glass) are grouped into runs for the beam tracer.
## Cost scales with the number of exposed faces and surfaces, not with ray length.

enum Hit { NONE, OPAQUE, MEDIA, SURFACE }

var dir := Vector2.DOWN      ## Direction light travels
var perp := Vector2.RIGHT    ## Lane axis: u = position · perp
var u0 := 0.0                ## u of lane 0's left edge
var lane_w := 0.02
var count := 0

var depth := PackedFloat32Array()   ## Distance along dir (s = position · dir) of the first hit
var kind := PackedByteArray()       ## Hit
var ref := PackedInt32Array()       ## Tile index (faces) or segment index (surfaces)
var side := PackedByteArray()       ## Face code of tile hits: 0 top, 1 bottom, 2 left, 3 right

## Optical runs: consecutive lanes whose first hit belongs to the same object (or to tile
## media). Each run is [first lane, last lane, min depth, key].
var runs: Array = []

var _site_w := 0.0

# Exposed tile faces (rebuilt when the grid's structure changes).
var _faces_version := -1
var _face_tile := PackedInt32Array()
var _face_side := PackedByteArray()
var _face_media := PackedByteArray()


func lane_u(k: int) -> float:
	return u0 + (k + 0.5) * lane_w


func lane_point(k: int, s: float) -> Vector2:
	return perp * lane_u(k) + dir * s


func build(grid: TileGrid, opaque: PackedByteArray, surfaces: SurfaceSet, p_dir: Vector2,
		p_lane_w: float) -> void:
	dir = p_dir.normalized()
	perp = Vector2(-dir.y, dir.x)
	lane_w = p_lane_w
	var tm := SimConst.TILE_M
	var gw := grid.width * tm
	var gh := grid.height * tm
	_site_w = gw
	var corners := [Vector2(0, 0), Vector2(gw, 0), Vector2(0, gh), Vector2(gw, gh)]
	var u_min := INF
	var u_max := -INF
	for c: Vector2 in corners:
		u_min = minf(u_min, c.dot(perp))
		u_max = maxf(u_max, c.dot(perp))
	u0 = u_min
	count = ceili((u_max - u_min) / lane_w)
	depth.resize(count)
	depth.fill(INF)
	kind.resize(count)
	kind.fill(Hit.NONE)
	ref.resize(count)
	ref.fill(-1)
	side.resize(count)
	side.fill(0)

	if _faces_version != grid.structure_version:
		_build_faces(grid, opaque)
	# Tile faces that face the sun: tops always (light travels down), and the side facing it.
	var want_left := dir.x > 1e-6
	var want_right := dir.x < -1e-6
	var w := grid.width
	for f in _face_tile.size():
		var code := _face_side[f]
		if (code == 2 and not want_left) or (code == 3 and not want_right):
			continue
		var t := _face_tile[f]
		var x := (t % w) * tm
		var y := (t / w) * tm
		var a: Vector2
		var b: Vector2
		match code:
			0:
				a = Vector2(x, y)
				b = Vector2(x + tm, y)
			2:
				a = Vector2(x, y)
				b = Vector2(x, y + tm)
			_:
				a = Vector2(x + tm, y)
				b = Vector2(x + tm, y + tm)
		_raster(a, b, Hit.MEDIA if _face_media[f] else Hit.OPAQUE, t, code)
	for s in surfaces.count():
		if surfaces.coating[s] != SurfaceSet.Coating.PROBE:
			_raster(surfaces.a[s], surfaces.b[s], Hit.SURFACE, s, 0)
	_build_runs(surfaces)


## Lanes whose light crosses segment a–b before reaching their first hit (probe readings).
func lanes_reaching(a: Vector2, b: Vector2) -> PackedInt32Array:
	var out := PackedInt32Array()
	var ua := a.dot(perp)
	var ub := b.dot(perp)
	if absf(ub - ua) < 1e-9:
		return out
	var sa := a.dot(dir)
	var sb := b.dot(dir)
	var k0 := maxi(0, ceili((minf(ua, ub) - u0) / lane_w - 0.5))
	var k1 := mini(count - 1, floori((maxf(ua, ub) - u0) / lane_w - 0.5))
	for k in range(k0, k1 + 1):
		var t := (lane_u(k) - ua) / (ub - ua)
		if sa + t * (sb - sa) < depth[k]:
			out.append(k)
	return out


func _raster(a: Vector2, b: Vector2, hit: Hit, p_ref: int, code: int) -> void:
	var ua := a.dot(perp)
	var ub := b.dot(perp)
	if absf(ub - ua) < 1e-9:
		return   # Edge-on: covers no lane width
	var sa := a.dot(dir)
	var sb := b.dot(dir)
	var inv := 1.0 / (ub - ua)
	var k0 := maxi(0, ceili((minf(ua, ub) - u0) / lane_w - 0.5))
	var k1 := mini(count - 1, floori((maxf(ua, ub) - u0) / lane_w - 0.5))
	for k in range(k0, k1 + 1):
		var s := sa + (u0 + (k + 0.5) * lane_w - ua) * inv * (sb - sa)
		if s < depth[k]:
			depth[k] = s
			kind[k] = hit
			ref[k] = p_ref
			side[k] = code


func _build_runs(surfaces: SurfaceSet) -> void:
	runs.clear()
	var cur_key := -2
	var start := -1
	var s_min := INF
	for k in count + 1:
		var key := -2   # Not optical
		if k < count:
			if kind[k] == Hit.SURFACE:
				key = surfaces.owner[ref[k]]
			elif kind[k] == Hit.MEDIA:
				key = -1
		if key != cur_key:
			if cur_key != -2:
				runs.append([start, k - 1, s_min, cur_key])
			cur_key = key
			start = k
			s_min = INF
		if key != -2:
			s_min = minf(s_min, depth[k])


## Faces where light can arrive from a transparent neighbour into a different material.
## Bottom faces never face the sun.
func _build_faces(grid: TileGrid, opaque: PackedByteArray) -> void:
	_face_tile.clear()
	_face_side.clear()
	_face_media.clear()
	var w := grid.width
	var h := grid.height
	var mat := grid.material
	for y in h:
		for x in w:
			var i := y * w + x
			var m := mat[i]
			if m == MaterialDB.AIR_ID:
				continue
			# Neighbours above, left, right (outside the site counts as air).
			var above := mat[i - w] if y > 0 else MaterialDB.AIR_ID
			var left := mat[i - 1] if x > 0 else MaterialDB.AIR_ID
			var right := mat[i + 1] if x < w - 1 else MaterialDB.AIR_ID
			for code in [0, 2, 3]:
				var nb: int = above if code == 0 else (left if code == 2 else right)
				if nb != m and not opaque[nb]:
					_face_tile.append(i)
					_face_side.append(code)
					_face_media.append(0 if opaque[m] else 1)
	_faces_version = grid.structure_version


## s at which lane k enters the site: through the top edge, or through the side wall the
## light comes from, whichever is later along the light.
func entry_s(k: int) -> float:
	var u := lane_u(k)
	var s := -(perp.y * u) / dir.y   # y = 0
	if dir.x > 1e-9:
		s = maxf(s, -(perp.x * u) / dir.x)   # x = 0
	elif dir.x < -1e-9:
		s = maxf(s, (_site_w - perp.x * u) / dir.x)   # x = site width
	return s
