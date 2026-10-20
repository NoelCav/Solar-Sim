class_name PowerSystem
extends SimSystem
## Electrical networks (§10, D14): wire tiles joined into networks (ConduitNetworks); objects
## join the network at their port (Mounting.port_tiles). Each tick, on every network with a
## grid connection, each cell delivers what it can make now (SolarCell) and the network sells
## it at the market price (Market). Delivered energy leaves the cell's heat (D13): light in =
## heat + electricity. A network with no grid connection draws nothing (cells sit at open
## circuit and all their light is heat). Runs after the light system and before heat.

var networks := ConduitNetworks.new()
var network_grid := PackedByteArray()          ## Per network: 1 if a grid connection is on it

var _cells := []                               ## Per network: ids of the cells on it
var _members_key := Vector2i(-1, -1)           ## (networks.version, objects_version) of _cells


func system_name() -> StringName:
	return &"power"


func tick(world: SimWorld, dt: float) -> void:
	sync(world)
	var light: LightSystem = world.get_system(&"light")
	var scale := light.power_scale(world)
	for obj: SimObject in world.objects.values():
		obj.power_w = 0.0
	for n in networks.count:
		if network_grid[n] == 0:
			continue
		var total := 0.0
		for id: int in _cells[n]:
			var obj: SimObject = world.objects[id]
			obj.power_w = SolarCell.object_power(obj, scale)
			obj.heat_in -= obj.power_w * dt
			total += obj.power_w
		world.money += Market.earnings(world, total, dt)


## What network n delivers now, W (0 without a grid connection). Read from the light now, as
## the next tick will, so it is right while paused too.
func output_w(world: SimWorld, n: int) -> float:
	sync(world)
	if n < 0 or n >= networks.count or network_grid[n] == 0:
		return 0.0
	var light: LightSystem = world.get_system(&"light")
	var total := 0.0
	for id: int in _cells[n]:
		total += SolarCell.object_power(world.objects[id], light.power_scale(world))
	return total


## The rated power of the cells on network n, W (SolarCell.rated_power summed; 0 without one).
func rated_w(world: SimWorld, n: int) -> float:
	sync(world)
	if n < 0 or n >= networks.count:
		return 0.0
	var total := 0.0
	for id: int in _cells[n]:
		total += SolarCell.rated_power(world.objects[id].def)
	return total


## Brings the networks and who is on them up to date with the wires and objects (also while
## paused, for the inspector).
func sync(world: SimWorld) -> void:
	networks.sync(world.grid, world.grid.wire)
	if _members_key != Vector2i(networks.version, world.objects_version):
		_rebuild_members(world)


## Whether `obj` is on a network with a grid connection (a cell there delivers what it makes).
func sells(world: SimWorld, obj: SimObject) -> bool:
	sync(world)
	var n := network_of(world, obj)
	return n >= 0 and network_grid[n] == 1


## The network object `obj` is connected to, or -1.
func network_of(world: SimWorld, obj: SimObject) -> int:
	networks.sync(world.grid, world.grid.wire)
	for i in Mounting.port_tiles(world, obj):
		if networks.at(i) >= 0:
			return networks.at(i)
	return -1


func _rebuild_members(world: SimWorld) -> void:
	_cells.clear()
	for n in networks.count:
		_cells.append([])
	network_grid.resize(networks.count)
	network_grid.fill(0)
	for obj: SimObject in world.objects.values():
		var n := network_of(world, obj)
		if n < 0:
			continue
		if obj.def.kind == ObjectDef.Kind.CELL:
			_cells[n].append(obj.id)
		elif obj.def.kind == ObjectDef.Kind.GRID_TIE:
			network_grid[n] = 1
	_members_key = Vector2i(networks.version, world.objects_version)
