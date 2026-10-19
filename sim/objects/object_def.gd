class_name ObjectDef
extends Resource
## Data definition of a placeable object (design doc §9). M1 covers optical objects;
## ports, thermal nodes and construction costs arrive with their systems.

enum Kind { LENS, MIRROR, PRISM, PROBE }

@export var key: StringName
@export var display_name: String
@export var kind: Kind = Kind.LENS
## Body material for lenses and prisms (a MaterialDef key).
@export var material: StringName = &"crown_glass"
@export var color: Color = Color(0.8, 0.9, 1.0, 0.35)

@export_group("Shape")
## Lens diameter, prism base, or mirror/probe length, m.
@export var size_m: float = 1.0
## Lens center thickness, m (grows automatically if the faces would cross).
@export var thickness_m: float = 0.1
## Lens face radii, m; 0 = flat.
@export var radius_front_m: float = 1.0
@export var radius_back_m: float = 1.0
@export var apex_angle_deg: float = 60.0
@export var arc_segments: int = 32

@export_group("Optics")
## Mirror reflectance per spectral bin.
@export var reflectance: PackedFloat32Array = PackedFloat32Array([0.9, 0.9, 0.9, 0.9, 0.9, 0.9])


## Local-space optical pieces (see OpticsGen).
func build_pieces() -> Array:
	match kind:
		Kind.LENS:
			return OpticsGen.convex_lens(size_m, radius_front_m, radius_back_m, thickness_m, arc_segments)
		Kind.PRISM:
			return OpticsGen.prism(size_m, apex_angle_deg)
		_:
			return OpticsGen.flat_strip(size_m)


## True for objects whose pieces enclose a body of `material`.
func is_body() -> bool:
	return kind == Kind.LENS or kind == Kind.PRISM
