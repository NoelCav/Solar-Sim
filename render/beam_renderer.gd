class_name BeamRenderer
extends MeshInstance2D
## Draws the published light (design doc §6.7), additively into the HDR 2D buffer:
## - the direct-light sheet: a faint tint over everywhere direct sun reaches, so shadows
##   read clearly;
## - beams: filled triangles whose brightness follows irradiance through a log tone curve,
##   so plain sunlight is faint, a 10× beam is bright and a focus blooms through the glow;
## - secondary rays (pooled reflections) as thin lines.
## Colors follow the current view (ViewMode); unsplit sunlight sums to white.
## Exposure and the moonlight tint come from DisplayLight.

const SHEET_LEVEL := 0.07           ## Brightness of the direct-light sheet
const VERTEX_SCALE := 4.0           ## Vertex colors are stored /4 and scaled back by self_modulate
const FADE_S := 0.25                ## Crossfade from the previous light to a newly published one

var world: SimWorld
var view := ViewMode.NORMAL:
	set(value):
		view = value
		_seen_version = -1
var wavelength := -1:               ## Single bin to show, or -1 for all (ViewMode)
	set(value):
		wavelength = value
		_seen_version = -1

var _light: LightSystem
var _seen_version := -1
var _rgb: Array[Vector3] = []       ## Per-bin color for the current view, white-balanced
var _sky_rgb: Array[Vector3] = []   ## The same as the sun or moon shows it (night vision tints moonlight)
var _old: MeshInstance2D            ## The previous light, fading out after each publish
var _fade := 1.0                    ## 0 → 1 over FADE_S after a publish


func setup(p_world: SimWorld) -> void:
	world = p_world
	_light = world.get_system(&"light")
	z_index = 5
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat
	self_modulate = Color(VERTEX_SCALE, VERTEX_SCALE, VERTEX_SCALE, 1.0)
	_old = MeshInstance2D.new()
	_old.material = mat
	_old.self_modulate = self_modulate
	_old.show_behind_parent = true
	add_child(_old)


func _process(delta: float) -> void:
	if _light != null and _light.trace_version != _seen_version:
		# Light that moved (the sun, an edit) crossfades instead of jumping; a view change
		# swaps at once.
		var moved := _seen_version >= 0
		_old.mesh = mesh if moved else null
		rebuild()
		_fade = 0.0 if moved else 1.0
	if _fade < 1.0:
		_fade = minf(_fade + delta / FADE_S, 1.0)
		if _fade >= 1.0:
			_old.mesh = null
	# Additive blending weights by alpha, so the two meshes sum to one full copy
	# (self_modulate, which children don't inherit).
	self_modulate.a = _fade
	_old.self_modulate.a = 1.0 - _fade


## Brightness for a concentration ratio C (1 = plain sunlight).
static func tone(c: float) -> float:
	return BeamGeometry.tone(c)


## Per-bin colors for the view, scaled so AM1.5 sunlight across the shown bins is white. `_rgb`
## is for lamps, `_sky_rgb` for the sky (tinted pale blue by moonlight).
func _balance() -> void:
	var colors := ViewMode.bin_colors(view, wavelength)
	var white := Vector3.ZERO
	for b in Spectrum.BIN_COUNT:
		if colors[b].a > 0.0:
			white += Vector3(colors[b].r, colors[b].g, colors[b].b) * Spectrum.AM15_SHARE[b]
	_rgb.clear()
	_sky_rgb.clear()
	for b in Spectrum.BIN_COUNT:
		var c := colors[b]
		var v := Vector3.ZERO
		if c.a > 0.0:
			v = Vector3(c.r / maxf(white.x, 1e-3), c.g / maxf(white.y, 1e-3), c.b / maxf(white.z, 1e-3)) \
				* Spectrum.AM15_SHARE[b]
			# A single-band view (UV, IR) has no white to balance against: keep its hue.
			if v.x + v.y + v.z > 0.0 and _shown_bins(colors) <= 2:
				v = Vector3(c.r, c.g, c.b) * Spectrum.AM15_SHARE[b] / _shown_share(colors)
		v *= ViewMode.beam_gain(view)
		_rgb.append(v)
		_sky_rgb.append(v * DisplayLight.MOON_TINT if world.light_is_moon else v)


static func _shown_bins(colors: Array[Color]) -> int:
	var n := 0
	for c in colors:
		if c.a > 0.0:
			n += 1
	return n


static func _shown_share(colors: Array[Color]) -> float:
	var s := 0.0
	for b in Spectrum.BIN_COUNT:
		if colors[b].a > 0.0:
			s += Spectrum.AM15_SHARE[b]
	return s


