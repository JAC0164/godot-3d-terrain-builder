// Cartoon outlines as a post-effect (game side, not part of the terrain):
// dark lines where the depth jumps (silhouettes of trees, ridges, cliffs).
// Use: instance world/looks/outline.tscn as a child of the Camera3D.
// Depth only, so it works with the Mobile renderer (no normal buffer). Lines
// fade out with distance, or far grass and the horizon would turn black.
shader_type spatial;
render_mode unshaded, depth_draw_never, depth_test_disabled, cull_disabled, fog_disabled, shadows_disabled;

uniform sampler2D depth_tex : hint_depth_texture, filter_nearest;
uniform vec4 line_color : source_color = vec4(0.16, 0.10, 0.06, 1.0);
// Relative depth jump that draws a line (0.06 = 6 %).
uniform float threshold = 0.06;
// Line width in pixels.
uniform float width = 1.5;
// Lines fade out between these camera distances (metres).
uniform float fade_start = 35.0;
uniform float fade_end = 70.0;

void vertex() {
	// Full-screen quad (QuadMesh 2 x 2), whatever the camera.
	POSITION = vec4(VERTEX.xy, 1.0, 1.0);
}

float linear_depth(vec2 uv, mat4 inv_projection) {
	float d = texture(depth_tex, uv).r;
	vec4 v = inv_projection * vec4(uv * 2.0 - 1.0, d, 1.0);
	return -v.z / v.w;
}

void fragment() {
	vec2 px = width / VIEWPORT_SIZE;
	float c = linear_depth(SCREEN_UV, INV_PROJECTION_MATRIX);
	float far_n = max(
		max(linear_depth(SCREEN_UV + vec2(px.x, 0.0), INV_PROJECTION_MATRIX), linear_depth(SCREEN_UV - vec2(px.x, 0.0), INV_PROJECTION_MATRIX)),
		max(linear_depth(SCREEN_UV + vec2(0.0, px.y), INV_PROJECTION_MATRIX), linear_depth(SCREEN_UV - vec2(0.0, px.y), INV_PROJECTION_MATRIX)));
	float edge = step(threshold, (far_n - c) / max(c, 0.001)) * (1.0 - smoothstep(fade_start, fade_end, c));
	ALBEDO = line_color.rgb;
	ALPHA = edge;
}
