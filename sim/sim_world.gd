class_name SimWorld
extends RefCounted
## Owns all simulation state and steps it at a fixed rate (design doc §5).
## Pure data: no Node dependencies, so it runs headless for tests (D5).

signal ticked

var materials: MaterialDB
var grid: TileGrid
var rng := RandomNumberGenerator.new()
var seed_value: int

var tick_count: int = 0
var time_s: float = 0.0                 ## Sim seconds since world start

# Environment state (written by EnvironmentSystem)
var ambient_k: float = SimConst.DEFAULT_AMBIENT_K
var sun_direction := Vector2.DOWN       ## Direction light travels, y down
var sun_elevation: float = 0.0          ## Radians above horizon
var sun_is_up := false

# Site parameters
var site_max_elevation_deg: float = 60.0
var site_mean_ambient_k: float = SimConst.DEFAULT_AMBIENT_K

## Systems in tick order (§5.3). Later milestones append light, objects, power, pipes,
## heat, liquid, gas and damage systems here.
var systems: Array[SimSystem] = []

var _queue: Array[SimCommand] = []
var _history: Array[SimCommand] = []
const MAX_HISTORY := 200


func _init(p_materials: MaterialDB, width: int, height: int, p_seed: int = 1) -> void:
	materials = p_materials
	seed_value = p_seed
	rng.seed = p_seed
	grid = TileGrid.new(width, height, site_mean_ambient_k)
	time_s = SimConst.START_TIME_OF_DAY * SimConst.DAY_LENGTH_S
	systems = [EnvironmentSystem.new()]
	_tick_environment_only()


## 0..1 fraction of the day; 0 = midnight, 0.5 = noon.
func time_of_day() -> float:
	return fposmod(time_s / SimConst.DAY_LENGTH_S, 1.0)


func day_number() -> int:
	return int(time_s / SimConst.DAY_LENGTH_S)


func enqueue(cmd: SimCommand) -> void:
	_queue.append(cmd)


## Applies queued commands without advancing time (used while paused so edits still show).
func flush_commands() -> void:
	if _queue.is_empty():
		return
	var pending := _queue
	_queue = []
	for cmd in pending:
		if cmd.apply(self) and cmd.is_undoable():
			_history.append(cmd)
			if _history.size() > MAX_HISTORY:
				_history.pop_front()


func undo_last() -> void:
	if not _history.is_empty():
		_history.pop_back().undo(self)


func can_undo() -> bool:
	return not _history.is_empty()


## Advances the simulation by one fixed tick.
func tick() -> void:
	flush_commands()
	for system in systems:
		if system.enabled:
			system.tick(self, SimConst.DT)
	tick_count += 1
	time_s += SimConst.DT
	ticked.emit()


func get_system(system_name: StringName) -> SimSystem:
	for system in systems:
		if system.system_name() == system_name:
			return system
	return null


func _tick_environment_only() -> void:
	var env := get_system(&"environment")
	if env != null:
		env.tick(self, 0.0)
