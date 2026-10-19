class_name SkyRenderer
extends ColorRect
## Sky behind the world, in screen space (it follows the camera). No sun disk: a soft glow
## comes in from the screen edge the light comes from, colored by the spectrum that actually
## arrives (Spectrum.atmospheric), and the sky's own color is that light as scattered by air
## (Spectrum.sky_scatter): blue at noon, orange-red low at dawn and dusk. At night a pale
## blue glow comes from wherever the moon is (EnvironmentSystem), with stars.

const NIGHT_TOP := Color(0.003, 0.004, 0.012)
const NIGHT_LOW := Color(0.008, 0.011, 0.026)
const MOON := Color(0.55, 0.65, 0.95)
const GLOW_RADIUS := 1.1       ## Glow radius, fraction of the screen diagonal
const GLOW_OUTSIDE := 0.2      ## How far past the screen edge the glow is centred, fraction of its radius
const STARS := 140

var world: SimWorld
var _glow_tex: GradientTexture2D


func setup(p_world: SimWorld) -> void:
	world = p_world
	z_index = -10
	color = Color(0, 0, 0, 0)    # Everything is drawn in _draw
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# Screen space, behind the world: a rect repositioned from the canvas transform each
	# frame lags a camera moved later in the frame, showing black at the edges while panning.
	var layer := CanvasLayer.new()
	layer.layer = -1
	get_parent().add_child(layer)
	reparent(layer, false)
	var g := Gradient.new()
	# No bright core and a falloff that eases to zero ((1 - r)³), so it reads as glow: no disk
	# in the middle and no visible rim against a dark night sky.
	var offsets := PackedFloat32Array()
	var colors := PackedColorArray()
	for k in 17:
		var x := k / 16.0
		offsets.append(x)
		colors.append(Color(1, 1, 1, 0.55 * pow(1.0 - x, 3.0)))
	g.offsets = offsets
	g.colors = colors
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
	position = Vector2.ZERO
	size = get_viewport_rect().size
	queue_redraw()


func _draw() -> void:
	if world == null:
		return
	var sun_angle := world.sun_arc_angle
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
		_glow(sun_angle, Color(c.r, c.g * 0.95, c.b * 0.85, clampf(world.sun_dni / 700.0, 0.2, 0.7)))
	# The moon's glow follows the real moon, brighter the more of it is lit, once the sun is low.
	if world.moon_is_up and h < 0.1:
		var a := 0.28 * sqrt(world.moon_illuminated) * clampf((0.1 - h) / 0.3, 0.0, 1.0)
		if a > 0.01:
			_glow(world.moon_arc_angle, Color(MOON.r, MOON.g, MOON.b, a))


## A radial glow centred beyond where the line from the screen centre toward the light source
## (at `angle` on the sky arc: 0 east horizon, PI/2 overhead) leaves the screen, so only its
## soft outer part shows.
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
	var r := size.length() * GLOW_RADIUS
	var at := half + toward * (t + r * GLOW_OUTSIDE)
	draw_texture_rect(_glow_tex, Rect2(at - Vector2(r, r), Vector2(r, r) * 2.0), false, col)


static func _hash(n: int) -> float:
	return fposmod(sin(n * 12.9898 + 78.233) * 43758.5453, 1.0)
