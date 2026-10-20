class_name ObjectRenderer
extends Node2D
## Draws placed objects from their optical polylines: lens and prism bodies as tinted
## glass, mirrors and cells as a bright face over a dark back, probes as a dashed line (their
## readings are tags drawn by MapMarkers). Stands (Mounting) are drawn first, behind them;
## power meters (PowerMeters) last, on the cells' poles and in grid connections.
## In the heat view, lenses, prisms, mirrors and cells are filled with their own temperature color.

const STAND_COLOR := Color(0.3, 0.31, 0.34)
const POLE_M := 0.04            ## Pole width
const FOOT_M := 0.2             ## Foot width

var world: SimWorld
var highlighted_id := -1
var selected_id := -1
var view := ViewMode.NORMAL
var overlay: OverlayRenderer   ## For the heat scale


func setup(p_world: SimWorld) -> void:
	world = p_world
	z_index = 4


func _process(_delta: float) -> void:
	queue_redraw()


func _draw() -> void:
	if world == null:
		return
	# Draw in screen units (scaled back by 1/zoom), so outlines, their anti-aliased edges and
	# text stay one screen pixel sharp at any zoom instead of being magnified.
	var zoom := get_viewport().get_canvas_transform().get_scale().x
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE / zoom)
	var px := SimConst.PX_PER_M * zoom
	var heat := view == ViewMode.HEAT and overlay != null
	for obj: SimObject in world.objects.values():
		if obj.mounted and obj.def.mount == ObjectDef.Mount.STAND:
			var base := Mounting.stand_base(world, obj.position)
			if is_finite(base):
				draw_stand(self, obj.position, base, px, STAND_COLOR)
	for obj: SimObject in world.objects.values():
		var def := obj.def
		var pieces := obj.world_pieces()
		var hl := obj.id == highlighted_id or obj.id == selected_id
		match def.kind:
			ObjectDef.Kind.LENS, ObjectDef.Kind.PRISM, ObjectDef.Kind.GRID_TIE, ObjectDef.Kind.BATTERY, \
					ObjectDef.Kind.LAMP:
				var outline := OpticsGen.outline(pieces)
				var pts := PackedVector2Array()
				for p in outline:
					pts.append(p * px)
				if pts.size() >= 3:
					var fill := _heat_color(obj) if heat else def.color
					if def.kind == ObjectDef.Kind.LAMP and not heat:
						fill = def.color.darkened(0.6).lerp(def.color.lightened(0.3), obj.lamp_level)
						draw_circle(obj.position * px, def.size_m * px * 1.5, Color(1.0, 0.9, 0.6, 0.25 * obj.lamp_level))
					draw_colored_polygon(pts, fill)
					pts.append(pts[0])
					var edge := Color(0.9, 0.97, 1.0, 0.9 if hl else 0.6)
					if obj.id == selected_id:
						edge = Color(1.0, 0.85, 0.45)
					draw_polyline(pts, edge, 2.0 if hl else 1.0, true)
			ObjectDef.Kind.MIRROR, ObjectDef.Kind.CELL:
				var a: Vector2 = pieces[0][0][0] * px
				var b: Vector2 = pieces[0][0][1] * px
				var back := Vector2.from_angle(obj.angle + PI * 0.5) * clampf(0.004 * px, 1.5, 12.0)
				draw_line(a + back, b + back, _heat_color(obj) if heat else Color(0.15, 0.15, 0.18),
					clampf(0.006 * px, 2.0, 16.0), true)
				draw_line(a, b, def.color if not hl else Color.WHITE, 2.0, true)
			ObjectDef.Kind.PROBE:
				var a: Vector2 = pieces[0][0][0] * px
				var b: Vector2 = pieces[0][0][1] * px
				draw_line(a, b, Color(0, 0, 0, 0.6), 5.0 if hl else 4.0, true)
				draw_dashed_line(a, b, def.color, 3.0 if hl else 2.5, 6.0)
	PowerMeters.draw_all(self, world, Transform2D.IDENTITY.scaled(Vector2.ONE / zoom), px)


## Draws a stand on `ci` (screen units, `px` pixels per meter): a pole from the object center
## `top` (m) down to the ground at `base_y` (m), on a foot.
static func draw_stand(ci: CanvasItem, top: Vector2, base_y: float, px: float, color: Color) -> void:
	var base := Vector2(top.x, base_y) * px
	ci.draw_line(top * px, base, color, maxf(POLE_M * px, 2.0), true)
	var foot := Vector2(FOOT_M * 0.5 * px, 0.0)
	ci.draw_line(base - foot, base + foot, color, maxf(POLE_M * px, 2.0), true)


func _heat_color(obj: SimObject) -> Color:
	var t := obj.temperature_k if obj.temperature_k > 0.0 else world.ambient_k
	var c := overlay.heat_gradient.sample(OverlayRenderer.heat_x(SimConst.k_to_c(t)))
	c.a = 0.95
	return c
