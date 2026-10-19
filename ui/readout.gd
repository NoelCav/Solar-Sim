class_name Readout
extends RefCounted
## Text for values shown to the player (HUD, inspector, map labels, legends): one place for
## units and for comparing light to the source being traced.


## Irradiance with a unit that fits its size (µW/m² for starlight-dim, MW/m² for a focus).
static func irradiance(w_m2: float) -> String:
	if w_m2 >= 1e6:
		return "%.1f MW/m²" % (w_m2 / 1e6)
	if w_m2 >= 1e4:
		return "%.0f kW/m²" % (w_m2 / 1e3)
	if w_m2 >= 1e3:
		return "%.1f kW/m²" % (w_m2 / 1e3)
	if w_m2 >= 1.0 or w_m2 <= 0.0:
		return "%.0f W/m²" % w_m2
	if w_m2 >= 1e-3:
		return "%.1f mW/m²" % (w_m2 * 1e3)
	return "%.1f µW/m²" % (w_m2 * 1e6)


## Money, e.g. "$12.34" (cents shown to a hundredth while amounts are small).
static func money(dollars: float) -> String:
	return "$%.2f" % dollars if absf(dollars) >= 10.0 else "$%.4f" % dollars


## Electrical power with a unit that fits its size.
static func power(watts: float) -> String:
	if absf(watts) >= 1e6:
		return "%.2f MW" % (watts / 1e6)
	if absf(watts) >= 1e3:
		return "%.2f kW" % (watts / 1e3)
	return "%.1f W" % watts


## Irradiance split by Spectrum band, e.g. "UV 4 W/m² · visible 410 W/m² · IR 520 W/m²".
static func bands(uv: float, visible: float, infrared: float) -> String:
	return "UV %s · visible %s · IR %s" % [irradiance(uv), irradiance(visible), irradiance(infrared)]


## "sun" or "moon": the light being traced.
static func light_name(world: SimWorld) -> String:
	return "moon" if world.light_is_moon else "sun"


## Irradiance as a multiple of plain light from the source being traced (0 when none is up).
static func times_light(world: SimWorld, w_m2: float) -> float:
	return w_m2 / world.light_dni if world.light_dni > 0.0 else 0.0
