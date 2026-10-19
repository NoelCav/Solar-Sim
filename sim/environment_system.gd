class_name EnvironmentSystem
extends SimSystem
## Time of day, sun direction and intensity, ambient temperature (tick step 2).
## Circular sun arc; latitude, seasons and weather come later.


func system_name() -> StringName:
	return &"environment"


func tick(world: SimWorld, _dt: float) -> void:
	var day := world.time_of_day()
	# Sun angle: 0 at sunrise (6:00), PI at sunset (18:00).
	var sun_angle := (day - 0.25) * TAU
	world.sun_elevation = sin(sun_angle) * deg_to_rad(world.site_max_elevation_deg)
	world.sun_is_up = world.sun_elevation > 0.0
	# Direction light travels, in world space (y down). Sun rises on the left (east).
	# Projected onto the east–west slice plane the sun always passes the zenith at noon;
	# true elevation (above) only affects intensity via air mass.
	var horizontal := -cos(sun_angle)
	world.sun_direction = Vector2(-horizontal, maxf(sin(sun_angle), 0.0)).normalized() \
		if world.sun_is_up else Vector2.DOWN
	# Ambient peaks mid-afternoon (~15:00), coldest before dawn.
	world.ambient_k = world.site_mean_ambient_k \
		+ SimConst.AMBIENT_SWING_K * sin((day - 0.375) * TAU)
	_update_irradiance(world)


## Direct normal irradiance per bin from air mass (Kasten–Young air mass, per-bin optical
## depths in Spectrum.atmospheric), so low sun is dimmer and redder (§6.2).
func _update_irradiance(world: SimWorld) -> void:
	if not world.sun_is_up:
		world.air_mass = INF
		world.sun_dni = 0.0
		world.sun_spectrum = Spectrum.make_zero()
		world.diffuse_irradiance = 0.0
		return
	var h := world.sun_elevation
	var am := 1.0 / (sin(h) + 0.50572 * pow(rad_to_deg(h) + 6.07995, -1.6364))
	world.air_mass = am
	world.sun_spectrum = Spectrum.atmospheric(am)
	world.sun_dni = Spectrum.total(world.sun_spectrum)
	world.diffuse_irradiance = SimConst.DIFFUSE_W_M2 * sqrt(sin(h))
