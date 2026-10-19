extends Node
## Agent tools for the running game, called through the Godot MCP's game_eval, e.g.
## `return SimProbe.run("state", {})` or `return SimProbe.run("help", {})`.
## Answers with plain dictionaries of sim state; action commands go through the world's
## command queue like player input (D6). Positions are meters (x right, y down), angles degrees.

const ASCII := " .:-=+*#%@"

var _main: Main


func run(cmd: String, a: Dictionary = {}) -> Dictionary:
	_main = get_tree().current_scene as Main
	if _main == null or _main.world == null:
		return {"error": "game not ready"}
	match cmd:
		"help": return _help()
		"state": return _state()
		"objects": return _objects()
		"defs": return _defs()
		"object": return _object(a)
		"tile": return _tile(a)
		"region": return _region(a)
		"peaks": return _peaks(a)
		"trace": return _trace(a)
		"place": return _place(a)
		"move": return _move(a)
		"rotate": return _rotate(a)
		"remove": return _remove(a)
		"time": return _time(a)
		"pause": return _pause(a)
		"speed": return _speed(a)
		"view": return _view(a)
		"wavelength": return _wavelength(a)
		"camera": return _camera(a)
	return {"error": "unknown cmd '%s'; try help" % cmd}


func _help() -> Dictionary:
	return {"commands": {
		"state": "time, sun, ambient, speed/pause, view, light and heat stats",
		"objects": "all placed objects: id, key, kind, position, angle, absorbed W, probe reading",
		"defs": "object definitions that can be placed (keys)",
		"object": "{id}: one object with its bounds",
		"tile": "{x, y} meters (or {tx, ty} tiles): material, temperature, absorbed light",
		"region": "{x0, y0, x1, y1, layer: light|heat|material, cols?: 60}: ASCII map plus summary",
		"peaks": "{layer: light|heat, n: 10}: hottest or brightest tiles",
		"trace": "{x, y, angle (deg, 90 = straight down) or dx, dy, bin: 0-5 (UV..IR, default 2 green)}: one test ray through current geometry; returns segments with power",
		"place": "{key, x, y, angle}", "move": "{id, x, y}", "rotate": "{id, angle} absolute or {id, by}",
		"remove": "{id}", "time": "{hour}", "pause": "{on: bool}", "speed": "{n: 1|2|4}",
		"view": "{name: Normal|Light|UV|Infrared|Heat}", "wavelength": "{bin: -1..5}",
		"camera": "{x, y, zoom}: centre the view on a point (for screenshots)",
	}}


func _state() -> Dictionary:
	var w := _main.world
	var light: LightSystem = w.get_system(&"light")
	var heat: ThermalSystem = w.get_system(&"heat")
	var tod := w.time_of_day() * 24.0
	return {
		"day": w.day_number() + 1, "hour": snappedf(tod, 0.01), "time_s": snappedf(w.time_s, 0.01),
		"paused": _main.paused, "speed": _main.speed, "view": ViewMode.NAMES[_main.view],
		"wavelength": _main.wavelength,
		"sun": {"up": w.sun_is_up, "elevation_deg": snappedf(rad_to_deg(w.sun_elevation), 0.1),
			"direction": _v(w.sun_direction), "dni_w_m2": snappedf(w.sun_dni, 0.1)},
		"ambient_c": snappedf(SimConst.k_to_c(w.ambient_k), 0.01),
		"world_m": _v(Vector2(w.grid.width, w.grid.height) * SimConst.TILE_M),
		"objects": w.objects.size(),
		"light": _round_dict(light.stats).merged({"last_pass_ms": snappedf(light.last_trace_ms, 0.01)}),
		"heat_ms": snappedf(heat.last_step_ms, 0.01),
		"fps": Engine.get_frames_per_second(), "sim_ms_per_frame": snappedf(_main.sim_ms, 0.01),
	}


func _objects() -> Dictionary:
	var out := []
	for obj: SimObject in _main.world.objects.values():
		out.append(_object_info(obj))
	return {"objects": out}


