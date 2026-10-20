extends "res://tests/optics_fixtures.gd"
## Optics checks against closed-form physics (design doc §17 workflow).

const LENS_CROWN := preload("res://data/objects/lens_crown.tres")
const PRISM_FLINT := preload("res://data/objects/prism_flint.tres")
const MIRROR_ALUMINUM := preload("res://data/objects/mirror_aluminum.tres")


func _tracer(world: SimWorld) -> LightEngine:
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)   # Builds surfaces + buckets
	light.tracer().Begin()
	return light.tracer()


## A crown lens with a 5 cm probe near its focus (thin lens: f ≈ R / (2(n-1)) ≈ 1.15 m),
## traced once. Returns the probe.
func _lens_over_probe(world: SimWorld) -> SimObject:
	var probe_def := ObjectDef.new()
	probe_def.key = &"tiny_probe"
	probe_def.kind = ObjectDef.Kind.PROBE
	probe_def.size_m = 0.05
	_place(world, LENS_CROWN, Vector2(10.0, 4.0))
	var probe := _place(world, probe_def, Vector2(10.0, 4.0 + 1.05))
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	return probe


## Watts arriving on face `side` of tile i: the sum of its surface strips (D18).
func _face_arriving(light: LightSystem, i: int, side: int) -> float:
	var total := 0.0
	var face := i * 4 + side
	for k in light.strip_ids.size():
		if light.strip_ids[k] / SimConst.SKIN_STRIPS == face:
			total += light.strip_arriving[k]
	return total


## Paraxial rays through a thick biconvex lens cross the axis at the back focal distance
## predicted by the lensmaker's equation.
func test_lens_focal_length_matches_lensmaker() -> void:
	var world := _make_world()
	var r := 2.0
	var t := 0.15
	var center := Vector2(10.0, 4.0)
	_place(world, _lens_def(r, r, t), center)
	var tr := _tracer(world)
	var bin := Spectrum.Bin.GREEN
	tr.Trace(Vector2(center.x + 0.02, 0.5), Vector2.DOWN, _single_bin(bin, 1.0))
	# Find the transmitted leg below the lens and where it crosses x = center.x.
	var crossing := INF
	var seg_from: PackedVector2Array = tr.SegFrom()
	var seg_to: PackedVector2Array = tr.SegTo()
	for k in seg_from.size():
		var a := seg_from[k]
		var b := seg_to[k]
		if a.y > center.y + t * 0.5 - 0.01 and absf(b.x - a.x) > 1e-9:
			var s := (center.x - a.x) / (b.x - a.x)
			if s >= 0.0 and s <= 1.0 and b.y > a.y:
				crossing = minf(crossing, a.y + s * (b.y - a.y))
	var n := world.materials.get_by_key(&"crown_glass").refractive_index(Spectrum.WAVELENGTH_UM[bin])
	var inv_f := (n - 1.0) * (2.0 / r - (n - 1.0) * t / (n * r * r))
	var f := 1.0 / inv_f
	var bfd := f * (1.0 - (n - 1.0) * t / (n * r))
	check_near(crossing - (center.y + t * 0.5), bfd, bfd * 0.01, "back focal distance")


## A ray from air into a glass tile bends by Snell's law.
func test_refraction_into_glass_tile_obeys_snell() -> void:
	var world := _make_world(20, 20)
	var glass := world.materials.id_of(&"crown_glass")
	var g := world.grid
	var cells := PackedInt32Array()
	for y in range(10, 20):
		for x in 20:
			cells.append(g.idx(x, y))
	world.enqueue(PaintTilesCommand.new(cells, glass))
	world.flush_commands()
	var tr := _tracer(world)
	var theta_i := deg_to_rad(40.0)
	var d := Vector2(sin(theta_i), cos(theta_i))
	var bin := Spectrum.Bin.RED
	tr.Trace(Vector2(1.0, 1.0), d, _single_bin(bin, 1.0))
	var inside := Vector2.ZERO
	var seg_from: PackedVector2Array = tr.SegFrom()
	var seg_to: PackedVector2Array = tr.SegTo()
	for k in seg_from.size():
		if seg_from[k].y > 2.4999 and seg_to[k].y > seg_from[k].y:
			inside = (seg_to[k] - seg_from[k]).normalized()
			break
	var n := world.materials.get_def(glass).refractive_index(Spectrum.WAVELENGTH_UM[bin])
	var air := world.materials.get_def(MaterialDB.AIR_ID).refractive_index(Spectrum.WAVELENGTH_UM[bin])
	check_near(asin(inside.x), asin(air * sin(theta_i) / n), 1e-4, "refraction angle")


