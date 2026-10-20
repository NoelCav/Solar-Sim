class_name Scenarios
extends RefCounted
## Named, deterministic sites built on fresh terrain (WorldGen): the demo a new game starts
## with, and test sites that each stress one part of the sim. The benchmark (tests/bench.gd)
## and the running game (SimProbe `site`, the top bar's Site menu) load exactly the same thing.
## Built through commands (D6), like the player would; each sets its clock to its start hour.
## Positions are meters from the middle of the site; heights are above the ground there.

## name → start hour (of game day 0), what it is for, and the hours the benchmark measures;
## `symmetric_about` (m from the middle): a rig the benchmark checks for mirror symmetry at noon.
const LIST := {
	"demo": {"hour": 7.2, "bench": [9.0, 12.0],
		"about": "The starter rig: lenses, a prism, a mirror, a probe, a cell selling to the grid"},
	"lens_field": {"hour": 9.0, "bench": [9.0, 12.0],
		"about": "30 identical lenses in a row: lots of beams, the object cache, many focal spots"},
	"power_farm": {"hour": 12.0, "bench": [12.0, 17.5],
		"about": "Ten panels, six surface cells (four under lenses: ~3× sun), an open cell, batteries, "
			+ "a network without a grid"},
	"optics_mix": {"hour": 10.5, "bench": [10.5, 15.0],
		"about": "Prism rainbow, a mirror chain, glass blocks, a water pool under a lens, a burning focus"},
	"lamp_lab": {"hour": 22.0, "bench": [22.0, 12.0],
		"about": "Lamps: one in the open, one over a cell panel, a spot lamp at a lens's focus over a surface cell "
			+ "(a collimated beam), a spot lamp aimed along the ground"},
	"night": {"hour": -1.0, "bench": [],
		"about": "The demo by moonlight: the dimmest light the engine traces (start hour: brightest moon)"},
	"dug_terrain": {"hour": 9.0, "bench": [9.0],
		"about": "Pits, tunnels and floating blocks under lenses: many lit faces for the sun map and the skin"},
	"edge_optics": {"hour": 12.0, "bench": [12.0, 9.0], "symmetric_about": -24.0,
		"about": "Awkward optics on flat ground: lenses in series, a mirror V, light sent back up through a "
			+ "lens, a prism by a glass block, a half-shaded lens, a lens in water, a probe in a focal cone, "
			+ "grazing angles"},
}

## The demo rig: [object key, x from the middle (m), height (m), angle (deg)], and a wire run.
const DEMO := [
	[&"lens_crown", -5.0, 3.5, 0.0],
	[&"probe", -5.0, 2.4, 0.0],
	[&"prism_flint", -1.0, 2.0, 0.0],
	[&"mirror_aluminum", 3.0, 1.5, 30.0],
	[&"lens_acrylic", 8.0, 5.0, 0.0],
	[&"cell_si", 12.0, 1.0, 0.0],
	[&"grid_tie", 14.0, 0.0, 0.0],
]
const DEMO_WIRE := [12.0, 14.0]


static func names() -> Array:
	return LIST.keys()


## Builds scenario `name` on `world` (freshly made and generated). Returns "" or why not.
static func build(world: SimWorld, objects: ObjectDB, name: String) -> String:
	if not LIST.has(name):
		return "no scenario '%s' (have: %s)" % [name, ", ".join(names())]
	match name:
		"demo":
			_demo(world, objects)
		"lens_field":
			for k in 30:
				_put(world, objects, &"lens_crown", 8.0 + k * 2.0 - _middle(world), 3.0)
		"power_farm":
			_power_farm(world, objects)
		"optics_mix":
			_optics_mix(world, objects)
		"lamp_lab":
			_lamp_lab(world, objects)
		"night":
			_demo(world, objects)
		"dug_terrain":
			_dug_terrain(world, objects)
		"edge_optics":
			_edge_optics(world, objects)
	world.flush_commands()
	var hour: float = LIST[name].hour
	world.time_s = (hour if hour >= 0.0 else _brightest_moon(world)) / 24.0 * SimConst.DAY_LENGTH_S
	world.refresh_environment()
	return ""


static func _demo(world: SimWorld, objects: ObjectDB) -> void:
	for e: Array in DEMO:
		_put(world, objects, e[0], e[1], e[2], e[3])
	_wire(world, DEMO_WIRE[0], DEMO_WIRE[1])


