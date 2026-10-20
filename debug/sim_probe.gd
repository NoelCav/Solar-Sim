extends Node
## Agent tools for the running game, called through the Godot MCP's game_eval, e.g.
## `return SimProbe.run("state", {})` or `return SimProbe.run("help", {})`.
## Answers with plain dictionaries of sim state; action commands go through the world's
## command queue like player input (D6). Positions are meters (x right, y down), angles degrees.

const ASCII := " .:-=+*#%@"
## Commands: name -> arguments and what it returns (`help` lists them). Each is handled by
## `_cmd_<name>(args)`.
const COMMANDS := {
	"state": "time, sun, moon (phase, lit), traced light, ambient, speed/pause, view, light and heat stats",
	"objects": "all placed objects: id, key, kind, position, angle, absorbed W, probe reading and spectrum "
		+ "(W/m² per bin, UV..IR)",
	"defs": "object definitions that can be placed (keys)",
	"object": "{id}: one object with its bounds",
	"tile": "{x, y} meters (or {tx, ty} tiles): material, temperature, absorbed light, and per skinned face "
		+ "(top/bottom/left/right) its surface strips' temperature (°C) and arriving light (W/m²)",
	"region": "{x0, y0, x1, y1, layer: light|heat|material|wire, cols?: 60}: ASCII map plus summary",
	"peaks": "{layer: light|heat, n: 10}: hottest or brightest tiles",
	"trace": "{x, y, angle (deg, 90 = straight down) or dx, dy, bin: 0-5 (UV..IR, default 2 green)}: "
		+ "one test ray through current geometry; returns segments with power",
	"place": "{key, x, y, angle, free: false}: on its stand / the ground, snapped (free: floating, creative)",
	"move": "{id, x, y}",
	"rotate": "{id, angle} absolute or {id, by}",
	"remove": "{id}",
	"site": "{op: save|reset}: save the site now (it autosaves every 5 s), or forget it and start fresh",
	"power": "money, grid price, and each wire network: tiles, grid connection, W sold, cells on it",
	"wire": "{x0, y0, x1, y1, remove: false}: lay (or remove) wire along an L from (x0, y0) across, then "
		+ "down/up to (x1, y1)",
	"time": "{hour}: jump to that hour of the current day (24+ = next day)",
	"pause": "{on: bool}",
	"speed": "{n: 1|2|4|8|16}",
	"view": "{name: Normal|Light|Heat}",
	"wavelength": "{bin: -1..5}",
	"camera": "{x, y, zoom}: centre the view on a point (for screenshots)",
	"step": "{n: 1}: pause, then advance exactly n sim ticks (light passes run within ticks)",
	"fan": "{x0, y0, x1, y1 start line, n: 400, sun_offset_deg: 0, bin: 2, box: [bx0, by0, bx1, by1], "
		+ "hist_deg: 2}: ground truth without the beam engine: n parallel plain rays along the traced "
		+ "light (rotated by sun_offset_deg) from the start line; histogram of directions of legs "
		+ "leaving the box, weighted by power",
	"beams": "{x0, y0, x1, y1}: published beam records and secondary rays overlapping a box: count, "
		+ "watts, and a fingerprint to compare passes",
	"strips": "{x0, y0, x1, y1, bin: 2, max: 40}: beam render records with a point in the box, leg by "
		+ "leg: start/end widths (m, as BeamMesh measures them) and concentration C (1 = plain sun); "
		+ "sorted by peak C",
}

var _main: Main


func run(cmd: String, a: Dictionary = {}) -> Dictionary:
	_main = get_tree().current_scene as Main
	if _main == null or _main.world == null:
		return {"error": "game not ready"}
	if cmd != "help" and not COMMANDS.has(cmd):
		return {"error": "unknown cmd '%s'; try help" % cmd}
	return call("_cmd_" + cmd, a)


func _cmd_help(_a: Dictionary) -> Dictionary:
	return {"commands": COMMANDS}


