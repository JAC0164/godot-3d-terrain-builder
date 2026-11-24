// Shared body of detail_wind.gdshader and detail_wind_two_sided.gdshader
// (see detail_wind.gdshader). TWO_SIDED: thin parts are single triangles drawn
// from both sides; their back faces keep the mesh normal (upward on grass)
// instead of the flipped one, so both sides are lit the same.

// Direction the wind blows towards, in world X / Z.
uniform vec2 wind_direction = vec2(1.0, 0.35);
// Mesh height of the plant's top (built-in meshes: grass 0.4-0.7, tree 1).
uniform float height = 1.0;
// Sway at the top, in mesh units (the instance scale enlarges it).
uniform float strength = 0.05;
uniform float speed = 1.4;
// Quick shiver of blades / leaves at the top, in mesh units.
uniform float flutter = 0.01;
// Bend = (y / height) ^ stiffness: higher values keep the trunk still, only the top moves.
uniform float stiffness = 2.0;
// Global multiplier (MaterialFactory.set_wind); 0 = no wind.
uniform float wind_scale = 1.0;

void vertex() {
	if (!OUTPUT_IS_SRGB) {
		COLOR.rgb = mix(pow((COLOR.rgb + vec3(0.055)) * (1.0 / (1.0 + 0.055)), vec3(2.4)), COLOR.rgb * (1.0 / 12.92), lessThan(COLOR.rgb, vec3(0.04045)));
	}
	float bend = pow(clamp(VERTEX.y / max(height, 0.01), 0.0, 1.5), stiffness) * wind_scale;
	if (bend > 0.0) {
		vec3 origin = MODEL_MATRIX[3].xyz;
		vec2 dir = normalize(wind_direction + vec2(1e-5, 0.0));
		float t = TIME * speed;
		// Gusts travel across the map along the wind.
		float along = dot(origin.xz, dir);
		float gust = 0.55 + 0.45 * sin(t * 0.45 - along * 0.05) * sin(t * 0.17 - along * 0.021 + 1.3);
		float sway = gust * (0.7 + 0.3 * sin(t * 1.7 + origin.x * 0.37 + origin.z * 0.29));
		// World wind direction in the instance's space (it is rotated and scaled).
		vec3 local_dir = transpose(mat3(MODEL_MATRIX)) * vec3(dir.x, 0.0, dir.y);
		local_dir.y = 0.0;
		local_dir = normalize(local_dir + vec3(1e-5, 0.0, 0.0));
		vec3 shiver = vec3(sin(t * 5.3 + VERTEX.x * 9.0 + origin.z), 0.0, cos(t * 4.7 + VERTEX.z * 9.0 + origin.x)) * flutter;
		VERTEX += (local_dir * strength * sway + shiver) * bend;
	}
}

void fragment() {
#ifdef TWO_SIDED
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
#endif
	ALBEDO = COLOR.rgb;
	ROUGHNESS = 1.0;
	METALLIC = 0.0;
}