## Rebuilds the mesh from the published light now.
func rebuild() -> void:
	_seen_version = _light.trace_version
	_balance()
	var px := SimConst.PX_PER_M
	var verts := PackedVector2Array()
	var cols := PackedColorArray()
	for layer in _light.layers():
		var sky := layer.lamp_id < 0
		var rgb := _sky_rgb if sky else _rgb
		var exposure := DisplayLight.exposure(world) if sky else DisplayLight.lamp_exposure(world)
		_build_sheet(layer, rgb, exposure, verts, cols, px)
		_build_beams(layer, rgb, exposure, verts, cols, px)
		_build_rays(layer, rgb, exposure, verts, cols, px)
	if verts.is_empty():
		mesh = null
		return
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = cols
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = m


func _build_sheet(layer: LightLayer, rgb_bins: Array[Vector3], exposure: float, verts: PackedVector2Array,
		cols: PackedColorArray, px: float) -> void:
	var from := layer.sheet_from
	var to := layer.sheet_to
	if from.is_empty():
		return
	# Tint from the current spectrum through the view's colors (reddens at sunset); a lamp's from its own.
	var rgb := Vector3.ZERO
	var share_sum := 0.0
	for b in Spectrum.BIN_COUNT:
		share_sum += Spectrum.AM15_SHARE[b]
	var spectrum := world.light_spectrum if layer.lamp_id < 0 else layer.shown_source.spectrum
	var total := Spectrum.total(spectrum)
	if total <= 0.0:
		return
	for b in Spectrum.BIN_COUNT:
		if Spectrum.AM15_SHARE[b] > 0.0:
			rgb += rgb_bins[b] * (spectrum[b] / total) / Spectrum.AM15_SHARE[b] * share_sum
	var level := SHEET_LEVEL * minf(total * exposure / SimConst.REFERENCE_DNI, 1.0) / VERTEX_SCALE
	var c := Color(rgb.x * level, rgb.y * level, rgb.z * level, 1.0)
	if layer.sheet_point:
		# A lamp's lanes fan out: one wedge per drawn lane, as wide as the lanes it stands for.
		var spread := SimConst.LANE_WIDTH_RAD * LightPass.SHEET_STRIDE * 0.5
		for k in from.size():
			var a := from[k] * px
			var b := to[k] * px
			var side := (b - a).orthogonal() * spread
			verts.append_array([a, b - side, b + side])
			for j in 3:
				cols.append(c)
		return
	# One strip per drawn lane, exactly as wide as the lanes it stands for, so neighbours
	# meet edge to edge whatever their lengths (shadow edges stay crisp, no slits).
	var half := SimConst.LANE_WIDTH_M * LightPass.SHEET_STRIDE * 0.5 * px
	for k in from.size():
		var a := from[k] * px
		var b := to[k] * px
		var side := (b - a).normalized().orthogonal() * half
		verts.append_array([a - side, b - side, b + side, a - side, b + side, a + side])
		for j in 6:
			cols.append(c)


func _build_beams(layer: LightLayer, rgb_bins: Array[Vector3], exposure: float, verts: PackedVector2Array,
		cols: PackedColorArray, px: float) -> void:
	BeamGeometry.build(layer.beam_render, rgb_bins, SimConst.REFERENCE_DNI / exposure, px, VERTEX_SCALE, verts, cols)


func _build_rays(layer: LightLayer, rgb_bins: Array[Vector3], exposure: float, verts: PackedVector2Array,
		cols: PackedColorArray, px: float) -> void:
	var from := layer.ray_from
	var to := layer.ray_to
	var power := layer.ray_power
	# A pooled reflection ray stands for REFL_POOL_M of wavefront, so it is drawn as a soft
	# strip that wide (bright on its center line, fading to nothing at its edges, same total)
	# rather than a hairline: weak secondary light reads as haze, not as stray lines.
	var width_m := SimConst.REFL_POOL_M
	var half := width_m * 0.5 * px
	var reference := SimConst.REFERENCE_DNI / exposure
	for k in from.size():
		var rgb := Vector3.ZERO
		for b in Spectrum.BIN_COUNT:
			var irr := power[k * Spectrum.BIN_COUNT + b] / (width_m * SimConst.DEPTH_M)
			if irr > 0.0:
				rgb += rgb_bins[b] * tone(irr / (reference * Spectrum.AM15_SHARE[b]))
		if rgb.x + rgb.y + rgb.z < 1e-4:
			continue
		var a := from[k] * px
		var b2 := to[k] * px
		var side := (b2 - a).normalized().orthogonal() * half
		var c := Color(rgb.x * 2.0 / VERTEX_SCALE, rgb.y * 2.0 / VERTEX_SCALE, rgb.z * 2.0 / VERTEX_SCALE, 1.0)
		var edge := Color(0, 0, 0, 1)
		# Two quads: edge → center line → other edge (a triangle-shaped profile).
		verts.append_array([a - side, b2 - side, b2, a - side, b2, a,
			a, b2, b2 + side, a, b2 + side, a + side])
		cols.append_array([edge, edge, c, edge, c, c, c, c, edge, c, edge, edge])
