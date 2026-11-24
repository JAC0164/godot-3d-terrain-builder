extends SceneTree
## A mountain landscape from a pixel map (assets/pixel_maps/savane_anneau.png,
## made with map-editor.html). The image is enlarged x2 (sharp pixels: 1 pixel
## = 2 x 2 cells of 1 m, so the decor keeps its size) and imported by the
## plugin: green = ground, blue = valleys (lowered), red = mountains. Then,
## game side (not in the plugin):
## - the red pixels, blurred, raise broad massifs that spill past the red
##   areas (the plugin alone raises only inside them: lone spikes);
## - rolling foothills over the whole map and rough ridges on the massifs
##   (noise added to the vertex heights);
## - ground styles by height and slope: snow on the peaks, rock on steep
##   slopes and high ground, grass below (Temperate biome styles);
## - the Temperate biome (grass, rocks) plus shrubs, pebbles and dead trees.
## Saves res://scenes/montagnes_image.tscn and renders a few views to
## res://results/montagnes_image/. Real window, kept off screen:
##   godot --path . --rendering-method mobile --position -3000,-3000 --resolution 1280x720 --script res://tools/build_mountains_from_image.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const GridMath = preload(ADDON + "core/grid_math.gd")
const StylePalette = preload(ADDON + "styles/style_palette.gd")
const ImageGenerator = preload(ADDON + "generation/image_generator.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const DetailLayer = preload(ADDON + "biomes/detail_layer.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")

const IMAGE := "res://assets/pixel_maps/savane_anneau.png"
const SCENE := "res://scenes/montagnes_image.tscn"
const OUT := "res://results/montagnes_image"
const ENLARGE := 2
const MOUNTAIN_HEIGHT := 26.0
const VALLEY_DEPTH := 3.0
## Blur radius of the red pixels (cells): how far massifs spread.
const MASSIF_REACH := 14
const FOOTHILLS := 6.0
const RIDGES := 6.0
const GRASS_COLOR := Color(0.45, 0.56, 0.27)

var _terrain: Node3D

func _initialize() -> void:
	var image := Image.load_from_file(ProjectSettings.globalize_path(IMAGE))
	image.resize(image.get_width() * ENLARGE, image.get_height() * ENLARGE, Image.INTERPOLATE_NEAREST)
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

func _biome() -> Resource:
	var biome: Resource = TerrainBiome.make_temperate()
	biome.name = "Mountains"
	# Alpine meadow green instead of the bright default grass.
	(biome.ground_styles[0] as Resource).set("top_color", GRASS_COLOR)
	var layers: Array = biome.detail_layers.duplicate()
	layers.append(TerrainBiome.make_layer("Shrubs", 5, 0.02, {
		"ground_filter": DetailLayer.GroundFilter.GREENISH, "slope_max": 30.0, "clump_size": 10.0,
		"scale_min": 0.8, "scale_max": 1.5, "color_mode": DetailLayer.ColorMode.GROUND, "tint": Color(0.75, 0.95, 0.6)}))
	layers.append(TerrainBiome.make_layer("Pebbles", 4, 0.05, {
		"steep_bonus": 3.0, "scale_min": 0.5, "scale_max": 1.0, "color_mode": DetailLayer.ColorMode.SIDE, "desaturate": 0.4}))
	layers.append(TerrainBiome.make_layer("Dead Trees", 10, 0.002, {
		"ground_filter": DetailLayer.GroundFilter.GREENISH, "slope_max": 25.0, "scale_min": 1.8, "scale_max": 2.6}))
	biome.detail_layers = layers
	return biome

func _build(image: Image) -> Node3D:
	var biome := _biome()
	var styles := {}
	for style in biome.ground_styles:
		styles[style.name] = style

	var root := Node3D.new()
	root.name = "MontagnesImage"
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

	terrain.set_meta(Meta.HEIGHT_MAX, MOUNTAIN_HEIGHT + RIDGES + FOOTHILLS + 2.0)
	terrain.set_meta(Meta.HEIGHT_MIN, -(VALLEY_DEPTH + 2.0))
	terrain.set_meta(Meta.GENERATOR_USE_SINGLE_STYLE, true)
	terrain.set_meta(Meta.GENERATOR_SMOOTHNESS, 0.0)
	# Red stays at ground level here: the massifs are added by _roughen.
	terrain.set_meta(Meta.GENERATOR_RAISE_HEIGHT, 0.0)
	terrain.set_meta(Meta.GENERATOR_LOWER_DEPTH, VALLEY_DEPTH)
	terrain.set_meta(Meta.COLLISION_ENABLED, true)
	print("pixel map: ", ImageGenerator.apply(terrain, image))

	_roughen(terrain, _massif_field(image))
	_paint_by_height(terrain, styles)

	terrain.set_meta(Meta.BIOME, biome)
	var shading: Dictionary = biome.shading_values()
	for key in shading:
		terrain.set_meta(key, shading[key])

	var builder := TerrainBuilder.new()
	builder.owner_provider = func() -> Node: return root
	var t := Time.get_ticks_msec()
	builder.rebuild_all(terrain)
	print("rebuild_all %d ms, details %s" % [Time.get_ticks_msec() - t, DetailScatter.count_instances(terrain)])
	return root

## 0..1 per cell: red pixels blurred over MASSIF_REACH cells (3 box blurs ~
## a gaussian), then stretched so red cores reach 1.
func _massif_field(image: Image) -> PackedFloat32Array:
	var w := image.get_width()
	var h := image.get_height()
	var field := PackedFloat32Array()
	field.resize(w * h)
	for y in h:
		for x in w:
			if ImageGenerator.classify_pixel(image.get_pixel(x, y), 0.2) == ImageGenerator.PixelClass.RAISED:
				field[y * w + x] = 1.0
	for i in 3:
		field = _box_blur(field, w, h, MASSIF_REACH / 2)
	for i in field.size():
		field[i] = smoothstep(0.03, 0.55, field[i])
	return field

func _box_blur(src: PackedFloat32Array, w: int, h: int, r: int) -> PackedFloat32Array:
	var tmp := PackedFloat32Array()
	tmp.resize(src.size())
	for y in h:
		for x in w:
			var sum := 0.0
			for k in range(-r, r + 1):
				sum += src[y * w + clampi(x + k, 0, w - 1)]
			tmp[y * w + x] = sum / float(2 * r + 1)
	var out := PackedFloat32Array()
	out.resize(src.size())
	for y in h:
		for x in w:
			var sum := 0.0
			for k in range(-r, r + 1):
				sum += tmp[clampi(y + k, 0, h - 1) * w + x]
			out[y * w + x] = sum / float(2 * r + 1)
	return out

## Massifs from the blurred red, foothills everywhere, rough ridges growing
## with the massif.
func _roughen(terrain: Node3D, massif: PackedFloat32Array) -> void:
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var mask: PackedFloat32Array = terrain.get_meta(Meta.MASK)
	var hills := FastNoiseLite.new()
	hills.seed = 11
	hills.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	hills.frequency = 1.0 / 45.0
	hills.fractal_octaves = 3
	var ridges := FastNoiseLite.new()
	ridges.seed = 5
	ridges.frequency = 1.0 / 14.0
	ridges.fractal_type = FastNoiseLite.FRACTAL_RIDGED
	ridges.fractal_octaves = 4
	var top := 0.0
	for i in heights.size():
		if mask[i] <= 0.0:
			continue
		var x := i % resolution
		var z := i / resolution
		var side := resolution - 1
		var up := massif[mini(z, side - 1) * side + mini(x, side - 1)]
		var h := heights[i] + MOUNTAIN_HEIGHT * up
		h += (hills.get_noise_2d(x, z) * 0.5 + 0.5) * FOOTHILLS
		h += ridges.get_noise_2d(x, z) * RIDGES * up
		heights[i] = h
		top = maxf(top, h)
	terrain.set_meta(Meta.HEIGHTS, heights)
	print("highest point %.1f m" % top)

## Snow on the peaks, rock on steep or high ground, grass below.
func _paint_by_height(terrain: Node3D, styles: Dictionary) -> void:
	var grass := _style_id(terrain, styles["Grass"])
	var rock := _style_id(terrain, styles["Rock"])
	var snow := _style_id(terrain, styles["Snow"])
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var spacing := world_size / float(resolution - 1)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var cell_styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES)
	var jitter := FastNoiseLite.new()
	jitter.seed = 3
	jitter.frequency = 1.0 / 9.0
	var counts := [0, 0, 0]
	for z in range(resolution - 1):
		for x in range(resolution - 1):
			var cell := GridMath.cell_index(x, z, resolution)
			if cell_styles[cell] < 0:
				continue
			var a := heights[z * resolution + x]
			var b := heights[z * resolution + x + 1]
			var c := heights[(z + 1) * resolution + x]
			var d := heights[(z + 1) * resolution + x + 1]
			var h := (a + b + c + d) * 0.25 + jitter.get_noise_2d(x, z) * 2.0
			var rise := maxf(absf(b - a + d - c), absf(c - a + d - b)) * 0.5 / spacing
			var slope := rad_to_deg(atan(rise))
			if h > MOUNTAIN_HEIGHT * 0.9:
				cell_styles[cell] = snow
				counts[2] += 1
			elif slope > 30.0 or h > MOUNTAIN_HEIGHT * 0.55:
				cell_styles[cell] = rock
				counts[1] += 1
			else:
				cell_styles[cell] = grass
				counts[0] += 1
	terrain.set_meta(Meta.CELL_STYLES, cell_styles)
	print("cells: grass %d, rock %d, snow %d" % counts)

