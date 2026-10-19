class_name Main
extends Node2D
## Entry point: builds the sim, steps it at a fixed rate, and wires up the views.

const WORLD_WIDTH := 300
const WORLD_HEIGHT := 120
const SPEEDS: Array[int] = [1, 2, 4, 8, 16]

@export var world_seed := 1
@export var place_demo_rig := true

var world: SimWorld
var object_db: ObjectDB   ## Placeable object definitions
var paused := false
var speed := 1

var sim_ms := 0.0         ## Smoothed CPU time spent stepping the sim per frame
var view := ViewMode.NORMAL
var wavelength := -1      ## Wavelength filter: one spectral bin, or -1 for all

var _accumulator := 0.0
var _light: LightSystem
var _previewed := Vector3(-1, -1, -1)   ## Structure, objects, time of the last paused preview

@onready var _sky: SkyRenderer = $Sky
@onready var _tiles: TileRenderer = $Tiles
@onready var _objects: ObjectRenderer = $Objects
@onready var _beams: BeamRenderer = $Beams
@onready var _overlay: OverlayRenderer = $Overlay
@onready var _brush: CreativeBrush = $Brush
@onready var _tool: ObjectTool = $ObjectTool
@onready var _camera: CameraController = $Camera
@onready var _markers: MapMarkers = $Markers
@onready var _hud: Hud = $HudLayer/Hud


func _ready() -> void:
	InputSetup.ensure_defaults()
	var materials := MaterialDB.new()
	var err := materials.load_dir()
	if err != "":
		push_error("Material load failed: " + err)
		return
	object_db = ObjectDB.new()
	err = object_db.load_dir()
	if err != "":
		push_error("Object load failed: " + err)
		return
	world = SimWorld.new(materials, WORLD_WIDTH, WORLD_HEIGHT, world_seed)
	WorldGen.generate(world)
	if place_demo_rig:
		DemoRig.place(world, object_db)
	_light = world.get_system(&"light")
	_light.retrace(world)

	_sky.setup(world)
	var backdrop := BackdropRenderer.new()
	add_child(backdrop)
	move_child(backdrop, _sky.get_index() + 1)
	backdrop.setup(world)
	_tiles.setup(world)
	_tiles.lit_materials.append(backdrop.material as ShaderMaterial)
	_tiles.dimmed[backdrop.outside] = 0.0
	_tiles.dimmed[_objects] = 0.12   # Objects stay faintly visible to edit in the dark
	_objects.setup(world)
	_beams.setup(world)
	_overlay.setup(world)
	_objects.overlay = _overlay
	_brush.setup(world)
	_tool.setup(world, object_db, _brush, _objects)
	_markers.setup(world, _overlay)
	_hud.setup(world, self, _brush, _tool, _overlay)
	_camera.position = Vector2(WORLD_WIDTH * 0.5, WORLD_HEIGHT * WorldGen.SURFACE_FRACTION - 8.0) * SimConst.TILE_PX
	_camera.zoom = Vector2.ONE * 1.5


func _process(delta: float) -> void:
	if world == null:
		return
	if paused:
		world.flush_commands()
		_accumulator = 0.0
		# Show edits made while paused without advancing the sim.
		var key := Vector3(world.grid.structure_version, world.objects_version, world.time_s)
		if key != _previewed and _light.is_stale(world):
			_light.preview(world)
			_previewed = key
		return
	var start := Time.get_ticks_usec()
	_accumulator += delta * speed
	var steps := 0
	while _accumulator >= SimConst.DT and steps < SimConst.MAX_TICKS_PER_FRAME * speed:
		world.tick()
		_accumulator -= SimConst.DT
		steps += 1
	if steps == SimConst.MAX_TICKS_PER_FRAME * speed:
		_accumulator = 0.0  # Too far behind; drop time rather than spiral.
	sim_ms = lerpf(sim_ms, (Time.get_ticks_usec() - start) / 1000.0, 0.1)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"sim_pause"):
		toggle_pause()
	elif event.is_action_pressed(&"sim_speed"):
		cycle_speed()
	elif event.is_action_pressed(&"overlay_cycle"):
		set_view((view + 1) % ViewMode.COUNT)
	elif event.is_action_pressed(&"wavelength_next"):
		set_wavelength(wavelength + 1 if wavelength < Spectrum.BIN_COUNT - 1 else -1)
	elif event.is_action_pressed(&"wavelength_prev"):
		set_wavelength(wavelength - 1 if wavelength >= 0 else Spectrum.BIN_COUNT - 1)
	elif event.is_action_pressed(&"time_forward"):
		skip_hours(6.0 if Input.is_key_pressed(KEY_SHIFT) else 1.0)
	elif event.is_action_pressed(&"time_back"):
		skip_hours(-6.0 if Input.is_key_pressed(KEY_SHIFT) else -1.0)


## Switches what the beams, tile overlay and markers show (ViewMode).
func set_view(v: int) -> void:
	view = v
	_beams.view = v
	_overlay.view = v
	_markers.view = v
	_objects.view = v
	_hud.refresh_view()


## Narrows the beams and tile overlay to one spectral bin (-1 = all).
func set_wavelength(bin: int) -> void:
	wavelength = bin
	_beams.wavelength = bin
	_overlay.wavelength = bin
	_hud.refresh_view()


func toggle_pause() -> void:
	paused = not paused
	invalidate_preview()


## Makes the paused view trace a fresh preview next frame (after something else used it).
func invalidate_preview() -> void:
	_previewed = Vector3(-1, -1, -1)


func cycle_speed() -> void:
	set_speed(SPEEDS[(SPEEDS.find(speed) + 1) % SPEEDS.size()])


## Runs at one of SPEEDS, unpausing.
func set_speed(n: int) -> void:
	speed = n
	if paused:
		toggle_pause()


## Moves the clock by whole hours (the sun follows even while paused).
func skip_hours(hours: float) -> void:
	world.enqueue(SetTimeCommand.new(world.time_s + hours * SimConst.DAY_LENGTH_S / 24.0))
