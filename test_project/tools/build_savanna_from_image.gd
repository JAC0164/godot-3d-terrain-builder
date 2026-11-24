extends SceneTree
## A savanna from a pixel map (assets/pixel_maps/savane_anneau.png, made with
## map-editor.html), the way build_savanna.gd does it from a generated map:
## green = dry grass plain, red = laterite plateau (raised), blue = greener
## depression (lowered). Flat laterite and burnt patches are painted on the
## plain, a dried waterhole sits in the middle of the largest blue area, and
## the Senegal Savanna biome grows its grass, shrubs, acacias, baobabs...
## Saves res://scenes/savane_image.tscn and renders a few views to
## res://results/savane_image/. Real window, kept off screen:
##   godot --path . --rendering-method mobile --position -3000,-3000 --resolution 1280x720 --script res://tools/build_savanna_from_image.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const GridMath = preload(ADDON + "core/grid_math.gd")
const StylePalette = preload(ADDON + "styles/style_palette.gd")
const ImageGenerator = preload(ADDON + "generation/image_generator.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const WaterholeStyle = preload(ADDON + "styles/waterhole_style.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")

const IMAGE := "res://assets/pixel_maps/savane_anneau.png"
const SCENE := "res://scenes/savane_image.tscn"
const OUT := "res://results/savane_image"

var _terrain: Node3D

func _initialize() -> void:
	var image := Image.load_from_file(ProjectSettings.globalize_path(IMAGE))
	var error := ImageGenerator.validate_image(image)
	if not error.is_empty():
		push_error(error)
		quit(1)
		return
	var root := _build(image)
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, SCENE)
	print("saved %s (%d KB)" % [SCENE, FileAccess.get_file_as_bytes(SCENE).size() / 1024])
	get_root().add_child(root)
	await _render(root)
	quit(0)

func _build(image: Image) -> Node3D:
	var biome: Resource = load(ADDON + "biomes/presets/senegal_savanna.tres")
	var styles := {}
	for style in biome.ground_styles:
		styles[style.name] = style

	var root := Node3D.new()
	root.name = "SavaneImage"
	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	root.add_child(terrain)
	terrain.owner = root
	_terrain = terrain
	TerrainData.initialize(terrain)
	var feature_node := MeshInstance3D.new()
	feature_node.name = Meta.GENERATED_MESH_NAME
	terrain.add_child(feature_node)
	feature_node.owner = root

	terrain.set_meta(Meta.GENERATOR_USE_SINGLE_STYLE, false)
	terrain.set_meta(Meta.GENERATOR_SMOOTHNESS, 2.0)
	terrain.set_meta(Meta.GENERATOR_RAISE_HEIGHT, 2.5)
	terrain.set_meta(Meta.GENERATOR_LOWER_DEPTH, 0.8)
	terrain.set_meta(Meta.COLLISION_ENABLED, true)
	_set_generator_style(terrain, "green", styles["Dry Grass"])
	_set_generator_style(terrain, "red", styles["Laterite"])
	_set_generator_style(terrain, "blue", styles["Green Savanna"])
	var stats := ImageGenerator.apply(terrain, image)
	print("pixel map: ", stats)

	# Flat laterite and burnt patches on the dry grass plain (colour only).
	var laterite := _style_id(terrain, styles["Laterite"])
	var burnt := _style_id(terrain, styles["Burnt Ground"])
	var dry := _style_id(terrain, styles["Dry Grass"])
	var size := maxi(image.get_width(), image.get_height())
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
			if patches.get_noise_2d(x, z) > 0.35:
				cell_styles[cell] = laterite
			elif fire.get_noise_2d(x, z) > 0.5:
				cell_styles[cell] = burnt
	terrain.set_meta(Meta.CELL_STYLES, cell_styles)

	# Biome + its baked shading / waterhole values (what "Biome" in the
	# Inspector does).
	terrain.set_meta(Meta.BIOME, biome)
	var shading: Dictionary = biome.shading_values()
	shading.merge(biome.waterhole_values(), true)
	for key in shading:
		terrain.set_meta(key, shading[key])
	_add_basin_waterhole(terrain, image)

	var builder := TerrainBuilder.new()
	builder.owner_provider = func() -> Node: return root
	var t := Time.get_ticks_msec()
	builder.rebuild_all(terrain)
	print("rebuild_all %d ms, details %s" % [Time.get_ticks_msec() - t, DetailScatter.count_instances(terrain)])
	return root

