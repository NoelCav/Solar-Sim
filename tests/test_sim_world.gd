extends TestSuite
## World checks: grid layers, ticking, sun and moon motion, commands and undo, determinism.

const LENS_CROWN := preload("res://data/objects/lens_crown.tres")
const PROBE := preload("res://data/objects/probe.tres")


func _make_world(seed_value: int = 7) -> SimWorld:
	var world := SimWorld.new(load_materials(), 64, 32, seed_value)
	WorldGen.generate(world)
	return world


func test_grid_allocates_every_layer() -> void:
	var g := TileGrid.new(10, 5)
	for layer in [g.material, g.temperature, g.integrity, g.flags,
			g.liquid_amount, g.liquid_type, g.smoke, g.steam, g.energy_in, g.wire]:
		check_eq(layer.size(), 50, "layer size")
	check_eq(g.idx(3, 2), 23, "index")
	check_eq(g.coords(23), Vector2i(3, 2), "coords")


func test_ticks_advance_time() -> void:
	var world := _make_world()
	var t0 := world.time_s
	for i in SimConst.TICK_RATE:
		world.tick()
	check_eq(world.tick_count, SimConst.TICK_RATE, "tick count")
	check_near(world.time_s - t0, 1.0, 1e-6, "one second")


func test_sun_rises_east_and_sets_west() -> void:
	var world := _make_world()
	world.time_s = 0.30 * SimConst.DAY_LENGTH_S
	world.tick()
	check(world.sun_is_up and world.sun_direction.x > 0.0, "morning light travels west→east (+x)")
	world.time_s = 0.70 * SimConst.DAY_LENGTH_S
	world.tick()
	check(world.sun_is_up and world.sun_direction.x < 0.0, "evening light travels -x")
	world.time_s = 0.0
	world.tick()
	check(not world.sun_is_up, "midnight")



## The moon lags the sun by its phase, so it rises later each day: one rise every
## cycle / (cycle - 1) days.
func test_moon_rises_later_each_day() -> void:
	var world := _make_world()
	var step := SimConst.DAY_LENGTH_S / 2000.0
	var rises: Array[float] = []
	var was_up := true   # Don't count a moon already up at the start
	var t := 0.0
	while t < 4.0 * SimConst.DAY_LENGTH_S and rises.size() < 3:
		world.time_s = t
		world.refresh_environment()
		if world.moon_is_up and not was_up:
			rises.append(t)
		was_up = world.moon_is_up
		t += step
	check_eq(rises.size(), 3, "three moonrises")
	var cycle := SimConst.MOON_CYCLE_DAYS
	var expected := SimConst.DAY_LENGTH_S * cycle / (cycle - 1.0)
	for k in rises.size() - 1:
		check_near(rises[k + 1] - rises[k], expected, 2.0 * step, "moonrise to moonrise")


## At night the moon is the traced light: from its direction, at about MOON_FULL_RATIO of
## sunlight times the lit fraction cubed (less what the atmosphere takes). With the moon
## set, nothing is traced.
func test_moon_is_the_light_at_night() -> void:
	var world := _make_world()
	world.time_s = 1.0 * SimConst.DAY_LENGTH_S   # Midnight, moon a little past full and high
	world.refresh_environment()
	check(not world.sun_is_up and world.moon_is_up, "moon up at midnight")
	check(world.light_is_moon and world.light_is_up, "moon is the traced light")
	check(world.light_direction.is_equal_approx(world.moon_direction), "light comes from the moon")
	check(world.moon_illuminated > 0.9, "nearly full (%.2f lit)" % world.moon_illuminated)
	var top := SimConst.SOLAR_CONSTANT * SimConst.MOON_FULL_RATIO * pow(world.moon_illuminated, 3.0)
	check(world.light_dni < top and world.light_dni > 0.4 * top,
		"moonlight %s W/m² (above the atmosphere %s)" % [String.num_scientific(world.light_dni), String.num_scientific(top)])
	var am := EnvironmentSystem.air_mass_at(world.moon_elevation)
	var sun := Spectrum.atmospheric(am)
	var moon := world.moon_spectrum
	check(moon[Spectrum.Bin.RED] / moon[Spectrum.Bin.BLUE] > 1.3 * sun[Spectrum.Bin.RED] / sun[Spectrum.Bin.BLUE],
		"moonlight is redder than sunlight through the same air")
	world.time_s = 4.0 * SimConst.DAY_LENGTH_S   # Midnight near new moon: moon down
	world.refresh_environment()
	check(not world.moon_is_up and not world.light_is_up, "no light with the moon set")