## Ten panels at 1.5 m; six surface cells on the ground, the first four under crown lenses at
## 85 % of their focal length (the 1 m lens's light on a 25 cm cell: about 3× sun, hot); all wired
## to one grid connection. Beyond the wire: a panel with no wire (open circuit) and a panel wired
## to a battery with no grid connection. A battery also sits on the main network.
static func _power_farm(world: SimWorld, objects: ObjectDB) -> void:
	var lens := objects.get_by_key(&"lens_crown")
	var glass := world.materials.get_by_key(lens.material)
	var f := OpticsGen.focal_length(lens.size_m, lens.radius_front_m, lens.radius_back_m, lens.thickness_m,
		glass.refractive_index(0.55))
	_put(world, objects, &"grid_tie", -14.0, 0.0)
	for k in 10:
		_put(world, objects, &"cell_si", -12.0 + k * 1.5, 1.5)
	for k in 6:
		var x := 4.0 + k * 1.25
		_put(world, objects, &"cell_si_surface", x, 0.0)
		if k < 4:
			_put(world, objects, &"lens_crown", x, 0.85 * f)
	_wire(world, -14.0, 10.5)
	_put(world, objects, &"cell_si", 13.0, 1.5)
	_put(world, objects, &"cell_si", 16.0, 1.5)
	_put(world, objects, &"battery", 18.0, 0.0)
	_wire(world, 16.0, 18.0)
	_put(world, objects, &"battery", -11.0, 0.0)


## Lamps (design §6.11): an LED lamp over open ground; one over a cell panel; a spot lamp at the
## front focal point of a crown lens, over a surface cell (the lens makes the beam parallel); a spot
## lamp lying on its side, lighting along the ground.
static func _lamp_lab(world: SimWorld, objects: ObjectDB) -> void:
	var lens := objects.get_by_key(&"lens_crown")
	var glass := world.materials.get_by_key(lens.material)
	var f := OpticsGen.focal_length(lens.size_m, lens.radius_front_m, lens.radius_back_m, lens.thickness_m,
		glass.refractive_index(0.55))
	_put(world, objects, &"lamp_led", -12.0, 3.0)
	_put(world, objects, &"lamp_led", -6.0, 2.5)
	_put(world, objects, &"cell_si", -6.0, 1.0)
	_put(world, objects, &"lens_crown", 2.0, 2.0)
	_put(world, objects, &"lamp_spot", 2.0, 2.0 + f + 0.1)
	_put(world, objects, &"cell_si_surface", 2.0, 0.0)
	_put(world, objects, &"lamp_spot", 8.0, 0.75, 90.0)


static func _optics_mix(world: SimWorld, objects: ObjectDB) -> void:
	_put(world, objects, &"prism_flint", -10.0, 2.5)
	_put(world, objects, &"probe", -10.0, 1.0)
	_put(world, objects, &"mirror_aluminum", -5.0, 2.0, 30.0)
	_put(world, objects, &"mirror_aluminum", -2.0, 3.5, -20.0)
	_put(world, objects, &"lens_acrylic", 3.0, 5.0)
	# A crown-glass block standing on the ground, and a water pool dug into it under a lens.
	var c := _column(world, 7.0)
	var top := _ground_row(world, c)
	_paint_rect(world, &"crown_glass", c, top - 3, c + 5, top - 1)
	c = _column(world, 12.0)
	top = _ground_row(world, c)
	_paint_rect(world, &"water", c, top, c + 7, top + 1)
	_put(world, objects, &"lens_crown", 13.0, 4.0)


## Pits every few meters, a tunnel with a roof, floating stone blocks, and lenses above them.
static func _dug_terrain(world: SimWorld, objects: ObjectDB) -> void:
	var g := world.grid
	for c in range(10, g.width - 10, 9):
		var top := _ground_row(world, c)
		_paint_rect(world, &"air", c, top, c + 1, top + 3)
	var t := _column(world, -6.0)
	var roof := _ground_row(world, t) + 2
	_paint_rect(world, &"air", t, roof, t + 24, roof + 1)
	for k in 6:
		var b := _column(world, -20.0 + k * 7.0)
		var r := _ground_row(world, b) - 10
		_paint_rect(world, &"stone", b, r, b + 2, r + 1)
	for k in 8:
		_put(world, objects, &"lens_crown", -18.0 + k * 5.0, 4.5)


