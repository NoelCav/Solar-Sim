class_name ObjectDef
extends Resource
## Data definition of a placeable object (design doc §9). M1 covers optical objects;
## ports, thermal nodes and construction costs arrive with their systems.

enum Kind { LENS, MIRROR, PRISM, PROBE, CELL }
## How it stands in the world (Mounting): on a stand, flat on the ground, or floating.
enum Mount { STAND, GROUND, FREE }

@export var key: StringName
@export var display_name: String
@export var kind: Kind = Kind.LENS
@export var mount: Mount = Mount.STAND
## Body material for lenses and prisms (a MaterialDef key).
@export var material: StringName = &"crown_glass"
@export var color: Color = Color(0.8, 0.9, 1.0, 0.35)

@export_group("Shape")
## Lens diameter, prism base, or mirror/probe/cell length, m.
@export var size_m: float = 1.0
## Lens center thickness, m (grows automatically if the faces would cross).
@export var thickness_m: float = 0.1
## Lens face radii, m; 0 = flat.
@export var radius_front_m: float = 1.0
@export var radius_back_m: float = 1.0
@export var apex_angle_deg: float = 60.0
## Segments per curved face. Shading normals are interpolated, so refraction stays smooth;
## 16 keeps the shape within ~0.5 mm for typical radii.
@export var arc_segments: int = 16

@export_group("Optics")
## Reflectance per spectral bin: a mirror's, or what a cell's front (its AR coating) and back reflect.
@export var reflectance: PackedFloat32Array = PackedFloat32Array([0.9, 0.9, 0.9, 0.9, 0.9, 0.9])

@export_group("Cell")
## Solar cell parameters (§9.1, SolarCell). Defaults: crystalline silicon, calibrated to ≈22 %
## at 1 sun and 25 °C.
## Junction bandgap, eV: photons below it pass through or heat the cell; above it each yields Eg.
@export var cell_bandgap_ev: float = 1.12
## Fraction of absorbed photons whose carriers reach the contacts.
@export var cell_collection: float = 0.9
## Operating voltage over Eg/q at 1 sun (fill factor and Voc losses together).
@export var cell_voltage_factor: float = 0.5
## Open-circuit voltage at 1 sun, V: sets how much concentration raises the voltage.
@export var cell_voc_v: float = 0.7
## Efficiency lost per K above 25 °C.
@export var cell_temp_coeff: float = 0.004
## Resistive loss per sun of concentration (η_series = 1 − r·C).
@export var cell_series_r: float = 0.002


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
