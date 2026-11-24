@tool
extends RefCounted
## Brush feedback drawn over the 3D viewport (EditorPlugin
## _forward_3d_draw_over_viewport): a ring lying on the ground under the
## cursor, coloured per tool, with a small tool symbol in its centre and a
## label (tool, size). Nothing is added to the scene, so nothing can be saved
## by mistake, and it costs nothing in game.
##
##   outer ring  = brush radius (full reach)
##   inner ring  = half radius (50 % strength, the brush falls off smoothly)
##   road/river  = ring of the feature width, waterhole = its radius + cracks
##   erase over a road / river = orange ring ("erases the feature")

const Meta = preload("../core/terrain_meta.gd")
const ToolMode = preload("../editing/tool_mode.gd")
const SurfaceRay = preload("../editing/surface_ray.gd")

const SEGMENTS := 56
const LIFT := 0.06

const COLORS := {
	ToolMode.Mode.ERASE: Color(1.0, 0.38, 0.32),
	ToolMode.Mode.RAISE: Color(0.5, 0.92, 0.45),
	ToolMode.Mode.LOWER: Color(1.0, 0.62, 0.3),
	ToolMode.Mode.FLATTEN: Color(0.45, 0.75, 1.0),
	ToolMode.Mode.SMOOTH: Color(0.62, 0.92, 1.0),
	ToolMode.Mode.WATERHOLE: Color(0.92, 0.72, 0.5),
	ToolMode.Mode.VEGETATION: Color(0.55, 0.95, 0.35),
	ToolMode.Mode.VEGETATION_CLEAR: Color(1.0, 0.8, 0.35),
	ToolMode.Mode.VEGETATION_RESET: Color(0.85, 0.85, 0.85),
}
const FEATURE_ERASE_COLOR := Color(1.0, 0.72, 0.2)

## Draws the brush of `mode` at the local ground point `center`.
## `info`: {radius, strength, stroke_active, carve, over_feature (erase)}.
static func draw(overlay: Control, camera: Camera3D, terrain: Node3D, mode: ToolMode.Mode, center: Vector3, info: Dictionary) -> void:
	if camera == null or not is_instance_valid(terrain) or mode == ToolMode.Mode.NONE:
		return
	var scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0
	var carve: PackedFloat32Array = info.get("carve", PackedFloat32Array())
	var radius: float = info.get("radius", 3.0)
	var active: bool = info.get("stroke_active", false)
	var strength: float = info.get("strength", 1.0)
	var color := _tool_color(terrain, mode, info)
	var label := ToolMode.display_name(mode)
	var ring_radius := radius
	if mode == ToolMode.Mode.ROAD:
		ring_radius = Meta.get_float(terrain, Meta.ROAD_WIDTH, Meta.DEFAULT_ROAD_WIDTH) * 0.5
		label = "Road  %.1f m wide" % (ring_radius * 2.0)
	elif mode == ToolMode.Mode.RIVER:
		ring_radius = Meta.get_float(terrain, Meta.RIVER_WIDTH, Meta.DEFAULT_RIVER_WIDTH) * 0.5
		label = "River  %.1f m wide" % (ring_radius * 2.0)
	elif mode == ToolMode.Mode.WATERHOLE:
		label = "Waterhole  r %.1f m" % radius
	elif mode == ToolMode.Mode.ERASE and info.get("over_feature", false):
		label = "Remove road / river"
	elif ToolMode.is_vegetation_tool(mode):
		var target: String = info.get("vegetation_target", "")
		label = "%s %s  %.1f m  %d%%" % [label, target if target != "" else "(all plants)", radius, roundi(strength * 100.0)]
	else:
		label = "%s  %.1f m  %d%%" % [label, radius, roundi(strength * 100.0)]

	var width := (3.0 if active else 2.0) * scale
	var outer := _ground_circle(camera, terrain, carve, center, ring_radius)
	_stroke(overlay, outer, color, width, scale)
	if ToolMode.is_brush_tool(mode) and not (mode == ToolMode.Mode.ERASE and info.get("over_feature", false)):
		var inner := _ground_circle(camera, terrain, carve, center, ring_radius * 0.5)
		_stroke(overlay, inner, Color(color, 0.45), 1.0 * scale, scale)
	if mode == ToolMode.Mode.WATERHOLE:
		_draw_cracks(overlay, camera, terrain, carve, center, radius, color, scale)

	var projected_center: Variant = _project(camera, terrain, center + Vector3(0, LIFT, 0))
	if projected_center == null:
		return
	var screen_center: Vector2 = projected_center
	_draw_symbol(overlay, mode, screen_center, color, scale)
	var font := overlay.get_theme_default_font()
	var font_size := int(13 * scale)
	var text_pos: Vector2 = screen_center + Vector2(14, -14) * scale
	overlay.draw_string_outline(font, text_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, int(4 * scale), Color(0, 0, 0, 0.6))
	overlay.draw_string(font, text_pos, label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1, 1, 1, 0.95))