func _cmd_state(_a: Dictionary) -> Dictionary:
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
		"moon": {"up": w.moon_is_up, "elevation_deg": snappedf(rad_to_deg(w.moon_elevation), 0.1),
			"direction": _v(w.moon_direction), "phase": snappedf(w.moon_phase, 0.001),
			"lit": snappedf(w.moon_illuminated, 0.001), "dni_w_m2": w.moon_dni},
		"traced": ("moon" if w.light_is_moon else "sun") if w.light_is_up else "none",
		"ambient_c": snappedf(SimConst.k_to_c(w.ambient_k), 0.01),
		"world_m": _v(Vector2(w.grid.width, w.grid.height) * SimConst.TILE_M),
		"objects": w.objects.size(),
		"light": _round_dict(light.stats).merged({"last_pass_ms": snappedf(light.last_trace_ms, 0.01)}),
		"heat_ms": snappedf(heat.last_step_ms, 0.01),
		"fps": Engine.get_frames_per_second(), "sim_ms_per_frame": snappedf(_main.sim_ms, 0.01),
	}


func _cmd_objects(_a: Dictionary) -> Dictionary:
	var out := []
	for obj: SimObject in _main.world.objects.values():
		out.append(_object_info(obj))
	return {"objects": out}


func _object_info(obj: SimObject) -> Dictionary:
	var d := {"id": obj.id, "key": str(obj.def.key), "name": obj.def.display_name,
		"kind": ObjectDef.Kind.keys()[obj.def.kind], "x": snappedf(obj.position.x, 0.001),
		"y": snappedf(obj.position.y, 0.001), "angle_deg": snappedf(rad_to_deg(obj.angle), 0.01),
		"absorbed_w": snappedf(obj.absorbed_w, 0.01), "mounted": obj.mounted,
		"temp_c": snappedf(SimConst.k_to_c(obj.temperature_k), 0.01) if obj.temperature_k > 0.0 else null}
	if obj.def.kind == ObjectDef.Kind.PROBE:
		# Unrounded: moonlight readings are mW/m².
		d["probe_w_m2"] = obj.incident_irradiance()
		d["spectrum_w_m2"] = Array(obj.incident_spectrum())
	if obj.def.kind == ObjectDef.Kind.CELL:
		var light: LightSystem = _main.world.get_system(&"light")
		d["front_w_m2"] = snappedf(obj.incident_irradiance() * light.power_scale(_main.world), 0.01)
		d["could_make_w"] = snappedf(SolarCell.object_power(obj, light.power_scale(_main.world)), 0.001)
		d["delivering_w"] = snappedf(obj.power_w, 0.001)
		d["front_direct_w_m2"] = snappedf(Spectrum.total(obj.incident_direct) * light.power_scale(_main.world)
			/ (obj.def.size_m * SimConst.DEPTH_M), 0.01)
	return d


func _cmd_defs(_a: Dictionary) -> Dictionary:
	var out := []
	for def: ObjectDef in _main.object_db.defs:
		out.append({"key": str(def.key), "name": def.display_name, "kind": ObjectDef.Kind.keys()[def.kind],
			"size_m": def.size_m})
	return {"defs": out}


func _cmd_object(a: Dictionary) -> Dictionary:
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


