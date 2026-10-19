class_name UndoCommand
extends SimCommand
## Undoes the most recent undoable command. Queued like any other command so
## undo happens at a deterministic point in the tick.


func apply(world: SimWorld) -> bool:
	world.undo_last()
	return false


func is_undoable() -> bool:
	return false