static func _tool_color(terrain: Node3D, mode: ToolMode.Mode, info: Dictionary) -> Color:
	match mode:
		ToolMode.Mode.PAINT:
			var paint: Color = terrain.get_meta(Meta.BRUSH_TOP_COLOR, Color(0.9, 0.9, 0.9))
			return Color(paint.lightened(0.15), 1.0)
		ToolMode.Mode.ROAD:
			var road_color: Color = terrain.get_meta(Meta.ROAD_COLOR, Meta.DEFAULT_ROAD_COLOR)
			return Color(road_color.lightened(0.5), 1.0)
		ToolMode.Mode.RIVER:
			var river_color: Color = terrain.get_meta(Meta.RIVER_COLOR, Meta.DEFAULT_RIVER_COLOR)
			return Color(river_color.lightened(0.35), 1.0)
		ToolMode.Mode.ERASE:
			return FEATURE_ERASE_COLOR if info.get("over_feature", false) else COLORS[mode]
	return COLORS.get(mode, Color.WHITE)

## Screen points of a circle lying on the ground (null entries behind the camera).
static func _ground_circle(camera: Camera3D, terrain: Node3D, carve: PackedFloat32Array, center: Vector3, radius: float) -> Array:
	var points := []
	for i in SEGMENTS + 1:
		var angle := TAU * float(i) / float(SEGMENTS)
		var p := Vector2(center.x + cos(angle) * radius, center.z + sin(angle) * radius)
		var local := Vector3(p.x, SurfaceRay.height_at(terrain, carve, p) + LIFT, p.y)
		points.append(_project(camera, terrain, local))
	return points

static func _project(camera: Camera3D, terrain: Node3D, local: Vector3) -> Variant:
	var world := terrain.to_global(local)
	if camera.is_position_behind(world):
		return null
	return camera.unproject_position(world)

## Polyline with a dark halo (readable on light and dark ground); splits at
## points behind the camera.
static func _stroke(overlay: Control, points: Array, color: Color, width: float, scale: float) -> void:
	var run := PackedVector2Array()
	for p: Variant in points + [null]:
		if p == null:
			if run.size() >= 2:
				overlay.draw_polyline(run, Color(0, 0, 0, 0.45), width + 2.0 * scale, true)
				overlay.draw_polyline(run, color, width, true)
			run = PackedVector2Array()
		else:
			var screen_point: Vector2 = p
			run.append(screen_point)

static func _draw_cracks(overlay: Control, camera: Camera3D, terrain: Node3D, carve: PackedFloat32Array, center: Vector3, radius: float, color: Color, scale: float) -> void:
	# A few fixed jagged cracks from the centre: reads as "dried mud".
	for k in 5:
		var angle := TAU * float(k) / 5.0 + 0.4
		var points := []
		for step in 4:
			var d := radius * (0.12 + 0.2 * float(step))
			var jitter := 0.35 * (1.0 if step % 2 == 0 else -1.0)
			var p := Vector2(center.x + cos(angle + jitter * 0.4) * d, center.z + sin(angle + jitter * 0.4) * d)
			points.append(_project(camera, terrain, Vector3(p.x, SurfaceRay.height_at(terrain, carve, p) + LIFT, p.y)))
		_stroke(overlay, points, Color(color, 0.7), 1.25 * scale, scale)

static func _draw_symbol(overlay: Control, mode: ToolMode.Mode, c: Vector2, color: Color, scale: float) -> void:
	var s := 7.0 * scale
	var w := 2.0 * scale
	var halo := Color(0, 0, 0, 0.45)
	var lines: Array = []
	match mode:
		ToolMode.Mode.PAINT:
			overlay.draw_circle(c, s * 0.75, halo)
			overlay.draw_circle(c, s * 0.6, color)
			return
		ToolMode.Mode.ERASE:
			lines = [[c + Vector2(-s, -s), c + Vector2(s, s)], [c + Vector2(-s, s), c + Vector2(s, -s)]]
		ToolMode.Mode.RAISE:
			lines = [[c + Vector2(0, s), c + Vector2(0, -s)], [c + Vector2(-s * 0.7, -s * 0.3), c + Vector2(0, -s), c + Vector2(s * 0.7, -s * 0.3)]]
		ToolMode.Mode.LOWER:
			lines = [[c + Vector2(0, -s), c + Vector2(0, s)], [c + Vector2(-s * 0.7, s * 0.3), c + Vector2(0, s), c + Vector2(s * 0.7, s * 0.3)]]
		ToolMode.Mode.FLATTEN:
			lines = [[c + Vector2(-s, s * 0.35), c + Vector2(s, s * 0.35)], [c + Vector2(-s * 0.6, -s * 0.6), c + Vector2(0, 0), c + Vector2(s * 0.6, -s * 0.6)]]
		ToolMode.Mode.SMOOTH:
			var wave := []
			for i in 9:
				var x := -s + 2.0 * s * float(i) / 8.0
				wave.append(c + Vector2(x, sin(float(i) / 8.0 * TAU) * s * 0.45))
			lines = [wave]
		ToolMode.Mode.VEGETATION:
			lines = [[c + Vector2(-s, 0), c + Vector2(s, 0)], [c + Vector2(0, -s), c + Vector2(0, s)]]
		ToolMode.Mode.VEGETATION_CLEAR:
			lines = [[c + Vector2(-s, 0), c + Vector2(s, 0)]]
		ToolMode.Mode.VEGETATION_RESET:
			var ring := []
			for i in 17:
				ring.append(c + Vector2.from_angle(TAU * float(i) / 16.0) * s * 0.7)
			lines = [ring]
		_:
			overlay.draw_circle(c, 3.0 * scale, halo)
			overlay.draw_circle(c, 2.0 * scale, color)
			return
	for line: Array in lines:
		var points := PackedVector2Array(line)
		overlay.draw_polyline(points, halo, w + 2.0 * scale, true)
		overlay.draw_polyline(points, color, w, true)
