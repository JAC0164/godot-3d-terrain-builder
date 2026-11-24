// Example Ground Material shader (terrain Inspector > Look > Ground Material):
// the terrain's vertex colours (biome ground styles, baked shading) with a
// fine "soil grain" on top, so the ground has texture up close instead of
// looking like a smooth plastic sheet at eye height.
//   - grain: tiny light / dark speckles and small bumps in the lighting
//     (world-space, about 1 m), faded out in the distance (no shimmering);
//   - patches: large, soft colour variation (about 15 m) that hides
//     the regularity of the triangles.
// One noise texture, no UVs needed (the terrain has none): the ground is
// projected from above, cliffs from above too (stretched, but cliffs are
// darker and steep: rarely noticed; set cliff_grain to 0 to remove it there).
// Contract of a custom ground shader: COLOR = vertex colour picked in sRGB,
// convert it to linear like the built-in material (first lines of vertex()).
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, specular_disabled;

uniform sampler2D noise_tex : repeat_enable, filter_linear_mipmap;
uniform sampler2D noise_normal : hint_normal, repeat_enable, filter_linear_mipmap;
// Size (m) of one repeat of the grain texture.
uniform float grain_size = 1.6;
// How much lighter / darker the grain makes the ground (0 = none).
uniform float grain_strength = 0.16;
// Small bumps in the lighting from the grain (0 = flat lighting).
uniform float grain_bumps = 0.35;
// Size (m) and strength of the large soft colour patches.
uniform float patch_size = 18.0;
uniform float patch_strength = 0.10;
// The grain fades out between these distances (m) from the camera.
uniform float fade_start = 20.0;
uniform float fade_end = 70.0;
// Grain on steep faces (cliffs): 0 = none, 1 = as on the ground.
uniform float cliff_grain = 0.4;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	if (!OUTPUT_IS_SRGB) {
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	vec2 p = world_pos.xz;
	float near = 1.0 - smoothstep(fade_start, fade_end, length(world_pos - CAMERA_POSITION_WORLD));
	float flat_ground = mix(cliff_grain, 1.0, smoothstep(0.55, 0.8, world_normal.y));
	// Two grain scales (rotated against each other: no visible repeat).
	float g1 = texture(noise_tex, p / grain_size).r - 0.5;
	float g2 = texture(noise_tex, mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8)) * p / (grain_size * 0.41) + 0.37).r - 0.5;
	float grain = (g1 * 0.6 + g2 * 0.4) * 2.0;
	float patches = (texture(noise_tex, p / patch_size + 0.71).r - 0.5) * 2.0;
	vec3 color = COLOR.rgb * (1.0 + grain * grain_strength * near * flat_ground) * (1.0 + patches * patch_strength);
	ALBEDO = clamp(color, 0.0, 1.0);
	ROUGHNESS = 1.0;
	// Grain bumps: tilt the normal by the normal-map slope (ground seen from above).
	vec3 n = texture(noise_normal, p / grain_size).xyz * 2.0 - 1.0;
	vec3 wn = normalize(world_normal + vec3(n.x, 0.0, -n.y) * grain_bumps * near * flat_ground);
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);
}
