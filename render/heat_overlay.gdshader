shader_type canvas_item;
// Heat view overlay (OverlayRenderer): the per-tile temperature colors, with the surface skin
// (D18) drawn over each solid face in its own temperature color, so a hot focal spot on a cool
// block shows where it is.

#include "res://render/surface_strips.gdshaderinc"

uniform sampler2D skin_tex : filter_nearest;   // Skin strip colors, alpha 0 where no skin
uniform int strips = 10;                       // SimConst.SKIN_STRIPS
uniform float face_skin = 0.15;                // Drawn depth of the skin, in tiles (as tiles.gdshader)

void fragment() {
	ivec2 size = textureSize(TEXTURE, 0);
	vec2 t = UV * vec2(size);
	ivec2 cell = ivec2(floor(t));
	vec2 f = fract(t);
	vec4 col = texelFetch(TEXTURE, cell, 0);
	vec4 w = skin_weights(f, face_skin);
	for (int face = 0; face < 4; face++) {
		vec4 skin = strip_texel(skin_tex, cell, f, strips, face);
		if (skin.a > 0.0) {
			col = mix(col, skin, w[face]);
		}
	}
	COLOR = col;
}
