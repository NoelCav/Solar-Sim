extends TestSuite
## Shared by the optics test files: small worlds and objects to trace.


## An all-air world with the given objects, sun off so only test rays are traced.
func _make_world(w: int = 80, h: int = 80) -> SimWorld:
	return SimWorld.new(load_materials(), w, h, 1)


func _place(world: SimWorld, def: ObjectDef, pos: Vector2, angle: float = 0.0) -> SimObject:
	world.enqueue(PlaceObjectCommand.new(def, pos, angle))
	world.flush_commands()
	return world.objects[world.next_object_id - 1]


func _single_bin(bin: int, watts: float) -> PackedFloat32Array:
	var p := Spectrum.make_zero()
	p[bin] = watts
	return p


func _lens_def(r1: float, r2: float, t: float, d: float = 1.0) -> ObjectDef:
	var def := ObjectDef.new()
	def.key = &"test_lens"
	def.kind = ObjectDef.Kind.LENS
	def.material = &"crown_glass"
	def.size_m = d
	def.radius_front_m = r1
	def.radius_back_m = r2
	def.thickness_m = t
	def.arc_segments = 256
	return def


func _flat_world(w: int = 40, h: int = 20, ground_row: int = 15) -> SimWorld:
	var world := SimWorld.new(load_materials(), w, h, 1)
	var g := world.grid
	var stone := world.materials.id_of(&"stone")
	for y in range(ground_row, h):
		for x in w:
			g.material[g.idx(x, y)] = stone
	g.mark_structure_changed()
	return world


## Every emitted watt is absorbed, escapes, scatters or is culled, and culling stays small.
func _check_energy_balance(s: Dictionary) -> void:
	var out: float = s.absorbed + s.escaped + s.scattered + s.culled
	check(s.emitted > 0.0, "light emitted")
	check_near(out / s.emitted, 1.0, 1e-4, "energy balance")
	check(s.culled < 0.02 * s.emitted, "culling stays small (%.2f%%)" % [100.0 * s.culled / s.emitted])


## The tracer of `world`'s sky pass, set up on the current geometry with its results cleared.
func _tracer(world: SimWorld) -> LightEngine:
	var light: LightSystem = world.get_system(&"light")
	light.retrace(world)   # Builds surfaces + buckets
	light.tracer().Begin()
	return light.tracer()


func _probe_def(length: float) -> ObjectDef:
	var def := ObjectDef.new()
	def.key = &"test_probe"
	def.kind = ObjectDef.Kind.PROBE
	def.size_m = length
	return def
