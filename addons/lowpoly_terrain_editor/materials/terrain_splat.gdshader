shader_type spatial;
// Blended ground textures (MaterialFactory.terrain_splat_material): up to 7
// textured ground styles in one surface, blended per vertex like the
// untextured style colours.
// COLOR.rgb = the baked colour of the untextured part (sRGB, shading and
// waterhole colours included), COLOR.a = baked shade of the textures / 2,
// CUSTOM0 = weights of layers 0-3, CUSTOM1.rgb = layers 4-6 (the weights sum
// to the textured part), CUSTOM1.a = waterhole tint: the textures keep their
// grain but take the colour of COLOR.rgb (dried clay basins).
// The textures are projected from above (local X / Z), like the UVs of a
// textured style: one repeat every `tile` metres. A steep facet (its normal's
// height under STEEP) is projected instead on the closest of 8 vertical
// planes (every 45 degrees around it), so its texture is not stretched down
// the slope. The facet comes from the screen derivatives of the position: one
// projection per triangle (no seam inside a facet), still one read per layer.
// Height blend: where weights overlap, each pixel shows the layer whose
// weight plus local relief (texel brightness minus the texture's mean) is
// highest, fading over `blend_depth`: pebbles and cracks poke through instead
// of two photos fading into each other.
// Far fade: from `fade_start` to `fade_end` metres the textures turn into
// their mean colour (no visible repeat from far / from above) and the layer
// borders widen to a soft blend, like the untextured colours.
// The means come from `mean_color` (MaterialFactory, from the palette): one
// texture read per layer near, none beyond `fade_end`. A layer without a
// known mean (alpha 0) reads it from the texture's last mip.
// On phones MaterialFactory swaps filter_linear_mipmap_anisotropic for
// filter_linear_mipmap (trilinear, lighter on mobile GPUs).
// USE_PBR (MaterialFactory adds the define when a layer has a normal or
// roughness map): up to 4 layers (`pbr_layer`: their index, -1 = none) also
// read a normal + roughness map (7 + 8 = 15 texture slots, within the 16 of
// phones), specular on. The normal maps follow the same projection
// (tangent = its U direction), no mesh tangents needed.
// MaterialFactory swaps cull_back for cull_disabled (Double Sided).
#ifdef USE_PBR
render_mode diffuse_lambert, cull_back;
#else
render_mode diffuse_lambert, specular_disabled, cull_back;
#endif

uniform sampler2D layer_0 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_1 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_2 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_3 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_4 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_5 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D layer_6 : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
#ifdef USE_PBR
uniform sampler2D normal_0 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_1 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_2 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D normal_3 : hint_normal, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_0 : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_1 : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_2 : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rough_3 : hint_default_white, filter_linear_mipmap_anisotropic, repeat_enable;
// Layer index of the normal / roughness maps 0-3 (-1 = unused slot).
uniform ivec4 pbr_layer = ivec4(-1);
// How much the normal maps bend the light (1 = as authored).
uniform float normal_strength = 1.0;
#endif
// 1 / tile size (m) of layers 0-3 and 4-6 (w unused).
uniform vec4 inv_tile_a = vec4(0.25);
uniform vec4 inv_tile_b = vec4(0.25);
// How much the texture relief moves the border (weight units), and the
// width of the fade between layers (0 = hard edge, 1 = plain cross-fade).
uniform float height_strength = 0.8;
uniform float blend_depth = 0.12;
uniform float far_blend_depth = 0.6;
uniform float fade_start = 25.0;
uniform float fade_end = 90.0;
// Mean colour (linear rgb) of layers 0-6, a = 1 when known (unset = 0).
uniform vec4 mean_color[7];

varying vec3 ground_pos;
varying vec3 ground_normal;
varying vec4 weights_a;
varying vec4 weights_b;

void vertex() {
	ground_pos = VERTEX;
	ground_normal = NORMAL;
	weights_a = CUSTOM0;
	weights_b = CUSTOM1;
}

// Same conversion as StandardMaterial3D's vertex_color_is_srgb.
vec3 to_linear(vec3 c) {
	return mix(pow((c + vec3(0.055)) * (1.0 / 1.055), vec3(2.4)), c * (1.0 / 12.92), lessThan(c, vec3(0.04045)));
}