func _cmd_tile(a: Dictionary) -> Dictionary:
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
	var scale := light.irradiance_scale(w)
	var d := {"tx": i % g.width, "ty": i / g.width,
		"x": snappedf((i % g.width + 0.5) * SimConst.TILE_M, 0.001),
		"y": snappedf((i / g.width + 0.5) * SimConst.TILE_M, 0.001),
		"material": def.display_name if def else "?", "temp_c": snappedf(SimConst.k_to_c(g.temperature[i]), 0.01)}
	if light.tile_power.size() == g.size():
		d["absorbed_w"] = snappedf(light.tile_power[i] * light.power_scale(w), 0.001)
		d["absorbed_w_m2"] = snappedf(light.tile_power[i] * scale, 0.1)
		var o := i * Spectrum.BAND_COUNT
		d["bands_w_m2"] = {"uv": snappedf(light.band_power[o] * scale, 0.1),
			"visible": snappedf(light.band_power[o + 1] * scale, 0.1),
			"infrared": snappedf(light.band_power[o + 2] * scale, 0.1)}
	# Surface skin (D18): strips along each skinned face.
	var skin := w.skin
	var faces := {}
	for side in 4:
		var f := skin.face_of[i * 4 + side] if i * 4 + side < skin.face_of.size() else -1
		if f < 0:
			continue
		var temps := []
		var lit := []
		for s in skin.strips:
			temps.append(snappedf(SimConst.k_to_c(skin.temperature[f * skin.strips + s]), 0.1))
			lit.append(snappedf(light.strip_irradiance((i * 4 + side) * skin.strips + s, w), 0.1))
		faces[["top", "bottom", "left", "right"][side]] = {"strip_temp_c": temps, "strip_w_m2": lit}
	if not faces.is_empty():
		d["skin"] = faces
	return d


## An ASCII map of a region (log-scaled for light and heat) and a summary.
func _cmd_region(a: Dictionary) -> Dictionary:
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
				"material", "wire":
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
			if layer == "wire":
				var i := g.idx(x, y)
				row += "=" if g.wire[i] != 0 else ("#" if w.materials.is_solid[g.material[i]] else ".")
			elif layer == "material":
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


func _cmd_peaks(a: Dictionary) -> Dictionary:
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
func _cmd_trace(a: Dictionary) -> Dictionary:
	var w := _main.world
	var light: LightSystem = w.get_system(&"light")
	var dir := Vector2(float(a.get("dx", 0)), float(a.get("dy", 1)))
	if a.has("angle"):
		dir = Vector2.from_angle(deg_to_rad(float(a.angle)))
	var origin := Vector2(float(a.get("x", 0)), float(a.get("y", 0)))
	var bin := clampi(int(a.get("bin", Spectrum.Bin.GREEN)), 0, Spectrum.BIN_COUNT - 1)
	var e := light.probe_engine(w)
	if e == null:
		return {"error": "light not set up yet"}
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
	_main.invalidate_preview()
	return {"segments": segs, "absorbed": snappedf(s.absorbed, 0.0001), "escaped": snappedf(s.escaped, 0.0001),
		"scattered": snappedf(s.scattered, 0.0001), "culled": snappedf(s.culled, 0.0001)}


func _cmd_place(a: Dictionary) -> Dictionary:
	var def := _main.object_db.get_by_key(StringName(str(a.get("key", ""))))
	if def == null:
		return {"error": "no def '%s'; see defs" % a.get("key")}
	_main.world.enqueue(PlaceObjectCommand.new(def, Vector2(float(a.get("x", 0)), float(a.get("y", 0))),
		deg_to_rad(float(a.get("angle", 0))), not bool(a.get("free", false))))
	return {"ok": true, "queued": "applies on the next tick (see objects; refused if occupied or no ground)"}


func _cmd_move(a: Dictionary) -> Dictionary:
	var obj: SimObject = _main.world.objects.get(int(a.get("id", -1)))
	if obj == null:
		return {"error": "no object"}
	_main.world.enqueue(TransformObjectCommand.new(obj.id,
		Vector2(float(a.get("x", obj.position.x)), float(a.get("y", obj.position.y))), obj.angle))
	return {"ok": true}


func _cmd_rotate(a: Dictionary) -> Dictionary:
	var obj: SimObject = _main.world.objects.get(int(a.get("id", -1)))
	if obj == null:
		return {"error": "no object"}
	var angle := deg_to_rad(float(a.angle)) if a.has("angle") else obj.angle + deg_to_rad(float(a.get("by", 0)))
	_main.world.enqueue(TransformObjectCommand.new(obj.id, obj.position, angle))
	return {"ok": true}


