class_name DebugHud
extends Label
## Top-left readout: time, speed, sun, system timings, tool, and an inspector for the
## hovered tile and object.

var world: SimWorld
var runner: Main
var brush: CreativeBrush
var tool: ObjectTool
var overlay: OverlayRenderer

var _light: LightSystem
var _heat: ThermalSystem


func setup(p_world: SimWorld, p_runner: Main, p_brush: CreativeBrush, p_tool: ObjectTool,
		p_overlay: OverlayRenderer) -> void:
	world = p_world
	runner = p_runner
	brush = p_brush
	tool = p_tool
	overlay = p_overlay
	_light = world.get_system(&"light")
	_heat = world.get_system(&"heat")
	position = Vector2(12, 8)
	add_theme_color_override(&"font_shadow_color", Color.BLACK)
	add_theme_constant_override(&"shadow_offset_x", 1)
	add_theme_constant_override(&"shadow_offset_y", 1)


func _process(_delta: float) -> void:
	if world == null:
		return
	var tod := world.time_of_day() * 24.0
	var tool_line := "Tool: %s" % (
		"tile brush — %s (size %d)   Q/E material  [ ] size  LMB paint  RMB erase" % [
			brush.selected().display_name, brush.brush_radius * 2 + 1]
		if tool.selected < 0 else
		"%s   LMB place / drag   RMB remove" % tool.selected_def().display_name)
	var lines: PackedStringArray = [
		"Day %d  %02d:%02d   %s   tick %d   %d fps" % [
			world.day_number() + 1, int(tod), int(fmod(tod, 1.0) * 60.0),
			"PAUSED" if runner.paused else "%dx" % runner.speed,
			world.tick_count, Engine.get_frames_per_second()],
		"Ambient %.1f °C   sun %s" % [SimConst.k_to_c(world.ambient_k),
			"%.0f°  AM %.1f  DNI %.0f W/m²  diffuse %.0f W/m²" % [rad_to_deg(world.sun_elevation),
				world.air_mass, world.sun_dni, world.diffuse_irradiance] if world.sun_is_up else "down"],
		"Sim %.1f ms/frame   light pass %.0f ms (%d paths)   heat band %.1f ms   overlay: %s (H)" % [runner.sim_ms,
			_light.last_trace_ms, _light.stats.get("rays", 0), _heat.last_step_ms, overlay.mode_name()],
		tool_line,
		"1–%d objects  0 brush   R/F rotate (Shift fine)  X delete   Ctrl+Z undo   Space pause  Tab speed  , . ±1 h" % tool.defs.size(),
	]
	var cell := brush.hovered_cell()
	var g := world.grid
	if g.in_bounds(cell.x, cell.y):
		var i := g.idx(cell.x, cell.y)
		var def := world.materials.get_def(g.material[i])
		var absorbed := 0.0
		if _light.tile_power.size() == g.size():
			absorbed = _light.tile_power[i] * _light.power_scale(world)
		lines.append("(%d, %d)  %s  %.1f °C  integrity %.0f%%  light %.1f W (%.0f W/m²)" % [
			cell.x, cell.y, def.display_name if def else "?", SimConst.k_to_c(g.temperature[i]),
			g.integrity[i] * 100.0, absorbed, absorbed / (SimConst.TILE_M * SimConst.DEPTH_M)])
	var obj: SimObject = world.objects.get(tool.hovered_id)
	if obj != null:
		var info := "%s #%d  at (%.2f, %.2f) m  %.1f°" % [obj.def.display_name, obj.id,
			obj.position.x, obj.position.y, rad_to_deg(obj.angle)]
		if obj.def.kind == ObjectDef.Kind.PROBE:
			var bins := PackedStringArray()
			for b in Spectrum.BIN_COUNT:
				bins.append("%.1f" % obj.incident[b])
			info += "   %.0f W/m²  bins W [%s]" % [obj.probe_irradiance(), ", ".join(bins)]
		else:
			info += "   absorbing %.1f W" % obj.absorbed_w
		lines.append(info)
	text = "\n".join(lines)
