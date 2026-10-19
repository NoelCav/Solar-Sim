class_name SimCommand
extends RefCounted
## Base class for every mutation of sim state (design doc D6).
## Commands are queued and applied at the start of a tick, which keeps the sim
## deterministic and gives creative mode undo for free.


## Applies the command. Returns false if it had no effect (it is then not recorded for undo).
func apply(_world: SimWorld) -> bool:
	return false


func undo(_world: SimWorld) -> void:
	pass


func is_undoable() -> bool:
	return true