## Objects can't overlap each other or solid ground (Placement): placing or moving into
## occupied space is refused and the object stays put; a drag that ends blocked still
## undoes in one step.
func test_objects_cannot_overlap() -> void:
	var world := _make_world()
	var lens := LENS_CROWN
	var sky := Mounting.ground_y(world, 16, 0.0) - 2.0
	world.enqueue(PlaceObjectCommand.new(lens, Vector2(4.0, sky)))
	world.enqueue(PlaceObjectCommand.new(lens, Vector2(4.0, sky)))          # On top: refused
	world.enqueue(PlaceObjectCommand.new(lens, Vector2(4.6, sky + 0.05)))   # Edges cross: refused
	world.enqueue(PlaceObjectCommand.new(lens, Vector2(6.0, sky)))
	world.flush_commands()
	check_eq(world.objects.size(), 2, "two of four placements fit")
	var ids := world.objects.keys()
	var a: SimObject = world.objects[ids[0]]
	var b: SimObject = world.objects[ids[1]]
	world.enqueue(TransformObjectCommand.new(b.id, a.position + Vector2(0.3, 0.0), b.angle, false))
	world.enqueue(TransformObjectCommand.new(a.id, Vector2(4.0, Mounting.ground_y(world, 16, 0.0)), a.angle, false))
	world.flush_commands()
	check_eq(b.position, Vector2(6.0, sky), "moving into another lens is refused")
	check_eq(a.position, Vector2(4.0, sky), "moving into the ground is refused")
	# A drag: one allowed step, one blocked, then finish records the move once.
	world.enqueue(TransformObjectCommand.new(b.id, Vector2(5.5, sky), b.angle, false))
	world.enqueue(TransformObjectCommand.new(b.id, Vector2(4.5, sky), b.angle, false))
	world.enqueue(TransformObjectCommand.finish(b.id, Vector2(6.0, sky), b.angle))
	world.flush_commands()
	check_eq(b.position, Vector2(5.5, sky), "a drag stops at the last free spot")
	world.undo_last()
	check_eq(b.position, Vector2(6.0, sky), "one undo returns to the drag's start")


func test_paint_command_applies_and_undoes() -> void:
	var world := _make_world()
	var g := world.grid
	var i := g.idx(5, 2)
	var before := g.material[i]
	var steel := world.materials.id_of(&"steel")
	world.enqueue(PaintTilesCommand.new(PackedInt32Array([i]), steel))
	world.tick()
	check_eq(g.material[i], steel, "painted")
	world.enqueue(UndoCommand.new())
	world.tick()
	check_eq(g.material[i], before, "undone")


func test_same_seed_and_commands_are_deterministic() -> void:
	var a := _make_world(42)
	var b := _make_world(42)
	var copper := a.materials.id_of(&"copper")
	for w in [a, b]:
		w.enqueue(PaintTilesCommand.new(PackedInt32Array([10, 11, 12]), copper, 500.0))
		for i in 100:
			w.tick()
	check_eq(a.state_hash(), b.state_hash(), "state hash")
	check(a.state_hash() != _make_world(43).state_hash(), "different seed differs")


## Mounted objects stand on stands (Mounting): centered in their tile column, at a height above
## the ground in tile steps (clamped to the stand's range), and stay snapped when dragged.
## Surface cells lie flat on the ground.
func test_stands_snap_to_columns_and_heights() -> void:
	var world := _make_world()
	var lens := LENS_CROWN
	var ground := Mounting.ground_y(world, 16, 0.0)   # Column 16: x 4.0-4.25 m
	world.enqueue(PlaceObjectCommand.new(lens, Vector2(4.07, ground - 2.13), 0.0, true))
	world.flush_commands()
	var a: SimObject = world.objects[world.next_object_id - 1]
	check(a.mounted, "mounted")
	check_eq(a.position, Vector2(4.125, ground - 2.25), "column center, 2.25 m up")
	var far := Mounting.ground_y(world, 40, 0.0)
	world.enqueue(PlaceObjectCommand.new(lens, Vector2(10.1, far - 20.0), 0.0, true))
	world.flush_commands()
	check_eq(world.objects[world.next_object_id - 1].position.y, far - Mounting.MAX_HEIGHT_M, "tallest stand")
	world.enqueue(TransformObjectCommand.new(a.id, Vector2(5.01, Mounting.ground_y(world, 20, 0.0) - 1.4), 0.3))
	world.flush_commands()
	check_eq(a.position, Vector2(5.125, Mounting.ground_y(world, 20, 0.0) - 1.5), "dragged: snapped again")
	check_near(a.angle, 0.3, 1e-6, "tilt stays free")
	var cell: ObjectDef = load("res://data/objects/cell_si_surface.tres")
	var g30 := Mounting.ground_y(world, 30, 0.0)
	world.enqueue(PlaceObjectCommand.new(cell, Vector2(7.6, g30 - 3.0), 0.5, true))
	world.flush_commands()
	var c: SimObject = world.objects[world.next_object_id - 1]
	check_eq(c.position, Vector2(7.625, g30 - Mounting.GROUND_LIFT_M), "surface cell on the ground")
	check_eq(c.angle, 0.0, "lying flat")


