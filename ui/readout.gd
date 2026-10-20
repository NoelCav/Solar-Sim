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


## An item's numbers for the build catalog: the one that matters most at a glance (on the
## card), or all of them when `full` (the card's tooltip).
static func item_stats(def: ObjectDef, materials: MaterialDB, full := false) -> String:
	var mat := materials.get_by_key(def.material)
	var n := mat.refractive_index(0.55) if mat != null else 1.0
	match def.kind:
		ObjectDef.Kind.LENS:
			var f := OpticsGen.focal_length(def.size_m, def.radius_front_m, def.radius_back_m, def.thickness_m, n)
			if is_inf(f):
				return plate_stats(def, mat, full)
			var focus := "focus %s" % length(f) if f > 0.0 else "diverges, focus −%s" % length(-f)
			if not full:
				return "%s · %s" % [length(def.size_m), focus]
			return "%s wide · %s · %.0f %% through · %s, n %.2f" % [length(def.size_m), focus,
				OpticsGen.normal_transmission(n) * 100.0, mat.display_name if mat else "?", n]
		ObjectDef.Kind.MIRROR:
			return "%s · reflects %.0f %%" % [length(def.size_m), _mean(def.reflectance) * 100.0]
		ObjectDef.Kind.PRISM:
			if not full:
				return "%.0f° · %s" % [def.apex_angle_deg, mat.display_name if mat else "?"]
			return "%.0f° apex · %s · n %.2f" % [def.apex_angle_deg, mat.display_name if mat else "?", n]
		ObjectDef.Kind.CELL:
			if not full:
				return "%s · %s rated" % [length(def.size_m), power(SolarCell.rated_power(def))]
			return "%s · %s rated: %.0f %% of plain sun, face-on at 25 °C" % [length(def.size_m),
				power(SolarCell.rated_power(def)), SolarCell.rated_efficiency(def) * 100.0]
		ObjectDef.Kind.PROBE:
			return "Measures light; blocks nothing"
		ObjectDef.Kind.GRID_TIE:
			return "Sells the power of its wire network"
		ObjectDef.Kind.LAMP:
			var lamp := "%s · %s of light" % [power(def.lamp_watts), power(def.lamp_light_w())]
			if not full:
				return lamp
			var cone := "all around" if def.lamp_spread_deg >= 360.0 else "a %.0f° cone" % def.lamp_spread_deg
			return "%s · lights %s" % [lamp, cone]
		ObjectDef.Kind.BATTERY:
			var held := "%s · %s" % [energy(def.battery_capacity_kwh * Market.J_PER_KWH), power(def.battery_max_w)]
			return held + " · takes surplus when power is cheap, sells when dear" if full else held
	return ""


## A flat plate (a lens with flat faces: a filter or a window): how much of each color it passes at
## normal incidence (two faces' reflection and the glass's absorption over its thickness).
static func plate_stats(def: ObjectDef, mat: MaterialDef, full: bool) -> String:
	if mat == null:
		return ""
	var share := PackedStringArray()
	var labels := ["UV", "B", "G", "R", "NIR"]
	for b in labels.size():
		var n := mat.refractive_index(Spectrum.WAVELENGTH_UM[b])
		var t := OpticsGen.normal_transmission(n) * exp(-mat.bulk_absorption[b] * maxf(def.thickness_m, 0.005))
		share.append("%s %.0f %%" % [labels[b], t * 100.0])
	if not full:
		return "%s plate · passes %s" % [length(def.size_m), " ".join(share.slice(1, 4))]
	return "%s plate, %s thick · passes %s" % [length(def.size_m), length(def.thickness_m), " · ".join(share)]


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


## Energy with a unit that fits its size, from joules.
static func energy(joules: float) -> String:
	var kwh := joules / Market.J_PER_KWH
	return "%.2f kWh" % kwh if absf(kwh) >= 1.0 else "%.0f Wh" % (kwh * 1000.0)


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