## Light inside glass beyond the critical angle reflects completely.
func test_total_internal_reflection() -> void:
	var world := _make_world(20, 20)
	var glass := world.materials.id_of(&"crown_glass")
	var g := world.grid
	var cells := PackedInt32Array()
	for y in range(0, 10):
		for x in 20:
			cells.append(g.idx(x, y))
	world.enqueue(PaintTilesCommand.new(cells, glass))
	world.flush_commands()
	var tr := _tracer(world)
	var theta := deg_to_rad(60.0)   # Critical angle for n ≈ 1.52 is ~41°
	tr.Trace(Vector2(0.5, 0.5), Vector2(sin(theta), cos(theta)), _single_bin(Spectrum.Bin.GREEN, 1.0))
	var escaped_below := false
	for p: Vector2 in tr.SegTo():
		if p.y > 2.5 + 0.01:
			escaped_below = true
	check(not escaped_below, "no light leaves through the bottom face")
	check(tr.Stats().absorbed > 0.0, "the trapped ray is absorbed in the glass")


## A prism bends blue more than red.
func test_prism_disperses() -> void:
	var world := _make_world()
	var center := Vector2(10.0, 5.0)
	_place(world, PRISM_FLINT, center)   # Apex up
	# Hit the left face ~50° off its normal (near minimum deviation; 30° would TIR in flint).
	var face_mid := Vector2(center.x - 0.15, center.y - 0.087)
	var d := Vector2.from_angle(deg_to_rad(-20.0))
	var tr := _tracer(world)
	var dirs := {}
	for bin in [Spectrum.Bin.BLUE, Spectrum.Bin.RED]:
		tr.Begin()
		tr.Trace(face_mid - d * 2.0, d, _single_bin(bin, 1.0))
		# Exit direction = the strongest leg that leaves the prism.
		var best := -1
		var best_w := 0.0
		var seg_from: PackedVector2Array = tr.SegFrom()
		var seg_to: PackedVector2Array = tr.SegTo()
		var seg_power: PackedFloat32Array = tr.SegPower()
		for k in seg_from.size():
			var w: float = seg_power[k * Spectrum.BIN_COUNT + bin]
			if seg_from[k].distance_to(center) < 0.45 and seg_to[k].distance_to(center) > 0.45 \
					and w > best_w:
				best = k
				best_w = w
		dirs[bin] = (seg_to[best] - seg_from[best]).normalized() if best >= 0 else d
	var dev_blue := d.angle_to(dirs[Spectrum.Bin.BLUE])
	var dev_red := d.angle_to(dirs[Spectrum.Bin.RED])
	check(absf(dev_blue) > absf(dev_red) + deg_to_rad(0.3), "blue deviates more (blue %.2f°, red %.2f°)" % [
		rad_to_deg(dev_blue), rad_to_deg(dev_red)])


## Every emitted watt is absorbed, escapes, scatters or is culled.
func test_sun_trace_conserves_energy() -> void:
	var world := SimWorld.new(load_materials(), 64, 32, 3)
	WorldGen.generate(world)
	world.time_s = 0.42 * SimConst.DAY_LENGTH_S
	world.tick()
	_place(world, LENS_CROWN, Vector2(6.0, 3.0))
	_place(world, PRISM_FLINT, Vector2(10.0, 3.0), 0.4)
	_place(world, MIRROR_ALUMINUM, Vector2(13.0, 3.0), 0.6)
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	_check_energy_balance(light.stats)


## A lens concentrates sunlight: the probe at its focus reads far above plain DNI.
func test_lens_concentrates_onto_probe() -> void:
	var world := _make_world(80, 60)
	world.time_s = 0.5 * SimConst.DAY_LENGTH_S
	world.tick()
	var probe := _lens_over_probe(world)
	var concentration := probe.incident_irradiance() / world.sun_dni
	check(concentration > 8.0, "concentration %.1f×" % concentration)


