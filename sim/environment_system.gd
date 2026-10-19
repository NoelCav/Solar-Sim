class_name EnvironmentSystem
extends SimSystem
## Time of day, sun and moon direction and intensity, ambient temperature (tick step 2).
## Circular arcs; latitude, seasons and weather come later. The moon lags the sun by its
## phase (a full moon rises at sunset, later each day) and shines by reflected sunlight.
## The traced light (world.light_*) is the sun when it is up, else the moon.


func system_name() -> StringName:
	return &"environment"


func tick(world: SimWorld, _dt: float) -> void:
	var day := world.time_of_day()
	# Sun angle: 0 at sunrise (6:00), PI at sunset (18:00).
	var sun_angle := (day - 0.25) * TAU
	world.sun_arc_angle = sun_angle
	world.sun_elevation = elevation(world, sun_angle)
	world.sun_is_up = world.sun_elevation > 0.0
	world.sun_direction = arc_direction(sun_angle) if world.sun_is_up else Vector2.DOWN
	world.moon_phase = moon_phase(world.time_s)
	var moon_angle := sun_angle - world.moon_phase * TAU
	world.moon_arc_angle = moon_angle
	world.moon_elevation = elevation(world, moon_angle)
	world.moon_is_up = world.moon_elevation > 0.0
	world.moon_direction = arc_direction(moon_angle) if world.moon_is_up else Vector2.DOWN
	# Ambient peaks mid-afternoon (~15:00), coldest before dawn.
	world.ambient_k = world.site_mean_ambient_k \
		+ SimConst.AMBIENT_SWING_K * sin((day - 0.375) * TAU)
	_update_irradiance(world)


## Moon phase at sim time t: 0 new, 0.5 full.
static func moon_phase(t: float) -> float:
	return fposmod(SimConst.MOON_START_PHASE + t / (SimConst.MOON_CYCLE_DAYS * SimConst.DAY_LENGTH_S), 1.0)


## Elevation (radians) of a body at `angle` on its arc (0 rising, PI setting).
static func elevation(world: SimWorld, angle: float) -> float:
	return sin(angle) * deg_to_rad(world.site_max_elevation_deg)


## Direction light travels from a body at `angle` on its arc, in world space (y down); it
## rises on the left (east). Projected onto the east–west slice plane the arc always passes
## the zenith; true elevation only affects intensity via air mass.
static func arc_direction(angle: float) -> Vector2:
	return Vector2(cos(angle), maxf(sin(angle), 0.0)).normalized()


## Kasten–Young relative air mass at elevation h (radians, > 0).
static func air_mass_at(h: float) -> float:
	return 1.0 / (sin(h) + 0.50572 * pow(rad_to_deg(h) + 6.07995, -1.6364))


## Direct normal irradiance per bin from air mass (Kasten–Young air mass, per-bin optical
## depths in Spectrum.atmospheric), so low sun is dimmer and redder (§6.2).
## The moon reflects sunlight: SimConst.MOON_FULL_RATIO of it at full, falling as the lit
## fraction cubed (a quarter moon is about 1/8 of full, like the real phase curve), through
## the atmosphere at its own air mass.
func _update_irradiance(world: SimWorld) -> void:
	if world.sun_is_up:
		var h := world.sun_elevation
		world.air_mass = air_mass_at(h)
		world.sun_spectrum = Spectrum.atmospheric(world.air_mass)
		world.sun_dni = Spectrum.total(world.sun_spectrum)
		world.diffuse_irradiance = SimConst.DIFFUSE_W_M2 * sqrt(sin(h))
	else:
		world.air_mass = INF
		world.sun_dni = 0.0
		world.sun_spectrum = Spectrum.make_zero()
		world.diffuse_irradiance = 0.0
	world.moon_illuminated = 0.5 * (1.0 - cos(world.moon_phase * TAU))
	world.moon_spectrum = Spectrum.make_zero()
	world.moon_dni = 0.0
	if world.moon_is_up:
		var k := SimConst.MOON_FULL_RATIO * pow(world.moon_illuminated, 3.0)
		var spectrum := Spectrum.atmospheric(air_mass_at(world.moon_elevation))
		for b in Spectrum.BIN_COUNT:
			spectrum[b] *= k
		world.moon_spectrum = spectrum
		world.moon_dni = Spectrum.total(spectrum)
	world.light_is_moon = not world.sun_is_up and world.moon_dni > 0.0
	world.light_is_up = world.sun_is_up or world.light_is_moon
	world.light_direction = world.moon_direction if world.light_is_moon else world.sun_direction
	world.light_dni = world.moon_dni if world.light_is_moon else world.sun_dni
	world.light_spectrum = world.moon_spectrum if world.light_is_moon else world.sun_spectrum
