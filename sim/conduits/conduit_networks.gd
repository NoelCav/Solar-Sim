class_name ConduitNetworks
extends RefCounted
## Networks of a conduit layer (D14): tiles of the layer joined through their 4-neighbours
## form one network. Rebuilt only when the layer changes (TileGrid.conduit_version); the
## per-tick solvers (power now, pipes later) work on the networks, not on tiles.

var network := PackedInt32Array()   ## Per tile: its network, or -1 where the layer is empty
var count := 0                      ## Number of networks
var version := -1                   ## The key the networks were built for


## Rebuilds the networks of `layer` (one byte per tile, nonzero = present) if it changed: when
## `key` (by default the grid's conduit_version) differs from the one they were built for.
func sync(grid: TileGrid, layer: PackedByteArray, key := -1) -> void:
	if key < 0:
		key = grid.conduit_version
	if version == key:
		return
	var w := grid.width
	var n := grid.size()
	network.resize(n)
	network.fill(-1)
	count = 0
	var stack := PackedInt32Array()
	for start in n:
		if layer[start] == 0 or network[start] >= 0:
			continue
		network[start] = count
		stack.append(start)
		while not stack.is_empty():
			var i := stack[stack.size() - 1]
			stack.resize(stack.size() - 1)
			var x := i % w
			for nb: int in [i - w if i >= w else -1, i + w if i + w < n else -1,
					i - 1 if x > 0 else -1, i + 1 if x < w - 1 else -1]:
				if nb >= 0 and layer[nb] != 0 and network[nb] < 0:
					network[nb] = count
					stack.append(nb)
		count += 1
	version = key


## The network at tile i, or -1.
func at(i: int) -> int:
	return network[i] if i >= 0 and i < network.size() else -1