func _object_info(obj: SimObject) -> Dictionary:
	var d := {"id": obj.id, "key": str(obj.def.key), "name": obj.def.display_name,
		"kind": ObjectDef.Kind.keys()[obj.def.kind], "x": snappedf(obj.position.x, 0.001),
		"y": snappedf(obj.position.y, 0.001), "angle_deg": snappedf(rad_to_deg(obj.angle), 0.01),
		"absorbed_w": snappedf(obj.absorbed_w, 0.01)}
	if obj.def.kind == ObjectDef.Kind.PROBE:
		d["probe_w_m2"] = snappedf(obj.probe_irradiance(), 0.1)
	return d


func _defs() -> Dictionary:
	var out := []
	for def: ObjectDef in _main._tool.defs:
		out.append({"key": str(def.key), "name": def.display_name, "kind": ObjectDef.Kind.keys()[def.kind],
			"size_m": def.size_m})
	return {"defs": out}


func _object(a: Dictionary) -> Dictionary:
	var obj: SimObject = _main.world.objects.get(int(a.get("id", -1)))
	if obj == null:
		return {"error": "no object %s" % a.get("id")}
	var d := _object_info(obj)
	var lo := Vector2(INF, INF)
	var hi := -lo
	for piece in obj.world_pieces():
		for p: Vector2 in piece[0]:
			lo = lo.min(p)
			hi = hi.max(p)
	d["bounds"] = {"x0": snappedf(lo.x, 0.001), "y0": snappedf(lo.y, 0.001), "x1": snappedf(hi.x, 0.001),
		"y1": snappedf(hi.y, 0.001)}
	return d


func _cell(a: Dictionary) -> Vector2i:
	if a.has("tx"):
		return Vector2i(int(a.tx), int(a.ty))
	return Vector2i(floori(float(a.get("x", 0)) / SimConst.TILE_M), floori(float(a.get("y", 0)) / SimConst.TILE_M))


func _tile(a: Dictionary) -> Dictionary:
	var c := _cell(a)
	var g := _main.world.grid
	if not g.in_bounds(c.x, c.y):
		return {"error": "out of bounds"}
	return _tile_info(g.idx(c.x, c.y))


func _tile_info(i: int) -> Dictionary:
	var w := _main.world
	var g := w.grid
	var light: LightSystem = w.get_system(&"light")
	var def := w.materials.get_def(g.material[i])
	var area := SimConst.TILE_M * SimConst.DEPTH_M
	var scale := light.power_scale(w)
	var d := {"tx": i % g.width, "ty": i / g.width,
		"x": snappedf((i % g.width + 0.5) * SimConst.TILE_M, 0.001),
		"y": snappedf((i / g.width + 0.5) * SimConst.TILE_M, 0.001),
		"material": def.display_name if def else "?", "temp_c": snappedf(SimConst.k_to_c(g.temperature[i]), 0.01)}
	if light.tile_power.size() == g.size():
		var watts := light.tile_power[i] * scale
		d["absorbed_w"] = snappedf(watts, 0.001)
		d["absorbed_w_m2"] = snappedf(watts / area, 0.1)
		var o := i * Spectrum.BAND_COUNT
		d["bands_w_m2"] = {"uv": snappedf(light.band_power[o] * scale / area, 0.1),
			"visible": snappedf(light.band_power[o + 1] * scale / area, 0.1),
			"infrared": snappedf(light.band_power[o + 2] * scale / area, 0.1)}
	return d