func _cmd_wire(a: Dictionary) -> Dictionary:
	var g := _main.world.grid
	var c0 := _cell({"x": a.get("x0", 0), "y": a.get("y0", 0)})
	var c1 := _cell({"x": a.get("x1", 0), "y": a.get("y1", 0)})
	var cells := PackedInt32Array()
	for x in range(mini(c0.x, c1.x), maxi(c0.x, c1.x) + 1):
		if g.in_bounds(x, c0.y):
			cells.append(g.idx(x, c0.y))
	for y in range(mini(c0.y, c1.y), maxi(c0.y, c1.y) + 1):
		if g.in_bounds(c1.x, y):
			cells.append(g.idx(c1.x, y))
	_main.world.enqueue(PaintWiresCommand.new(cells, 0 if bool(a.get("remove", false)) else 1))
	return {"ok": true, "tiles": cells.size()}


func _cmd_power(_a: Dictionary) -> Dictionary:
	var w := _main.world
	var power: PowerSystem = w.get_system(&"power")
	power.networks.sync(w.grid, w.grid.wire)
	var nets := []
	for n in power.networks.count:
		nets.append({"network": n, "tiles": power.networks.network.count(n), "grid": power.network_grid[n] == 1
			if n < power.network_grid.size() else false,
			"sold_w": snappedf(power.output_w(w, n), 0.001),
			"objects": []})
	for obj: SimObject in w.objects.values():
		var n := power.network_of(w, obj)
		if n >= 0:
			nets[n]["objects"].append(obj.id)
	return {"money": w.money, "price_per_kwh": snappedf(Market.price_per_kwh(w), 0.0001), "networks": nets}


func _cmd_site(a: Dictionary) -> Dictionary:
	match str(a.get("op", "save")):
		"save":
			return {"ok": _main.save_site(), "path": ProjectSettings.globalize_path(Main.SAVE_PATH)}
		"reset":
			_main.reset_site.call_deferred()
			return {"ok": true, "note": "fresh site on the next frame"}
	return {"error": "op is save or reset"}


func _cmd_remove(a: Dictionary) -> Dictionary:
	_main.world.enqueue(RemoveObjectCommand.new(int(a.get("id", -1))))
	return {"ok": true}


func _cmd_time(a: Dictionary) -> Dictionary:
	var w := _main.world
	var day_start := floorf(w.time_s / SimConst.DAY_LENGTH_S) * SimConst.DAY_LENGTH_S
	w.enqueue(SetTimeCommand.new(day_start + float(a.get("hour", 12)) / 24.0 * SimConst.DAY_LENGTH_S))
	return {"ok": true}


func _cmd_pause(a: Dictionary) -> Dictionary:
	if bool(a.get("on", not _main.paused)) != _main.paused:
		_main.toggle_pause()
	return {"paused": _main.paused}


func _cmd_speed(a: Dictionary) -> Dictionary:
	var n := int(a.get("n", 1))
	if n in Main.SPEEDS:
		_main.speed = n
	return {"speed": _main.speed}


func _cmd_view(a: Dictionary) -> Dictionary:
	var k := ViewMode.NAMES.find(str(a.get("name", "Normal")))
	if k < 0:
		return {"error": "views: %s" % [ViewMode.NAMES]}
	_main.set_view(k)
	return {"ok": true}


func _cmd_wavelength(a: Dictionary) -> Dictionary:
	_main.set_wavelength(clampi(int(a.get("bin", -1)), -1, Spectrum.BIN_COUNT - 1))
	return {"ok": true}


func _cmd_camera(a: Dictionary) -> Dictionary:
	var cam := _main.get_node("Camera") as Camera2D
	var px := SimConst.TILE_PX / SimConst.TILE_M
	cam.position = Vector2(float(a.get("x", cam.position.x / px)), float(a.get("y", cam.position.y / px))) * px
	if a.has("zoom"):
		cam.zoom = Vector2.ONE * float(a.zoom)
	return {"ok": true}


