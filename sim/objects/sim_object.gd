class_name SimObject
extends RefCounted
## A placed object instance: definition + rigid transform (meters, radians) + runtime state.

var id: int
var def: ObjectDef
var position: Vector2
var angle: float
## Follows its definition's mount (Mounting): on a stand or the ground. False: floating where it
## was put (creative mode).
var mounted := false

## Written by the light system each trace: power absorbed in the body (W), and for probes and
## cells the power arriving on the active face per spectral bin (W), all of it and the part
## that came straight from the sun or moon (the rest came through optics: refracted or reflected).
var absorbed_w := 0.0
var incident := Spectrum.make_zero()
var incident_direct := Spectrum.make_zero()

## Own thermal node (D13), kept by ThermalSystem: temperature (0 until first set to the air
## around it) and energy received this tick (light), J.
var temperature_k := 0.0
var heat_in := 0.0
## Electrical power it delivers this tick, W (PowerSystem; cells on a network that sells).
var power_w := 0.0
## Battery: energy held, J (real energy; saved), and this tick's flow, W (+ out to the network,
## − in from it).
var stored_j := 0.0
var flow_w := 0.0
## Lamp: how bright it is, 0 to 1 (the share of its rated power it gets; PowerSystem).
var lamp_level := 1.0
## Cells and probes: light from lamps arriving on the active face now, W per bin, all of it and
## the part straight from the lamp (the sky's is in `incident`, scaled by LightLayer.power_scale).
var lamp_light := Spectrum.make_zero()
var lamp_direct := Spectrum.make_zero()


func _init(p_id: int, p_def: ObjectDef, p_position: Vector2, p_angle: float) -> void:
	id = p_id
	def = p_def
	position = p_position
	angle = p_angle


func transform() -> Transform2D:
	return Transform2D(angle, position)


## World-space optical pieces.
func world_pieces() -> Array:
	return OpticsGen.transformed(def.build_pieces(), transform())


## Light arriving on the active face (probe, cell front) per spectral bin, W/m² across it.
func incident_spectrum() -> PackedFloat32Array:
	var s := incident.duplicate()
	var area := def.face_area_m2()
	for b in Spectrum.BIN_COUNT:
		s[b] /= area
	return s


## Light arriving on the active face, W/m² across it.
func incident_irradiance() -> float:
	return Spectrum.total(incident_spectrum())

