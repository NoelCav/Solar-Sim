// Surface strips (D18) as textures: one texel per strip, x = tile x * strips + strip,
// y = tile y * 4 + face (0 top, 1 bottom, 2 left, 3 right); strips run along +x on top and
// bottom faces and +y on left and right faces (LightEngine.StripIds, SurfaceSkin).

// The texel of face `face` of tile `cell` on the strip that a pixel at `f` (0-1 within the
// tile) lines up with.
vec4 strip_texel(sampler2D tex, ivec2 cell, vec2 f, int strips, int face) {
	float along = face <= 1 ? f.x : f.y;
	int strip = min(int(along * float(strips)), strips - 1);
	return texelFetch(tex, ivec2(cell.x * strips + strip, cell.y * 4 + face), 0);
}

// How much of each face's skin (top, bottom, left, right) a pixel at `f` lies in: 1 within
// the skin depth `skin` (in tiles) of that face, fading out just beyond.
vec4 skin_weights(vec2 f, float skin) {
	vec4 dist = vec4(f.y, 1.0 - f.y, f.x, 1.0 - f.x);
	return vec4(1.0) - smoothstep(vec4(0.6 * skin), vec4(skin), dist);
}