## Moonlight is traced like sunlight, a millionth as strong: a lens still concentrates it
## onto a probe, energy balances, and scaled cull thresholds keep culling small.
func test_moonlight_through_lens() -> void:
	var world := _make_world(80, 60)
	# The night's highest moon (sun down), so the light comes nearly straight down.
	var best_t := 0.0
	var best_h := -INF
	for k in 1000:
		world.time_s = (1.0 + k / 1000.0) * SimConst.DAY_LENGTH_S
		world.refresh_environment()
		if not world.sun_is_up and world.moon_elevation > best_h:
			best_h = world.moon_elevation
			best_t = world.time_s
	world.time_s = best_t
	world.tick()
	check(world.light_is_moon, "moon is the traced light")
	var probe := _lens_over_probe(world)
	_check_energy_balance((world.get_system(&"light") as LightSystem).stats)
	var concentration := probe.incident_irradiance() / world.light_dni
	check(concentration > 8.0, "concentration %.1f×" % concentration)


## Light only heats open air where a body is: no ray may stay flagged as inside a lens or
## prism after slipping past a corner (regression for grazing hits near prism corners).
func test_no_stray_deposits_in_open_air() -> void:
	var world := SimWorld.new(load_materials(), 300, 120, 1)
	WorldGen.generate(world)
	var objects := ObjectDB.new()
	objects.load_dir()
	Scenarios.build(world, objects, "demo")
	var light: LightSystem = world.get_system(&"light")
	var g := world.grid
	var stray := 0
	for hour in [7.5, 9.46, 11.0, 13.17, 15.0, 16.5]:
		world.time_s = hour / 24.0 * SimConst.DAY_LENGTH_S
		world.tick()
		light.retrace(world)
		for i in g.size():
			if light.tile_power[i] > 0.0 and g.material[i] == MaterialDB.AIR_ID:
				stray += 1
	check_eq(stray, 0, "no light deposited in air (bodies keep their own, D13)")


## Direct light on flat ground: each surface tile absorbs DNI × cos(zenith) × face width ×
## slice depth × absorptivity, with no rays traced.
func test_direct_sun_on_flat_ground() -> void:
	var world := _flat_world()
	world.time_s = 0.42 * SimConst.DAY_LENGTH_S
	world.tick()
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	var g := world.grid
	var i := g.idx(20, 15)
	var stone := world.materials.get_by_key(&"stone")
	var expected := 0.0
	for b in Spectrum.BIN_COUNT:
		expected += world.sun_spectrum[b] * stone.surface_absorptivity[b]
	expected *= SimConst.TILE_M * world.sun_direction.y * SimConst.DEPTH_M
	check_near(light.tile_power[i], expected, expected * 0.1, "surface tile power")
	var arriving := world.sun_dni * world.sun_direction.y * SimConst.TILE_M * SimConst.DEPTH_M
	check_near(_face_arriving(light, i, 0), arriving, arriving * 0.1, "light arriving on the top face")
	check_eq(_face_arriving(light, i, 1) + _face_arriving(light, i, 2) + _face_arriving(light, i, 3), 0.0,
		"no light on the other faces")
	check_eq(light.tile_power[g.idx(20, 16)], 0.0, "tile below the surface is dark")
	check_eq(light.stats.rays, 0, "no rays needed without optics")


## A floating block casts a shadow on the ground along the sun direction.
func test_block_casts_shadow() -> void:
	var world := _flat_world()
	world.time_s = 0.5 * SimConst.DAY_LENGTH_S
	world.tick()
	var g := world.grid
	var stone := world.materials.id_of(&"stone")
	var cells := PackedInt32Array()
	for x in range(18, 22):
		cells.append(g.idx(x, 5))
	world.enqueue(PaintTilesCommand.new(cells, stone))
	world.flush_commands()
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	check_eq(light.tile_power[g.idx(20, 15)], 0.0, "ground under the block is shaded")
	check(light.tile_power[g.idx(10, 15)] > 0.0, "ground beside it is lit")
	check(light.tile_power[g.idx(20, 5)] > 0.0, "the block's top is lit")


