class_name Main
extends Node2D
## Entry point: builds the sim, steps it at a fixed rate, and wires up the views.

const WORLD_WIDTH := 300
const WORLD_HEIGHT := 120
const SPEEDS: Array[int] = [1, 2, 4]

@export var world_seed := 1
@export var place_demo_rig := true

var world: SimWorld
var paused := false
var speed := 1

var sim_ms := 0.0         ## Smoothed CPU time spent stepping the sim per frame
var view := ViewMode.NORMAL

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
	var object_db := ObjectDB.new()
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
	_tiles.setup(world)
	_objects.setup(world)
	_beams.setup(world)
	_overlay.setup(world)
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
		paused = not paused
		_previewed = Vector3(-1, -1, -1)
	elif event.is_action_pressed(&"sim_speed"):
		speed = SPEEDS[(SPEEDS.find(speed) + 1) % SPEEDS.size()]
	elif event.is_action_pressed(&"overlay_cycle"):
		set_view((view + 1) % ViewMode.COUNT)
	elif event.is_action_pressed(&"time_forward") or event.is_action_pressed(&"time_back"):
		var hour := SimConst.DAY_LENGTH_S / 24.0
		var direction := 1.0 if event.is_action_pressed(&"time_forward") else -1.0
		world.enqueue(SetTimeCommand.new(world.time_s + direction * hour))


## Switches what the beams, tile overlay and markers show (ViewMode).
func set_view(v: int) -> void:
	view = v
	_beams.view = v
	_overlay.view = v
	_markers.view = v
	_hud.refresh_view()