func _cmd_step(a: Dictionary) -> Dictionary:
	if not _main.paused:
		_main.toggle_pause()
	var w := _main.world
	var light: LightSystem = w.get_system(&"light")
	var before := light.trace_version
	for k in clampi(int(a.get("n", 1)), 1, 2000):
		w.tick()
	return {"hour": snappedf(w.time_of_day() * 24.0, 0.0001), "ticks": w.tick_count,
		"sun_dir_deg": snappedf(rad_to_deg(w.light_direction.angle()), 0.001),
		"passes_published": light.trace_version - before}


func _cmd_fan(a: Dictionary) -> Dictionary:
	var w := _main.world
	var light: LightSystem = w.get_system(&"light")
	var dir := w.light_direction.rotated(deg_to_rad(float(a.get("sun_offset_deg", 0))))
	var p0 := Vector2(float(a.get("x0", 0)), float(a.get("y0", 0)))
	var p1 := Vector2(float(a.get("x1", 0)), float(a.get("y1", 0)))
	var n := clampi(int(a.get("n", 400)), 2, 20000)
	var bin := clampi(int(a.get("bin", Spectrum.Bin.GREEN)), 0, Spectrum.BIN_COUNT - 1)
	var bx: Array = a.get("box", [0, 0, 1e9, 1e9])
	var box := Rect2(Vector2(bx[0], bx[1]), Vector2(bx[2] - bx[0], bx[3] - bx[1]))
	var hist_deg := float(a.get("hist_deg", 2.0))
	var e := light.probe_engine(w)
	if e == null:
		return {"error": "light not set up yet"}
	var power := Spectrum.make_zero()
	power[bin] = 1.0 / n
	for k in n:
		e.Trace(p0.lerp(p1, (k + 0.5) / n), dir, power)
	var from: PackedVector2Array = e.SegFrom()
	var to: PackedVector2Array = e.SegTo()
	var pw: PackedFloat32Array = e.SegPower()
	var hist := {}
	var out_w := 0.0
	for k in from.size():
		if box.has_point(from[k]) and not box.has_point(to[k]):
			var ang := rad_to_deg((to[k] - from[k]).angle())
			var key := snappedf(ang, hist_deg)
			var wk := pw[k * Spectrum.BIN_COUNT + bin]
			hist[key] = hist.get(key, 0.0) + wk
			out_w += wk
	var keys := hist.keys()
	keys.sort()
	var rows := []
	for key in keys:
		if hist[key] > 0.002:
			rows.append([key, snappedf(hist[key], 0.0001)])
	_main.invalidate_preview()
	return {"sun_dir_deg": snappedf(rad_to_deg(dir.angle()), 0.001), "leaving_box_w": snappedf(out_w, 0.0001),
		"histogram_deg_w": rows}


## Beam records (BeamGeometry layout) touching a box: how many, their power and a coarse
## fingerprint (sum of record points), to see whether consecutive passes changed shape.
func _cmd_beams(a: Dictionary) -> Dictionary:
	var light: LightSystem = _main.world.get_system(&"light")
	var box := Rect2(Vector2(float(a.get("x0", 0)), float(a.get("y0", 0))), Vector2.ZERO)
	box = box.expand(Vector2(float(a.get("x1", 1e9)), float(a.get("y1", 1e9))))
	var buf := light.beam_render
	var o := 0
	var n := 0
	var watts := 0.0
	var fp := Vector2.ZERO
	var legs := 0
	while o < buf.size():
		var kind := int(buf[o])
		var w := buf[o + 2]
		var pts := int(buf[o + 3])
		var stride := 6 if kind == BeamGeometry.STRIP else 3
		var start := o + (4 if kind == BeamGeometry.STRIP else 5)
		var hit := false
		var sum := Vector2.ZERO
		for k in pts:
			var q := start + k * stride
			var p := Vector2(buf[q], buf[q + 1])
			sum += p
			if box.has_point(p):
				hit = true
		if hit:
			n += 1
			watts += w
			fp += sum
			legs += pts
		o = start + pts * stride
	var rays := 0
	var ray_w := 0.0
	for k in light.ray_from.size():
		if box.has_point(light.ray_from[k]) or box.has_point(light.ray_to[k]):
			rays += 1
			for b in Spectrum.BIN_COUNT:
				ray_w += light.ray_power[k * Spectrum.BIN_COUNT + b]
	return {"version": light.trace_version, "records": n, "points": legs, "watts": snappedf(watts, 0.001),
		"fingerprint": _v(fp), "secondary_rays": rays, "secondary_w": snappedf(ray_w, 0.001)}