func _style_id(terrain: Node3D, style: Resource) -> int:
	return StylePalette.capture_style_definition(terrain, style.top_color, style.side_color, null, null, style.top_tile_size, style.side_tile_size)

# --- Renders --------------------------------------------------------------------

func _ground(p: Vector2) -> float:
	return WaterholeMesher.surface_height(_terrain.get_meta(Meta.HEIGHTS), PackedFloat32Array(),
		_terrain.get_meta(Meta.RESOLUTION), _terrain.get_meta(Meta.WORLD_SIZE), p)

func _at(p: Vector2, lift: float) -> Vector3:
	return Vector3(p.x, _ground(p) + lift, p.y)

## Local position of the highest vertex.
func _peak() -> Vector3:
	var resolution: int = _terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = _terrain.get_meta(Meta.WORLD_SIZE)
	var heights: PackedFloat32Array = _terrain.get_meta(Meta.HEIGHTS)
	var best := 0
	for i in heights.size():
		if heights[i] > heights[best]:
			best = i
	var p := GridMath.grid_to_local(best % resolution, best / resolution, resolution, world_size)
	return Vector3(p.x, heights[best], p.z)

func _render(root: Node3D) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	root.add_child((load("res://world/open_world_sky.tscn") as PackedScene).instantiate())
	var camera := Camera3D.new()
	camera.fov = 60.0
	camera.far = 1200.0
	root.add_child(camera)
	camera.current = true
	var half: float = float(_terrain.get_meta(Meta.WORLD_SIZE)) * 0.5
	var peak := _peak()
	var views := {
		"vue_haute": [Vector3(0, half * 1.15, half * 1.4), Vector3(0, 0, 0)],
		"vue_oblique": [Vector3(-half * 1.15, half * 0.45, half * 0.95), Vector3(0, 4, 0)],
		"vallee": [_at(Vector2(0, 0), 1.7), Vector3(peak.x, peak.y * 0.6, peak.z)],
		"depuis_sommet": [peak + Vector3(0, 3.0, 0) + (Vector3(-peak.x, 0, -peak.z).normalized() * 4.0), Vector3(-peak.x, 0, -peak.z)],
	}
	var names: Array = views.keys()
	for view_name: String in names:
		var view: Array = views[view_name]
		camera.look_at_from_position(view[0], view[1])
		for f in range(20):
			await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png("%s/%s.png" % [OUT, view_name])
	var sheet := Image.create(1280, 720, false, Image.FORMAT_RGB8)
	for i in names.size():
		var img := Image.load_from_file(ProjectSettings.globalize_path("%s/%s.png" % [OUT, names[i]]))
		img.convert(Image.FORMAT_RGB8)
		img.resize(640, 360, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(0, 0, 640, 360), Vector2i((i % 2) * 640, (i / 2) * 360))
	sheet.save_png(OUT + "/planche.png")
	print("rendered ", names)