## A dried waterhole in the middle of the blue pixels (their centroid),
## sized to the blue area.
func _add_basin_waterhole(terrain: Node3D, image: Image) -> void:
	var sum := Vector2.ZERO
	var count := 0
	for y in image.get_height():
		for x in image.get_width():
			if ImageGenerator.classify_pixel(image.get_pixel(x, y), 0.2) == ImageGenerator.PixelClass.INDENTED:
				sum += Vector2(x, y)
				count += 1
	if count == 0:
		return
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var spacing := world_size / float(resolution - 1)
	var side := resolution - 1
	var offset := Vector2((side - image.get_width()) / 2, (side - image.get_height()) / 2)
	var cell := sum / float(count) + offset
	var p := GridMath.grid_to_local(int(round(cell.x)), int(round(cell.y)), resolution, world_size)
	var center := Vector2(p.x, p.z) + Vector2(spacing, spacing) * 0.5
	var radius := clampf(sqrt(float(count) / PI) * spacing * 0.45, 3.0, 10.0)
	WaterholeStyle.commit(terrain, center, radius)
	print("waterhole at %s, radius %.1f m (%d blue pixels)" % [center, radius, count])

func _set_generator_style(terrain: Node3D, prefix: String, style: Resource) -> void:
	terrain.set_meta(Meta.generator_style_key(prefix, "top_color"), style.top_color)
	terrain.set_meta(Meta.generator_style_key(prefix, "cliff_color"), style.side_color)

func _style_id(terrain: Node3D, style: Resource) -> int:
	return StylePalette.capture_style_definition(terrain, style.top_color, style.side_color, null, null, style.top_tile_size, style.side_tile_size)

# --- Renders --------------------------------------------------------------------

func _ground(p: Vector2) -> float:
	return WaterholeMesher.surface_height(_terrain.get_meta(Meta.HEIGHTS), PackedFloat32Array(),
		_terrain.get_meta(Meta.RESOLUTION), _terrain.get_meta(Meta.WORLD_SIZE), p)

func _at(p: Vector2, lift: float) -> Vector3:
	return Vector3(p.x, _ground(p) + lift, p.y)

func _render(root: Node3D) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	root.add_child((load("res://world/savanna_sky.tscn") as PackedScene).instantiate())
	var camera := Camera3D.new()
	camera.fov = 60.0
	camera.far = 600.0
	root.add_child(camera)
	camera.current = true
	var half: float = float(_terrain.get_meta(Meta.WORLD_SIZE)) * 0.5
	var holes: Array = _terrain.get_meta(Meta.WATERHOLES, [])
	var hole: Vector2 = (holes[0] as Dictionary)["center"] if not holes.is_empty() else Vector2.ZERO
	var views := {
		"vue_haute": [Vector3(0, half * 1.2, half * 1.45), Vector3(0, 0, 0)],
		"vue_oblique": [Vector3(-half * 1.1, half * 0.55, half * 0.9), Vector3(0, 0, 0)],
		"anneau": [_at(Vector2(half * 0.05, half * 0.72), 1.7), _at(Vector2(-half * 0.6, half * 0.2), 1.5)],
		"bassin": [_at(hole + Vector2(half * 0.45, half * 0.3), 2.2), _at(hole, 0.0)],
	}
	var names: Array = views.keys()
	for view_name: String in names:
		var view: Array = views[view_name]
		camera.look_at_from_position(view[0], view[1])
		for f in range(20):
			await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png("%s/%s.png" % [OUT, view_name])
	# 2 x 2 contact sheet.
	var sheet := Image.create(1280, 720, false, Image.FORMAT_RGB8)
	for i in names.size():
		var img := Image.load_from_file(ProjectSettings.globalize_path("%s/%s.png" % [OUT, names[i]]))
		img.convert(Image.FORMAT_RGB8)
		img.resize(640, 360, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(0, 0, 640, 360), Vector2i((i % 2) * 640, (i / 2) * 360))
	sheet.save_png(OUT + "/planche.png")
	print("rendered ", names)
