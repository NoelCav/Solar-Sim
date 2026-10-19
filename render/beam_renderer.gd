class_name BeamRenderer
extends MeshInstance2D
## Draws the published light (design doc §6.7), additively into the HDR 2D buffer:
## - the direct-light sheet: a faint tint over everywhere direct sun reaches, so shadows
##   read clearly;
## - beams: filled triangles whose brightness follows irradiance through a log tone curve,
##   so plain sunlight is faint, a 10× beam is bright and a focus blooms through the glow;
## - secondary rays (pooled reflections) as thin lines.
## Colors follow the current view (ViewMode); unsplit sunlight sums to white.

const REFERENCE_DNI := 1000.0       ## Irradiance that tones to BeamGeometry.SUN_LEVEL
const SHEET_LEVEL := 0.07           ## Brightness of the direct-light sheet
const VERTEX_SCALE := 4.0           ## Vertex colors are stored /4 and scaled back by self_modulate
const RAY_WIDTH_PX := 1.5

var world: SimWorld
var view := ViewMode.NORMAL:
	set(value):
		view = value
		_seen_version = -1

var _light: LightSystem
var _seen_version := -1
var _rgb: Array[Vector3] = []       ## Per-bin color for the current view, white-balanced


func setup(p_world: SimWorld) -> void:
	world = p_world
	_light = world.get_system(&"light")
	z_index = 5
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat
	self_modulate = Color(VERTEX_SCALE, VERTEX_SCALE, VERTEX_SCALE, 1.0)


func _process(_delta: float) -> void:
	if _light != null and _light.trace_version != _seen_version:
		_rebuild()


## Brightness for a concentration ratio C (1 = plain sunlight).
static func tone(c: float) -> float:
	return BeamGeometry.tone(c)


## Per-bin colors for the view, scaled so AM1.5 sunlight across the shown bins is white.
func _balance() -> void:
	var colors := ViewMode.bin_colors(view)
	var white := Vector3.ZERO
	for b in Spectrum.BIN_COUNT:
		if colors[b].a > 0.0:
			white += Vector3(colors[b].r, colors[b].g, colors[b].b) * Spectrum.AM15_SHARE[b]
	_rgb.clear()
	for b in Spectrum.BIN_COUNT:
		var c := colors[b]
		var v := Vector3.ZERO
		if c.a > 0.0:
			v = Vector3(c.r / maxf(white.x, 1e-3), c.g / maxf(white.y, 1e-3), c.b / maxf(white.z, 1e-3)) \
				* Spectrum.AM15_SHARE[b]
			# A single-band view (UV, IR) has no white to balance against: keep its hue.
			if v.x + v.y + v.z > 0.0 and _shown_bins(colors) <= 2:
				v = Vector3(c.r, c.g, c.b) * Spectrum.AM15_SHARE[b] / _shown_share(colors)
		_rgb.append(v * ViewMode.beam_gain(view))


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


func _rebuild() -> void:
	_seen_version = _light.trace_version
	_balance()
	var px := SimConst.TILE_PX / SimConst.TILE_M
	var verts := PackedVector2Array()
	var cols := PackedColorArray()
	_build_sheet(verts, cols, px)
	_build_beams(verts, cols, px)
	_build_rays(verts, cols, px)
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


func _build_sheet(verts: PackedVector2Array, cols: PackedColorArray, px: float) -> void:
	var from := _light.sheet_from
	var to := _light.sheet_to
	if from.is_empty():
		return
	# Tint from the current spectrum through the view's colors (reddens at sunset).
	var rgb := Vector3.ZERO
	var share_sum := 0.0
	for b in Spectrum.BIN_COUNT:
		share_sum += Spectrum.AM15_SHARE[b]
	var total := Spectrum.total(world.sun_spectrum)
	if total <= 0.0:
		return
	for b in Spectrum.BIN_COUNT:
		if Spectrum.AM15_SHARE[b] > 0.0:
			rgb += _rgb[b] * (world.sun_spectrum[b] / total) / Spectrum.AM15_SHARE[b] * share_sum
	var level := SHEET_LEVEL * minf(total / REFERENCE_DNI, 1.0) / VERTEX_SCALE
	var c := Color(rgb.x * level, rgb.y * level, rgb.z * level, 1.0)
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


func _build_beams(verts: PackedVector2Array, cols: PackedColorArray, px: float) -> void:
	BeamGeometry.build(_light.beam_strips, _light.beam_slivers, _rgb, REFERENCE_DNI, px,
		VERTEX_SCALE, verts, cols)


func _build_rays(verts: PackedVector2Array, cols: PackedColorArray, px: float) -> void:
	var from := _light.ray_from
	var to := _light.ray_to
	var power := _light.ray_power
	# A pooled reflection ray stands for REFL_POOL_M of wavefront.
	var width_m := BeamTracer.REFL_POOL_M
	for k in from.size():
		var rgb := Vector3.ZERO
		for b in Spectrum.BIN_COUNT:
			var irr := power[k * Spectrum.BIN_COUNT + b] / (width_m * SimConst.DEPTH_M)
			if irr > 0.0:
				rgb += _rgb[b] * tone(irr / (REFERENCE_DNI * Spectrum.AM15_SHARE[b]))
		if rgb.x + rgb.y + rgb.z < 1e-4:
			continue
		var a := from[k] * px
		var b2 := to[k] * px
		var side := (b2 - a).normalized().orthogonal() * (RAY_WIDTH_PX * 0.5)
		var c := Color(rgb.x / VERTEX_SCALE, rgb.y / VERTEX_SCALE, rgb.z / VERTEX_SCALE, 1.0)
		verts.append_array([a - side, b2 - side, b2 + side, a - side, b2 + side, a + side])
		for j in 6:
			cols.append(c)