## Light is recorded on the faces it lands on (D19): morning sun travels +x, so a floating
## block's top and sun-side (left) faces are lit and its far side is not.
func test_light_lands_on_the_faces_it_hits() -> void:
	var world := _flat_world()
	world.time_s = 0.33 * SimConst.DAY_LENGTH_S
	world.tick()
	check(world.sun_direction.x > 0.3, "low morning sun from the left")
	var g := world.grid
	var cells := PackedInt32Array()
	for x in range(18, 22):
		for y in range(5, 7):
			cells.append(g.idx(x, y))
	world.enqueue(PaintTilesCommand.new(cells, world.materials.id_of(&"stone")))
	world.flush_commands()
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	check(_face_arriving(light, g.idx(19, 5), 0) > 0.0, "top face lit")
	check(_face_arriving(light, g.idx(18, 6), 2) > 0.0, "sun-side (left) face lit")
	check_eq(_face_arriving(light, g.idx(21, 6), 3), 0.0, "far (right) face dark")
	check_eq(_face_arriving(light, g.idx(19, 6), 1), 0.0, "bottom face dark")


## Beams and plain rays agree on how much light a lens puts into its focal tiles.
func test_beams_match_ray_tree_at_focus() -> void:
	var world := _flat_world(40, 30, 25)
	world.time_s = 0.5 * SimConst.DAY_LENGTH_S
	world.tick()
	# Lens 1.2 m above the ground so the focus lands on the surface.
	_place(world, LENS_CROWN, Vector2(5.0, 25 * SimConst.TILE_M - 1.23))
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	var g := world.grid
	var beam_focus := 0.0
	for x in range(18, 22):   # Tiles under the lens (x 4.5–5.5 m)
		beam_focus += light.tile_power[g.idx(x, 25)]
	# Reference: dense plain rays across the lens only.
	var tr := light.tracer()
	tr.Begin()
	var spacing := 0.002
	var x := 4.5
	while x < 5.5:
		var p := Spectrum.make_zero()
		for b in Spectrum.BIN_COUNT:
			p[b] = world.sun_spectrum[b] * spacing * SimConst.DEPTH_M
		tr.Trace(Vector2(x, 0.5), world.sun_direction, p)
		x += spacing
	var ray_focus := 0.0
	var ray_power: PackedFloat32Array = tr.TilePower()
	for xx in range(18, 22):
		ray_focus += ray_power[g.idx(xx, 25)]
	check(beam_focus > 100.0, "focus collects light (%.1f W)" % beam_focus)
	check_near(beam_focus / ray_focus, 1.0, 0.05, "beam vs ray tree at focus")


## An incremental pass (replaying tasks the edit can't have affected) gives the same light as
## tracing the edited world from scratch.
func test_incremental_pass_matches_full_trace() -> void:
	var worlds: Array[SimWorld] = []
	for k in 2:
		var world := _flat_world(80, 40, 30)
		world.time_s = 0.46 * SimConst.DAY_LENGTH_S
		world.tick()
		for j in 5:
			_place(world, LENS_CROWN, Vector2(3.0 + j * 3.0, 4.0))
		worlds.append(world)
	var edited := worlds[0]
	var fresh := worlds[1]
	var light: LightSystem = edited.get_system(&"light")
	light.retrace(edited)
	# Move the outermost lens and paint a tile beyond it, in both worlds. (Tasks whose recorded
	# paths, reflections included, reach an edit are traced again; the lenses at the other end
	# stay replayable.)
	for world in worlds:
		var obj: SimObject = world.objects.values()[4]
		world.enqueue(TransformObjectCommand.new(obj.id, obj.position + Vector2(0.3, 0.2), 0.1))
		world.enqueue(PaintTilesCommand.new(PackedInt32Array([world.grid.idx(70, 29)]),
			world.materials.id_of(&"stone")))
		world.flush_commands()
	light.retrace(edited)
	var replayed: int = light.stats.replayed
	var fresh_light: LightSystem = fresh.get_system(&"light")
	fresh_light.retrace(fresh)
	check(replayed > 0, "some tasks were replayed (%d)" % replayed)
	check_eq(fresh_light.stats.replayed, 0, "fresh world traced everything")
	var worst := 0.0
	for i in light.tile_power.size():
		worst = maxf(worst, absf(light.tile_power[i] - fresh_light.tile_power[i]))
	check(worst < 1e-3, "tile power matches a full trace (max diff %.6f W)" % worst)
	check_near(light.stats.absorbed, fresh_light.stats.absorbed, 1e-3, "absorbed total")


