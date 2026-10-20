class_name SiteSave
extends RefCounted
## Saves and restores a site: the clock, money, objects (definition key, position, tilt,
## mounted, battery charge), the wire layer and the terrain (tile materials). Temperatures and light are not
## saved; they settle again within moments. Restoring is part of building the world, like
## WorldGen: it writes the state directly, before play starts (no commands, no undo history).

const VERSION := 1


## The site as a JSON-friendly dictionary.
static func capture(world: SimWorld) -> Dictionary:
	var objects := []
	for obj: SimObject in world.objects.values():
		objects.append({"key": str(obj.def.key), "x": obj.position.x, "y": obj.position.y,
			"angle": obj.angle, "mounted": obj.mounted, "stored_j": obj.stored_j})
	var wires := []   # [tile, channels] pairs
	for i in world.grid.size():
		if world.grid.wire[i] != 0:
			wires.append([i, world.grid.wire[i]])
	var g := world.grid
	var materials := g.material.to_byte_array()
	return {"version": VERSION, "width": g.width, "height": g.height, "time_s": world.time_s,
		"money": world.money, "objects": objects, "wires": wires, "materials_size": materials.size(),
		"materials": Marshalls.raw_to_base64(materials.compress(FileAccess.COMPRESSION_ZSTD))}


## Restores a captured site into a freshly built world of the same size. Returns "" or why it
## couldn't (then the world is left as it was).
static func restore(world: SimWorld, data: Dictionary, defs: ObjectDB) -> String:
	var g := world.grid
	if int(data.get("version", 0)) != VERSION or int(data.get("width", 0)) != g.width \
			or int(data.get("height", 0)) != g.height:
		return "save is from another version or site size"
	var raw := Marshalls.base64_to_raw(str(data.get("materials", ""))).decompress(
		int(data.get("materials_size", 0)), FileAccess.COMPRESSION_ZSTD)
	var materials := raw.to_int32_array()
	if materials.size() != g.size():
		return "terrain data is damaged"
	g.material = materials
	g.mark_structure_changed()
	g.wire.fill(0)
	for w: Variant in data.get("wires", []):
		# [tile, channels]; older saves hold a bare tile index (channel 0)
		var i := int(w[0]) if w is Array else int(w)
		if i >= 0 and i < g.size():
			g.wire[i] = int(w[1]) if w is Array else 1
	g.conduit_version += 1
	world.time_s = float(data.get("time_s", world.time_s))
	world.money = float(data.get("money", 0.0))
	for id in world.objects.keys():
		world.remove_object(id)
	for o: Dictionary in data.get("objects", []):
		var def := defs.get_by_key(StringName(str(o.get("key", ""))))
		if def == null:
			continue
		var obj := SimObject.new(world.next_object_id, def, Vector2(float(o.x), float(o.y)), float(o.angle))
		obj.mounted = bool(o.get("mounted", false))
		obj.stored_j = float(o.get("stored_j", 0.0))
		world.add_object(obj)
	world.refresh_environment()
	return ""


## The site as JSON text, floats at full precision (a reload puts every object exactly back).
static func to_text(world: SimWorld) -> String:
	return JSON.stringify(capture(world), "", true, true)


## Writes the site to `path` (JSON).
static func save_file(world: SimWorld, path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(to_text(world))
	return true


## Restores the site from `path`. Returns "" or why it couldn't.
static func load_file(world: SimWorld, path: String, defs: ObjectDB) -> String:
	if not FileAccess.file_exists(path):
		return "no save"
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not data is Dictionary:
		return "save is not readable"
	return restore(world, data, defs)
