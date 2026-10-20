class_name SimCommand
extends RefCounted
## Base class for every mutation of sim state (design doc D6).
## Commands are queued and applied at the start of a tick, which keeps the sim
## deterministic and gives creative mode undo for free.


static var _groups := 0

## Commands of one gesture (a brush stroke, a dragged line) share a group and undo together; 0 is
## no group.
var group := 0


## A new group number for a gesture's commands.
static func new_group() -> int:
	_groups += 1
	return _groups


## Applies the command. Returns false if it had no effect (it is then not recorded for undo).
func apply(_world: SimWorld) -> bool:
	return false


func undo(_world: SimWorld) -> void:
	pass


func is_undoable() -> bool:
	return true
