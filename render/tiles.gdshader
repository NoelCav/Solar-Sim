shader_type canvas_item;
// Shades the one-texel-per-tile material texture so blocks read as solid without art:
// per-tile color jitter, fine grain inside each tile, a lit rim where a face meets open
// space, a dark rim underneath, and gradual darkening with depth below the surface.
// Lighting (DisplayLight): `ambient` is the light everything gets (1 by day, near 0 at
// night); light_tex holds how lit each surface strip is by light arriving on it (D18; one
// texel per strip: x = tile x * strips + strip, y = tile y * 4 + face; TileRenderer). Light
// lands on a solid block's surface, so each face brightens only a thin skin along itself,
// strip by strip (a focus lights a spot). At night only moonlit (and focused) strips show (D19).

#include "res://render/surface_strips.gdshaderinc"

uniform float grain = 0.07;        // Strength of the speckle inside a tile
uniform float jitter = 0.05;       // Per-tile brightness variation
uniform float rim = 0.16;          // Width of the edge bevel, in tiles
uniform int depth_tiles = 12;      // How far down depth darkening reaches
uniform float depth_dark = 0.45;   // Darkening at full depth
uniform float ambient = 1.0;
uniform sampler2D light_tex : filter_nearest;
uniform float face_skin = 0.15;    // Depth of the lit skin on exposed faces, in tiles
uniform int strips = 10;           // Surface strips per face (SimConst.SKIN_STRIPS)

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// Neighbour fetch, clamped to the grid (outside counts as the edge tile). A macro, because
// TEXTURE can't be passed into functions.
#define FETCH(c) texelFetch(TEXTURE, clamp(c, ivec2(0), size - 1), 0)
#define SOLID(c) (FETCH(c).a > 0.9)
// A solid neighbour of a different material (compared by palette color).
#define DIFFERS(c) (FETCH(c).a > 0.9 && distance(FETCH(c).rgb, base.rgb) > 0.02)

void fragment() {
	ivec2 size = textureSize(TEXTURE, 0);
	vec2 t = UV * vec2(size);
	ivec2 cell = ivec2(floor(t));
	vec2 f = fract(t);
	vec4 base = texelFetch(TEXTURE, cell, 0);
	if (base.a <= 0.0) {
		discard;
	}
	vec3 col = base.rgb;
	// Per-tile variation plus 4×4 grain, so flat fills look like many blocks.
	col *= 1.0 + (hash(vec2(cell)) - 0.5) * 2.0 * jitter;
	vec2 sub = floor(f * 4.0);
	col *= 1.0 + (hash(vec2(cell) * 4.0 + sub + 0.37) - 0.5) * 2.0 * grain;
	if (base.a > 0.9) {
		// Bevel: faces open to air or glass catch light on top/left, shade bottom/right.
		float light = 0.0;
		if (!SOLID(cell + ivec2(0, -1)) && f.y < rim) light += 0.35;
		if (!SOLID(cell + ivec2(-1, 0)) && f.x < rim) light += 0.15;
		if (!SOLID(cell + ivec2(0, 1)) && f.y > 1.0 - rim) light -= 0.30;
		if (!SOLID(cell + ivec2(1, 0)) && f.x > 1.0 - rim) light -= 0.18;
		// A thin dark seam where two different solid materials meet.
		float seam = 0.08;
		if (f.y < seam && DIFFERS(cell + ivec2(0, -1))) light -= 0.25;
		if (f.x < seam && DIFFERS(cell + ivec2(-1, 0))) light -= 0.25;
		if (f.y > 1.0 - seam && DIFFERS(cell + ivec2(0, 1))) light -= 0.25;
		if (f.x > 1.0 - seam && DIFFERS(cell + ivec2(1, 0))) light -= 0.25;
		col *= 1.0 + light;
		// Depth below the nearest open space above.
		int d = 0;
		for (int k = 1; k <= depth_tiles; k++) {
			if (!SOLID(cell + ivec2(0, -k))) {
				break;
			}
			d = k;
		}
		col *= 1.0 - depth_dark * (float(d) + f.y) / float(depth_tiles + 1);
	}
	// Light on the strip of each face (top, bottom, left, right) that this pixel lines up with.
	vec4 faces = vec4(strip_texel(light_tex, cell, f, strips, 0).r, strip_texel(light_tex, cell, f, strips, 1).r,
		strip_texel(light_tex, cell, f, strips, 2).r, strip_texel(light_tex, cell, f, strips, 3).r);
	float lit = max(max(faces.r, faces.g), max(faces.b, faces.a));
	if (base.a > 0.9) {
		// Each face lights only the skin along itself.
		vec4 skin = faces * skin_weights(f, face_skin);
		lit = max(max(skin.r, skin.g), max(skin.b, skin.a));
	}
	col *= ambient + (1.0 - ambient) * lit;
	COLOR = vec4(col, base.a);
}