// Weights under 1/255 are interpolation leftovers: skipped.
const float EPS = 0.002;
const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
const vec3 FLAT_NORMAL = vec3(0.5, 0.5, 1.0);
// Facets whose normal's height is under this (slope over ~45 degrees) are
// projected from the side. At 0.7 both projections stretch alike (~1.4x).
const float STEEP = 0.7;

// One layer, faded by `fade`: colour, mean colour and the height score
// (weight + relief). Fully faded: the mean alone, no texture read. `proj`:
// the projected position (metres).
void layer(sampler2D tex, vec2 proj, float weight, float inv_tile, vec4 known_mean, float fade, out vec3 color, out vec3 mean, out float score) {
	vec2 uv = proj * inv_tile;
	mean = known_mean.a > 0.5 ? known_mean.rgb : textureLod(tex, uv, 14.0).rgb;
	if (fade >= 1.0) {
		color = mean;
		score = weight;
		return;
	}
	vec3 c = texture(tex, uv).rgb;
	color = mix(c, mean, fade);
	score = weight + dot(c - mean, vec3(0.333)) * height_strength * (1.0 - fade);
}

#ifdef USE_PBR
// Normal (encoded 0-1) and roughness of layer `index`, flat / mean far away.
void surface(sampler2D normal_tex, sampler2D rough_tex, vec2 proj, int index, float fade, out vec3 normal, out float rough) {
	float inv_tile = index < 4 ? inv_tile_a[index] : inv_tile_b[index - 4];
	vec2 uv = proj * inv_tile;
	float rough_mean = textureLod(rough_tex, uv, 14.0).r;
	if (fade >= 1.0) {
		normal = FLAT_NORMAL;
		rough = rough_mean;
		return;
	}
	normal = mix(texture(normal_tex, uv).rgb, FLAT_NORMAL, fade);
	rough = mix(texture(rough_tex, uv).r, rough_mean, fade);
}
#endif

