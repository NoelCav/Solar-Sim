class_name PowerSystem
extends SimSystem
## Electrical networks (§10, D14): wire tiles joined into networks (ConduitNetworks); objects
## join the network at their port (Mounting.port_tiles). Each tick, on every network with a
## grid connection, each cell delivers what it can make now (SolarCell) and the network sells
## it at the market price (Market). Delivered energy leaves the cell's heat (D13): light in =
## heat + electricity. A network with no grid connection draws nothing (cells sit at open
## circuit and all their light is heat). Runs after the light system and before heat.

var networks := ConduitNetworks.new()
var network_power_w := PackedFloat32Array()   ## Per network: W delivered (sold) this tick
var network_grid := PackedByteArray()          ## Per network: 1 if a grid connection is on it

var _cells := []                               ## Per network: ids of the cells on it
var _members_key := Vector2i(-1, -1)           ## (networks.version, objects_version) of _cells


func system_name() -> StringName:
	return &"power"


func tick(world: SimWorld, dt: float) -> void:
	var g := world.grid
	networks.sync(g, g.wire)
	if _members_key != Vector2i(networks.version, world.objects_version):
		_rebuild_members(world)
	var light: LightSystem = world.get_system(&"light")
	var scale := light.power_scale(world)
	for obj: SimObject in world.objects.values():
		obj.power_w = 0.0
	for n in networks.count:
		network_power_w[n] = 0.0
		if network_grid[n] == 0:
			continue
		var total := 0.0
		for id: int in _cells[n]:
			var obj: SimObject = world.objects[id]
			obj.power_w = SolarCell.object_power(obj, scale)
			obj.heat_in -= obj.power_w * dt
			total += obj.power_w
		network_power_w[n] = total
		world.money += Market.earnings(world, total, dt)


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
	network_power_w.resize(networks.count)
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