## Updating the air distance field locally after edits gives the same field as a rebuild.
func test_incremental_distance_field_matches_rebuild() -> void:
	var world := _flat_world(80, 40, 30)
	world.time_s = 0.46 * SimConst.DAY_LENGTH_S
	world.tick()
	for j in 4:
		_place(world, LENS_CROWN, Vector2(3.0 + j * 4.0, 4.0))
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	for step in 3:
		var obj: SimObject = world.objects.values()[step]
		world.enqueue(TransformObjectCommand.new(obj.id, obj.position + Vector2(1.3, 0.7), 0.2))
		world.enqueue(PaintTilesCommand.new(PackedInt32Array([world.grid.idx(10 + step * 9, 12)]),
			world.materials.id_of(&"stone")))
		world.flush_commands()
		light.retrace(world)
	var tr := light.tracer()
	var incremental: PackedByteArray = tr.AirDist()
	tr.BuildAccel()
	check(incremental == tr.AirDist(), "distance field after local updates equals a full rebuild")


## Paraxial ray through two thick lenses in series (exact surface trace) lands where ray
## transfer matrices predict.
func test_two_lenses_in_series_match_ray_matrices() -> void:
	var world := _make_world()
	var r := 2.0
	var t := 0.15
	var gap := 0.6                  # Center to center
	var c1 := Vector2(10.0, 4.0)
	var c2 := c1 + Vector2(0.0, gap)
	_place(world, _lens_def(r, r, t), c1)
	_place(world, _lens_def(r, r, t), c2)
	var tr := _tracer(world)
	var bin := Spectrum.Bin.GREEN
	var h := 0.02
	tr.Trace(Vector2(c1.x + h, 0.5), Vector2.DOWN, _single_bin(bin, 1.0))
	var crossing := INF
	var seg_from: PackedVector2Array = tr.SegFrom()
	var seg_to: PackedVector2Array = tr.SegTo()
	for k in seg_from.size():
		var a := seg_from[k]
		var b := seg_to[k]
		if a.y > c2.y + t * 0.5 - 0.01 and absf(b.x - a.x) > 1e-9:
			var s := (c1.x - a.x) / (b.x - a.x)
			if s >= 0.0 and s <= 1.0 and b.y > a.y:
				crossing = minf(crossing, a.y + s * (b.y - a.y))
	# Ray matrices on (height, angle): refraction at radius R from n1 to n2, then travel.
	var n := world.materials.get_by_key(&"crown_glass").refractive_index(Spectrum.WAVELENGTH_UM[bin])
	var ray := Vector2(h, 0.0)
	var steps := [[1.0, n, r], [t, 0.0, 0.0], [n, 1.0, -r], [gap - t, 0.0, 0.0],
		[1.0, n, r], [t, 0.0, 0.0], [n, 1.0, -r]]
	for st: Array in steps:
		if st[1] == 0.0:
			ray.x += st[0] * ray.y          # Travel a distance
		else:
			var n1: float = st[0]
			var n2: float = st[1]
			ray.y = (n1 * ray.y - (n2 - n1) * ray.x / st[2]) / n2
	var expected := -ray.x / ray.y      # Distance past the last vertex to the axis
	check_near(crossing - (c2.y + t * 0.5), expected, expected * 0.01, "focus after two lenses")


