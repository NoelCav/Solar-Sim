class_name ObjectDB
extends RefCounted
## Registry of all ObjectDefs, loaded from data/objects (D11), in catalog order: by category,
## then by name (the build catalog and the 1–9 keys follow it).

const OBJECTS_DIR := "res://data/objects"

var defs: Array[ObjectDef] = []
var _by_key: Dictionary[StringName, ObjectDef] = {}


## Loads every .tres in the objects directory. Returns an error string, or "" on success.
func load_dir(dir_path: String = OBJECTS_DIR) -> String:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return "Cannot open %s" % dir_path
	defs.clear()
	_by_key.clear()
	var files := dir.get_files()
	files.sort()
	for file in files:
		var name := file.trim_suffix(".remap")
		if not name.ends_with(".tres"):
			continue
		var res := load(dir_path.path_join(name))
		if res is ObjectDef:
			if _by_key.has(res.key):
				return "Duplicate object key '%s'" % res.key
			defs.append(res)
			_by_key[res.key] = res
	defs.sort_custom(func(a: ObjectDef, b: ObjectDef) -> bool:
		return a.category < b.category or a.category == b.category and a.display_name < b.display_name)
	return ""


func get_by_key(key: StringName) -> ObjectDef:
	return _by_key.get(key)
