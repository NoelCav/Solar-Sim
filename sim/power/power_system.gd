class_name PowerSystem
extends SimSystem
## Electrical networks (§10, D14): wire tiles joined into networks (ConduitNetworks); objects
## join the network at their port (Mounting.port_tiles). Each tick, on every network with a
## grid connection or a battery, each cell delivers what it can make now (SolarCell) and the
## network spends it (`flows`): batteries take in surplus when the price is low (Market.stance),
## give out when it is high, and the grid connection sells the rest at the market price.
## Delivered energy leaves the cell's heat (D13): light in = heat + electricity. A cell with
## nowhere to send its power sits at open circuit and all its light is heat. Runs after the light
## system and before heat.

var networks := ConduitNetworks.new()
var network_grid := PackedByteArray()          ## Per network: 1 if a grid connection is on it

var _cells := []                               ## Per network: ids of the cells on it
var _batteries := []                           ## Per network: ids of the batteries on it
var _members_key := Vector2i(-1, -1)           ## (networks.version, objects_version) of _cells


func system_name() -> StringName:
	return &"power"


func tick(world: SimWorld, dt: float) -> void:
	sync(world)
	for obj: SimObject in world.objects.values():
		obj.power_w = 0.0
		obj.flow_w = 0.0
	for n in networks.count:
		var f := flows(world, n, dt)
		for id: int in _cells[n]:
			var obj: SimObject = world.objects[id]
			obj.power_w = f.cells[id]
			obj.heat_in -= obj.power_w * dt
		for id: int in _batteries[n]:
			var obj: SimObject = world.objects[id]
			var w: float = f.batteries[id]
			obj.flow_w = w
			var eff := obj.def.battery_efficiency
			var joules := absf(w) * dt * SimConst.DAY_COMPRESSION
			obj.stored_j = maxf(obj.stored_j - joules / eff, 0.0) if w > 0.0 else obj.stored_j + joules * eff
		world.money += Market.earnings(world, f.sold_w, dt)


## What network n does over the next `dt` game seconds, from the light and charges now:
## {cells: {id: W delivered}, batteries: {id: W, + out, − in}, sold_w: W to the grid}.
## The one home of the network's energy policy; ticks, meters and the inspector all read it, so
## they agree (also while paused).
func flows(world: SimWorld, n: int, dt: float) -> Dictionary:
	sync(world)
	var out := {"cells": {}, "batteries": {}, "sold_w": 0.0}
	if n < 0 or n >= networks.count:
		return out
	var grid := network_grid[n] == 1
	var light_scale := (world.get_system(&"light") as LightSystem).power_scale(world)
	var made := 0.0
	for id: int in _cells[n]:
		made += SolarCell.object_power(world.objects[id], light_scale)
	var stance := Market.stance(world)
	var to_batteries := 0.0
	var from_batteries := 0.0
	var real_s := dt * SimConst.DAY_COMPRESSION
	for id: int in _batteries[n]:
		var obj: SimObject = world.objects[id]
		var def := obj.def
		var w := 0.0
		if not grid or stance == Market.Stance.CHARGE:
			var room_w := (def.battery_capacity_kwh * Market.J_PER_KWH - obj.stored_j) / (def.battery_efficiency * real_s)
			w = -clampf(minf(room_w, def.battery_max_w), 0.0, maxf(made - to_batteries, 0.0))
			to_batteries -= w
		elif stance == Market.Stance.SELL:
			w = clampf(obj.stored_j * def.battery_efficiency / real_s, 0.0, def.battery_max_w)
			from_batteries += w
		out.batteries[id] = w
	# With a grid every cell delivers (what the batteries don't take is sold); without one, only
	# the share that charges them.
	var delivered := made if grid else to_batteries
	var share := delivered / made if made > 0.0 else 0.0
	for id: int in _cells[n]:
		out.cells[id] = SolarCell.object_power(world.objects[id], light_scale) * share
	out.sold_w = delivered - to_batteries + from_batteries if grid else 0.0
	return out


## What network n sells now, W (0 without a grid connection).
func output_w(world: SimWorld, n: int) -> float:
	return flows(world, n, SimConst.DT).sold_w


## What network n can send out, W: the rated power of its cells plus what its batteries can add
## (SolarCell.rated_power, ObjectDef.battery_max_w; 0 for no network).
func rated_w(world: SimWorld, n: int) -> float:
	sync(world)
	if n < 0 or n >= networks.count:
		return 0.0
	var total := 0.0
	for id: int in _cells[n]:
		total += SolarCell.rated_power(world.objects[id].def)
	for id: int in _batteries[n]:
		total += world.objects[id].def.battery_max_w
	return total


## Brings the networks and who is on them up to date with the wires and objects (also while
## paused, for the inspector).
func sync(world: SimWorld) -> void:
	networks.sync(world.grid, world.grid.wire)
	if _members_key != Vector2i(networks.version, world.objects_version):
		_rebuild_members(world)


## Whether `obj` is on a network that takes its power (a grid connection or a battery), so a
## cell there delivers what it makes.
func delivers(world: SimWorld, obj: SimObject) -> bool:
	sync(world)
	var n := network_of(world, obj)
	return n >= 0 and (network_grid[n] == 1 or not _batteries[n].is_empty())


## The network object `obj` is connected to, or -1.
func network_of(world: SimWorld, obj: SimObject) -> int:
	networks.sync(world.grid, world.grid.wire)
	for i in Mounting.port_tiles(world, obj):
		if networks.at(i) >= 0:
			return networks.at(i)
	return -1


func _rebuild_members(world: SimWorld) -> void:
	_cells.clear()
	_batteries.clear()
	for n in networks.count:
		_cells.append([])
		_batteries.append([])
	network_grid.resize(networks.count)
	network_grid.fill(0)
	for obj: SimObject in world.objects.values():
		var n := network_of(world, obj)
		if n < 0:
			continue
		match obj.def.kind:
			ObjectDef.Kind.CELL:
				_cells[n].append(obj.id)
			ObjectDef.Kind.BATTERY:
				_batteries[n].append(obj.id)
			ObjectDef.Kind.GRID_TIE:
				network_grid[n] = 1
	_members_key = Vector2i(networks.version, world.objects_version)
