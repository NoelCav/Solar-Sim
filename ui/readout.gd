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


## One line of key numbers for an item in the build catalog.
static func item_stats(def: ObjectDef, materials: MaterialDB) -> String:
	var mat := materials.get_by_key(def.material)
	var n := mat.refractive_index(0.55) if mat != null else 1.0
	match def.kind:
		ObjectDef.Kind.LENS:
			var f := OpticsGen.focal_length(def.size_m, def.radius_front_m, def.radius_back_m, def.thickness_m, n)
			return "%s wide · focus %s · %.0f %% through" % [length(def.size_m), length(f),
				OpticsGen.normal_transmission(n) * 100.0]
		ObjectDef.Kind.MIRROR:
			return "%s · reflects %.0f %%" % [length(def.size_m), _mean(def.reflectance) * 100.0]
		ObjectDef.Kind.PRISM:
			return "%.0f° apex · %s · n %.2f" % [def.apex_angle_deg, mat.display_name if mat else "?", n]
		ObjectDef.Kind.CELL:
			return "%s · %.0f %% in plain sun" % [length(def.size_m), SolarCell.rated_efficiency(def) * 100.0]
		ObjectDef.Kind.PROBE:
			return "Measures light; blocks nothing"
		ObjectDef.Kind.GRID_TIE:
			return "Sells the power of its wire network"
	return ""


## A length, e.g. "1 m", "25 cm", "1.15 m".
static func length(m: float) -> String:
	if is_inf(m):
		return "none"
	if m < 1.0:
		return "%.0f cm" % (m * 100.0)
	return "%.0f m" % m if is_equal_approx(m, roundf(m)) else "%.2f m" % m


## A time of day from hours, e.g. "13:45".
static func clock(hours: float) -> String:
	var minutes := int(roundf(fposmod(hours, 24.0) * 60.0)) % (24 * 60)
	return "%02d:%02d" % [minutes / 60, minutes % 60]


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


static func _mean(values: PackedFloat32Array) -> float:
	var sum := 0.0
	for v in values:
		sum += v
	return sum / maxi(values.size(), 1)


## Irradiance split by Spectrum band, e.g. "UV 4 W/m² · visible 410 W/m² · IR 520 W/m²".
static func bands(uv: float, visible: float, infrared: float) -> String:
	return "UV %s · visible %s · IR %s" % [irradiance(uv), irradiance(visible), irradiance(infrared)]


## "sun" or "moon": the light being traced.
static func light_name(world: SimWorld) -> String:
	return "moon" if world.light_is_moon else "sun"


## Irradiance as a multiple of plain light from the source being traced (0 when none is up).
static func times_light(world: SimWorld, w_m2: float) -> float:
	return w_m2 / world.light_dni if world.light_dni > 0.0 else 0.0
