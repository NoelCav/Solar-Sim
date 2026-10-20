class_name SurfaceSkin
extends RefCounted
## The surface skin (D18, design doc §7): every face where a solid tile meets a non-solid one
## (air, liquid) is split into SimConst.SKIN_STRIPS strips along the face. The skin is that
## surface: light lands on it, and it is where the solid exchanges heat with what's outside.
##
## Per strip (width w = TILE_M / strips, area a = w · DEPTH_M):
## - to its own tile: half a tile of the solid, k·a / (TILE_M / 2)
## - to the tile across the face: a convective film h·a (gas) or half a tile of liquid
## - to the neighbouring strips along the surface: a near-surface layer as deep as a strip is
##   wide, k·DEPTH_M, so a hot spot spreads sideways
## - radiation: sky-facing tops to the sky, other faces to the tile across them
## In series, body and film reproduce the old tile-to-air conductance exactly, so the skin
## only changes things where light is uneven along a face (a focal spot heats a spot).
##
## The skin's heat capacity is negligible next to its tile, so it is solved steady each tick
## (SkinKernel): light in = heat out, exactly. Strips are stored face by face in runs of
## faces that continue each other along a surface line (same orientation, consecutive tiles),
## so lateral conduction crosses tile borders. Pure data; ThermalSystem solves it, the light
## system writes `light_w` / `light_scale` (traced light) and `face_energy_in` (diffuse).

var strips := SimConst.SKIN_STRIPS
var faces := 0
var face_tile := PackedInt32Array()     ## Per face: its solid tile
var face_side := PackedByteArray()      ## Per face: 0 top, 1 bottom, 2 left, 3 right
var face_next := PackedInt32Array()     ## Per face: the non-solid tile across it
var face_of := PackedInt32Array()       ## Per tile face (tile * 4 + side): its face index, or -1
var run_start := PackedInt32Array()     ## First face of each run, plus `faces` at the end
var temperature := PackedFloat32Array() ## Per strip, K
var face_energy_in := PackedFloat32Array()  ## Per face, J spread evenly over its strips (diffuse light)
## Traced sky light absorbed per strip, W at the traced DNI, and the factor to the light now: the
## light system writes the rate when a pass publishes and the factor every tick.
var light_w := PackedFloat32Array()
var light_scale := 0.0
## Light absorbed per strip from lamps, W now (the light system rewrites it every tick).
var extra_w := PackedFloat32Array()
var version := -1                       ## Grid structure_version the faces were built for


## Rebuilds the faces when the grid's structure changed; strips of faces that still exist keep
## their temperature, new ones start at their tile's temperature.
func sync(world: SimWorld) -> void:
	var g := world.grid
	if version == g.structure_version:
		return
	var old_of := face_of
	var old_t := temperature
	var w := g.width
	var solid := world.materials.is_solid
	face_tile.clear()
	face_side.clear()
	face_next.clear()
	run_start.clear()
	face_of.resize(g.size() * 4)
	face_of.fill(-1)
	# Runs: top/bottom faces along rows (+x), left/right faces along columns (+y), matching
	# the order of strips along a face (LightEngine.StripIds).
	for side in 4:
		var horizontal := side <= 1
		var lines := g.height if horizontal else g.width
		var length := g.width if horizontal else g.height
		for line in lines:
			var running := false
			for c in length:
				var i := line * w + c if horizontal else c * w + line
				var nb := _across(g, i, side)
				var exposed := nb >= 0 and solid[g.material[i]] and not solid[g.material[nb]]
				if exposed:
					if not running:
						run_start.append(face_tile.size())
					face_of[i * 4 + side] = face_tile.size()
					face_tile.append(i)
					face_side.append(side)
					face_next.append(nb)
				running = exposed
	faces = face_tile.size()
	run_start.append(faces)
	temperature.resize(faces * strips)
	face_energy_in.resize(faces)
	face_energy_in.fill(0.0)
	light_w.resize(faces * strips)
	light_w.fill(0.0)
	extra_w.resize(faces * strips)
	extra_w.fill(0.0)
	for f in faces:
		var key := face_tile[f] * 4 + face_side[f]
		var old := old_of[key] if key < old_of.size() else -1
		for s in strips:
			temperature[f * strips + s] = old_t[old * strips + s] if old >= 0 else g.temperature[face_tile[f]]
	version = g.structure_version


## The strip index (face * strips + strip) for a light-engine strip index, or -1 when that
## face has no skin.
func local_strip(engine_strip: int) -> int:
	var f := face_of[engine_strip / strips] if engine_strip / strips < face_of.size() else -1
	return f * strips + engine_strip % strips if f >= 0 else -1


## Hottest strip on any face of tile i, K (0 if the tile has no skin, or before the first sync).
func max_temperature(i: int) -> float:
	var t := 0.0
	if i * 4 + 3 >= face_of.size():
		return t
	for side in 4:
		var f := face_of[i * 4 + side]
		if f >= 0:
			for s in strips:
				t = maxf(t, temperature[f * strips + s])
	return t


## The tile across face `side` of tile i, or -1 outside the grid.
static func _across(g: TileGrid, i: int, side: int) -> int:
	var x := i % g.width
	var y := i / g.width
	match side:
		0:
			return i - g.width if y > 0 else -1
		1:
			return i + g.width if y < g.height - 1 else -1
		2:
			return i - 1 if x > 0 else -1
		_:
			return i + 1 if x < g.width - 1 else -1
