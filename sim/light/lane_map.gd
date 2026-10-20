class_name LaneMap
extends RefCounted
## Stage 1 of a light pass: direct light as a 1D shadow map (design doc §6.4.1, §6.11).
##
## Parallel light (sun, moon): the site is cut into lanes LANE_WIDTH_M wide across the light's
## direction; u is the position across it. A point source (lamp): lanes are LANE_WIDTH_RAD of
## angle around it; u is the angle. Every face turned toward the source and every optical
## surface is projected onto the lanes, keeping the nearest along the light. Lanes whose first
## hit is an opaque face are settled directly (no rays); lanes whose first hit is an optical
## surface or a transparent tile face (water, glass) are grouped into runs for the beam tracer.
## Cost scales with the number of exposed faces and surfaces, not with ray length.

enum Hit { NONE, OPAQUE, MEDIA, SURFACE }

var point := false           ## A point source (lamp) rather than parallel light
var origin := Vector2.ZERO   ## Point source: where it is
var dir := Vector2.DOWN      ## Parallel: direction light travels
var perp := Vector2.RIGHT    ## Parallel: lane axis, u = position · perp
var u0 := 0.0                ## u of lane 0's left edge
var lane_w := 0.02           ## Lane width in u (m across the light, or radians)
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


## The point `s` along lane k's ray (from the line s = 0 for parallel light).
func lane_point(k: int, s: float) -> Vector2:
	if point:
		return origin + Vector2.from_angle(lane_u(k)) * s
	return perp * lane_u(k) + dir * s


## Maps the light of `src` (a LightSource) over the grid and the optical surfaces.
func build(grid: TileGrid, opaque: PackedByteArray, surfaces: SurfaceSet, src: LightSource) -> void:
	point = src.kind == LightSource.Kind.POINT
	var tm := SimConst.TILE_M
	_site_w = grid.width * tm
	if point:
		origin = src.position
		lane_w = SimConst.LANE_WIDTH_RAD
		u0 = src.angle_min
		count = ceili((src.angle_max - src.angle_min) / lane_w)
	else:
		dir = src.direction.normalized()
		perp = Vector2(-dir.y, dir.x)
		lane_w = SimConst.LANE_WIDTH_M
		var corners := [Vector2(0, 0), Vector2(_site_w, 0), Vector2(0, grid.height * tm),
			Vector2(_site_w, grid.height * tm)]
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
	# Tile faces turned toward the source. Parallel light: tops always (light travels down) and
	# the side facing it, never bottoms. A lamp: any face it is on the outer side of.
	var want_left := dir.x > 1e-6
	var want_right := dir.x < -1e-6
	var w := grid.width
	for f in _face_tile.size():
		var code := _face_side[f]
		var t := _face_tile[f]
		var x := (t % w) * tm
		var y := (t / w) * tm
		var a: Vector2
		var b: Vector2
		match code:
			0:
				a = Vector2(x, y)
				b = Vector2(x + tm, y)
			1:
				a = Vector2(x, y + tm)
				b = Vector2(x + tm, y + tm)
			2:
				a = Vector2(x, y)
				b = Vector2(x, y + tm)
			_:
				a = Vector2(x + tm, y)
				b = Vector2(x + tm, y + tm)
		if point:
			if not _faces_origin(code, a):
				continue
		elif code == 1 or (code == 2 and not want_left) or (code == 3 and not want_right):
			continue
		_raster(a, b, Hit.MEDIA if _face_media[f] else Hit.OPAQUE, t, code)
	for s in surfaces.count():
		if surfaces.coating[s] != SurfaceSet.Coating.PROBE:
			_raster(surfaces.a[s], surfaces.b[s], Hit.SURFACE, s, 0)
	_build_runs(surfaces)


## Lanes whose light crosses segment a–b before reaching their first hit (probe readings).
func lanes_reaching(a: Vector2, b: Vector2) -> PackedInt32Array:
	var out := PackedInt32Array()
	if point:
		for k in _point_lanes(a, b):
			var t := _point_depth(k, a, b)
			if t >= 0.0 and t < depth[k]:
				out.append(k)
		return out
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
	if point:
		for k in _point_lanes(a, b):
			var t := _point_depth(k, a, b)
			if t >= 0.0 and t < depth[k]:
				depth[k] = t
				kind[k] = hit
				ref[k] = p_ref
				side[k] = code
		return
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


## Whether a face (code as in Hit/side, `a` its first corner) looks toward the lamp.
func _faces_origin(code: int, a: Vector2) -> bool:
	match code:
		0:
			return origin.y < a.y
		1:
			return origin.y > a.y
		2:
			return origin.x < a.x
	return origin.x > a.x


## The lanes whose rays may cross segment a–b: those within the angles it subtends from the lamp
## (always less than half a turn), taken modulo a full turn.
func _point_lanes(a: Vector2, b: Vector2) -> PackedInt32Array:
	var out := PackedInt32Array()
	var aa := (a - origin).angle()
	var delta := wrapf((b - origin).angle() - aa, -PI, PI)
	if absf(delta) < 1e-9:
		return out   # Seen edge-on
	var lo := minf(aa, aa + delta)
	var hi := maxf(aa, aa + delta)
	for turn in [-TAU, 0.0, TAU]:
		var k0 := maxi(0, ceili((lo + turn - u0) / lane_w - 0.5))
		var k1 := mini(count - 1, floori((hi + turn - u0) / lane_w - 0.5))
		for k in range(k0, k1 + 1):
			out.append(k)
	return out


## Distance along lane k's ray to the line through a and b (negative: it points away).
func _point_depth(k: int, a: Vector2, b: Vector2) -> float:
	var d := Vector2.from_angle(lane_u(k))
	var e := b - a
	var denom := d.cross(e)
	if absf(denom) < 1e-12:
		return -1.0
	return (a - origin).cross(e) / denom


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


## Faces where light can arrive from a transparent neighbour into a different material. Bottom
## faces never face the sun (build skips them for parallel light) but can face a lamp.
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
			var below := mat[i + w] if y < h - 1 else MaterialDB.AIR_ID
			for code in [0, 2, 3, 1]:
				var nb: int = above if code == 0 else (left if code == 2 else (right if code == 3 else below))
				if nb != m and not opaque[nb]:
					_face_tile.append(i)
					_face_side.append(code)
					_face_media.append(0 if opaque[m] else 1)
	_faces_version = grid.structure_version


## s at which lane k enters the site: through the top edge, or through the side wall the
## light comes from, whichever is later along the light (a lamp's rays start at the lamp).
func entry_s(k: int) -> float:
	if point:
		return 0.0
	var u := lane_u(k)
	var s := -(perp.y * u) / dir.y   # y = 0
	if dir.x > 1e-9:
		s = maxf(s, -(perp.x * u) / dir.x)   # x = 0
	elif dir.x < -1e-9:
		s = maxf(s, (_site_w - perp.x * u) / dir.x)   # x = site width
	return s
