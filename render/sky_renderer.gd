class_name SkyRenderer
extends ColorRect
## Placeholder sky behind the world: color follows the sun's height.
## Real sky (air-mass reddening, sunsets) comes with the light system in M1.

const NIGHT := Color(0.02, 0.03, 0.08)
const DAY := Color(0.42, 0.65, 0.92)
const DUSK := Color(0.85, 0.45, 0.25)

var world: SimWorld


func setup(p_world: SimWorld) -> void:
	world = p_world
	var g := world.grid
	position = Vector2.ZERO
	size = Vector2(g.width, g.height) * SimConst.TILE_PX
	z_index = -10
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(_delta: float) -> void:
	if world == null:
		return
	var h := clampf(world.sun_direction.y if world.sun_is_up else 0.0, 0.0, 1.0)
	var day_col := DUSK.lerp(DAY, smoothstep(0.0, 0.5, h))
	color = NIGHT.lerp(day_col, smoothstep(0.0, 0.15, h)) if world.sun_is_up else NIGHT
