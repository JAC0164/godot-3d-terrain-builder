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
const DetailLayer = preload(ADDON + "biomes/detail_layer.gd")
const GroundStyle = preload(ADDON + "biomes/ground_style.gd")
const DetailMeshes = preload(ADDON + "mesh/detail_meshes.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")

const IMAGE := "res://assets/pixel_maps/savane_anneau.png"
const OUT := "res://results/biomes_image"
const MOUNTAINS := "res://results/montagnes_image"

const GROUND := DetailLayer.ColorMode.GROUND
const SIDE := DetailLayer.ColorMode.SIDE
const FIXED := DetailLayer.ColorMode.FIXED
const BY_COLOR := DetailLayer.GroundFilter.COLOR

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
	list.append_array(_trial_biomes())
	return list

func _trial_biomes() -> Array[Dictionary]:
	var list: Array[Dictionary] = []

	# Desert: sand, sandstone mesas, a green oasis in the hollow.
	var sand := Color(0.87, 0.74, 0.5)
	var oasis := Color(0.42, 0.56, 0.24)
	var desert := _biome("Desert", [
		TerrainBiome.make_ground("Sand", sand, Color(0.74, 0.57, 0.38)),
		TerrainBiome.make_ground("Sandstone", Color(0.76, 0.48, 0.3), Color(0.66, 0.38, 0.24)),
		TerrainBiome.make_ground("Oasis", oasis, Color(0.52, 0.4, 0.26)),
	], [
		TerrainBiome.make_layer("Oasis Grass", DetailMeshes.GRASS_TUFT, 0.9, {"ground_filter": BY_COLOR, "filter_color": oasis, "filter_tolerance": 0.2, "slope_max": 30.0, "tint": Color(0.92, 1.06, 0.7)}),
		TerrainBiome.make_layer("Oasis Trees", DetailMeshes.ACACIA, 0.03, {"ground_filter": BY_COLOR, "filter_color": oasis, "filter_tolerance": 0.2, "slope_max": 22.0, "scale_min": 3.0, "scale_max": 5.0, "color_mode": FIXED, "tint": Color(0.85, 1.1, 0.8), "cast_shadows": true}),
		TerrainBiome.make_layer("Dry Tufts", DetailMeshes.DRY_GRASS_TUFT, 0.06, {"ground_filter": BY_COLOR, "filter_color": sand, "filter_tolerance": 0.2, "clump_size": 6.0, "clump_coverage": 0.4, "color_mode": FIXED, "tint": Color(0.85, 0.74, 0.5)}),
		TerrainBiome.make_layer("Rocks", DetailMeshes.ROCK, 0.012, {"steep_bonus": 8.0, "edge_bonus": 6.0, "scale_min": 0.6, "scale_max": 1.5, "small_bias": 2.0, "sink": 0.25, "color_mode": SIDE, "desaturate": 0.2}),
		TerrainBiome.make_layer("Skulls", DetailMeshes.ZEBU_SKULL, 0.002, {"slope_max": 15.0, "scale_min": 0.55, "scale_max": 0.75, "color_mode": FIXED}),
		TerrainBiome.make_layer("Dead Trees", DetailMeshes.DEAD_TREE, 0.001, {"slope_max": 20.0, "scale_min": 2.0, "scale_max": 3.2, "color_mode": FIXED}),
	])
	list.append({"title": "Désert (essai)", "file": "desert", "biome": desert,
		"styles": ["Sand", "Sandstone", "Oasis"], "raise": 5.0, "lower": 0.8})

	# Snow: snowfield, bare rock hills, a frozen lake.
	var snow := Color(0.93, 0.95, 0.98)
	var tundra := _biome("Snow", [
		TerrainBiome.make_ground("Snow", snow, Color(0.6, 0.63, 0.68)),
		TerrainBiome.make_ground("Rock", Color(0.5, 0.5, 0.5), Color(0.36, 0.36, 0.37)),
		TerrainBiome.make_ground("Ice", Color(0.68, 0.84, 0.95), Color(0.5, 0.63, 0.74)),
	], [
		TerrainBiome.make_layer("Frozen Grass", DetailMeshes.DRY_GRASS_TUFT, 0.15, {"ground_filter": BY_COLOR, "filter_color": snow, "filter_tolerance": 0.1, "clump_size": 5.0, "clump_coverage": 0.35, "color_mode": FIXED, "tint": Color(0.75, 0.72, 0.6)}),
		TerrainBiome.make_layer("Rocks", DetailMeshes.ROCK, 0.02, {"steep_bonus": 8.0, "edge_bonus": 6.0, "scale_min": 0.6, "scale_max": 1.6, "small_bias": 2.0, "sink": 0.3, "color_mode": SIDE}),
		TerrainBiome.make_layer("Pebbles", DetailMeshes.PEBBLES, 0.05, {"ground_filter": BY_COLOR, "filter_color": Color(0.5, 0.5, 0.5), "filter_tolerance": 0.15, "color_mode": SIDE}),
		TerrainBiome.make_layer("Dead Trees", DetailMeshes.DEAD_TREE, 0.004, {"ground_filter": BY_COLOR, "filter_color": snow, "filter_tolerance": 0.1, "slope_max": 25.0, "scale_min": 2.0, "scale_max": 3.5, "color_mode": FIXED, "tint": Color(0.7, 0.68, 0.66), "cast_shadows": true}),
	])
	list.append({"title": "Neige (essai)", "file": "neige", "biome": tundra,
		"styles": ["Snow", "Rock", "Ice"], "raise": 4.0, "lower": 0.5})

	# Volcanic: ash plain, black basalt hills, a lava hollow (orange colour only, no glow).
	var ash := Color(0.36, 0.34, 0.33)
	var volcanic := _biome("Volcanic", [
		TerrainBiome.make_ground("Ash", ash, Color(0.26, 0.24, 0.23)),
		TerrainBiome.make_ground("Basalt", Color(0.17, 0.16, 0.16), Color(0.12, 0.11, 0.11)),
		TerrainBiome.make_ground("Lava", Color(1.0, 0.4, 0.08), Color(0.35, 0.12, 0.05)),
	], [
		TerrainBiome.make_layer("Rocks", DetailMeshes.ROCK, 0.03, {"steep_bonus": 8.0, "edge_bonus": 6.0, "scale_min": 0.6, "scale_max": 1.6, "small_bias": 2.0, "sink": 0.25, "color_mode": FIXED, "tint": Color(0.16, 0.15, 0.15)}),
		TerrainBiome.make_layer("Pebbles", DetailMeshes.PEBBLES, 0.2, {"ground_filter": BY_COLOR, "filter_color": ash, "filter_tolerance": 0.12, "color_mode": FIXED, "tint": Color(0.2, 0.19, 0.19)}),
		TerrainBiome.make_layer("Burnt Trees", DetailMeshes.DEAD_TREE, 0.006, {"ground_filter": BY_COLOR, "filter_color": ash, "filter_tolerance": 0.12, "slope_max": 25.0, "scale_min": 2.0, "scale_max": 3.5, "color_mode": FIXED, "tint": Color(0.12, 0.1, 0.09), "cast_shadows": true}),
	])
	list.append({"title": "Volcanique (essai)", "file": "volcan", "biome": volcanic,
		"styles": ["Ash", "Basalt", "Lava"], "raise": 5.0, "lower": 0.8})

	# Tropical: lush grass, jungle hills, a swamp.
	var lush := Color(0.27, 0.56, 0.2)
	var jungle := Color(0.18, 0.42, 0.15)
	var swamp := Color(0.26, 0.36, 0.24)
	var tropical := _biome("Tropical", [
		TerrainBiome.make_ground("Lush Grass", lush, Color(0.42, 0.3, 0.18)),
		TerrainBiome.make_ground("Jungle", jungle, Color(0.36, 0.25, 0.15)),
		TerrainBiome.make_ground("Swamp", swamp, Color(0.3, 0.24, 0.16)),
	], [
		TerrainBiome.make_layer("Grass", DetailMeshes.GRASS_TUFT, 1.0, {"ground_filter": DetailLayer.GroundFilter.GREENISH, "slope_max": 34.0, "scale_min": 0.9, "scale_max": 1.5, "tint": Color(0.92, 1.06, 0.7)}),
		TerrainBiome.make_layer("Bushes", DetailMeshes.SHRUB, 0.12, {"ground_filter": DetailLayer.GroundFilter.GREENISH, "clump_size": 6.0, "clump_coverage": 0.6, "slope_max": 35.0, "scale_min": 1.0, "scale_max": 2.0, "color_mode": FIXED, "tint": Color(0.55, 1.0, 0.45)}),
		TerrainBiome.make_layer("Trees", DetailMeshes.ACACIA, 0.05, {"ground_filter": BY_COLOR, "filter_color": jungle, "filter_tolerance": 0.12, "slope_max": 35.0, "scale_min": 3.5, "scale_max": 6.0, "color_mode": FIXED, "tint": Color(0.6, 1.1, 0.55), "cast_shadows": true}),
		TerrainBiome.make_layer("Big Trees", DetailMeshes.BAOBAB, 0.004, {"ground_filter": BY_COLOR, "filter_color": lush, "filter_tolerance": 0.12, "slope_max": 18.0, "scale_min": 5.0, "scale_max": 7.0, "color_mode": FIXED, "tint": Color(0.8, 1.0, 0.75), "cast_shadows": true}),
		TerrainBiome.make_layer("Reeds", DetailMeshes.DRY_GRASS_TUFT, 0.8, {"ground_filter": BY_COLOR, "filter_color": swamp, "filter_tolerance": 0.1, "height_scale_min": 1.6, "height_scale_max": 2.4, "color_mode": FIXED, "tint": Color(0.45, 0.6, 0.3)}),
	])
	list.append({"title": "Tropical (essai)", "file": "tropical", "biome": tropical,
		"styles": ["Lush Grass", "Jungle", "Swamp"], "raise": 4.0, "lower": 0.6})

	# Autumn: golden grass, red-brown hills, a green meadow in the hollow.
	var golden := Color(0.7, 0.52, 0.24)
	var autumn := _biome("Autumn", [
		TerrainBiome.make_ground("Golden Grass", golden, Color(0.48, 0.34, 0.2)),
		TerrainBiome.make_ground("Red Hills", Color(0.6, 0.3, 0.17), Color(0.45, 0.26, 0.18)),
		TerrainBiome.make_ground("Meadow", Color(0.46, 0.55, 0.26), Color(0.42, 0.32, 0.2)),
	], [
		TerrainBiome.make_layer("Grass", DetailMeshes.DRY_GRASS_TUFT, 0.8, {"slope_max": 32.0, "clump_size": 7.0, "clump_coverage": 0.7, "color_mode": GROUND, "tint": Color(1.05, 0.95, 0.8)}),
		TerrainBiome.make_layer("Orange Shrubs", DetailMeshes.SHRUB, 0.06, {"clump_size": 8.0, "clump_coverage": 0.5, "slope_max": 30.0, "scale_min": 1.0, "scale_max": 1.8, "color_mode": FIXED, "tint": Color(1.25, 0.6, 0.25)}),
		TerrainBiome.make_layer("Red Trees", DetailMeshes.ACACIA, 0.012, {"slope_max": 25.0, "scale_min": 3.5, "scale_max": 5.5, "color_mode": FIXED, "tint": Color(1.4, 0.55, 0.3), "cast_shadows": true}),
		TerrainBiome.make_layer("Rocks", DetailMeshes.ROCK, 0.015, {"steep_bonus": 8.0, "edge_bonus": 6.0, "scale_min": 0.55, "scale_max": 1.4, "small_bias": 2.0, "sink": 0.25, "color_mode": SIDE, "desaturate": 0.4}),
	])
	list.append({"title": "Automne (essai)", "file": "automne", "biome": autumn,
		"styles": ["Golden Grass", "Red Hills", "Meadow"], "raise": 3.5, "lower": 0.8})
	return list

## A trial biome with the savanna's baked shading.
func _biome(biome_name: String, grounds: Array, layers: Array) -> Resource:
	var biome: Resource = TerrainBiome.new()
	biome.name = biome_name
	var styles: Array[GroundStyle] = []
	styles.assign(grounds)
	biome.ground_styles = styles
	var detail: Array[DetailLayer] = []
	detail.assign(layers)
	biome.detail_layers = detail
	biome.blend = 2
	biome.blend_noise = 0.75
	biome.slope_tint = 0.5
	biome.ambient_occlusion = 0.45
	biome.variation = 0.08
	biome.cliff_darken = 0.3
	return biome

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