## An ASCII map of a region (log-scaled for light and heat) and a summary.
func _region(a: Dictionary) -> Dictionary:
	var w := _main.world
	var g := w.grid
	var light: LightSystem = w.get_system(&"light")
	var layer := str(a.get("layer", "light"))
	var c0 := _cell({"x": a.get("x0", 0), "y": a.get("y0", 0)})
	var c1 := _cell({"x": a.get("x1", g.width * SimConst.TILE_M), "y": a.get("y1", g.height * SimConst.TILE_M)})
	c0 = c0.clamp(Vector2i.ZERO, Vector2i(g.width - 1, g.height - 1))
	c1 = c1.clamp(Vector2i.ZERO, Vector2i(g.width - 1, g.height - 1))
	var cols := clampi(int(a.get("cols", 60)), 4, 200)
	var step := maxi(1, ceili(float(c1.x - c0.x + 1) / cols))
	var values := {}
	var top := 0.0
	var total := 0.0
	var best := -1
	for y in range(c0.y, c1.y + 1):
		for x in range(c0.x, c1.x + 1):
			var i := g.idx(x, y)
			var v := 0.0
			match layer:
				"heat":
					v = g.temperature[i] - w.ambient_k
				"material":
					v = g.material[i]
				_:
					v = light.tile_power[i] * light.power_scale(w) if light.tile_power.size() == g.size() else 0.0
					total += v
			if best < 0 or v > top:
				top = v
				best = i
			values[i] = v
	var rows := PackedStringArray()
	for y in range(c0.y, c1.y + 1, step):
		var row := ""
		for x in range(c0.x, c1.x + 1, step):
			var v := 0.0
			for yy in range(y, mini(y + step, c1.y + 1)):
				for xx in range(x, mini(x + step, c1.x + 1)):
					v = maxf(v, values[g.idx(xx, yy)])
			if layer == "material":
				var def := w.materials.get_def(int(v))
				row += "." if def == null or def.phase == MaterialDef.Phase.GAS else def.display_name.substr(0, 1)
			elif top <= 0.0 or v <= 0.0:
				row += " "
			else:
				var k := int(log(1.0 + 99.0 * v / top) / log(100.0) * (ASCII.length() - 1))
				row += ASCII[clampi(k, 0, ASCII.length() - 1)]
		rows.append(row)
	var out := {"layer": layer, "tiles_per_char": step, "origin_tile": [c0.x, c0.y], "map": rows,
		"scale": "log, '@' = max" if layer != "material" else "first letter of material, '.' = air"}
	if layer == "light":
		out["total_absorbed_w"] = snappedf(total, 0.01)
	if best >= 0 and layer != "material":
		out["max"] = _tile_info(best)
	return out


func _peaks(a: Dictionary) -> Dictionary:
	var w := _main.world
	var g := w.grid
	var light: LightSystem = w.get_system(&"light")
	var n := clampi(int(a.get("n", 10)), 1, 100)
	var heat := str(a.get("layer", "light")) == "heat"
	var idx := []
	if heat:
		for i in g.size():
			idx.append(i)
	else:
		for i in light.shown_lit:
			idx.append(i)
	idx.sort_custom(func(p: int, q: int) -> bool:
		return (g.temperature[p] > g.temperature[q]) if heat else (light.tile_power[p] > light.tile_power[q]))
	var out := []
	for k in mini(n, idx.size()):
		out.append(_tile_info(idx[k]))
	return {"peaks": out}


## One test ray through the current geometry on the preview pass (the sim's own passes are
## untouched).
func _trace(a: Dictionary) -> Dictionary:
	var w := _main.world
	var light: LightSystem = w.get_system(&"light")
	if light._preview == null:
		return {"error": "light not set up yet"}
	var dir := Vector2(float(a.get("dx", 0)), float(a.get("dy", 1)))
	if a.has("angle"):
		dir = Vector2.from_angle(deg_to_rad(float(a.angle)))
	var origin := Vector2(float(a.get("x", 0)), float(a.get("y", 0)))
	var bin := clampi(int(a.get("bin", Spectrum.Bin.GREEN)), 0, Spectrum.BIN_COUNT - 1)
	var p := light._preview
	p.start(w, light._shown)
	var e := p.engine
	e.Begin()
	var power := Spectrum.make_zero()
	power[bin] = 1.0
	e.Trace(origin, dir.normalized(), power)
	var from: PackedVector2Array = e.SegFrom()
	var to: PackedVector2Array = e.SegTo()
	var pw: PackedFloat32Array = e.SegPower()
	var segs := []
	for k in from.size():
		segs.append({"from": _v(from[k]), "to": _v(to[k]),
			"power": snappedf(pw[k * Spectrum.BIN_COUNT + bin], 0.0001),
			"angle_deg": snappedf(rad_to_deg((to[k] - from[k]).angle()), 0.01)})
	var s: Dictionary = e.Stats()
	_main._previewed = Vector3(-1, -1, -1)   # Make the paused view re-preview normally
	return {"segments": segs, "absorbed": snappedf(s.absorbed, 0.0001), "escaped": snappedf(s.escaped, 0.0001),
		"scattered": snappedf(s.scattered, 0.0001), "culled": snappedf(s.culled, 0.0001)}


