class_name Placement
extends RefCounted
## Where an object may be: its shape may not overlap another object's shape or a solid tile
## (solids and powders; air and liquids are free, so a lens can sit in water). Commands
## that place or move objects ask here and refuse otherwise; the build ghost shows it.
##
## A shape is its outline (OpticsGen.outline): closed for bodies (lens, prism) and machines,
## open for surfaces (mirror, probe, cell). Two shapes overlap when their edges cross or one
## lies inside the other's closed outline. Machines are behind the play plane (D19): they
## collide with other machines and the ground, not with optics.


## True when `def` at `position`, `angle` overlaps nothing; `ignore_id` is the object being
## moved (it may overlap its own old place).
static func is_clear(world: SimWorld, def: ObjectDef, position: Vector2, angle: float,
		ignore_id := -1) -> bool:
	var shape := OpticsGen.outline(OpticsGen.transformed(def.build_pieces(), Transform2D(angle, position)))
	var closed := def.is_closed()
	var box := _bounds(shape)
	for obj: SimObject in world.objects.values():
		if obj.id == ignore_id or obj.def.is_machine() != def.is_machine():
			continue
		var other := OpticsGen.outline(obj.world_pieces())
		if box.intersects(_bounds(other), true) and overlaps(shape, closed, other, obj.def.is_closed()):
			return false
	return not _touches_solid(world, shape, closed, box)


## Whether two outlines overlap (touching counts).
static func overlaps(a: PackedVector2Array, a_closed: bool, b: PackedVector2Array, b_closed: bool) -> bool:
	var na := a.size() if a_closed else a.size() - 1
	var nb := b.size() if b_closed else b.size() - 1
	for i in na:
		var a0 := a[i]
		var a1 := a[(i + 1) % a.size()]
		for j in nb:
			if Geometry2D.segment_intersects_segment(a0, a1, b[j], b[(j + 1) % b.size()]) != null:
				return true
	if a_closed and Geometry2D.is_point_in_polygon(b[0], a):
		return true
	return b_closed and Geometry2D.is_point_in_polygon(a[0], b)


static func _touches_solid(world: SimWorld, shape: PackedVector2Array, closed: bool, box: Rect2) -> bool:
	var g := world.grid
	var tm := SimConst.TILE_M
	var solid := world.materials.is_solid
	for y in range(floori(box.position.y / tm), floori(box.end.y / tm) + 1):
		for x in range(floori(box.position.x / tm), floori(box.end.x / tm) + 1):
			if not g.in_bounds(x, y) or not solid[g.material[g.idx(x, y)]]:
				continue
			var tile := PackedVector2Array([Vector2(x, y) * tm, Vector2(x + 1, y) * tm,
				Vector2(x + 1, y + 1) * tm, Vector2(x, y + 1) * tm])
			if overlaps(shape, closed, tile, true):
				return true
	return false


static func _bounds(points: PackedVector2Array) -> Rect2:
	var r := Rect2(points[0], Vector2.ZERO)
	for p in points:
		r = r.expand(p)
	return r
