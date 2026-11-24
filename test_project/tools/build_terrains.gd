extends SceneTree
## Generates test terrains with the plugin modules (no editor needed), times
## every build step and saves one scene per size into res://scenes/.
##
## Run from the test_project folder:
##   godot --headless --path . --script res://tools/build_terrains.gd
## Optional: -- --sizes=64,128,256

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const ImageGenerator = preload(ADDON + "generation/image_generator.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const StrokeController = preload(ADDON + "editing/stroke_controller.gd")
const ToolMode = preload(ADDON + "editing/tool_mode.gd")

const DEFAULT_SIZES := [64, 128, 256]

func _initialize() -> void:
	var sizes: Array = DEFAULT_SIZES
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sizes="):
			sizes = []
			for part in arg.trim_prefix("--sizes=").split(","):
				sizes.append(int(part))

	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://scenes"))
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://results"))

	var report := {"engine": Engine.get_version_info()["string"], "terrains": []}
	for size in sizes:
		report["terrains"].append(_build(int(size)))

	var file := FileAccess.open("res://results/build_report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	file.close()
	print("Wrote res://results/build_report.json")
	quit()

# -----------------------------------------------------------------------------

func _ms(start_usec: int) -> float:
	return snappedf(float(Time.get_ticks_usec() - start_usec) / 1000.0, 0.01)

func _build(size: int) -> Dictionary:
	print("--- Terrain %dx%d ---" % [size, size])
	var timings := {}

	var root := Node3D.new()
	root.name = "Terrain%d" % size

	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	root.add_child(terrain)
	terrain.owner = root
	TerrainData.initialize(terrain)

	var feature_node := MeshInstance3D.new()
	feature_node.name = Meta.GENERATED_MESH_NAME
	terrain.add_child(feature_node)
	feature_node.owner = root

	var builder := TerrainBuilder.new()
	builder.owner_provider = func() -> Node: return root

	# Generator settings: three styles, rounded hills, collision on.
	terrain.set_meta(Meta.GENERATOR_USE_SINGLE_STYLE, false)
	terrain.set_meta(Meta.GENERATOR_SMOOTHNESS, 3.0)
	terrain.set_meta(Meta.GENERATOR_RAISE_HEIGHT, 4.0)
	terrain.set_meta(Meta.GENERATOR_LOWER_DEPTH, 1.0)
	terrain.set_meta(Meta.COLLISION_ENABLED, true)
	_set_generator_style(terrain, "green", Color(0.42, 0.68, 0.30), Color(0.47, 0.34, 0.22))
	_set_generator_style(terrain, "red", Color(0.58, 0.58, 0.55), Color(0.38, 0.36, 0.34))
	_set_generator_style(terrain, "blue", Color(0.86, 0.79, 0.55), Color(0.62, 0.52, 0.36))

	var t := Time.get_ticks_usec()
	var image := _make_island_image(size)
	timings["pixel_map"] = _ms(t)
	image.save_png("res://results/pixel_map_%d.png" % size)

	t = Time.get_ticks_usec()
	var stats := ImageGenerator.apply(terrain, image)
	timings["image_to_data"] = _ms(t)

	_add_features(terrain, size)

	t = Time.get_ticks_usec()
	builder.rebuild_river_carve(terrain)
	timings["river_carve"] = _ms(t)

	t = Time.get_ticks_usec()
	builder.rebuild_all_chunks(terrain)
	timings["chunks"] = _ms(t)

	t = Time.get_ticks_usec()
	var feature_faces := builder.rebuild_feature_mesh(terrain)
	timings["roads_rivers"] = _ms(t)

	t = Time.get_ticks_usec()
	builder.rebuild_collision(terrain, feature_faces)
	timings["collision"] = _ms(t)

	t = Time.get_ticks_usec()
	builder.rebuild_all(terrain)
	timings["rebuild_all"] = _ms(t)

	timings.merge(_time_editing(terrain, builder, size))

	var geometry := _geometry_stats(terrain)

	var scene_path := "res://scenes/terrain_%d.tscn" % size
	var packed := PackedScene.new()
	packed.pack(root)
	t = Time.get_ticks_usec()
	ResourceSaver.save(packed, scene_path)
	timings["save_scene"] = _ms(t)
	geometry["scene_file_kb"] = int(FileAccess.get_file_as_bytes(scene_path).size() / 1024)

	print("  pixels: ", stats)
	print("  timings (ms): ", timings)
	print("  geometry: ", geometry)

	# Same terrain with the plugin's "Mobile Water (no refraction)" option.
	terrain.set_meta(Meta.RIVER_MOBILE_WATER, true)
	builder.rebuild_feature_mesh(terrain)
	var mobile_packed := PackedScene.new()
	mobile_packed.pack(root)
	ResourceSaver.save(mobile_packed, "res://scenes/terrain_%d_mobilewater.tscn" % size)

	root.free()
	return {"size": size, "pixels": stats, "timings_ms": timings, "geometry": geometry}

func _set_generator_style(terrain: Node3D, prefix: String, top: Color, cliff: Color) -> void:
	terrain.set_meta(Meta.generator_style_key(prefix, "top_color"), top)
	terrain.set_meta(Meta.generator_style_key(prefix, "cliff_color"), cliff)

## Island pixel map: white sea, green ground, red hills, blue dents.
func _make_island_image(size: int) -> Image:
	var noise := FastNoiseLite.new()
	noise.seed = 1234
	noise.frequency = 3.0 / float(size)
	noise.fractal_octaves = 4

	var detail := FastNoiseLite.new()
	detail.seed = 99
	detail.frequency = 9.0 / float(size)

	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	var center := Vector2(size, size) * 0.5
	for y in range(size):
		for x in range(size):
			var d := Vector2(x, y).distance_to(center) / (float(size) * 0.5)
			var n := noise.get_noise_2d(x, y)
			var island := 0.62 + n * 0.55 - d * d * 1.05
			var color := Color.WHITE
			if island > 0.0:
				color = Color(0, 1, 0)
				if island > 0.42:
					color = Color(1, 0, 0)
				elif island < 0.2 and detail.get_noise_2d(x, y) > 0.25:
					color = Color(0, 0, 1)
			image.set_pixel(x, y, color)
	return image

## Rivers and roads crossing the island, scaled with its size.
func _add_features(terrain: Node3D, size: int) -> void:
	var s := float(size)
	var lines := [
		[FeatureStyle.RIVER, Vector2(-0.30, -0.18), Vector2(0.40, 0.12), 0.06],
		[FeatureStyle.ROAD, Vector2(-0.12, -0.36), Vector2(0.16, 0.34), 0.04],
	]
	if size >= 128:
		lines.append([FeatureStyle.RIVER, Vector2(0.05, -0.38), Vector2(-0.10, 0.05), 0.05])
		lines.append([FeatureStyle.ROAD, Vector2(-0.34, 0.10), Vector2(0.30, -0.20), 0.03])
	if size >= 256:
		lines.append([FeatureStyle.RIVER, Vector2(-0.38, 0.25), Vector2(0.0, 0.32), 0.04])
		lines.append([FeatureStyle.ROAD, Vector2(0.20, -0.32), Vector2(0.34, 0.18), 0.03])

	for line in lines:
		var a: Vector2 = line[1] * s
		var b: Vector2 = line[2] * s
		var wiggle: float = line[3] * s
		var normal := (b - a).orthogonal().normalized()
		var steps := maxi(8, int(a.distance_to(b) / 1.5))
		var points: Array[Vector2] = []
		for i in range(steps + 1):
			var f := float(i) / float(steps)
			points.append(a.lerp(b, f) + normal * sin(f * TAU * 1.5) * wiggle)
		FeatureStyle.commit(terrain, line[0], points)

## Times a sculpt stroke and a paint stroke through the real StrokeController
## (snapshot capture + data edit + partial chunk rebuild), like in the editor.
func _time_editing(terrain: Node3D, builder: TerrainBuilder, size: int) -> Dictionary:
	var result := {}
	var strokes := StrokeController.new(builder)
	strokes.brush_radius = 3.0
	for mode in [ToolMode.Mode.RAISE, ToolMode.Mode.PAINT]:
		strokes.mode = mode
		var start := Vector3(-0.15 * size, 0.0, 0.05 * size)
		var t := Time.get_ticks_usec()
		strokes.begin(terrain, start)
		var begin_ms := _ms(t)
		var dabs := 30
		t = Time.get_ticks_usec()
		for i in range(dabs):
			strokes.update(terrain, start + Vector3(float(i) * 0.5, 0.0, 0.0))
		var per_dab := snappedf(_ms(t) / float(dabs), 0.01)
		t = Time.get_ticks_usec()
		strokes.end(terrain)
		var end_ms := _ms(t)
		# Enum name (paint, raise, ...): stable keys for the perf reports.
		var key := String(ToolMode.Mode.keys()[mode]).to_lower()
		result["%s_stroke_begin" % key] = begin_ms
		result["%s_per_dab" % key] = per_dab
		result["%s_stroke_end" % key] = end_ms
	return result

func _geometry_stats(terrain: Node3D) -> Dictionary:
	var chunk_nodes := 0
	var surfaces := 0
	var triangles := 0
	var vertices := 0
	var detail_nodes := 0
	var detail_counts := {}
	var materials := {}
	var container := terrain.get_node(Meta.GENERATED_CHUNKS_NAME)
	for chunk in container.get_children():
		var mesh: ArrayMesh = chunk.mesh
		if mesh == null:
			continue
		chunk_nodes += 1
		for i in range(mesh.get_surface_count()):
			surfaces += 1
			var count := mesh.surface_get_array_len(i)
			vertices += count
			triangles += count / 3
			materials[mesh.surface_get_material(i).get_instance_id()] = true
		for detail in chunk.get_children():
			if detail is MultiMeshInstance3D:
				detail_nodes += 1
				# "_Details_<index>_<layer name>" -> layer name
				var key := str(detail.name).get_slice("_", 3).to_lower()
				detail_counts[key] = int(detail_counts.get(key, 0)) + detail.multimesh.instance_count

	var feature_mesh: ArrayMesh = terrain.get_node(Meta.GENERATED_MESH_NAME).mesh
	var feature_surfaces := 0
	var feature_triangles := 0
	if feature_mesh:
		feature_surfaces = feature_mesh.get_surface_count()
		for i in range(feature_surfaces):
			feature_triangles += feature_mesh.surface_get_array_len(i) / 3
			materials[feature_mesh.surface_get_material(i).get_instance_id()] = true

	var shape_node := terrain.get_node_or_null("%s/%s" % [Meta.GENERATED_COLLISION_BODY_NAME, Meta.GENERATED_COLLISION_SHAPE_NAME])
	var collision_triangles := 0
	if shape_node and shape_node.shape:
		collision_triangles = (shape_node.shape as ConcavePolygonShape3D).get_faces().size() / 3

	return {
		"chunks": chunk_nodes,
		"terrain_surfaces": surfaces,
		"terrain_triangles": triangles,
		"terrain_vertices": vertices,
		"feature_surfaces": feature_surfaces,
		"feature_triangles": feature_triangles,
		"unique_materials": materials.size(),
		"collision_triangles": collision_triangles,
		"detail_nodes": detail_nodes,
		"detail_instances": detail_counts,
	}
