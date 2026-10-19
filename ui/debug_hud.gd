class_name DebugHud
extends Label
## Top-left readout: time, speed, tick, brush, and the hovered tile's state.

var world: SimWorld
var runner: Main
var brush: CreativeBrush


func setup(p_world: SimWorld, p_runner: Main, p_brush: CreativeBrush) -> void:
	world = p_world
	runner = p_runner
	brush = p_brush
	position = Vector2(12, 8)
	add_theme_color_override(&"font_shadow_color", Color.BLACK)
	add_theme_constant_override(&"shadow_offset_x", 1)
	add_theme_constant_override(&"shadow_offset_y", 1)


func _process(_delta: float) -> void:
	if world == null:
		return
	var tod := world.time_of_day() * 24.0
	var lines: PackedStringArray = [
		"Day %d  %02d:%02d   %s   tick %d   %d fps" % [
			world.day_number() + 1, int(tod), int(fmod(tod, 1.0) * 60.0),
			"PAUSED" if runner.paused else "%dx" % runner.speed,
			world.tick_count, Engine.get_frames_per_second()],
		"Ambient %.1f °C   sun %s" % [
			SimConst.k_to_c(world.ambient_k),
			"%.0f°" % rad_to_deg(world.sun_elevation) if world.sun_is_up else "down"],
		"Brush: %s  (size %d)   Q/E material  [ ] size  LMB paint  RMB erase  Ctrl+Z undo" % [
			brush.selected().display_name, brush.brush_radius * 2 + 1],
		"Space pause   Tab speed   WASD / MMB pan   wheel zoom",
	]
	var cell := brush.hovered_cell()
	var g := world.grid
	if g.in_bounds(cell.x, cell.y):
		var i := g.idx(cell.x, cell.y)
		var def := world.materials.get_def(g.material[i])
		lines.append("(%d, %d)  %s  %.1f °C  integrity %.0f%%" % [
			cell.x, cell.y, def.display_name if def else "?",
			SimConst.k_to_c(g.temperature[i]), g.integrity[i] * 100.0])
	text = "\n".join(lines)
