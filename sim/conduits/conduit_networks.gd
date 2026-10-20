class_name ConduitNetworks
extends RefCounted
## Networks of a conduit layer (D14): tiles of the layer joined through their 4-neighbours
## form one network. A tile holds up to CHANNELS channels (the bits of its byte: wires of different
## colors on one tile cross without touching); a network is within one channel. Rebuilt only when
## the layer changes (TileGrid.conduit_version); the per-tick solvers (power now, pipes later) work
## on the networks, not on tiles.

const CHANNELS := 4

var network := PackedInt32Array()   ## Per tile and channel (tile * CHANNELS + channel): its network, or -1
var count := 0                      ## Number of networks
var version := -1                   ## The key the networks were built for


## Rebuilds the networks of `layer` (one byte per tile, a bit per channel) if it changed: when
## `key` (by default the grid's conduit_version) differs from the one they were built for.
func sync(grid: TileGrid, layer: PackedByteArray, key := -1) -> void:
	if key < 0:
		key = grid.conduit_version
	if version == key:
		return
	var w := grid.width
	var n := grid.size()
	network.resize(n * CHANNELS)
	network.fill(-1)
	count = 0
	var stack := PackedInt32Array()
	for start in n:
		for c in CHANNELS:
			var bit := 1 << c
			if layer[start] & bit == 0 or network[start * CHANNELS + c] >= 0:
				continue
			network[start * CHANNELS + c] = count
			stack.append(start)
			while not stack.is_empty():
				var i := stack[stack.size() - 1]
				stack.resize(stack.size() - 1)
				var x := i % w
				for nb: int in [i - w if i >= w else -1, i + w if i + w < n else -1,
						i - 1 if x > 0 else -1, i + 1 if x < w - 1 else -1]:
					if nb >= 0 and layer[nb] & bit != 0 and network[nb * CHANNELS + c] < 0:
						network[nb * CHANNELS + c] = count
						stack.append(nb)
			count += 1
	version = key


## The network at tile i in `channel`, or -1.
func at(i: int, channel := 0) -> int:
	return network[i * CHANNELS + channel] if i >= 0 and i * CHANNELS + channel < network.size() else -1


## The network at tile i in the lowest channel that has one, or -1.
func any_at(i: int) -> int:
	for c in CHANNELS:
		if at(i, c) >= 0:
			return at(i, c)
	return -1


## The number of tiles in network n.
func tiles_in(n: int) -> int:
	return network.count(n)