void fragment() {
	// The facet (exact per triangle), turned to the side of the mesh normal.
	vec3 facet = normalize(cross(dFdx(ground_pos), dFdy(ground_pos)));
	facet = dot(facet, ground_normal) < 0.0 ? -facet : facet;
	// From above: U = local +X, V = local +Z. From the side: the vertical
	// plane facing the closest 45-degree direction d, U along it (d turned a
	// quarter, so U x V-up faces out), V downwards (the picture stays upright).
	vec2 proj = ground_pos.xz;
	vec3 proj_u = vec3(1.0, 0.0, 0.0);
	vec3 proj_v = vec3(0.0, 0.0, 1.0);
	if (facet.y < STEEP) {
		float angle = round(atan(facet.z, facet.x) * (4.0 / PI)) * (PI / 4.0);
		vec2 u = vec2(sin(angle), -cos(angle));
		proj = vec2(dot(ground_pos.xz, u), -ground_pos.y);
		proj_u = vec3(u.x, 0.0, u.y);
		proj_v = vec3(0.0, -1.0, 0.0);
	}
	float fade = smoothstep(fade_start, fade_end, length(VERTEX));
	float depth = mix(blend_depth, far_blend_depth, fade);
	float w[7] = float[7](weights_a.x, weights_a.y, weights_a.z, weights_a.w, weights_b.x, weights_b.y, weights_b.z);
	vec3 c[7];
	vec3 m[7];
	float s[7];
	vec3 n[7];
	float r[7];
	for (int i = 0; i < 7; i++) {
		c[i] = vec3(0.0);
		m[i] = vec3(0.0);
		s[i] = -10.0;
		n[i] = FLAT_NORMAL;
		r[i] = 1.0;
	}
	if (w[0] > EPS) layer(layer_0, proj, w[0], inv_tile_a.x, mean_color[0], fade, c[0], m[0], s[0]);
	if (w[1] > EPS) layer(layer_1, proj, w[1], inv_tile_a.y, mean_color[1], fade, c[1], m[1], s[1]);
	if (w[2] > EPS) layer(layer_2, proj, w[2], inv_tile_a.z, mean_color[2], fade, c[2], m[2], s[2]);
	if (w[3] > EPS) layer(layer_3, proj, w[3], inv_tile_a.w, mean_color[3], fade, c[3], m[3], s[3]);
	if (w[4] > EPS) layer(layer_4, proj, w[4], inv_tile_b.x, mean_color[4], fade, c[4], m[4], s[4]);
	if (w[5] > EPS) layer(layer_5, proj, w[5], inv_tile_b.y, mean_color[5], fade, c[5], m[5], s[5]);
	if (w[6] > EPS) layer(layer_6, proj, w[6], inv_tile_b.z, mean_color[6], fade, c[6], m[6], s[6]);
#ifdef USE_PBR
	vec3 pn;
	float pr;
	if (pbr_layer.x >= 0 && w[pbr_layer.x] > EPS) { surface(normal_0, rough_0, proj, pbr_layer.x, fade, pn, pr); n[pbr_layer.x] = pn; r[pbr_layer.x] = pr; }
	if (pbr_layer.y >= 0 && w[pbr_layer.y] > EPS) { surface(normal_1, rough_1, proj, pbr_layer.y, fade, pn, pr); n[pbr_layer.y] = pn; r[pbr_layer.y] = pr; }
	if (pbr_layer.z >= 0 && w[pbr_layer.z] > EPS) { surface(normal_2, rough_2, proj, pbr_layer.z, fade, pn, pr); n[pbr_layer.z] = pn; r[pbr_layer.z] = pr; }
	if (pbr_layer.w >= 0 && w[pbr_layer.w] > EPS) { surface(normal_3, rough_3, proj, pbr_layer.w, fade, pn, pr); n[pbr_layer.w] = pn; r[pbr_layer.w] = pr; }
#endif
	// The untextured (colour) part blends like a flat layer.
	float textured_weight = dot(weights_a, vec4(1.0)) + dot(weights_b.xyz, vec3(1.0));
	float plain = 1.0 - clamp(textured_weight, 0.0, 1.0);
	float top = plain > EPS ? plain : -10.0;
	for (int i = 0; i < 7; i++) {
		top = max(top, s[i]);
	}
	float floor_score = top - depth;
	vec3 tex_sum = vec3(0.0);
	vec3 mean_sum = vec3(0.0);
	vec3 normal_sum = vec3(0.0);
	float rough_sum = 0.0;
	float tex_total = 0.0;
	for (int i = 0; i < 7; i++) {
		float b = max(s[i] - floor_score, 0.0);
		tex_sum += c[i] * b;
		mean_sum += m[i] * b;
		normal_sum += n[i] * b;
		rough_sum += r[i] * b;
		tex_total += b;
	}
	vec3 base = to_linear(COLOR.rgb);
	float plain_b = plain > EPS ? max(plain - floor_score, 0.0) : 0.0;
	vec3 albedo = base * plain_b;
	if (tex_total > 0.0) {
		vec3 detail = tex_sum / tex_total;
		vec3 mean = mean_sum / tex_total;
		// The shade multiplied the sRGB colour of untextured faces: same here.
		float shade = to_linear(vec3(COLOR.a * 2.0)).r;
		// Waterholes: the grain of the texture (brightness / its mean) in the
		// baked colour.
		vec3 tinted = base * (dot(detail, LUMA) / max(dot(mean, LUMA), 0.02));
		albedo += mix(detail * shade, tinted, weights_b.w) * tex_total;
	}
	float total = max(tex_total + plain_b, 0.0001);
	ALBEDO = albedo / total;
#ifdef USE_PBR
	// The projection's U and V (Godot's binormal points to -V).
	TANGENT = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(proj_u, 0.0))).xyz);
	BINORMAL = normalize((VIEW_MATRIX * (MODEL_MATRIX * vec4(-proj_v, 0.0))).xyz);
	NORMAL_MAP = (normal_sum + FLAT_NORMAL * plain_b) / total;
	NORMAL_MAP_DEPTH = normal_strength;
	ROUGHNESS = (rough_sum + plain_b) / total;
#else
	ROUGHNESS = 1.0;
#endif
}