func _cmd_strips(a: Dictionary) -> Dictionary:
	var light: LightSystem = _main.world.get_system(&"light")
	var box := Rect2(Vector2(float(a.get("x0", 0)), float(a.get("y0", 0))), Vector2.ZERO)
	box = box.expand(Vector2(float(a.get("x1", 1e9)), float(a.get("y1", 1e9))))
	var want := int(a.get("bin", 2))
	var reference := SimConst.REFERENCE_DNI * Spectrum.AM15_SHARE[want] * SimConst.DEPTH_M
	var buf := light.beam_render
	var out := []
	var o := 0
	while o < buf.size():
		var kind := int(buf[o])
		var bin := int(buf[o + 1])
		var watts := buf[o + 2]
		var pts := int(buf[o + 3])
		var stride := 6 if kind == BeamGeometry.STRIP else 3
		var start := o + (4 if kind == BeamGeometry.STRIP else 5)
		o = start + pts * stride
		if bin != want:
			continue
		var hit := false
		for k in pts:
			if box.has_point(Vector2(buf[start + k * stride], buf[start + k * stride + 1])):
				hit = true
		if not hit:
			continue
		var legs := []
		var peak := 0.0
		for k in pts - 1:
			var q := start + k * stride
			var a0 := Vector2(buf[q], buf[q + 1])
			var a1 := Vector2(buf[q + stride], buf[q + stride + 1])
			if kind == BeamGeometry.STRIP:
				var b0 := Vector2(buf[q + 2], buf[q + 3])
				var b1 := Vector2(buf[q + stride + 2], buf[q + stride + 3])
				var d := (a1 - a0).normalized()
				var w0 := d.cross(b0 - a0)
				var w1 := d.cross(b1 - a1)
				var p := watts * 0.5 * (buf[q + 4] + buf[q + 5]) / reference
				var c0 := p / maxf(absf(w0), BeamGeometry.MIN_WIDTH_M)
				var c1 := p / maxf(absf(w1), BeamGeometry.MIN_WIDTH_M)
				peak = maxf(peak, maxf(c0, c1))
				legs.append({"a": _v(a0), "a_end": _v(a1), "w": [snappedf(w0, 0.0001), snappedf(w1, 0.0001)],
					"C": [snappedf(c0, 0.01), snappedf(c1, 0.01)]})
			else:
				var width := buf[start - 1]
				var c := watts * buf[q + 2] / (maxf(width, BeamGeometry.MIN_WIDTH_M) * reference)
				peak = maxf(peak, c)
				legs.append({"a": _v(a0), "a_end": _v(a1), "w": snappedf(width, 0.0001), "C": snappedf(c, 0.01)})
		out.append({"kind": "strip" if kind == BeamGeometry.STRIP else "sliver", "watts": snappedf(watts, 0.0001),
			"peak_C": snappedf(peak, 0.01), "legs": legs})
	out.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return x.peak_C > y.peak_C)
	return {"count": out.size(), "records": out.slice(0, int(a.get("max", 40)))}


static func _v(p: Vector2) -> Array:
	return [snappedf(p.x, 0.0001), snappedf(p.y, 0.0001)]


static func _round_dict(d: Dictionary) -> Dictionary:
	var out := {}
	for k in d:
		out[k] = snappedf(d[k], 0.01) if d[k] is float else d[k]
	return out
