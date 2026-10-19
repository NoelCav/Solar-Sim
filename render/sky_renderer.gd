class_name SkyRenderer
extends ColorRect
## Sky behind the world, in screen space (it follows the camera): a gradient that follows the
## time of day, the sun and moon on an arc across the screen, and stars at night. The sun's
## place on the arc matches the direction light travels, so shadows point away from it.

const NIGHT_TOP := Color(0.01, 0.015, 0.05)
const NIGHT_LOW := Color(0.04, 0.06, 0.14)
const DAY_TOP := Color(0.16, 0.32, 0.62)
const DAY_LOW := Color(0.50, 0.68, 0.88)
const DUSK_TOP := Color(0.20, 0.20, 0.42)
const DUSK_LOW := Color(0.95, 0.50, 0.25)
const SUN_PX := 34.0           ## Sun disk radius on screen
const MOON_PX := 24.0
const ARC_X := 0.44            ## Half-width of the sun's arc, fraction of the screen
const ARC_Y := 0.78            ## Height of the arc, fraction of the screen
const HORIZON := 0.92          ## Where the arc meets the "horizon", fraction down the screen
const STARS := 140

var world: SimWorld


func setup(p_world: SimWorld) -> void:
	world = p_world
	z_index = -10
	color = Color(0, 0, 0, 0)    # Everything is drawn in _draw
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	if world == null:
		return
	# Cover exactly what the camera sees.
	var inv := get_viewport().get_canvas_transform().affine_inverse()
	var vp := get_viewport_rect().size
	position = inv * Vector2.ZERO
	size = inv.basis_xform(vp)
	queue_redraw()


func _draw() -> void:
	if world == null:
		return
	var day := world.time_of_day()
	var sun_angle := (day - 0.25) * TAU   # 0 at sunrise, PI at sunset (as EnvironmentSystem)
	var h := sin(sun_angle)               # Sun height, -1..1
	var day_mix := smoothstep(-0.12, 0.25, h)
	var dusk := clampf(1.0 - absf(h) / 0.3, 0.0, 1.0)
	var top := NIGHT_TOP.lerp(DAY_TOP, day_mix).lerp(DUSK_TOP, dusk * 0.5)
	var low := NIGHT_LOW.lerp(DAY_LOW, day_mix).lerp(DUSK_LOW, dusk * 0.7)
	var w := size.x
	var ht := size.y
	draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(w, 0), Vector2(w, ht), Vector2(0, ht)]),
		PackedColorArray([top, top, low, low]))
	var px := w / get_viewport_rect().size.x   # Canvas units per screen pixel
	# Stars fade in after dusk.
	var star_a := 1.0 - smoothstep(-0.25, 0.0, h)
	if star_a > 0.0:
		for k in STARS:
			var p := Vector2(_hash(k * 2), _hash(k * 2 + 1) * 0.8) * size
			var tw := 0.6 + 0.4 * _hash(k * 7 + 3)
			draw_circle(p, (0.8 + _hash(k * 5) * 1.2) * px, Color(1, 1, 1, star_a * tw * 0.8))
	# Sun and moon on the same arc, opposite each other.
	var sun := _arc_point(sun_angle)
	if h > -0.15:
		var warm := clampf(1.0 - h / 0.4, 0.0, 1.0)
		var core := Color(1.0, 0.97, 0.85).lerp(Color(1.0, 0.65, 0.35), warm)
		for k in range(6, 0, -1):
			var r := SUN_PX * px * (1.0 + k * 0.9)
			draw_circle(sun, r, Color(core.r, core.g * 0.95, core.b * 0.8, 0.05))
		draw_circle(sun, SUN_PX * px, core)
	var moon := _arc_point(sun_angle + PI)
	if h < 0.15:
		var a := clampf((0.15 - h) / 0.3, 0.0, 1.0)
		draw_circle(moon, MOON_PX * px * 2.2, Color(0.8, 0.85, 1.0, 0.06 * a))
		draw_circle(moon, MOON_PX * px, Color(0.86, 0.88, 0.94, a))
		draw_circle(moon + Vector2(-0.35, -0.2) * MOON_PX * px, MOON_PX * px * 0.25, Color(0.72, 0.74, 0.8, a))
		draw_circle(moon + Vector2(0.3, 0.3) * MOON_PX * px, MOON_PX * px * 0.18, Color(0.72, 0.74, 0.8, a))


## Point on the sky arc for an angle (0 = east horizon on the left, PI/2 = overhead).
func _arc_point(angle: float) -> Vector2:
	return Vector2(size.x * (0.5 - ARC_X * cos(angle)), size.y * (HORIZON - ARC_Y * sin(angle)))


static func _hash(n: int) -> float:
	return fposmod(sin(n * 12.9898 + 78.233) * 43758.5453, 1.0)
