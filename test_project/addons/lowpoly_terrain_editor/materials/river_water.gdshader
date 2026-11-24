shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 water_color : source_color = vec4(0.12, 0.38, 0.55, 0.72);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_albedo_texture = false;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool use_normal_texture = false;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float tile_scale = 0.1666667;
uniform float flow_speed = 0.03;
uniform vec2 flow_direction = vec2(0.845, 0.533);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.18;
uniform float normal_strength : hint_range(0.0, 4.0) = 0.8;
uniform float refraction_strength : hint_range(0.0, 0.08) = 0.012;
varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 flow = flow_direction * (TIME * flow_speed);
	vec2 water_uv = world_position.xz * tile_scale + flow;
	vec4 albedo_sample = vec4(1.0);
	if (use_albedo_texture) {
		albedo_sample = texture(albedo_texture, water_uv);
	}
	vec3 normal_sample = vec3(0.5, 0.5, 1.0);
	if (use_normal_texture) {
		normal_sample = texture(normal_texture, water_uv).rgb;
		NORMAL_MAP = normal_sample;
		NORMAL_MAP_DEPTH = normal_strength;
	}
	ALBEDO = water_color.rgb * albedo_sample.rgb;
	ROUGHNESS = roughness_value;
	SPECULAR = 0.85;
	float alpha_value = clamp(water_color.a * albedo_sample.a, 0.0, 1.0);
	if (refraction_strength > 0.0) {
		vec2 normal_offset = (normal_sample.rg * 2.0 - 1.0) * refraction_strength;
		vec3 refracted = textureLod(screen_texture, SCREEN_UV + normal_offset, roughness_value * 4.0).rgb;
		EMISSION += refracted * (1.0 - alpha_value) * 0.65;
	}
	ALPHA = alpha_value;
}
