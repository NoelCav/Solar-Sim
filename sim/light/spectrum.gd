class_name Spectrum
extends RefCounted
## The six spectral bins light is carried in (design doc §6.1).

enum Bin { UV, BLUE, GREEN, RED, NIR, IR }

const BIN_COUNT := 6

## Representative wavelength per bin, micrometers (used for dispersion).
const WAVELENGTH_UM: Array[float] = [0.350, 0.460, 0.540, 0.680, 0.950, 1.500]

## Photon energy per bin, eV (E = 1.240 / λ[µm]).
const PHOTON_EV: Array[float] = [3.54, 2.70, 2.30, 1.82, 1.31, 0.83]

## Approximate share of AM1.5 solar power per bin (sums to 1).
const AM15_SHARE: Array[float] = [0.05, 0.14, 0.16, 0.25, 0.22, 0.18]

## Display color per bin. NIR/IR are invisible in normal view.
const DISPLAY_COLOR: Array[Color] = [
	Color(0.55, 0.20, 1.00),
	Color(0.15, 0.35, 1.00),
	Color(0.20, 1.00, 0.30),
	Color(1.00, 0.20, 0.10),
	Color(0.45, 0.05, 0.05, 0.0),
	Color(0.20, 0.00, 0.00, 0.0),
]


static func make_zero() -> PackedFloat32Array:
	var s := PackedFloat32Array()
	s.resize(BIN_COUNT)
	return s


## Splits a total power (W) across bins by the AM1.5 shares.
static func from_total(total_w: float) -> PackedFloat32Array:
	var s := make_zero()
	for i in BIN_COUNT:
		s[i] = total_w * AM15_SHARE[i]
	return s


## AM1.5 shares reshaped for air mass `am` (blue attenuates faster), scaled to total `total_w`.
static func reddened(total_w: float, am: float) -> PackedFloat32Array:
	var s := make_zero()
	var sum := 0.0
	for i in BIN_COUNT:
		var rayleigh := pow(0.55 / WAVELENGTH_UM[i], 4.0)
		s[i] = AM15_SHARE[i] * exp(-SimConst.REDDENING * (am - 1.5) * rayleigh)
		sum += s[i]
	for i in BIN_COUNT:
		s[i] *= total_w / sum
	return s


static func total(s: PackedFloat32Array) -> float:
	var t := 0.0
	for v in s:
		t += v
	return t