## Sunlight through two stacked lenses (the second sees converging light, and is an
## identical object, so it exercises the shared object cache): the beam pipeline matches
## a dense plain ray tree across the ground, and energy balances.
func test_beams_match_ray_tree_through_two_lenses() -> void:
	var world := _flat_world(40, 30, 25)
	world.time_s = 0.47 * SimConst.DAY_LENGTH_S
	world.tick()
	var ground := 25 * SimConst.TILE_M
	# Two f ≈ 1.15 m lenses 0.5 m apart focus ≈ 0.45 m past the second: on the ground.
	_place(world, LENS_CROWN, Vector2(5.0, ground - 1.05))
	_place(world, LENS_CROWN, Vector2(5.0, ground - 0.55))
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)
	var s := light.stats
	check_near((s.absorbed + s.escaped + s.scattered + s.culled) / s.emitted, 1.0, 1e-4, "energy balance")
	var g := world.grid
	var beams := PackedFloat32Array()
	for x in g.width:
		beams.append(light.tile_power[g.idx(x, 25)])
	var tr := light.tracer()
	tr.Begin()
	var spacing := 0.002
	var x0 := -2.0
	while x0 < g.width * SimConst.TILE_M + 2.0:
		var p := Spectrum.make_zero()
		for b in Spectrum.BIN_COUNT:
			p[b] = world.sun_spectrum[b] * spacing * SimConst.DEPTH_M
		var d := world.sun_direction
		tr.Trace(Vector2(x0, 0.0) - d * 0.0, d, p)
		x0 += spacing
	var rays: PackedFloat32Array = tr.TilePower()
	var peak := 0
	var total := 0.0
	var diff := 0.0
	for x in g.width:
		var rp := rays[g.idx(x, 25)]
		if rp > rays[g.idx(peak, 25)]:
			peak = x
		total += rp
		diff += absf(beams[x] - rp)
	var beam_peak := 0
	for x in g.width:
		if beams[x] > beams[beam_peak]:
			beam_peak = x
	check_eq(beam_peak, peak, "focus lands on the same tile")
	var win_b := 0.0
	var win_r := 0.0
	for x in range(maxi(peak - 1, 0), mini(peak + 2, g.width)):
		win_b += beams[x]
		win_r += rays[g.idx(x, 25)]
	var plain := rays[g.idx(g.width - 5, 25)]   # Open ground, plain sunlight
	check(rays[g.idx(peak, 25)] > 1.5 * plain, "rays concentrate (%.1f W at the focus tile, %.1f W in plain sun)"
		% [rays[g.idx(peak, 25)], plain])
	check_near(win_b / win_r, 1.0, 0.05, "beam vs ray tree at the focus")
	check(diff / total < 0.05, "ground profile differs by %.2f%%" % [100.0 * diff / total])


## Moving the upper of two stacked lenses changes what the lower one receives: an
## incremental pass must retrace the lower lens too and match a fresh trace.
func test_incremental_pass_with_lenses_in_series() -> void:
	var worlds: Array[SimWorld] = []
	for k in 2:
		var world := _flat_world(80, 40, 30)
		world.time_s = 0.46 * SimConst.DAY_LENGTH_S
		world.tick()
		_place(world, LENS_CROWN, Vector2(6.0, 5.0))
		_place(world, LENS_CROWN, Vector2(6.0, 5.6))
		_place(world, LENS_CROWN, Vector2(14.0, 5.0))   # Unrelated, should replay
		worlds.append(world)
	var edited := worlds[0]
	var light: LightSystem = edited.get_system(&"light")
	light.retrace(edited)
	for world in worlds:
		var obj: SimObject = world.objects.values()[0]
		world.enqueue(TransformObjectCommand.new(obj.id, obj.position + Vector2(0.15, 0.0), 0.15))
		world.flush_commands()
	light.retrace(edited)
	var fresh_light: LightSystem = worlds[1].get_system(&"light")
	fresh_light.retrace(worlds[1])
	var worst := 0.0
	for i in light.tile_power.size():
		worst = maxf(worst, absf(light.tile_power[i] - fresh_light.tile_power[i]))
	check(worst < 1e-3, "tile power matches a full trace (max diff %.6f W)" % worst)
	check_near(light.stats.absorbed, fresh_light.stats.absorbed, 1e-3, "absorbed total")

## The object cache (identical objects share traced sample paths) changes nothing but the work:
## the light of a row of identical lenses is the same with and without it.
func test_object_cache_matches_tracing_every_path() -> void:
	var results := []
	for cached in [true, false]:
		var world := _flat_world(80, 40, 30)
		world.time_s = 0.46 * SimConst.DAY_LENGTH_S
		world.tick()
		for j in 5:
			_place(world, LENS_CROWN, Vector2(3.0 + j * 3.0, 4.0))
		var light: LightSystem = world.get_system(&"light")
		light.tracer().SetCacheEnabled(cached)
		light.retrace(world)
		results.append([light.tile_power, light.stats])
	LightEngine.new().SetCacheEnabled(true)
	check(results[0][1].cache_hits > 0 and results[1][1].cache_hits == 0,
		"the cache is used only when on (%d vs %d hits)" % [results[0][1].cache_hits, results[1][1].cache_hits])
	var worst := 0.0
	var total := 0.0
	for i in results[0][0].size():
		worst = maxf(worst, absf(results[0][0][i] - results[1][0][i]))
		total += results[1][0][i]
	check(worst < 1e-3 * total, "tile power matches without the cache (max diff %.5f of %.1f W)" % [worst, total])
