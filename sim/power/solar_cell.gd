class_name SolarCell
extends RefCounted
## The solar cell model (design doc §9.1): electrical power a cell can deliver from the light
## arriving on its face, per spectral bin. Pure functions; the cell's parameters are on its
## ObjectDef (front reflectance, bandgap, collection, voltage factor, Voc, temperature
## coefficient, series loss).
##
## Per bin: the coating reflects R; of the rest, photons below the bandgap Eg are not converted
## (they heat the cell); above it each photon yields at most Eg, so
##   P_elec = P_bin · (1 − R) · (Eg / E) · η_collect · η_voltage · η_temp · η_series
## - η_voltage = voltage_factor · (1 + (kT/q) · ln C / Voc): concentration C raises the voltage
## - η_temp = 1 − β · (T − 298 K): hot cells lose voltage
## - η_series = 1 − r_s · C: resistive loss grows with the current, i.e. with C
## C is the light arriving relative to plain sunlight (SimConst.REFERENCE_DNI). Everything a
## cell absorbs and doesn't deliver becomes heat in its own thermal node (D13).

const T_REF_K := 298.0
const KT_Q_V := 0.02569   ## Thermal voltage kT/q at T_REF_K, V


## Maximum electrical power (W) a cell of `def` delivers from `spectrum` (W per bin arriving
## on its active face) at cell temperature `temp_k`, over a face of `area_m2`.
static func max_power(def: ObjectDef, spectrum: PackedFloat32Array, temp_k: float, area_m2: float) -> float:
	return analyze(def, spectrum, temp_k, area_m2)["power_w"]


## Where the light arriving on a cell goes, W (the terms add up to the light arriving):
## power_w (electricity), reflected_w (by the coating), below_gap_w (photons under Eg),
## excess_w (photon energy above Eg), collection_w, voltage_w, temperature_w, series_w (the
## factors' losses, in that order); and power_bin_w, electricity per spectral bin.
static func analyze(def: ObjectDef, spectrum: PackedFloat32Array, temp_k: float, area_m2: float) -> Dictionary:
	var out := {"power_w": 0.0, "reflected_w": 0.0, "below_gap_w": 0.0, "excess_w": 0.0,
		"collection_w": 0.0, "voltage_w": 0.0, "temperature_w": 0.0, "series_w": 0.0,
		"power_bin_w": Spectrum.make_zero()}
	var total := Spectrum.total(spectrum)
	if total <= 0.0 or area_m2 <= 0.0:
		return out
	var c := total / area_m2 / SimConst.REFERENCE_DNI
	var factors := [def.cell_collection, voltage_efficiency(def, c), temperature_efficiency(def, temp_k),
		series_efficiency(def, c)]
	var eta := 1.0
	for f: float in factors:
		eta *= maxf(f, 0.0)
	var ceiling := 0.0   # Eg per absorbed photon above the gap, W
	for b in Spectrum.BIN_COUNT:
		var r := def.reflectance[b] if b < def.reflectance.size() else 0.0
		var absorbed := spectrum[b] * (1.0 - r)
		out.reflected_w += spectrum[b] * r
		var e := Spectrum.PHOTON_EV[b]
		if e < def.cell_bandgap_ev:
			out.below_gap_w += absorbed
			continue
		var top := absorbed * def.cell_bandgap_ev / e
		out.excess_w += absorbed - top
		out.power_bin_w[b] = top * eta
		ceiling += top
	var left := ceiling
	for k in factors.size():
		var kept := left * maxf(factors[k], 0.0)
		out[["collection_w", "voltage_w", "temperature_w", "series_w"][k]] = left - kept
		left = kept
	out.power_w = left
	return out


## A cell's rated efficiency: plain sunlight (AM1.5, SimConst.REFERENCE_DNI) at 25 °C.
static func rated_efficiency(def: ObjectDef) -> float:
	var area := def.size_m * SimConst.DEPTH_M
	var watts := SimConst.REFERENCE_DNI * area
	return max_power(def, Spectrum.from_total(watts), T_REF_K, area) / watts


## The front-face light of cell object `obj` now, W per bin: the traced light times
## `light_scale` (LightSystem.power_scale); `direct_only` keeps the part straight from the source.
static func object_light(obj: SimObject, light_scale: float, direct_only := false) -> PackedFloat32Array:
	var s := (obj.incident_direct if direct_only else obj.incident).duplicate()
	for b in Spectrum.BIN_COUNT:
		s[b] *= light_scale
	return s


## The temperature a cell object runs at, K (its own node; 25 °C before it has one).
static func object_temperature(obj: SimObject) -> float:
	return obj.temperature_k if obj.temperature_k > 0.0 else T_REF_K


## What cell object `obj` could deliver now, W.
static func object_power(obj: SimObject, light_scale: float) -> float:
	return max_power(obj.def, object_light(obj, light_scale), object_temperature(obj),
		obj.def.size_m * SimConst.DEPTH_M)


## η_voltage at concentration c (clamped below at a thousandth of a sun).
static func voltage_efficiency(def: ObjectDef, c: float) -> float:
	return def.cell_voltage_factor * (1.0 + KT_Q_V * log(maxf(c, 1e-3)) / def.cell_voc_v)


## η_temp at cell temperature temp_k (never below 0).
static func temperature_efficiency(def: ObjectDef, temp_k: float) -> float:
	return maxf(1.0 - def.cell_temp_coeff * (temp_k - T_REF_K), 0.0)


## η_series at concentration c (never below 0).
static func series_efficiency(def: ObjectDef, c: float) -> float:
	return maxf(1.0 - def.cell_series_r * c, 0.0)
