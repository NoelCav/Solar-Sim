class_name BeamRenderer
extends MeshInstance2D
## Draws traced light as additive quads, one per ray segment (design doc §6.7).
## Each quad is as wide as the ray spacing, so side-by-side rays tile into an even sheet
## whose brightness follows irradiance; converging rays overlap and add up past 1.0,
## which the HDR 2D buffer keeps and the glow pass blooms. Unsplit sunlight is
## white-balanced; rays split after a refraction show their bin color.
## In the light overlay NIR and IR get false colors too.

## Brightness of plain sunlight at REFERENCE_DNI. Concentration multiplies it.
const BASE_INTENSITY := 0.12
const REFERENCE_DNI := 1000.0
const MAX_VERTEX_INTENSITY := 64.0

const OVERLAY_COLORS: Array[Color] = [
	Color(0.55, 0.20, 1.00),
	Color(0.15, 0.35, 1.00),
	Color(0.20, 1.00, 0.30),
	Color(1.00, 0.20, 0.10),
	Color(1.00, 0.55, 0.00),
	Color(1.00, 0.00, 0.60),
]

var world: SimWorld
var show_invisible := false:
	set(value):
		show_invisible = value
		_seen_version = -1

var _light: LightSystem
var _seen_version := -1
var _bin_rgb: Array[Vector3] = []   ## Per-bin color, white-balanced, per watt of reference ray
var _bin_rgb_all: Array[Vector3] = []


func setup(p_world: SimWorld) -> void:
	world = p_world
	_light = world.get_system(&"light")
	z_index = 5
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = mat
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	_bin_rgb = _balanced(Spectrum.DISPLAY_COLOR, false)
	_bin_rgb_all = _balanced(OVERLAY_COLORS, true)


func _process(_delta: float) -> void:
	if _light != null and _light.trace_version != _seen_version:
		_rebuild()


## Scales bin colors so AM1.5 sunlight sums to white and a reference ray has unit power.
func _balanced(colors: Array[Color], include_invisible: bool) -> Array[Vector3]:
	var white := Vector3.ZERO
	for b in Spectrum.BIN_COUNT:
		if include_invisible or colors[b].a > 0.0:
			white += Vector3(colors[b].r, colors[b].g, colors[b].b) * Spectrum.AM15_SHARE[b]
	var ref_w := REFERENCE_DNI * SimConst.RAY_SPACING_M * SimConst.DEPTH_M
	var out: Array[Vector3] = []
	for b in Spectrum.BIN_COUNT:
		var c := colors[b]
		var v := Vector3.ZERO
		if include_invisible or c.a > 0.0:
			v = Vector3(c.r / white.x, c.g / white.y, c.b / white.z) * (BASE_INTENSITY / ref_w)
		out.append(v)
	return out


func _rebuild() -> void:
	_seen_version = _light.trace_version
	var from := _light.render_from
	var to := _light.render_to
	var power := _light.render_power
	var n := from.size()
	if n == 0:
		mesh = null
		return
	var bins := _bin_rgb_all if show_invisible else _bin_rgb
	var px := SimConst.TILE_PX / SimConst.TILE_M
	var half_w := SimConst.RAY_SPACING_M * px * 0.5
	var verts := PackedVector2Array()
	var colors := PackedColorArray()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	verts.resize(n * 4)
	colors.resize(n * 4)
	uvs.resize(n * 4)
	indices.resize(n * 6)
	var q := 0
	for k in n:
		var rgb := Vector3.ZERO
		for b in Spectrum.BIN_COUNT:
			rgb += bins[b] * power[k * Spectrum.BIN_COUNT + b]
		if rgb.x + rgb.y + rgb.z < 1e-4:
			continue
		rgb = rgb.clampf(0.0, MAX_VERTEX_INTENSITY)
		var a := from[k] * px
		var b2 := to[k] * px
		var dir := b2 - a
		if dir.length_squared() < 1e-6:
			continue
		var side := Vector2(-dir.y, dir.x).normalized() * half_w
		var c := Color(rgb.x, rgb.y, rgb.z, 1.0)
		var v := q * 4
		verts[v] = a - side
		verts[v + 1] = a + side
		verts[v + 2] = b2 + side
		verts[v + 3] = b2 - side
		uvs[v] = Vector2(0, 0)
		uvs[v + 1] = Vector2(1, 0)
		uvs[v + 2] = Vector2(1, 1)
		uvs[v + 3] = Vector2(0, 1)
		for j in 4:
			colors[v + j] = c
		var t := q * 6
		indices[t] = v
		indices[t + 1] = v + 1
		indices[t + 2] = v + 2
		indices[t + 3] = v
		indices[t + 4] = v + 2
		indices[t + 5] = v + 3
		q += 1
	if q == 0:
		mesh = null
		return
	verts.resize(q * 4)
	colors.resize(q * 4)
	uvs.resize(q * 4)
	indices.resize(q * 6)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_COLOR] = colors
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh = m
