shader_type canvas_item;
// Shades the one-texel-per-tile material texture so blocks read as solid without art:
// per-tile color jitter, fine grain inside each tile, a lit rim where a face meets open
// space, a dark rim underneath, and gradual darkening with depth below the surface.

uniform float grain = 0.07;        // Strength of the speckle inside a tile
uniform float jitter = 0.05;       // Per-tile brightness variation
uniform float rim = 0.16;          // Width of the edge bevel, in tiles
uniform int depth_tiles = 12;      // How far down depth darkening reaches
uniform float depth_dark = 0.45;   // Darkening at full depth

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

bool solid(sampler2D tex, ivec2 c, ivec2 size) {
	if (c.x < 0 || c.y < 0 || c.x >= size.x || c.y >= size.y) {
		return true;
	}
	return texelFetch(tex, c, 0).a > 0.9;
}

// True for a solid neighbour of a different material (compared by palette color).
bool differs(sampler2D tex, vec4 base, ivec2 c, ivec2 size) {
	if (c.x < 0 || c.y < 0 || c.x >= size.x || c.y >= size.y) {
		return false;
	}
	vec4 n = texelFetch(tex, c, 0);
	return n.a > 0.9 && distance(n.rgb, base.rgb) > 0.02;
}

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
		if (!solid(TEXTURE, cell + ivec2(0, -1), size) && f.y < rim) light += 0.35;
		if (!solid(TEXTURE, cell + ivec2(-1, 0), size) && f.x < rim) light += 0.15;
		if (!solid(TEXTURE, cell + ivec2(0, 1), size) && f.y > 1.0 - rim) light -= 0.30;
		if (!solid(TEXTURE, cell + ivec2(1, 0), size) && f.x > 1.0 - rim) light -= 0.18;
		// A thin dark seam where two different solid materials meet.
		float seam = 0.08;
		if (f.y < seam && differs(TEXTURE, base, cell + ivec2(0, -1), size)) light -= 0.25;
		if (f.x < seam && differs(TEXTURE, base, cell + ivec2(-1, 0), size)) light -= 0.25;
		if (f.y > 1.0 - seam && differs(TEXTURE, base, cell + ivec2(0, 1), size)) light -= 0.25;
		if (f.x > 1.0 - seam && differs(TEXTURE, base, cell + ivec2(1, 0), size)) light -= 0.25;
		col *= 1.0 + light;
		// Depth below the nearest open space above.
		int d = 0;
		for (int k = 1; k <= depth_tiles; k++) {
			if (!solid(TEXTURE, cell + ivec2(0, -k), size)) {
				break;
			}
			d = k;
		}
		col *= 1.0 - depth_dark * (float(d) + f.y) / float(depth_tiles + 1);
	}
	COLOR = vec4(col, base.a);
}
