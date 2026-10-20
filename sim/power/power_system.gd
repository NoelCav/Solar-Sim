class_name PowerSystem
extends SimSystem
## Electrical networks (§10, D14): wire tiles joined into networks (ConduitNetworks); objects
## join the network at their port (Mounting.port_tiles). Each tick, on every network, each cell
## delivers what it can make now (SolarCell) and the network spends it (`flows`): consumers
## (lamps) first, from the cells and then the batteries, then the grid connection supplies what is
## still missing at the retail price; what is left over charges batteries when the price is low
## (Market.stance), batteries give out when it is high, and the grid connection sells the rest.
## Delivered energy leaves the cell's heat (D13): light in = heat + electricity. A cell with
## nowhere to send its power sits at open circuit and all its light is heat. Runs after the light
## system (a lamp's brightness is what its network gave it the tick before) and before heat.

var networks := ConduitNetworks.new()
## What conducts: the wire layer, and the foot of every surface cell (a cell is a piece of wire,
## so a row of them is one network without any laid between them).
var conducts := PackedByteArray()
## Surface cell sets: cells whose feet touch, left to right, as lists of object ids; one meter each.
var sets := []
var set_of := {}                               ## Object id -> index in `sets`
var network_grid := PackedByteArray()          ## Per network: 1 if a grid connection is on it

var _cells := []                               ## Per network: ids of the cells on it
var _batteries := []                           ## Per network: ids of the batteries on it
var _lamps := []                               ## Per network: ids of the lamps on it
var _members_key := Vector2i(-1, -1)           ## (conduit_version, objects_version) of _cells
var _conducts_key := Vector2i(-1, -1)          ## (conduit_version, objects_version) of `conducts`


func system_name() -> StringName:
	return &"power"


func tick(world: SimWorld, dt: float) -> void:
	sync(world)
	for obj: SimObject in world.objects.values():
		obj.power_w = 0.0
		obj.flow_w = 0.0
		obj.lamp_level = 0.0   # A lamp on no network gets nothing
	for n in networks.count:
		var f := flows(world, n, dt)
		for id: int in _lamps[n]:
			world.objects[id].lamp_level = f.lamps[id]
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
		world.money += Market.earnings(world, f.sold_w, dt) - Market.cost(world, f.bought_w, dt)


## What network n does over the next `dt` game seconds, from the light and charges now:
## {cells: {id: W delivered}, batteries: {id: W, + out, − in}, lamps: {id: brightness 0 to 1},
## sold_w: W to the grid, bought_w: W from it}.
## The one home of the network's energy policy; ticks, meters and the inspector all read it, so
## they agree (also while paused). Order: lamps are served from the cells, then the batteries,
## then the grid; what the cells made beyond the lamps charges batteries (when the price is low,
## or always without a grid) and the rest is sold; a battery sells when the price is high.
func flows(world: SimWorld, n: int, dt: float) -> Dictionary:
	sync(world)
	var out := {"cells": {}, "batteries": {}, "lamps": {}, "sold_w": 0.0, "bought_w": 0.0}
	if n < 0 or n >= networks.count:
		return out
	var grid := network_grid[n] == 1
	var light_scale := (world.get_system(&"light") as LightSystem).power_scale(world)
	var made := 0.0
	for id: int in _cells[n]:
		made += SolarCell.object_power(world.objects[id], light_scale)
	var demand := 0.0
	for id: int in _lamps[n]:
		demand += world.objects[id].def.lamp_watts
	var stance := Market.stance(world)
	var real_s := dt * SimConst.DAY_COMPRESSION
	var spare := maxf(made - demand, 0.0)      # Cell power left after the lamps
	var missing := maxf(demand - made, 0.0)    # Lamp demand the cells can't meet
	var to_batteries := 0.0
	var sold_from_batteries := 0.0
	for id: int in _batteries[n]:
		var obj: SimObject = world.objects[id]
		var def := obj.def
		var can_give := clampf(obj.stored_j * def.battery_efficiency / real_s, 0.0, def.battery_max_w)
		var can_take := minf((def.battery_capacity_kwh * Market.J_PER_KWH - obj.stored_j)
			/ (def.battery_efficiency * real_s), def.battery_max_w)
		var w := 0.0
		if missing > 0.0:
			w = minf(can_give, missing)
			missing -= w
		elif grid and stance == Market.Stance.SELL:
			w = can_give
			sold_from_batteries += w
		elif not grid or stance == Market.Stance.CHARGE:
			w = -clampf(can_take, 0.0, spare - to_batteries)
			to_batteries -= w
		out.batteries[id] = w
	# Lamps get everything they ask for, less what nothing could supply (no grid to fall back on).
	var unmet := 0.0 if grid else missing
	var level := 1.0 - unmet / demand if demand > 0.0 else 0.0
	for id: int in _lamps[n]:
		out.lamps[id] = level
	# With a grid every cell delivers (the lamps first, then batteries, then the sale); without
	# one, only what the lamps and the batteries take.
	var used := minf(made, demand) + to_batteries
	var share := (made if grid else used) / made if made > 0.0 else 0.0
	for id: int in _cells[n]:
		out.cells[id] = SolarCell.object_power(world.objects[id], light_scale) * share
	if grid:
		out.sold_w = spare - to_batteries + sold_from_batteries
		out.bought_w = missing
	return out


