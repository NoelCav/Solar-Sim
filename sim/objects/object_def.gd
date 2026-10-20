class_name ObjectDef
extends Resource
## Data definition of a placeable object (design doc §9): optical objects (lens, mirror, prism,
## probe, cell) and machines (grid connection; later batteries and consumers). Machines are
## boxes behind the play plane (D19): no optics, and they only collide with other machines.

enum Kind { LENS, MIRROR, PRISM, PROBE, CELL, GRID_TIE, BATTERY, LAMP }
## How it stands in the world (Mounting): on a stand, flat on the ground, or floating.
enum Mount { STAND, GROUND, FREE }
## Where it is listed in the build catalog.
enum Category { OPTICS, POWER, MACHINES, TOOLS }

@export var key: StringName
@export var display_name: String
@export var kind: Kind = Kind.LENS
@export var mount: Mount = Mount.STAND
@export var category: Category = Category.OPTICS
## Body material for lenses and prisms (a MaterialDef key).
@export var material: StringName = &"crown_glass"
@export var color: Color = Color(0.8, 0.9, 1.0, 0.35)

@export_group("Shape")
## Lens diameter, prism base, mirror/probe/cell length, or machine width, m.
@export var size_m: float = 1.0
## Lens center thickness or machine height, m (a lens grows it if its faces would cross).
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

@export_group("Battery")
## Energy it holds, kWh (real energy, like the market's), and the most power it takes in or gives
## out, W.
@export var battery_capacity_kwh: float = 0.5
@export var battery_max_w: float = 250.0
## Share of the energy that survives one way in or out (lithium-ion round trip is about 90 %).
## The rest is lost; machines have no thermal node (D19), so it is not tracked as heat.
@export var battery_efficiency: float = 0.95

@export_group("Lamp")
## Electrical power at full brightness, W, and the share of it that leaves as light (the rest
## is heat in the lamp). A lamp is a line source along the slice (design §6.11): its watts of
## light go out in the plane.
@export var lamp_watts: float = 20.0
@export var lamp_efficiency: float = 0.3
## Share of its light per spectral bin (sums to 1): a warm white LED has no UV and almost no IR.
@export var lamp_spectrum: PackedFloat32Array = PackedFloat32Array([0.0, 0.10, 0.30, 0.45, 0.15, 0.0])
## Width of the cone it lights, degrees (360: all around). It points along the object's angle,
## down at angle 0.
@export var lamp_spread_deg: float = 360.0

@export_group("Cell")
## Solar cell parameters (§9.1, SolarCell). Defaults: crystalline silicon, calibrated to ≈22 %
## at 1 sun and 25 °C.
## Junction bandgap, eV: photons below it pass through or heat the cell; above it each yields Eg.
@export var cell_bandgap_ev: float = 1.12
## Fraction of absorbed photons whose carriers reach the contacts.
@export var cell_collection: float = 0.9
## Operating voltage over Eg/q at 1 sun (fill factor and Voc losses together).
@export var cell_voltage_factor: float = 0.52
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
		Kind.GRID_TIE, Kind.BATTERY, Kind.LAMP:
			return OpticsGen.box(size_m, thickness_m)
		_:
			return OpticsGen.flat_strip(size_m)


## The light a lamp gives at full brightness, W.
func lamp_light_w() -> float:
	return lamp_watts * lamp_efficiency


## Area of the active face (cell, probe, mirror): its width times the slice depth, m².
func face_area_m2() -> float:
	return size_m * SimConst.DEPTH_M


## True for objects whose pieces enclose an optical body of `material`.
func is_body() -> bool:
	return kind == Kind.LENS or kind == Kind.PRISM


## True for machines: boxes behind the play plane, outside the optics (D19).
func is_machine() -> bool:
	return kind == Kind.GRID_TIE or kind == Kind.BATTERY or kind == Kind.LAMP


## True when the shape is a closed outline (bodies and machines), not an open surface.
func is_closed() -> bool:
	return is_body() or is_machine()
