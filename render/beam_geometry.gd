class_name BeamGeometry
extends RefCounted
## Turns beam render records (LightEngine.Render()) into colored triangles; the per-vertex
## work runs in compiled code (BeamMesh, C#). Record layout, all floats:
## STRIP, bin, watts, n, then n × (ax, ay, bx, by, frac_a, frac_b);
## SLIVER, bin, watts, n, width, then n × (x, y, frac).
## Irradiance goes as 1/width, so each leg is cut into slices, packed toward the point where
## the two rays cross (a focus), and brightness is evaluated per slice. Only bins with a
## non-zero color are built, so a view pays only for what it shows.

const STRIP := 0
const SLIVER := 1
const MIN_WIDTH_M := 0.001     ## Width floor where rays cross at a focus
const SUN_LEVEL := 0.12        ## Brightness of plain sunlight (concentration 1)
const LOG_GAIN := 3.5          ## How fast brightness grows with concentration

static var _mesh := BeamMesh.new()


## Brightness for a concentration ratio c (1 = plain sunlight): linear up to 1, then
## logarithmic, so 1× is faint, 10× bright and a focus blooms through the HDR glow.
static func tone(c: float) -> float:
	if c <= 1.0:
		return SUN_LEVEL * c
	return SUN_LEVEL * (1.0 + LOG_GAIN * log(c))


## Appends triangles for every record in `buf`. `rgb[bin]` is the bin's color per unit of
## tone (zero = hidden); `px` converts meters to pixels; colors are divided by `vertex_scale`.
static func build(buf: PackedFloat32Array, rgb: Array[Vector3], reference_dni: float, px: float,
		vertex_scale: float, verts: PackedVector2Array, cols: PackedColorArray) -> void:
	var flat := PackedFloat32Array()
	for c in rgb:
		flat.append_array([c.x, c.y, c.z])
	var share := PackedFloat32Array(Spectrum.AM15_SHARE)
	var out: Array = _mesh.Build(buf, flat, share, reference_dni, px, vertex_scale, SimConst.DEPTH_M,
		SUN_LEVEL, LOG_GAIN, MIN_WIDTH_M)
	verts.append_array(out[0])
	cols.append_array(out[1])