## What network n sells now, W (0 without a grid connection).
func output_w(world: SimWorld, n: int) -> float:
	return flows(world, n, SimConst.DT).sold_w


## What network n buys from the grid now, W (lamps and the like beyond what its cells and batteries give).
func bought_w(world: SimWorld, n: int) -> float:
	return flows(world, n, SimConst.DT).bought_w


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
	_sync_networks(world)
	if _members_key != Vector2i(world.grid.conduit_version, world.objects_version):
		_rebuild_members(world)


## Whether `obj` is on a network that takes its power (a grid connection, a battery or a lamp), so
## a cell there delivers what it makes.
func delivers(world: SimWorld, obj: SimObject) -> bool:
	sync(world)
	var n := network_of(world, obj)
	return n >= 0 and (network_grid[n] == 1 or not _batteries[n].is_empty() or not _lamps[n].is_empty())


## The network object `obj` is connected to, or -1.
func network_of(world: SimWorld, obj: SimObject) -> int:
	_sync_networks(world)
	for i in Mounting.port_tiles(world, obj):
		if networks.at(i) >= 0:
			return networks.at(i)
	return -1


## Brings `conducts` and the networks up to date with the wires and the surface cells.
func _sync_networks(world: SimWorld) -> void:
	var g := world.grid
	var key := Vector2i(g.conduit_version, world.objects_version)
	if key != _conducts_key:
		conducts = g.wire.duplicate()
		for obj: SimObject in world.objects.values():
			if _is_surface_cell(obj):
				for i in Mounting.port_tiles(world, obj):
					conducts[i] = 1
		_build_sets(world)
		_conducts_key = key
	networks.sync(g, conducts, g.conduit_version * 1048576 + world.objects_version)


static func _is_surface_cell(obj: SimObject) -> bool:
	return obj.def.kind == ObjectDef.Kind.CELL and obj.def.mount == ObjectDef.Mount.GROUND


## Groups surface cells whose feet touch (a tile of one beside a tile of the other).
func _build_sets(world: SimWorld) -> void:
	sets.clear()
	set_of.clear()
	var at := {}   # Tile -> the cell whose foot is there
	var cells := []
	for obj: SimObject in world.objects.values():
		if _is_surface_cell(obj):
			cells.append(obj)
			for i in Mounting.port_tiles(world, obj):
				at[i] = obj.id
	var parent := {}
	for obj: SimObject in cells:
		parent[obj.id] = obj.id
	var w := world.grid.width
	for obj: SimObject in cells:
		for i in Mounting.port_tiles(world, obj):
			for nb: int in [i - 1, i + 1, i - w, i + w]:
				if at.has(nb):
					parent[_root(parent, at[nb])] = _root(parent, obj.id)
	var groups := {}
	for obj: SimObject in cells:
		var r := _root(parent, obj.id)
		if not groups.has(r):
			groups[r] = []
		groups[r].append(obj)
	for group: Array in groups.values():
		group.sort_custom(func(a: SimObject, b: SimObject) -> bool: return a.position.x < b.position.x)
		var ids := []
		for obj: SimObject in group:
			set_of[obj.id] = sets.size()
			ids.append(obj.id)
		sets.append(ids)


static func _root(parent: Dictionary, id: int) -> int:
	while parent[id] != id:
		parent[id] = parent[parent[id]]
		id = parent[id]
	return id


func _rebuild_members(world: SimWorld) -> void:
	_cells.clear()
	_batteries.clear()
	_lamps.clear()
	for n in networks.count:
		_cells.append([])
		_batteries.append([])
		_lamps.append([])
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
			ObjectDef.Kind.LAMP:
				_lamps[n].append(obj.id)
			ObjectDef.Kind.GRID_TIE:
				network_grid[n] = 1
	_members_key = Vector2i(world.grid.conduit_version, world.objects_version)
