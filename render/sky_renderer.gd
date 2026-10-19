class_name SkyRenderer
extends ColorRect
## Sky behind the world, in screen space (it follows the camera). No sun disk: a soft glow
## comes in from the screen edge the light comes from, colored by the spectrum that actually
## arrives (Spectrum.atmospheric), and the sky's own color is that light as scattered by air
## (Spectrum.sky_scatter): blue at noon, orange-red low at dawn and dusk. At night a pale
## blue moon glow comes from the opposite side, with stars.

const NIGHT_TOP := Color(0.012, 0.018, 0.05)
const NIGHT_LOW := Color(0.03, 0.045, 0.10)
const MOON := Color(0.55, 0.65, 0.95)
const GLOW_RADIUS := 0.85      ## Glow radius, fraction of the screen diagonal
const STARS := 140

var world: SimWorld
var _glow_tex: GradientTexture2D


func setup(p_world: SimWorld) -> void:
	world = p_world
	z_index = -10
	color = Color(0, 0, 0, 0)    # Everything is drawn in _draw
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var g := Gradient.new()
	g.offsets = PackedFloat32Array([0.0, 0.08, 0.35, 1.0])
	g.colors = PackedColorArray([Color(1, 1, 1, 0.95), Color(1, 1, 1, 0.55), Color(1, 1, 1, 0.15),
		Color(1, 1, 1, 0.0)])
	_glow_tex = GradientTexture2D.new()
	_glow_tex.gradient = g
	_glow_tex.fill = GradientTexture2D.FILL_RADIAL
	_glow_tex.fill_from = Vector2(0.5, 0.5)
	_glow_tex.fill_to = Vector2(1.0, 0.5)
	_glow_tex.width = 256
	_glow_tex.height = 256


func _process(_delta: float) -> void:
	if world == null:
		return
	# Cover exactly what the camera sees.
	var inv := get_viewport().get_canvas_transform().affine_inverse()
	position = inv * Vector2.ZERO
	size = inv.basis_xform(get_viewport_rect().size)
	queue_redraw()


func _draw() -> void:
	if world == null:
		return
	var sun_angle := (world.time_of_day() - 0.25) * TAU   # 0 at sunrise, PI at sunset
	var h := sin(sun_angle)
	var w := size.x
	var ht := size.y
	# Sky: scattered sunlight overhead, the direct (reddened) color toward the horizon.
	var top := NIGHT_TOP
	var low := NIGHT_LOW
	if world.sun_is_up:
		var direct := world.sun_spectrum
		var day := clampf(world.sun_dni / 900.0, 0.0, 1.0)
		# Overhead sky is lit along a short path (still blue at dawn); near the horizon the
		# long-path, reddened direct light dominates.
		var zenith := Spectrum.to_color(Spectrum.sky_scatter(Spectrum.atmospheric(minf(world.air_mass, 1.5))))
		var horizon := Spectrum.to_color(direct)
		var warm := 1.0 - smoothstep(2.0, 8.0, 12.0 - minf(world.air_mass, 12.0))   # 1 when AM ≳ 10
		top = NIGHT_TOP.lerp(zenith * Color(0.42, 0.58, 0.85), smoothstep(0.0, 0.45, day + 0.15))
		low = NIGHT_LOW.lerp(zenith.lerp(horizon, 0.25 + 0.6 * warm) * Color(0.82, 0.86, 0.95),
			smoothstep(0.0, 0.3, day + 0.1))
	elif h > -0.2:
		# Twilight after sunset / before sunrise.
		var t := (h + 0.2) / 0.2
		low = NIGHT_LOW.lerp(Color(0.35, 0.18, 0.15), t * 0.6)
	draw_polygon(PackedVector2Array([Vector2.ZERO, Vector2(w, 0), Vector2(w, ht), Vector2(0, ht)]),
		PackedColorArray([top, top, low, low]))
	var px := w / get_viewport_rect().size.x   # Canvas units per screen pixel
	var star_a := 1.0 - smoothstep(-0.25, 0.0, h)
	if star_a > 0.0:
		for k in STARS:
			var p := Vector2(_hash(k * 2), _hash(k * 2 + 1) * 0.8) * size
			var tw := 0.6 + 0.4 * _hash(k * 7 + 3)
			draw_circle(p, (0.8 + _hash(k * 5) * 1.2) * px, Color(1, 1, 1, star_a * tw * 0.8))
	# Glow from the edge the light comes from.
	if world.sun_is_up:
		var c := Spectrum.to_color(world.sun_spectrum)
		_glow(sun_angle, Color(c.r, c.g * 0.95, c.b * 0.85, clampf(world.sun_dni / 700.0, 0.25, 0.9)))
	if h < 0.1:
		_glow(sun_angle + PI, Color(MOON.r, MOON.g, MOON.b, 0.35 * clampf((0.1 - h) / 0.3, 0.0, 1.0)))


## A radial glow centred where the line from the screen centre toward the light source (at
## `angle` on the sky arc: 0 east horizon, PI/2 overhead) leaves the screen.
func _glow(angle: float, col: Color) -> void:
	var toward := Vector2(-cos(angle), -sin(angle))   # Screen space, y down
	if toward.y > 0.05:
		return   # Below the horizon
	var half := size * 0.5
	var t := INF
	if absf(toward.x) > 1e-4:
		t = minf(t, half.x / absf(toward.x))
	if absf(toward.y) > 1e-4:
		t = minf(t, half.y / absf(toward.y))
	var at := half + toward * t
	var r := size.length() * GLOW_RADIUS
	draw_texture_rect(_glow_tex, Rect2(at - Vector2(r, r), Vector2(r, r) * 2.0), false, col)


static func _hash(n: int) -> float:
	return fposmod(sin(n * 12.9898 + 78.233) * 43758.5453, 1.0)
