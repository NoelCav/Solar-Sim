class_name SolarCell
extends RefCounted
## The solar cell model (design doc §9.1): electrical power a cell can deliver from the light
## arriving on its face, per spectral bin. Pure functions; the cell's parameters are on its
## ObjectDef (bandgap, collection, voltage factor, Voc, temperature coefficient, series loss).
##
## Per bin of photon energy E: below the bandgap Eg nothing is converted (it heats the cell);
## above it, each photon yields at most Eg, so
##   P_elec = P_bin · (Eg / E) · η_collect · η_voltage · η_temp · η_series
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
	var total := Spectrum.total(spectrum)
	if total <= 0.0 or area_m2 <= 0.0:
		return 0.0
	var c := total / area_m2 / SimConst.REFERENCE_DNI
	var eta := def.cell_collection * voltage_efficiency(def, c) * temperature_efficiency(def, temp_k) \
		* series_efficiency(def, c)
	if eta <= 0.0:
		return 0.0
	var p := 0.0
	for b in Spectrum.BIN_COUNT:
		var e := Spectrum.PHOTON_EV[b]
		if e >= def.cell_bandgap_ev:
			p += spectrum[b] * def.cell_bandgap_ev / e
	return p * eta


## η_voltage at concentration c (clamped below at a thousandth of a sun).
static func voltage_efficiency(def: ObjectDef, c: float) -> float:
	return def.cell_voltage_factor * (1.0 + KT_Q_V * log(maxf(c, 1e-3)) / def.cell_voc_v)


## η_temp at cell temperature temp_k (never below 0).
static func temperature_efficiency(def: ObjectDef, temp_k: float) -> float:
	return maxf(1.0 - def.cell_temp_coeff * (temp_k - T_REF_K), 0.0)


## η_series at concentration c (never below 0).
static func series_efficiency(def: ObjectDef, c: float) -> float:
	return maxf(1.0 - def.cell_series_r * c, 0.0)
