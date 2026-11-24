// Example Detail Material shader: toon lighting AND wind, for the terrain's
// "Detail Material" slot. Shows the contract of a custom detail shader:
//   - COLOR = mesh vertex colour x MultiMesh instance colour, picked in sRGB:
//     convert it to linear (first lines of vertex()) like the built-in one;
//   - VERTEX.y = height in the mesh (built-in plants: 0 at the base, about 1
//     at the top of a tree).
// One material for every layer: grass, shrubs and trees share these wind
// values (the built-in material has one profile per kind of plant). Rigid
// props (rocks, skulls) would sway too: keep `strength` low, or give their
// layers a custom mesh with Use Mesh Materials.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_toon, specular_disabled;

uniform vec2 wind_direction = vec2(1.0, 0.35);
uniform float height = 1.0;
uniform float strength = 0.03;
uniform float speed = 1.3;
uniform float stiffness = 2.0;

void vertex() {
	if (!OUTPUT_IS_SRGB) {
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
	float bend = pow(clamp(VERTEX.y / max(height, 0.01), 0.0, 1.5), stiffness);
	vec3 origin = MODEL_MATRIX[3].xyz;
	vec2 dir = normalize(wind_direction + vec2(1e-5, 0.0));
	float t = TIME * speed;
	float sway = 0.6 + 0.4 * sin(t + origin.x * 0.37 + origin.z * 0.29);
	vec3 local_dir = transpose(mat3(MODEL_MATRIX)) * vec3(dir.x, 0.0, dir.y);
	local_dir.y = 0.0;
	local_dir = normalize(local_dir + vec3(1e-5, 0.0, 0.0));
	VERTEX += local_dir * strength * sway * bend;
}

void fragment() {
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 1.0;
}