## Outside creative mode everything but probes must be mounted.
func test_floating_needs_creative() -> void:
	var world := _make_world()
	world.creative = false
	var lens := LENS_CROWN
	var probe := PROBE
	var sky := Mounting.ground_y(world, 16, 0.0) - 2.0
	world.enqueue(PlaceObjectCommand.new(lens, Vector2(4.0, sky)))
	world.enqueue(PlaceObjectCommand.new(probe, Vector2(8.0, sky)))
	world.enqueue(PlaceObjectCommand.new(lens, Vector2(12.0, sky), 0.0, true))
	world.flush_commands()
	var keys: Array[StringName] = []
	for obj: SimObject in world.objects.values():
		keys.append(obj.def.key)
	check_eq(keys, [&"probe", &"lens_crown"] as Array[StringName], "floating lens refused")


## A saved site (SiteSave) comes back the same: objects with their transforms and mounting,
## wire, painted terrain, clock and money; a save for another site size is refused.
func test_site_save_round_trip() -> void:
	var world := _make_world()
	var g := world.grid
	world.enqueue(PlaceObjectCommand.new(LENS_CROWN, Vector2(4.07, Mounting.ground_y(world, 16, 0.0) - 2.1), 0.3, true))
	world.enqueue(PlaceObjectCommand.new(PROBE, Vector2(9.0, 2.0)))
	world.enqueue(PaintWiresCommand.new(PackedInt32Array([g.idx(3, 4), g.idx(4, 4)])))
	world.enqueue(PaintTilesCommand.new(PackedInt32Array([g.idx(10, 2)]), world.materials.id_of(&"copper")))
	world.flush_commands()
	world.money = 12.5
	world.time_s = 1234.5
	var data := JSON.parse_string(SiteSave.to_text(world)) as Dictionary
	var db := ObjectDB.new()
	db.load_dir()
	var back := _make_world()
	check_eq(SiteSave.restore(back, data, db), "", "restored")
	check_eq(back.grid.material, g.material, "terrain")
	check_eq(back.grid.wire, g.wire, "wire")
	check_eq(back.money, 12.5, "money")
	check_eq(back.time_s, 1234.5, "clock")
	check_eq(back.objects.size(), 2, "objects")
	for id in world.objects:
		var a: SimObject = world.objects[id]
		var b: SimObject = back.objects[id]
		check_eq([b.def.key, b.position, b.angle, b.mounted], [a.def.key, a.position, a.angle, a.mounted], "object %d" % id)
	var small := SimWorld.new(load_materials(), 16, 16, 1)
	check(SiteSave.restore(small, data, db) != "", "other site size refused")


## A gesture undoes as one: the wire laid by a whole stroke goes with one undo, while commands
## outside any group undo one at a time.
func test_undo_takes_a_whole_stroke() -> void:
	var world := SimWorld.new(load_materials(), 16, 8, 1)
	var g := world.grid
	var stroke := SimCommand.new_group()
	for x in [2, 3, 4]:
		var cmd := PaintWiresCommand.new(PackedInt32Array([g.idx(x, 2)]))
		cmd.group = stroke
		world.enqueue(cmd)
	world.enqueue(PaintWiresCommand.new(PackedInt32Array([g.idx(8, 2)])))
	world.flush_commands()
	world.enqueue(UndoCommand.new())
	world.flush_commands()
	check_eq(g.wire[g.idx(8, 2)], 0, "the ungrouped tile went with one undo")
	check_eq(g.wire[g.idx(3, 2)], 1, "the stroke is still there")
	world.enqueue(UndoCommand.new())
	world.flush_commands()
	check_eq(g.wire[g.idx(2, 2)] + g.wire[g.idx(3, 2)] + g.wire[g.idx(4, 2)], 0, "one undo takes the whole stroke")


## What can't turn stays level: surface cells, batteries and grid connections; lamps, lenses and
## panels turn.
func test_only_some_objects_rotate() -> void:
	var db := ObjectDB.new()
	db.load_dir()
	for key in [&"cell_si_surface", &"battery", &"grid_tie"]:
		check(not db.get_by_key(key).can_rotate(), "%s stays level" % key)
		check_eq(Mounting.snap_angle(db.get_by_key(key), 0.7), 0.0, "%s snaps level" % key)
	for key in [&"lamp_led", &"lens_crown", &"cell_si", &"mirror_aluminum"]:
		check(db.get_by_key(key).can_rotate(), "%s turns" % key)
