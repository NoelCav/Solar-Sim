class_name EnvironmentSystem
extends SimSystem
## Time of day, sun direction and ambient temperature (tick step 2).
## M0: a simple circular sun arc. Latitude, seasons, air mass and weather come in M1+.


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
