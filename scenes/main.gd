class_name Main
extends Node2D
## Entry point: builds the sim, steps it at a fixed rate, and wires up the views.

const WORLD_WIDTH := 300
const WORLD_HEIGHT := 120
const SPEEDS: Array[int] = [1, 2, 4]

@export var world_seed := 1

var world: SimWorld
var paused := false
var speed := 1

var _accumulator := 0.0

@onready var _sky: SkyRenderer = $Sky
@onready var _tiles: TileRenderer = $Tiles
@onready var _brush: CreativeBrush = $Brush
@onready var _camera: CameraController = $Camera
@onready var _hud: DebugHud = $HudLayer/Hud


func _ready() -> void:
	InputSetup.ensure_defaults()
	var materials := MaterialDB.new()
	var err := materials.load_dir()
	if err != "":
		push_error("Material load failed: " + err)
		return
	world = SimWorld.new(materials, WORLD_WIDTH, WORLD_HEIGHT, world_seed)
	WorldGen.generate(world)

	_sky.setup(world)
	_tiles.setup(world)
	_brush.setup(world)
	_hud.setup(world, self, _brush)
	_camera.position = Vector2(WORLD_WIDTH * 0.5, WORLD_HEIGHT * WorldGen.SURFACE_FRACTION) * SimConst.TILE_PX
	_camera.zoom = Vector2.ONE


func _process(delta: float) -> void:
	if world == null:
		return
	if paused:
		world.flush_commands()
		_accumulator = 0.0
		return
	_accumulator += delta * speed
	var steps := 0
	while _accumulator >= SimConst.DT and steps < SimConst.MAX_TICKS_PER_FRAME * speed:
		world.tick()
		_accumulator -= SimConst.DT
		steps += 1
	if steps == SimConst.MAX_TICKS_PER_FRAME * speed:
		_accumulator = 0.0  # Too far behind; drop time rather than spiral.


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(&"sim_pause"):
		paused = not paused
	elif event.is_action_pressed(&"sim_speed"):
		speed = SPEEDS[(SPEEDS.find(speed) + 1) % SPEEDS.size()]