## Optical setups where tracing bugs have hidden, on a flat platform so results are easy to
## reason about (and the first rig is mirror-symmetric at noon).
static func _edge_optics(world: SimWorld, objects: ObjectDB) -> void:
	var row := _ground_row(world, _column(world, 0.0))
	var c0 := _column(world, -32.0)
	var c1 := _column(world, 34.0)
	_paint_rect(world, &"air", c0, 0, c1, row - 1)
	_paint_rect(world, &"stone", c0, row, c1, row + 3)
	_put(world, objects, &"lens_crown", -24.0, 1.2)                # Symmetric: focus on the ground
	_put(world, objects, &"lens_crown", -16.0, 3.2)                # Two lenses in series
	_put(world, objects, &"lens_crown", -16.0, 1.8)
	_put(world, objects, &"mirror_aluminum", -9.5, 1.5, 45.0)      # A mirror V: light bounces between
	_put(world, objects, &"mirror_aluminum", -8.5, 1.5, -45.0)
	_put(world, objects, &"lens_crown", -2.0, 2.5)                 # A flat mirror under a lens sends
	_put(world, objects, &"mirror_aluminum", -2.0, 1.3)            # the light back up through it
	_put(world, objects, &"prism_flint", 3.0, 1.0)                 # Rainbow into a glass block
	var g := _column(world, 4.0)
	_paint_rect(world, &"crown_glass", g, row - 4, g + 3, row - 1)
	g = _column(world, 9.0)                                        # A lens half under an overhang
	_paint_rect(world, &"stone", g, row - 16, g + 6, row - 16)
	_put(world, objects, &"lens_crown", 11.0, 2.0)
	g = _column(world, 15.0)                                       # A lens standing in a pool
	_paint_rect(world, &"water", g, row, g + 11, row + 2)
	_put(world, objects, &"lens_crown", 16.5, 0.5)
	_put(world, objects, &"lens_crown", 22.0, 2.4)                 # A probe inside a focal cone
	_put(world, objects, &"probe", 22.0, 1.6)
	_put(world, objects, &"mirror_aluminum", 27.0, 2.0, 85.0)      # Grazing angles
	_put(world, objects, &"lens_crown", 31.0, 2.5, 80.0)


## The hour (counted from day 0, may pass 24) in the first moon cycle when moonlight is brightest.
static func _brightest_moon(world: SimWorld) -> float:
	var best := 22.0
	var best_dni := -1.0
	var day_s := SimConst.DAY_LENGTH_S
	for half_hours in int(SimConst.MOON_CYCLE_DAYS * 48):
		var hour := half_hours * 0.5
		world.time_s = hour / 24.0 * day_s
		world.refresh_environment()
		if not world.sun_is_up and world.moon_dni > best_dni:
			best_dni = world.moon_dni
			best = hour
	return best


static func _put(world: SimWorld, objects: ObjectDB, key: StringName, x: float, height: float,
		angle_deg := 0.0) -> void:
	var def := objects.get_by_key(key)
	if def == null:
		push_warning("Scenarios: unknown object '%s'" % key)
		return
	var at := _middle(world) + x
	var ground := Mounting.ground_y(world, floori(at / SimConst.TILE_M), 0.0)
	world.enqueue(PlaceObjectCommand.new(def, Vector2(at, ground - height), deg_to_rad(angle_deg), true))


## Wire along the tiles just above the ground from x0 to x1 (m from the middle), joined up and
## down where the ground steps.
static func _wire(world: SimWorld, x0: float, x1: float) -> void:
	var g := world.grid
	var cells := PackedInt32Array()
	var prev := -1
	for col in range(_column(world, x0), _column(world, x1) + 1):
		var row := _ground_row(world, col) - 1
		var from := row if prev < 0 else prev
		for r in range(mini(from, row), maxi(from, row) + 1):
			cells.append(g.idx(col, r))
		prev = row
	world.enqueue(PaintWiresCommand.new(cells))


static func _paint_rect(world: SimWorld, key: StringName, c0: int, r0: int, c1: int, r1: int) -> void:
	var g := world.grid
	var cells := PackedInt32Array()
	for r in range(r0, r1 + 1):
		for c in range(c0, c1 + 1):
			if g.in_bounds(c, r):
				cells.append(g.idx(c, r))
	world.enqueue(PaintTilesCommand.new(cells, world.materials.id_of(key)))
	world.flush_commands()   # Later placements stand on (or avoid) these tiles


static func _middle(world: SimWorld) -> float:
	return world.grid.width * SimConst.TILE_M * 0.5


static func _column(world: SimWorld, x: float) -> int:
	return floori((_middle(world) + x) / SimConst.TILE_M)


## The top solid row in column `col`.
static func _ground_row(world: SimWorld, col: int) -> int:
	return roundi(Mounting.ground_y(world, col, 0.0) / SimConst.TILE_M)
