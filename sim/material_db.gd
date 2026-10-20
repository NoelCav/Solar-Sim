class_name MaterialDB
extends RefCounted
## Registry of all MaterialDefs, indexed by stable id.
## Also exposes packed per-property arrays so hot sim loops avoid Resource lookups.

const MATERIALS_DIR := "res://data/materials"
const AIR_ID := 0

var defs: Array[MaterialDef] = []          ## Indexed by id; null for unused ids

# Packed lookups indexed by id (filled by _build_tables).
var conductivity := PackedFloat32Array()
var emissivity := PackedFloat32Array()
var is_solid := PackedByteArray()
var is_gas := PackedByteArray()
## Surface absorptivity averaged over the AM1.5 spectrum: the share of plain sunlight a
## face absorbs (diffuse sky light).
var sun_absorptivity := PackedFloat32Array()

var _by_key: Dictionary[StringName, MaterialDef] = {}


## Loads every .tres in the materials directory. Returns an error string, or "" on success.
func load_dir(dir_path: String = MATERIALS_DIR) -> String:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return "Cannot open %s" % dir_path
	var loaded: Array[MaterialDef] = []
	for file in dir.get_files():
		# Exported builds list "x.tres.remap"; load by the original name.
		var name := file.trim_suffix(".remap")
		if not name.ends_with(".tres"):
			continue
		var res := load(dir_path.path_join(name))
		if res is MaterialDef:
			loaded.append(res)
	return register_all(loaded)


## Registers a set of definitions, validating ids and keys.
func register_all(list: Array[MaterialDef]) -> String:
	defs.clear()
	_by_key.clear()
	for def in list:
		if def.id < 0:
			return "Material '%s' has no id" % def.key
		if def.id >= defs.size():
			defs.resize(def.id + 1)
		if defs[def.id] != null:
			return "Duplicate material id %d ('%s' and '%s')" % [def.id, defs[def.id].key, def.key]
		if _by_key.has(def.key):
			return "Duplicate material key '%s'" % def.key
		defs[def.id] = def
		_by_key[def.key] = def
	if defs.is_empty() or defs[AIR_ID] == null or defs[AIR_ID].key != &"air":
		return "Material id 0 must be 'air'"
	for def in defs:
		if def == null:
			continue
		for ref in [def.melts_to, def.burns_to, def.boils_to, def.condenses_to]:
			if ref != &"" and not _by_key.has(ref):
				return "Material '%s' references unknown material '%s'" % [def.key, ref]
	_build_tables()
	return ""


func get_def(id: int) -> MaterialDef:
	return defs[id] if id >= 0 and id < defs.size() else null


func get_by_key(key: StringName) -> MaterialDef:
	return _by_key.get(key)


func id_of(key: StringName) -> int:
	var def: MaterialDef = _by_key.get(key)
	return def.id if def != null else -1


func count() -> int:
	return defs.size()


## Materials that can be placed (everything except unused id slots), sorted by id.
func placeable() -> Array[MaterialDef]:
	var out: Array[MaterialDef] = []
	for def in defs:
		if def != null:
			out.append(def)
	return out


func _build_tables() -> void:
	var n := defs.size()
	for arr in [conductivity, emissivity, sun_absorptivity]:
		arr.resize(n)
		arr.fill(0.0)
	is_solid.resize(n)
	is_solid.fill(0)
	is_gas.resize(n)
	is_gas.fill(0)
	for def in defs:
		if def == null:
			continue
		conductivity[def.id] = def.conductivity
		emissivity[def.id] = def.emissivity
		is_solid[def.id] = 1 if def.is_solid() else 0
		is_gas[def.id] = 1 if def.phase == MaterialDef.Phase.GAS else 0
		for b in Spectrum.BIN_COUNT:
			sun_absorptivity[def.id] += def.surface_absorptivity[b] * Spectrum.AM15_SHARE[b]
