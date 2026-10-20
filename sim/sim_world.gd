class_name SimWorld
extends RefCounted
## Owns all simulation state and steps it at a fixed rate (design doc §5).
## Pure data: no Node dependencies, so it runs headless for tests (D5).

const MAX_HISTORY := 200

var materials: MaterialDB
var grid: TileGrid
var skin := SurfaceSkin.new()       ## Surfaces of solids: light lands and heat leaves here (D18)
var seed_value: int

var tick_count: int = 0
var time_s: float = 0.0                 ## Sim seconds since world start

# Environment state (written by EnvironmentSystem)
var ambient_k: float = SimConst.DEFAULT_AMBIENT_K
var sun_arc_angle: float = 0.0          ## Position on its arc: 0 rising (east), PI/2 overhead, PI setting
var sun_direction := Vector2.DOWN       ## Direction light travels, y down
var sun_elevation: float = 0.0          ## Radians above horizon
var sun_is_up := false
var air_mass: float = INF
var sun_dni: float = 0.0                ## Direct normal irradiance, W/m²
var sun_spectrum := Spectrum.make_zero()   ## DNI per spectral bin, W/m²
var diffuse_irradiance: float = 0.0     ## Diffuse sky light on horizontal surfaces, W/m²
var moon_phase: float = 0.0             ## 0 new, 0.5 full (moon cycle, §6.2)
var moon_illuminated: float = 0.0       ## Lit fraction of the disk
var moon_arc_angle: float = 0.0         ## Position on its arc, as sun_arc_angle
var moon_direction := Vector2.DOWN      ## Direction moonlight travels, y down
var moon_elevation: float = 0.0         ## Radians above horizon
var moon_is_up := false
var moon_dni: float = 0.0               ## Direct normal irradiance of moonlight, W/m²
var moon_spectrum := Spectrum.make_zero()
## The light the light system traces: the sun when it is up, else the moon.
var light_is_moon := false
var light_is_up := false
var light_direction := Vector2.DOWN
var light_dni: float = 0.0
var light_spectrum := Spectrum.make_zero()

# Site parameters
var site_max_elevation_deg: float = 60.0
var site_mean_ambient_k: float = SimConst.DEFAULT_AMBIENT_K

## Placed objects by id, in placement order. Mutate only through commands (D6).
var objects: Dictionary[int, SimObject] = {}
var objects_version: int = 0            ## Bumped whenever objects are added, removed or moved
## Creative mode: objects may float off their stands (Mounting). On while the game is tested.
var creative := true
var money := 0.0                        ## $, earned by selling power (PowerSystem, Market)
var next_object_id: int = 1

## Systems in tick order (§5.3). Later milestones insert objects, power, pipes,
## liquid, gas and damage systems.
var systems: Array[SimSystem] = []

var _queue: Array[SimCommand] = []
var _history: Array[SimCommand] = []


func _init(p_materials: MaterialDB, width: int, height: int, p_seed: int = 1) -> void:
	materials = p_materials
	seed_value = p_seed
	grid = TileGrid.new(width, height, site_mean_ambient_k)
	time_s = SimConst.START_TIME_OF_DAY * SimConst.DAY_LENGTH_S
	systems = [EnvironmentSystem.new(), LightSystem.new(), PowerSystem.new(), ThermalSystem.new()]
	refresh_environment()


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


## Undoes the last command, and with it the rest of its gesture (commands of the same group).
func undo_last() -> void:
	if _history.is_empty():
		return
	var cmd: SimCommand = _history.pop_back()
	cmd.undo(self)
	while cmd.group != 0 and not _history.is_empty() and _history.back().group == cmd.group:
		_history.pop_back().undo(self)


## Advances the simulation by one fixed tick.
func tick() -> void:
	flush_commands()
	for system in systems:
		system.tick(self, SimConst.DT)
	tick_count += 1
	time_s += SimConst.DT


func get_system(system_name: StringName) -> SimSystem:
	for system in systems:
		if system.system_name() == system_name:
			return system
	return null


## Low-level object insertion; callers outside the sim go through commands (D6).
func add_object(obj: SimObject) -> void:
	objects[obj.id] = obj
	next_object_id = maxi(next_object_id, obj.id + 1)
	objects_version += 1


func remove_object(id: int) -> SimObject:
	var obj: SimObject = objects.get(id)
	if obj != null:
		objects.erase(id)
		objects_version += 1
	return obj


## Moves/rotates an object.
func set_object_transform(id: int, position: Vector2, angle: float) -> void:
	var obj: SimObject = objects.get(id)
	if obj == null:
		return
	obj.position = position
	obj.angle = angle
	objects_version += 1


## Content hash over all persistent state, used by determinism tests and desync checks.
func state_hash() -> int:
	var objs := []
	for obj: SimObject in objects.values():
		objs.append([obj.id, obj.def.key, obj.position, obj.angle])
	return hash([grid.state_hash(), objs])


## Recomputes sun and ambient for the current time without advancing it (setup, time skips).
func refresh_environment() -> void:
	var env := get_system(&"environment")
	if env != null:
		env.tick(self, 0.0)
