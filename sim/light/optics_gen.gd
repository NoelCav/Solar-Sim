class_name OpticsGen
extends RefCounted
## Builds optical polylines from parameters (design doc §6.3). Analytic shapes are
## generated into polylines with per-vertex normals (D4).
## Output is in object-local meters, y down, as pieces [points, normals]; the pieces of
## a closed body are in outline order, and normals point outward (the front side).
## Corners are hard: each flat or curved face is its own piece.


## A lens with its optical axis along local y (light from -y). Radii are signed: positive bulges
## outward (convex), negative dishes inward (concave), 0 is flat; so this makes biconvex,
## plano-convex, biconcave, plano-concave, meniscus and flat plates. `thickness` is the center
## thickness; it grows if the edges would be thinner than 5 mm.
static func lens(diameter: float, r_front: float, r_back: float, thickness: float,
		arc_segments: int = 32) -> Array:
	var half := diameter * 0.5
	var s1 := _sagitta(r_front, half)
	var s2 := _sagitta(r_back, half)
	var t := center_thickness(diameter, r_front, r_back, thickness)
	var top := _arc_face(half, r_front, -t * 0.5, -1.0, arc_segments)
	var bottom := _arc_face(half, r_back, t * 0.5, 1.0, arc_segments)
	var top_edge_y := -t * 0.5 + s1
	var bottom_edge_y := t * 0.5 - s2
	# Outline order: top (left→right), right edge (down), bottom (right→left), left edge (up).
	var bottom_rev := [_reversed(bottom[0]), _reversed(bottom[1])]
	return [
		top,
		_flat(Vector2(half, top_edge_y), Vector2(half, bottom_edge_y), Vector2.RIGHT),
		bottom_rev,
		_flat(Vector2(-half, bottom_edge_y), Vector2(-half, top_edge_y), Vector2.LEFT),
	]


## The center thickness a lens is built with: `thickness`, or more when the faces would leave the
## edge thinner than 5 mm.
static func center_thickness(diameter: float, r_front: float, r_back: float, thickness: float) -> float:
	var half := diameter * 0.5
	return maxf(thickness, _sagitta(r_front, half) + _sagitta(r_back, half) + 0.005)


## Focal length of a lens built by `lens` (thick-lens lensmaker's equation; radii signed as there,
## convex positive, 0 for flat), for refractive index n, m: positive converges, negative diverges
## (its focus is virtual, that far behind the light), INF for none.
static func focal_length(diameter: float, r_front: float, r_back: float, thickness: float, n: float) -> float:
	var half := diameter * 0.5
	var t := center_thickness(diameter, r_front, r_back, thickness)
	var c1 := 1.0 / r_front if r_front != 0.0 else 0.0
	var c2 := 1.0 / r_back if r_back != 0.0 else 0.0
	var power := (n - 1.0) * (c1 + c2 - (n - 1.0) * t * c1 * c2 / n)
	return 1.0 / power if absf(power) > 1e-9 else INF


## Fraction of light a clear body of index n passes at normal incidence: two faces, each
## reflecting ((n − 1) / (n + 1))² (Fresnel), no absorption.
static func normal_transmission(n: float) -> float:
	var r := pow((n - 1.0) / (n + 1.0), 2.0)
	return (1.0 - r) * (1.0 - r)


## Isosceles prism: base along local x at y = +height/2 side, apex pointing to -y.
static func prism(base: float, apex_angle_deg: float) -> Array:
	var half := base * 0.5
	var height := half / tan(deg_to_rad(apex_angle_deg) * 0.5)
	var apex := Vector2(0.0, -height * 2.0 / 3.0)
	var right := Vector2(half, height / 3.0)
	var left := Vector2(-half, height / 3.0)
	return [
		_flat(apex, right, _outward(apex, right)),
		_flat(right, left, Vector2.DOWN),
		_flat(left, apex, _outward(left, apex)),
	]


## A single flat segment along local x (mirror, probe).
static func flat_strip(length: float) -> Array:
	var half := length * 0.5
	return [_flat(Vector2(-half, 0.0), Vector2(half, 0.0), Vector2.UP)]


## Applies a rigid transform to pieces.
static func transformed(pieces: Array, xf: Transform2D) -> Array:
	var out := []
	for piece in pieces:
		var pts := PackedVector2Array()
		var nrm := PackedVector2Array()
		for p: Vector2 in piece[0]:
			pts.append(xf * p)
		for n: Vector2 in piece[1]:
			nrm.append(xf.basis_xform(n).normalized())
		out.append([pts, nrm])
	return out


## Concatenated outline of a closed body, for drawing.
static func outline(pieces: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for piece in pieces:
		var pts: PackedVector2Array = piece[0]
		for k in pts.size():
			if out.is_empty() or out[out.size() - 1].distance_squared_to(pts[k]) > 1e-12:
				out.append(pts[k])
	return out


## How far a face of radius `radius` (signed: negative dishes inward) bulges at the rim relative to its
## center, m: positive for convex, negative for concave.
static func _sagitta(radius: float, half: float) -> float:
	if radius == 0.0:
		return 0.0
	var r := maxf(absf(radius), half)
	return signf(radius) * (r - sqrt(r * r - half * half))


## One lens face from x = -half to +half. `vertex_y` is the face's center; `side` is -1 for
## the top face and +1 for the bottom. A positive radius bulges away from the lens, a negative one
## dishes into it. Normals point away from the lens.
static func _arc_face(half: float, radius: float, vertex_y: float, side: float, n: int) -> Array:
	var pts := PackedVector2Array()
	var nrm := PackedVector2Array()
	if radius == 0.0:
		pts.append_array([Vector2(-half, vertex_y), Vector2(half, vertex_y)])
		nrm.append_array([Vector2(0, side), Vector2(0, side)])
		return [pts, nrm]
	var concave := radius < 0.0
	var r := maxf(absf(radius), half)
	var way := -side if concave else side   # A concave face is the circle on the other side
	var center := Vector2(0.0, vertex_y - way * r)
	for k in n + 1:
		var x := lerpf(-half, half, float(k) / n)
		var y := center.y + way * sqrt(r * r - x * x)
		var p := Vector2(x, y)
		pts.append(p)
		nrm.append((center - p).normalized() if concave else (p - center).normalized())
	return [pts, nrm]


## Axis-aligned box centered on the origin (machine bodies), in outline order.
static func box(width: float, height: float) -> Array:
	var a := Vector2(-width, -height) * 0.5
	var b := Vector2(width, -height) * 0.5
	var c := Vector2(width, height) * 0.5
	var d := Vector2(-width, height) * 0.5
	return [_flat(a, b, Vector2.UP), _flat(b, c, Vector2.RIGHT), _flat(c, d, Vector2.DOWN), _flat(d, a, Vector2.LEFT)]


static func _flat(p0: Vector2, p1: Vector2, n: Vector2) -> Array:
	return [PackedVector2Array([p0, p1]), PackedVector2Array([n, n])]


## Normal of edge p0→p1 pointing away from the origin (the body center).
static func _outward(p0: Vector2, p1: Vector2) -> Vector2:
	var e := p1 - p0
	var n := Vector2(-e.y, e.x).normalized()
	return n if n.dot((p0 + p1) * 0.5) > 0.0 else -n


static func _reversed(arr: PackedVector2Array) -> PackedVector2Array:
	var out := arr.duplicate()
	out.reverse()
	return out
