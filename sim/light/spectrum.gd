class_name Spectrum
extends RefCounted
## The six spectral bins light is carried in (design doc §6.1).

enum Bin { UV, BLUE, GREEN, RED, NIR, IR }
enum Band { UV, VISIBLE, INFRARED }   ## Coarse groupings of bins (BAND_OF)

const BIN_COUNT := 6

## Representative wavelength per bin, micrometers (used for dispersion).
const WAVELENGTH_UM: Array[float] = [0.350, 0.460, 0.540, 0.680, 0.950, 1.500]

## Photon energy per bin, eV (E = 1.240 / λ[µm]).
const PHOTON_EV: Array[float] = [3.54, 2.70, 2.30, 1.82, 1.31, 0.83]

## Share of solar power per bin above the atmosphere (AM0, sums to 1).
const AM0_SHARE: Array[float] = [0.08, 0.145, 0.135, 0.22, 0.17, 0.25]

## Clear-sky optical depths per bin at air mass 1 (§6.2): Rayleigh scattering by air
## (0.008735 λ^-4.08, Leckner), haze (Ångström β λ^-α with β 0.08, α 1.3) and absorption by
## water vapour and ozone (bands in NIR/IR; Chappuis ozone near red is small).
const TAU_RAYLEIGH: Array[float] = [0.633, 0.208, 0.108, 0.042, 0.0107, 0.0016]
const TAU_HAZE: Array[float] = [0.314, 0.219, 0.178, 0.132, 0.086, 0.047]
const TAU_ABSORB: Array[float] = [0.02, 0.0, 0.01, 0.01, 0.10, 0.20]

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


# --- Bands: coarse groupings of bins for views and per-band deposits ---
const BAND_COUNT := 3
const BAND_OF: Array[int] = [0, 1, 1, 1, 2, 2]
const BAND_NAMES: Array[String] = ["UV", "visible", "infrared"]


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


## Direct sunlight per bin (W/m², normal to the beam) after crossing `am` air masses:
## each bin attenuated by its own optical depth (Beer–Lambert), so low sun loses UV and blue
## first and turns red. At AM1.5 this totals ≈850 W/m²; at 5° elevation ≈95 W/m².
static func atmospheric(am: float) -> PackedFloat32Array:
	var s := make_zero()
	for i in BIN_COUNT:
		var tau := TAU_RAYLEIGH[i] + TAU_HAZE[i] + TAU_ABSORB[i]
		s[i] = SimConst.SOLAR_CONSTANT * AM0_SHARE[i] * exp(-am * tau)
	return s


## Skylight color per bin: direct light re-weighted by how strongly each bin scatters
## (Rayleigh plus a little haze), normalized; blue at noon, orange-red near the horizon.
static func sky_scatter(direct: PackedFloat32Array) -> PackedFloat32Array:
	var s := make_zero()
	for i in BIN_COUNT:
		s[i] = direct[i] * (TAU_RAYLEIGH[i] + 0.3 * TAU_HAZE[i])
	return s


## Display color (linear RGB, max component 1) of a spectrum's visible bins.
static func to_color(s: PackedFloat32Array) -> Color:
	var c := Vector3.ZERO
	for i in BIN_COUNT:
		var d := DISPLAY_COLOR[i]
		if d.a > 0.0 and i != Bin.UV:
			c += Vector3(d.r, d.g, d.b) * s[i] / maxf(AM15_SHARE[i], 1e-3)
	var m := maxf(c.x, maxf(c.y, c.z))
	return Color(c.x / m, c.y / m, c.z / m) if m > 0.0 else Color.BLACK


static func total(s: PackedFloat32Array) -> float:
	var t := 0.0
	for v in s:
		t += v
	return t
