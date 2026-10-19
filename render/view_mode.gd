class_name ViewMode
extends RefCounted
## The views the player can switch between (design doc §16): which spectral bins beams show,
## in what colors, and what the tile overlay displays. A wavelength filter (one bin, or -1
## for all) narrows any view to a single bin, shown in its false color.

enum { NORMAL, LIGHT, UV, INFRARED, HEAT }
const COUNT := 5
const NAMES: Array[String] = ["Normal", "Light", "UV", "Infrared", "Heat"]
const HINTS: Array[String] = [
	"Visible light as the eye sees it",
	"All wavelengths in false color; tiles show absorbed light",
	"Ultraviolet only; tiles show absorbed UV",
	"Near and far infrared only; tiles show absorbed IR",
	"Temperature of every tile, ground and air",
]

## Wavelength filter stops: -1 (all), then one per spectral bin.
const WAVELENGTH_NAMES: Array[String] = ["UV", "Blue", "Green", "Red", "Near IR", "Infrared"]

enum Overlay { NONE, ABSORBED, TEMPERATURE }

const _HIDDEN := Color(0, 0, 0, 0)
const _FALSE_COLORS: Array[Color] = [
	Color(0.62, 0.25, 1.00),   # UV
	Color(0.15, 0.40, 1.00),   # Blue
	Color(0.20, 1.00, 0.35),   # Green
	Color(1.00, 0.22, 0.12),   # Red
	Color(1.00, 0.60, 0.05),   # NIR
	Color(1.00, 0.10, 0.45),   # IR
]


## Beam color per bin for a view and wavelength filter; alpha 0 hides the bin.
static func bin_colors(view: int, wavelength := -1) -> Array[Color]:
	var c: Array[Color] = []
	for b in Spectrum.BIN_COUNT:
		var col := _HIDDEN
		if wavelength >= 0:
			c.append(_FALSE_COLORS[b] if b == wavelength else _HIDDEN)
			continue
		match view:
			NORMAL, HEAT:
				if b >= Spectrum.Bin.BLUE and b <= Spectrum.Bin.RED:
					col = Spectrum.DISPLAY_COLOR[b]
			LIGHT:
				col = _FALSE_COLORS[b]
			UV:
				if b == Spectrum.Bin.UV:
					col = _FALSE_COLORS[b]
			INFRARED:
				if b >= Spectrum.Bin.NIR:
					col = _FALSE_COLORS[b]
		c.append(col)
	return c


## Overall beam brightness for a view (heat view keeps beams faint behind the overlay).
static func beam_gain(view: int) -> float:
	return 0.35 if view == HEAT else 1.0


static func overlay(view: int) -> Overlay:
	match view:
		LIGHT, UV, INFRARED:
			return Overlay.ABSORBED
		HEAT:
			return Overlay.TEMPERATURE
	return Overlay.NONE


## Display name of a wavelength filter stop.
static func wavelength_name(wavelength: int) -> String:
	if wavelength < 0:
		return "All wavelengths"
	var um: float = Spectrum.WAVELENGTH_UM[wavelength]
	var at := "%.0f nm" % (um * 1000.0) if um < 1.0 else "%.1f µm" % um
	return "%s · %s" % [WAVELENGTH_NAMES[wavelength], at]


## Spectrum band the absorbed overlay shows, or -1 for all light.
static func overlay_band(view: int, wavelength := -1) -> int:
	if wavelength >= 0:
		return Spectrum.BAND_OF[wavelength]
	match view:
		UV:
			return Spectrum.Band.UV
		INFRARED:
			return Spectrum.Band.INFRARED
	return -1
