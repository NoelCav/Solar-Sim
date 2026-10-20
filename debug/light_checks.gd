class_name LightChecks
extends RefCounted
## Independent checks of the light engine, for the benchmark (tests/bench.gd) and SimProbe
## (`truth`, `steady`, `symmetry`). Each compares the beam engine's published light
## (LightSystem.tile_power) with something it must agree with, and reports where it doesn't.
## They trace on the preview engine or with fresh passes; the world's state is left as it was.


## Ground truth: plain rays (the engine's ray tree, no beams) `spacing_m` apart, entering along
## the top of the site between x0_m and x1_m, compared tile by tile with the beam pass. Keep the
## spacing a divisor of the tile (5 mm), else tiles alternately get one ray more and one fewer and
## the reference itself stripes. Only columns whose light all enters through that stretch of the
## top are compared. Returns totals
## (W, at the traced DNI), `ratio` (beams / rays), `l1` (sum |difference| / rays), `worst` (the
## largest difference on a tile brighter than 5 % of the peak, as a share of it) and `tiles`:
## the `top` largest differences.
static func ground_truth(world: SimWorld, spacing_m := 0.005, x0_m := 0.0, x1_m := INF, top := 5) -> Dictionary:
	var light: LightSystem = world.get_system(&"light")
	var dir := world.light_direction
	if not world.light_is_up or dir.y < 0.2 or light.tile_power.is_empty():
		return {"error": "no light to compare (light down or too low)"}
	var g := world.grid
	x1_m = minf(x1_m, g.width * SimConst.TILE_M)
	var e := light.probe_engine(world)
	var power := Spectrum.make_zero()
	for b in Spectrum.BIN_COUNT:
		power[b] = world.light_spectrum[b] * spacing_m * dir.y * SimConst.DEPTH_M
	var n := int((x1_m - x0_m) / spacing_m)
	for k in n:
		e.Trace(Vector2(x0_m + (k + 0.5) * spacing_m, 0.01), dir, power)
	var truth: PackedFloat32Array = e.TilePower()
	# Columns lit only through [x0, x1] at the top: shrink by the sideways run over the height.
	var shift := g.height * SimConst.TILE_M * dir.x / dir.y
	var c0 := ceili((x0_m + maxf(shift, 0.0)) / SimConst.TILE_M) + 1
	var c1 := floori((x1_m + minf(shift, 0.0)) / SimConst.TILE_M) - 1
	var beams := 0.0
	var rays := 0.0
	var l1 := 0.0
	var peak := 0.0
	var diffs := []
	for y in g.height:
		for x in range(maxi(c0, 0), mini(c1, g.width)):
			var i := g.idx(x, y)
			var b := light.tile_power[i]
			var r := truth[i]
			beams += b
			rays += r
			l1 += absf(b - r)
			peak = maxf(peak, maxf(b, r))
			if absf(b - r) > 1e-4:
				diffs.append([absf(b - r), i])
	diffs.sort_custom(func(p: Array, q: Array) -> bool: return p[0] > q[0])
	var worst := 0.0
	var tiles := []
	for d: Array in diffs:
		var i: int = d[1]
		var bright := maxf(light.tile_power[i], truth[i])
		if bright > 0.05 * peak:
			worst = maxf(worst, d[0] / bright)
		if tiles.size() < top:
			tiles.append({"tile": [i % g.width, i / g.width], "beams_w": light.tile_power[i], "rays_w": truth[i]})
	return {"rays": n, "ray_paths": e.RayCount(), "columns": [c0, c1], "beams_w": beams, "rays_w": rays,
		"ratio": beams / rays if rays > 0.0 else 0.0, "l1": l1 / rays if rays > 0.0 else 0.0,
		"worst": worst, "peak_w": peak, "tiles": tiles}


## Popping: the light advanced `steps` × 0.1° of the sun's arc, a fresh pass each, then put back.
## Smooth light changes about the same each step even when a focus slides across tiles, so the
## measure is the largest second difference of a tile's light (p[k+1] − 2 p[k] + p[k−1]) as a share
## of the brightest tile (`kink`); `jump` is the largest single-step change, for context.
static func steady(world: SimWorld, steps := 8) -> Dictionary:
	var light: LightSystem = world.get_system(&"light")
	if not world.light_is_up:
		return {"error": "light is down"}
	var t0 := world.time_s
	var frames: Array[PackedFloat32Array] = [light.tile_power.duplicate()]
	for k in steps:
		world.time_s += SimConst.DAY_LENGTH_S / 3600.0   # 0.1° of the arc
		world.refresh_environment()
		light.retrace(world, true)
		frames.append(light.tile_power.duplicate())
	world.time_s = t0
	world.refresh_environment()
	light.retrace(world, true)
	var peak := 0.0
	for f in frames:
		for v in f:
			peak = maxf(peak, v)
	if peak <= 0.0:
		return {"error": "no light"}
	var jump := 0.0
	var kink := 0.0
	var kink_at := -1
	var kink_step := -1
	for k in range(1, frames.size()):
		var a := frames[k - 1]
		var b := frames[k]
		for i in b.size():
			jump = maxf(jump, absf(b[i] - a[i]))
			if k + 1 < frames.size():
				var d2 := absf(frames[k + 1][i] - 2.0 * b[i] + a[i])
				if d2 > kink:
					kink = d2
					kink_at = i
					kink_step = k
	var at := world.grid.coords(kink_at) if kink_at >= 0 else Vector2i(-1, -1)
	var series := []
	if kink_at >= 0:
		for f in frames:
			series.append(snappedf(f[kink_at], 0.001))
	return {"steps": steps, "peak_w": peak, "jump": jump / peak, "kink": kink / peak, "kink_tile": [at.x, at.y],
		"kink_step": kink_step, "kink_series_w": series}


## A rig centred on the tile column at `about_m` (m from the middle) on flat ground: the light on
## the tiles `k` columns either side (k = 1 .. half_width) should match when the light comes
## straight down. Returns the largest difference as a share of the brightest of those tiles.
static func symmetry(world: SimWorld, about_m: float, half_width := 8) -> Dictionary:
	var light: LightSystem = world.get_system(&"light")
	var g := world.grid
	var c := floori((g.width * SimConst.TILE_M * 0.5 + about_m) / SimConst.TILE_M)
	var peak := 0.0
	var worst := 0.0
	var at := [-1, -1]
	for y in g.height:
		for k in range(1, half_width + 1):
			var a := light.tile_power[g.idx(c - k, y)]
			var b := light.tile_power[g.idx(c + k, y)]
			peak = maxf(peak, maxf(a, b))
			if absf(a - b) > worst:
				worst = absf(a - b)
				at = [k, y]
	return {"column": c, "sun_dir": [world.light_direction.x, world.light_direction.y], "peak_w": peak,
		"share": worst / peak if peak > 0.0 else 0.0, "worst_w": worst, "at_offset_row": at}
