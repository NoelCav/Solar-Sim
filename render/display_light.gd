class_name DisplayLight
extends RefCounted
## How traced light is shown: display policy only, the sim never reads it. Every renderer
## that turns light into brightness (beams, the light sheet, the Light view, lit tiles)
## takes its exposure and night level from here.
##
## Moonlight is about a millionth of sunlight, so at night it is drawn at a night exposure
## in a pale-blue tint. Without direct light the world fades to NIGHT_AMBIENT after dusk:
## only what light lands on shows.

const MOON_EXPOSURE := 0.35                  ## A full moon draws at this fraction of daylight
const MOON_TINT := Vector3(0.62, 0.74, 1.0)  ## Night vision: moonlight reads pale blue
## At night a lamp's light is drawn this many times brighter than traced (1 W/m² reads as full).
const LAMP_EXPOSURE := 1000.0
## Beams of lamp light are drawn at this gain at night: air shows no beam in real life, so they
## are only an aid, and a lens focusing a lamp would otherwise bloom like a sun.
const LAMP_BEAM_EXPOSURE := 30.0
const NIGHT_AMBIENT := 0.002                 ## Brightness of unlit things at night (linear; ~4 % on screen)


## Display gain for the light being traced: 1 by day; at night moonlight is scaled up so a
## full moon draws at MOON_EXPOSURE of daylight.
static func exposure(world: SimWorld) -> float:
	return MOON_EXPOSURE / SimConst.MOON_FULL_RATIO if world.light_is_moon else 1.0


## Display gain for lamp light: the eye adapts to the dark, so lamps are drawn at LAMP_EXPOSURE
## at night and at their true level by day (when they can't compete with the sun).
static func lamp_exposure(world: SimWorld) -> float:
	return lerpf(LAMP_EXPOSURE, 1.0, ambient(world))


## Display gain for a lamp's beams, sheet and rays (see LAMP_BEAM_EXPOSURE).
static func lamp_beam_exposure(world: SimWorld) -> float:
	return lerpf(LAMP_BEAM_EXPOSURE, 1.0, ambient(world))


## How lit everything is without direct light: 1 by day, fading through dusk to
## NIGHT_AMBIENT (and back at dawn) with the sun's height.
static func ambient(world: SimWorld) -> float:
	return lerpf(NIGHT_AMBIENT, 1.0, smoothstep(-0.08, 0.12, sin(world.sun_arc_angle)))