func _place(a: Dictionary) -> Dictionary:
	for def: ObjectDef in _main._tool.defs:
		if str(def.key) == str(a.get("key", "")):
			_main.world.enqueue(PlaceObjectCommand.new(def, Vector2(float(a.get("x", 0)), float(a.get("y", 0))),
				deg_to_rad(float(a.get("angle", 0)))))
			return {"ok": true, "id": _main.world.next_object_id}
	return {"error": "no def '%s'; see defs" % a.get("key")}


func _move(a: Dictionary) -> Dictionary:
	var obj: SimObject = _main.world.objects.get(int(a.get("id", -1)))
	if obj == null:
		return {"error": "no object"}
	_main.world.enqueue(TransformObjectCommand.new(obj.id,
		Vector2(float(a.get("x", obj.position.x)), float(a.get("y", obj.position.y))), obj.angle))
	return {"ok": true}


func _rotate(a: Dictionary) -> Dictionary:
	var obj: SimObject = _main.world.objects.get(int(a.get("id", -1)))
	if obj == null:
		return {"error": "no object"}
	var angle := deg_to_rad(float(a.angle)) if a.has("angle") else obj.angle + deg_to_rad(float(a.get("by", 0)))
	_main.world.enqueue(TransformObjectCommand.new(obj.id, obj.position, angle))
	return {"ok": true}


func _remove(a: Dictionary) -> Dictionary:
	_main.world.enqueue(RemoveObjectCommand.new(int(a.get("id", -1))))
	return {"ok": true}


func _time(a: Dictionary) -> Dictionary:
	var w := _main.world
	var day_start := floorf(w.time_s / SimConst.DAY_LENGTH_S) * SimConst.DAY_LENGTH_S
	w.enqueue(SetTimeCommand.new(day_start + float(a.get("hour", 12)) / 24.0 * SimConst.DAY_LENGTH_S))
	return {"ok": true}


func _pause(a: Dictionary) -> Dictionary:
	if bool(a.get("on", not _main.paused)) != _main.paused:
		_main.toggle_pause()
	return {"paused": _main.paused}


func _speed(a: Dictionary) -> Dictionary:
	var n := int(a.get("n", 1))
	if n in Main.SPEEDS:
		_main.speed = n
	return {"speed": _main.speed}


func _view(a: Dictionary) -> Dictionary:
	var k := ViewMode.NAMES.find(str(a.get("name", "Normal")))
	if k < 0:
		return {"error": "views: %s" % [ViewMode.NAMES]}
	_main.set_view(k)
	return {"ok": true}


func _wavelength(a: Dictionary) -> Dictionary:
	_main.set_wavelength(clampi(int(a.get("bin", -1)), -1, Spectrum.BIN_COUNT - 1))
	return {"ok": true}


func _camera(a: Dictionary) -> Dictionary:
	var cam := _main.get_node("Camera") as Camera2D
	var px := SimConst.TILE_PX / SimConst.TILE_M
	cam.position = Vector2(float(a.get("x", cam.position.x / px)), float(a.get("y", cam.position.y / px))) * px
	if a.has("zoom"):
		cam.zoom = Vector2.ONE * float(a.zoom)
	return {"ok": true}


static func _v(p: Vector2) -> Array:
	return [snappedf(p.x, 0.0001), snappedf(p.y, 0.0001)]


static func _round_dict(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		out[k] = snappedf(d[k], 0.01) if d[k] is float else d[k]
	return out
