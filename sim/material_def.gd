class_name MaterialDef
extends Resource
## Data definition of a tile/body material (design doc §8).
## All values are SI: kg/m³, J/(kg·K), W/(m·K), K, 1/m.

enum Phase { SOLID, POWDER, LIQUID, GAS }

@export_group("Identity")
## Stable string key, used for references between materials (melts_to, burns_to...).
@export var key: StringName
## Stable numeric id stored in tile data and saves. Never reuse or renumber.
@export var id: int = -1
@export var display_name: String
@export var phase: Phase = Phase.SOLID
@export var color: Color = Color.MAGENTA

@export_group("Thermal")
@export var density: float = 1000.0
@export var specific_heat: float = 1000.0
@export var conductivity: float = 1.0
@export_range(0.0, 1.0) var emissivity: float = 0.9

@export_group("Optical")
@export var transparent: bool = false
## Cauchy's equation n(λ) = A + B / λ², λ in µm.
@export var cauchy_a: float = 1.0
@export var cauchy_b: float = 0.0
## Bulk absorption coefficient per spectral bin, 1/m (Beer–Lambert, transparent media).
@export var bulk_absorption: PackedFloat32Array = PackedFloat32Array([0, 0, 0, 0, 0, 0])
## Fraction absorbed at an opaque surface per spectral bin; the rest scatters.
@export var surface_absorptivity: PackedFloat32Array = PackedFloat32Array([0.8, 0.8, 0.8, 0.8, 0.8, 0.8])
## Refractive index change per kelvin (thermal lensing).
@export var dn_dt: float = 0.0

@export_group("Mechanical")
## Relative mining time; 0 = cannot be mined (air, liquids).
@export var hardness: float = 1.0
@export var softening_temp: float = 0.0
@export var melt_temp: float = 0.0
@export var melts_to: StringName
## Max temperature difference (K) between neighbouring parts before cracking.
@export var thermal_shock_limit: float = 0.0
@export var falls_when_unsupported: bool = false

@export_group("Fire")
@export var flammable: bool = false
@export var ignition_temp: float = 0.0
## Integrity lost per second while burning.
@export var burn_rate: float = 0.0
## Heat released per second while burning, W.
@export var burn_energy: float = 0.0
@export var smoke_rate: float = 0.0
@export var burns_to: StringName

@export_group("Liquid & gas")
@export var boil_temp: float = 0.0
@export var boils_to: StringName
@export var condense_temp: float = 0.0
@export var condenses_to: StringName
@export var viscosity: float = 0.0


func refractive_index(wavelength_um: float) -> float:
	return cauchy_a + cauchy_b / (wavelength_um * wavelength_um)


func is_solid() -> bool:
	return phase == Phase.SOLID or phase == Phase.POWDER


## Heat capacity of one full tile of this material, J/K.
func tile_heat_capacity() -> float:
	return density * SimConst.TILE_VOLUME_M3 * specific_heat
