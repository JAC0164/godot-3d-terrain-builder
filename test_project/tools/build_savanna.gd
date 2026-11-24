extends SceneTree
## Builds savanna demo terrains with the "Senegal Savanna" biome preset:
## dry grass plains, laterite plateaus and patches, greener depressions,
## burnt patches, a laterite track and a few dried waterholes on the flat
## plain. Saves res://scenes/savanna_<size>.tscn.
##   godot --headless --path . --script res://tools/build_savanna.gd -- --sizes=128,256

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const GridMath = preload(ADDON + "core/grid_math.gd")
const StylePalette = preload(ADDON + "styles/style_palette.gd")
const ImageGenerator = preload(ADDON + "generation/image_generator.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const WaterholeStyle = preload(ADDON + "styles/waterhole_style.gd")

func _initialize() -> void:
	var sizes := [128, 256]
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--sizes="):
			sizes = Array(arg.trim_prefix("--sizes=").split(",")).map(func(part: String) -> int: return int(part))
	for size in sizes:
		_build(size)
	quit(0)

func _build(size: int) -> void:
	var biome: Resource = load(ADDON + "biomes/presets/senegal_savanna.tres")
	var styles := {}
	for style in biome.ground_styles:
		styles[style.name] = style

	var root := Node3D.new()
	root.name = "Savanna%d" % size
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

	# Pixel map: green = dry grass plain, red = laterite plateau (raised),
	# blue = greener depression (lowered).
	terrain.set_meta(Meta.GENERATOR_USE_SINGLE_STYLE, false)
	terrain.set_meta(Meta.GENERATOR_SMOOTHNESS, 3.0)
	terrain.set_meta(Meta.GENERATOR_RAISE_HEIGHT, 2.5)
	terrain.set_meta(Meta.GENERATOR_LOWER_DEPTH, 0.8)
	terrain.set_meta(Meta.COLLISION_ENABLED, true)
	_set_generator_style(terrain, "green", styles["Dry Grass"])
	_set_generator_style(terrain, "red", styles["Laterite"])
	_set_generator_style(terrain, "blue", styles["Green Savanna"])
	ImageGenerator.apply(terrain, _make_map(size))

	# Flat laterite and burnt patches painted over the plain (no height change).
	var laterite := _style_id(terrain, styles["Laterite"])
	var burnt := _style_id(terrain, styles["Burnt Ground"])
	var dry := _style_id(terrain, styles["Dry Grass"])
	var patches := FastNoiseLite.new()
	patches.seed = 7
	patches.frequency = 6.0 / float(size)
	var fire := FastNoiseLite.new()
	fire.seed = 21
	fire.frequency = 4.0 / float(size)
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var cell_styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES)
	for z in range(resolution - 1):
		for x in range(resolution - 1):
			var cell := GridMath.cell_index(x, z, resolution)
			if cell_styles[cell] != dry:
				continue
			if patches.get_noise_2d(x, z) > 0.32:
				cell_styles[cell] = laterite
			elif fire.get_noise_2d(x, z) > 0.5:
				cell_styles[cell] = burnt
	terrain.set_meta(Meta.CELL_STYLES, cell_styles)

	# A red laterite track across the plain.
	terrain.set_meta(Meta.ROAD_COLOR, Color(0.66, 0.4, 0.26))
	var s := float(size)
	var points: Array[Vector2] = []
	for i in range(41):
		var f := float(i) / 40.0
		points.append(Vector2((f - 0.5) * 0.9 * s, sin(f * TAU * 1.2) * 0.12 * s + 0.08 * s))
	FeatureStyle.commit(terrain, FeatureStyle.ROAD, points)

	# Biome + its baked shading / waterhole values (what "Biome" in the
	# Inspector does).
	terrain.set_meta(Meta.BIOME, biome)
	var shading: Dictionary = biome.shading_values()
	shading.merge(biome.waterhole_values(), true)
	for key in shading:
		terrain.set_meta(key, shading[key])
	_add_waterholes(terrain, size)

	var t := Time.get_ticks_usec()
	builder.rebuild_all(terrain)
	var build_ms := (Time.get_ticks_usec() - t) / 1000.0

	var plate_triangles := 0
	for node in terrain.find_children("Waterhole_*", "MeshInstance3D", true, false):
		plate_triangles += (node as MeshInstance3D).mesh.surface_get_array_len(0) / 3
	print("savanna %d: waterhole plates %d triangles" % [size, plate_triangles])
	var counts := DetailScatter.count_instances(terrain)
	var nodes := terrain.find_children("_Details*", "MultiMeshInstance3D", true, false).size()
	var path := "res://scenes/savanna_%d.tscn" % size
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, path)
	print("savanna %d: rebuild_all %.0f ms, %d detail nodes, %s, %d KB" % [
		size, build_ms, nodes, counts, FileAccess.get_file_as_bytes(path).size() / 1024])
	root.free()

