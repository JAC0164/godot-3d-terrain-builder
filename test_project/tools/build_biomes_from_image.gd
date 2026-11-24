extends SceneTree
## The same pixel map (assets/pixel_maps/savane_anneau.png) built with every
## biome, to compare: the plugin's two biomes (Temperate, Senegal Savanna) and
## five trial biomes made here, game side (desert, snow, volcanic, tropical,
## autumn: not in the plugin). Each one: green = its main ground, red = its
## raised ground, blue = its lowered ground, imported by the plugin's Pixel
## Map (smoothness 2), then its detail layers scattered.
## Renders one oblique view and one eye-level view per biome to
## res://results/biomes_image/ and two contact sheets (vues_obliques.png,
## hauteur_yeux.png), with results/montagnes_image/ added if present.
## Nothing is saved as a scene. Real window, kept off screen:
##   godot --path . --rendering-method mobile --position -3000,-3000 --resolution 1280x720 --script res://tools/build_biomes_from_image.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const ImageGenerator = preload(ADDON + "generation/image_generator.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const TrialBiomes = preload("res://tools/trial_biomes.gd")

const IMAGE := "res://assets/pixel_maps/savane_anneau.png"
const OUT := "res://results/biomes_image"
const MOUNTAINS := "res://results/montagnes_image"

var _terrain: Node3D
var _label: Label

func _initialize() -> void:
	var image := Image.load_from_file(ProjectSettings.globalize_path(IMAGE))
	var error := ImageGenerator.validate_image(image)
	if not error.is_empty():
		push_error(error)
		quit(1)
		return
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	var world := Node3D.new()
	get_root().add_child(world)
	world.add_child((load("res://world/open_world_sky.tscn") as PackedScene).instantiate())
	var camera := Camera3D.new()
	camera.fov = 60.0
	camera.far = 800.0
	world.add_child(camera)
	camera.current = true
	var overlay := CanvasLayer.new()
	world.add_child(overlay)
	_label = Label.new()
	_label.position = Vector2(24, 16)
	_label.add_theme_font_size_override("font_size", 44)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 12)
	overlay.add_child(_label)

	var names: Array[String] = []
	for variant: Dictionary in _variants():
		var terrain := _build(image, variant)
		world.add_child(terrain)
		await _render(camera, variant)
		names.append(variant["file"])
		terrain.queue_free()
		await process_frame
	# The mountains (build_mountains_from_image.gd) if they were rendered.
	if FileAccess.file_exists(MOUNTAINS + "/vue_oblique.png"):
		names.append("montagnes")
	_sheet(names, "oblique", "vues_obliques.png")
	_sheet(names, "yeux", "hauteur_yeux.png")
	quit(0)

# --- Biomes ---------------------------------------------------------------------

## title, file, biome, the three styles (green, red, blue) and the relief.
func _variants() -> Array[Dictionary]:
	var temperate: Resource = TerrainBiome.make_temperate()
	var savanna: Resource = load(ADDON + "biomes/presets/senegal_savanna.tres")
	var list: Array[Dictionary] = [
		{"title": "Tempéré (plugin)", "file": "tempere", "biome": temperate,
			"styles": ["Grass", "Rock", "Sand"], "raise": 2.5, "lower": 0.8},
		{"title": "Savane du Sénégal (plugin)", "file": "savane", "biome": savanna,
			"styles": ["Dry Grass", "Laterite", "Green Savanna"], "raise": 2.5, "lower": 0.8},
	]
	list.append_array(TrialBiomes.list())
	return list


# --- Build ----------------------------------------------------------------------

func _build(image: Image, variant: Dictionary) -> Node3D:
	var biome: Resource = variant["biome"]
	var styles := {}
	for style in biome.ground_styles:
		styles[style.name] = style
	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	_terrain = terrain
	TerrainData.initialize(terrain)
	var feature_node := MeshInstance3D.new()
	feature_node.name = Meta.GENERATED_MESH_NAME
	terrain.add_child(feature_node)

	terrain.set_meta(Meta.GENERATOR_USE_SINGLE_STYLE, false)
	terrain.set_meta(Meta.GENERATOR_SMOOTHNESS, 2.0)
	terrain.set_meta(Meta.GENERATOR_RAISE_HEIGHT, variant["raise"])
	terrain.set_meta(Meta.GENERATOR_LOWER_DEPTH, variant["lower"])
	var keys: Array = variant["styles"]
	var prefixes := ["green", "red", "blue"]
	for i in 3:
		var style: Resource = styles[keys[i]]
		terrain.set_meta(Meta.generator_style_key(prefixes[i], "top_color"), style.top_color)
		terrain.set_meta(Meta.generator_style_key(prefixes[i], "cliff_color"), style.side_color)
	ImageGenerator.apply(terrain, image)

	terrain.set_meta(Meta.BIOME, biome)
	var shading: Dictionary = biome.shading_values()
	shading.merge(biome.waterhole_values(), true)
	for key in shading:
		terrain.set_meta(key, shading[key])
	var builder := TerrainBuilder.new()
	builder.owner_provider = func() -> Node: return terrain
	var t := Time.get_ticks_msec()
	builder.rebuild_all(terrain)
	print("%s: %d ms, details %s" % [variant["file"], Time.get_ticks_msec() - t, DetailScatter.count_instances(terrain)])
	return terrain

# --- Renders --------------------------------------------------------------------

func _ground(p: Vector2) -> float:
	return WaterholeMesher.surface_height(_terrain.get_meta(Meta.HEIGHTS), PackedFloat32Array(),
		_terrain.get_meta(Meta.RESOLUTION), _terrain.get_meta(Meta.WORLD_SIZE), p)

func _render(camera: Camera3D, variant: Dictionary) -> void:
	_label.text = variant["title"]
	var half: float = float(_terrain.get_meta(Meta.WORLD_SIZE)) * 0.5
	var eye := Vector2(half * 0.05, half * 0.72)
	var target := Vector2(-half * 0.6, half * 0.2)
	var views := {
		"oblique": [Vector3(-half * 1.1, half * 0.55, half * 0.9), Vector3(0, 0, 0)],
		"yeux": [Vector3(eye.x, _ground(eye) + 1.7, eye.y), Vector3(target.x, _ground(target) + 1.5, target.y)],
	}
	for view_name: String in views:
		var view: Array = views[view_name]
		camera.look_at_from_position(view[0], view[1])
		for f in range(20):
			await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png("%s/%s_%s.png" % [OUT, variant["file"], view_name])

## 4 x 2 sheet of one view of every biome (1600 x 450, tiles 400 x 225).
func _sheet(names: Array[String], view: String, file: String) -> void:
	var sheet := Image.create(1600, 450, false, Image.FORMAT_RGB8)
	for i in names.size():
		var path := "%s/%s_%s.png" % [OUT, names[i], view]
		if names[i] == "montagnes":
			path = MOUNTAINS + ("/vue_oblique.png" if view == "oblique" else "/vallee.png")
		var img := Image.load_from_file(ProjectSettings.globalize_path(path))
		img.convert(Image.FORMAT_RGB8)
		img.resize(400, 225, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(0, 0, 400, 225), Vector2i((i % 4) * 400, (i / 4) * 225))
	sheet.save_png("%s/%s" % [OUT, file])
	print("sheet ", file)
