class_name Mounting
extends RefCounted
## How objects stand in the world (ObjectDef.mount). Optics and cell panels stand on stands:
## a pole from the ground in the middle of a tile column, extended in tile steps. Surface cells
## and machines rest on a ground tile. Probes float. An object's port (where wire connects it,
## D14) is at its foot: the tile just above the ground in its column, or the ground tile below.
## Stands are background props (D19): no optics, no heat, no occupancy; the object on top is
## the thing in the world. The placement commands
## snap through here, so the rule is enforced by the sim; the build ghost previews it.
## Objects placed with `mounted` false float freely (creative mode only).

const HEIGHT_STEP_M := SimConst.TILE_M   ## Stands extend in tile steps
const MIN_HEIGHT_M := 0.5               ## Object center above the ground, m
const MAX_HEIGHT_M := 6.0
const GROUND_LIFT_M := 0.01             ## Surface cells rest just above the tile (not touching)


## Where an object of `def` goes when placed or dragged toward `wanted`, m: the middle of its
## column, at a stand height (or on the ground) above the ground under `wanted`. Vector2.INF
## when the column has no ground below.
static func snap_position(world: SimWorld, def: ObjectDef, wanted: Vector2) -> Vector2:
	if def.mount == ObjectDef.Mount.FREE:
		return wanted
	var col := floori(wanted.x / SimConst.TILE_M)
	var ground := ground_y(world, col, wanted.y)
	if col < 0 or col >= world.grid.width or is_inf(ground):
		return Vector2.INF
	var x := (col + 0.5) * SimConst.TILE_M
	if def.mount == ObjectDef.Mount.GROUND:
		return Vector2(x, ground - GROUND_LIFT_M - _bottom(def))
	var height := clampf(snappedf(ground - wanted.y, HEIGHT_STEP_M), MIN_HEIGHT_M, MAX_HEIGHT_M)
	return Vector2(x, ground - height)


## The angle an object of `def` takes: ground cells lie flat; everything else tilts freely.
static func snap_angle(def: ObjectDef, angle: float) -> float:
	return 0.0 if def.mount == ObjectDef.Mount.GROUND else angle


## Top of the ground in column `col` under height `y` (m): the first solid tile at or below
## y's row; if that row is solid, the top of the solid it is in. INF when there is none.
static func ground_y(world: SimWorld, col: int, y: float) -> float:
	var g := world.grid
	if col < 0 or col >= g.width:
		return INF
	var solid := world.materials.is_solid
	var row := clampi(floori(y / SimConst.TILE_M), 0, g.height - 1)
	while row > 0 and solid[g.material[g.idx(col, row)]] and solid[g.material[g.idx(col, row - 1)]]:
		row -= 1
	for r in range(row, g.height):
		if solid[g.material[g.idx(col, r)]]:
			return r * SimConst.TILE_M
	return INF


## The tiles where wire connects object `obj` (D14): for a mounted object the tile at its foot
## and the ground tile under it; for a floating one the tile it is in.
static func port_tiles(world: SimWorld, obj: SimObject) -> PackedInt32Array:
	var g := world.grid
	var col := floori(obj.position.x / SimConst.TILE_M)
	var out := PackedInt32Array()
	if not obj.mounted:
		var row := floori(obj.position.y / SimConst.TILE_M)
		if g.in_bounds(col, row):
			out.append(g.idx(col, row))
		return out
	var base := stand_base(world, obj.position)
	if is_finite(base):
		var ground_row := roundi(base / SimConst.TILE_M)
		for row in [ground_row - 1, ground_row]:
			if g.in_bounds(col, row):
				out.append(g.idx(col, row))
	return out


## Lowest point of `def`'s shape below its center at angle 0, m (what rests on the ground).
static func _bottom(def: ObjectDef) -> float:
	var low := 0.0
	for p: Vector2 in OpticsGen.outline(def.build_pieces()):
		low = maxf(low, p.y)
	return low


## Base of the stand under an object at `at` (m): the ground below it, or INF if there is none.
static func stand_base(world: SimWorld, at: Vector2) -> float:
	return ground_y(world, floori(at.x / SimConst.TILE_M), at.y)