## Dried waterholes on flat, fully painted ground (what the Waterhole tool
## does on click), away from each other and from the track.
func _add_waterholes(terrain: Node3D, size: int) -> void:
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var spacing := world_size / float(resolution - 1)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var road: Array = terrain.get_meta(Meta.ROADS, [])[0]["points"]
	var wanted := maxi(2, size / 40)
	var placed: Array[Vector2] = []
	var rng := RandomNumberGenerator.new()
	rng.seed = 2024
	var tries := 0
	while placed.size() < wanted and tries < 4000:
		tries += 1
		var radius := rng.randf_range(4.0, 9.0) * spacing
		var gx := rng.randi_range(14, resolution - 15)
		var gz := rng.randi_range(14, resolution - 15)
		var p := GridMath.grid_to_local(gx, gz, resolution, world_size)
		var center := Vector2(p.x, p.z)
		if GridMath.distance_to_polyline(center, road) < radius * 1.6 + 3.0:
			continue
		var far := true
		for other in placed:
			if other.distance_to(center) < radius * 2.0 + 14.0:
				far = false
		if not far:
			continue
		var reach := int(ceil(radius * 1.6 / spacing))
		var h0 := heights[gz * resolution + gx]
		var flat := true
		for dz in range(-reach, reach + 1):
			for dx in range(-reach, reach + 1):
				var x := clampi(gx + dx, 0, resolution - 2)
				var z := clampi(gz + dz, 0, resolution - 2)
				if not TerrainData.cell_active(terrain, x, z) or absf(heights[z * resolution + x] - h0) > 0.35:
					flat = false
		if not flat:
			continue
		WaterholeStyle.commit(terrain, center, radius)
		placed.append(center)
	print("savanna %d: %d waterholes" % [size, placed.size()])

func _set_generator_style(terrain: Node3D, prefix: String, style: Resource) -> void:
	terrain.set_meta(Meta.generator_style_key(prefix, "top_color"), style.top_color)
	terrain.set_meta(Meta.generator_style_key(prefix, "cliff_color"), style.side_color)

func _style_id(terrain: Node3D, style: Resource) -> int:
	return StylePalette.capture_style_definition(terrain, style.top_color, style.side_color, null, null, style.top_tile_size, style.side_tile_size)

func _make_map(size: int) -> Image:
	var plateaus := FastNoiseLite.new()
	plateaus.seed = 4242
	plateaus.frequency = 2.5 / float(size)
	plateaus.fractal_octaves = 3
	var lows := FastNoiseLite.new()
	lows.seed = 77
	lows.frequency = 3.5 / float(size)
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in range(size):
		for x in range(size):
			var color := Color(0, 1, 0)
			if plateaus.get_noise_2d(x, y) > 0.3:
				color = Color(1, 0, 0)
			elif lows.get_noise_2d(x, y) < -0.42:
				color = Color(0, 0, 1)
			image.set_pixel(x, y, color)
	return image
