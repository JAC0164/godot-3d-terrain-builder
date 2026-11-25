extends SceneTree
## Texture test: the same generated map (open-world recipe at 256 cells, so it
## has tracks, rivers, waterholes and plateaus) without textures and with the
## HD textures of assets/textures/polyhaven (Poly Haven, CC0, 2K diffuse) on
## every ground style, cliff and road. Real window, kept off screen:
##   godot --path . --rendering-method mobile --position -3000,-3000 --resolution 1280x720 --script res://tools/texture_test.gd
## Writes res://results/textures/<variant>_<view>.png, planche.png (rows =
## views, columns = variants) and costs.txt (GPU ms, draw calls, texture
## memory per view, on this PC).

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")

const RECIPE := ADDON + "generation/presets/senegal_savanna_open_world_map.tres"
const TEX := "res://assets/textures/polyhaven/%s.jpg"
const OUT := "res://results/textures"
const SIZE := 256
const SEED := 7
## Ground style name -> [top texture, side texture].
const STYLE_TEXTURES := {
	"Dry Grass": ["dry_ground_01", "cliff_side"],
	"Laterite": ["cracked_red_ground", "excavated_soil_wall"],
	"Green Savanna": ["grass_path_2", "cliff_side"],
	"Sand": ["coast_sand_01", "cliff_side"],
	"Dry Clay": ["mud_cracked_dry_03", "cliff_side"],
	"Burnt Ground": ["brown_mud_dry", "cliff_side"],
}
const ROAD_TEXTURE := "dirt_aerial_02"
## Size (m) of one repeat of every texture.
const TILE := 3.0
## sans_texture: as today. textures: textured, details kept on textured
## ground. textures_defaut: textured, the layers' default Skip Textured (no
## details on textured ground).
const VARIANTS := ["sans_texture", "textures", "textures_defaut"]
const SHEET_W := 640
const SHEET_H := 360

var _root: Node3D
var _terrain: Node3D
var _camera: Camera3D
var _heights: PackedFloat32Array
var _resolution := 0
var _world_size := 0.0
var _spacing := 1.0

func _ground(p: Vector2) -> float:
	return WaterholeMesher.surface_height(_heights, PackedFloat32Array(), _resolution, _world_size, p)

func _at(p: Vector2, lift: float) -> Vector3:
	return Vector3(p.x, _ground(p) + lift, p.y)

func _recipe(variant: String) -> Resource:
	var recipe: Resource = (load(RECIPE) as Resource).duplicate()
	recipe.set("size", SIZE)
	if variant == "sans_texture":
		return recipe
	var biome: Resource = (recipe.get("biome") as Resource).duplicate()
	var styles: Array = (biome.get("ground_styles") as Array).duplicate()
	for i in styles.size():
		var style: Resource = (styles[i] as Resource).duplicate()
		var pair: Array = STYLE_TEXTURES.get(String(style.get("name")), [])
		if pair.size() == 2:
			style.set("top_texture", load(TEX % pair[0]))
			style.set("side_texture", load(TEX % pair[1]))
			style.set("top_tile_size", TILE)
			style.set("side_tile_size", TILE)
		styles[i] = style
	biome.set("ground_styles", styles)
	if variant == "textures":
		var layers: Array = (biome.get("detail_layers") as Array).duplicate()
		for i in layers.size():
			var layer: Resource = (layers[i] as Resource).duplicate()
			layer.set("skip_textured", false)
			layers[i] = layer
		biome.set("detail_layers", layers)
	recipe.set("biome", biome)
	return recipe

func _build(variant: String) -> int:
	if _root:
		_root.free()
	var t0 := Time.get_ticks_msec()
	_root = Node3D.new()
	get_root().add_child(_root)
	_root.add_child((load("res://world/savanna_sky.tscn") as PackedScene).instantiate())
	_terrain = Node3D.new()
	_terrain.name = "LowpolyTerrain"
	_root.add_child(_terrain)
	TerrainData.initialize(_terrain)
	MapGenerator.generate(_terrain, _recipe(variant), SEED)
	if variant != "sans_texture":
		# After the map (it sets the biome): road texture, one tile every 4 m (road UVs are in meters).
		var road := StandardMaterial3D.new()
		road.albedo_texture = load(TEX % ROAD_TEXTURE)
		road.uv1_scale = Vector3.ONE / 4.0
		road.texture_repeat = true
		road.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		var biome: Resource = (_terrain.get_meta(Meta.BIOME) as Resource).duplicate()
		biome.set("road_material", road)
		_terrain.set_meta(Meta.BIOME, biome)
	TerrainBuilder.new().rebuild_all(_terrain)
	_heights = _terrain.get_meta(Meta.HEIGHTS)
	_resolution = _terrain.get_meta(Meta.RESOLUTION)
	_world_size = _terrain.get_meta(Meta.WORLD_SIZE)
	_spacing = _world_size / float(_resolution - 1)
	_camera = Camera3D.new()
	_camera.fov = 60.0
	_camera.far = 800.0
	_root.add_child(_camera)
	_camera.current = true
	return Time.get_ticks_msec() - t0

# --- Views (same places for every variant: same seed) ---------------------------

## The point of `points` closest to the centre, and the point ~`ahead` m
## further along.
func _along(points: Array, ahead: float) -> Array:
	var best := 0
	for i in points.size():
		if (points[i] as Vector2).length() < (points[best] as Vector2).length():
			best = i
	if best > points.size() / 2:
		points = points.duplicate()
		points.reverse()
		best = points.size() - 1 - best
	var start: Vector2 = points[best]
	var end := start
	for i in range(best + 1, points.size()):
		end = points[i]
		if end.distance_to(start) >= ahead:
			break
	return [start, end]

func _feature_points(key: String) -> Array:
	var best: Array = []
	for feature in _terrain.get_meta(key, []):
		var points: Array = (feature as Dictionary).get("points", [])
		if points.size() > best.size():
			best = points
	return best

func _plateau_edge() -> Vector2:
	var half := _world_size * 0.5
	var best := INF
	var found := Vector2.ZERO
	for z in range(8, _resolution - 8, 2):
		for x in range(8, _resolution - 11, 2):
			var h := _heights[z * _resolution + x]
			var h2 := _heights[z * _resolution + x + 3]
			if h2 - h > 1.6:
				var p := Vector2(x * _spacing - half, z * _spacing - half)
				if p.length() < best:
					best = p.length()
					found = p + Vector2(_spacing * 1.5, 0)
	return found

func _views() -> Dictionary:
	var views := {
		"vue_haute": [Vector3(0, 95, 125), Vector3(0, 0, 0)],
		"hauteur_yeux": [_at(Vector2(-10, 20), 1.7), _at(Vector2(15, -15), 1.2)],
		"gros_plan": [_at(Vector2(-10, 20), 1.4), _at(Vector2(-8, 17), 0.0)],
	}
	var edge := _plateau_edge()
	views["falaise"] = [_at(edge + Vector2(-16, 12), 4.0), _at(edge + Vector2(3, 0), 1.0)]
	var road := _feature_points(Meta.ROADS)
	if road.size() >= 2:
		var seg := _along(road, 25.0)
		views["route"] = [_at(seg[0], 1.7), _at(seg[1], 0.8)]
	var river := _feature_points(Meta.RIVERS)
	if river.size() >= 2:
		var seg := _along(river, 6.0)
		var dir: Vector2 = ((seg[1] as Vector2) - (seg[0] as Vector2)).normalized()
		var side := Vector2(-dir.y, dir.x) * 12.0
		views["riviere"] = [_at((seg[0] as Vector2) + side - dir * 8.0, 4.0), _at(seg[0], 0.0)]
	var holes: Array = _terrain.get_meta(Meta.WATERHOLES, [])
	if not holes.is_empty():
		var hole: Dictionary = holes[0]
		for h in holes:
			if ((h as Dictionary)["center"] as Vector2).length() < (hole["center"] as Vector2).length():
				hole = h
		var c: Vector2 = hole["center"]
		var r: float = hole.get("radius", 6.0)
		views["point_eau"] = [_at(c + Vector2(r * 1.8, r * 1.4), 4.5), _at(c, 0.0)]
	return views

# --- Run ------------------------------------------------------------------------

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	await process_frame
	var viewport := get_root().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(viewport, true)
	var lines: Array[String] = ["variant view gpu_ms draw_calls texture_mb"]
	var names: Array = []
	for variant in VARIANTS:
		var ms := _build(variant)
		print("%s built in %d ms" % [variant, ms])
		lines.append("%s build_ms %d" % [variant, ms])
		var views := _views()
		if names.is_empty():
			names = views.keys()
		for view_name in names:
			if not views.has(view_name):
				continue
			var view: Array = views[view_name]
			_camera.look_at_from_position(_terrain.to_global(view[0]), _terrain.to_global(view[1]))
			for f in range(10):
				await RenderingServer.frame_post_draw
			var gpu := 0.0
			var frames := 40
			for f in range(frames):
				await RenderingServer.frame_post_draw
				gpu += RenderingServer.viewport_get_measured_render_time_gpu(viewport)
			var calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
			var tex_mb := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
			lines.append("%s %s %.2f %d %.1f" % [variant, view_name, gpu / frames, calls, tex_mb])
			get_root().get_texture().get_image().save_png("%s/%s_%s.png" % [OUT, variant, view_name])
		print("wrote %s_*" % variant)
	var file := FileAccess.open(OUT + "/costs.txt", FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()
	print("\n".join(lines))
	_sheet(names)
	quit(0)

## planche.png: one row per view, one column per variant.
func _sheet(names: Array) -> void:
	var sheet := Image.create(SHEET_W * VARIANTS.size(), SHEET_H * names.size(), false, Image.FORMAT_RGB8)
	for row in names.size():
		for col in VARIANTS.size():
			var path := ProjectSettings.globalize_path("%s/%s_%s.png" % [OUT, VARIANTS[col], names[row]])
			if not FileAccess.file_exists(path):
				continue
			var image := Image.load_from_file(path)
			image.convert(Image.FORMAT_RGB8)
			image.resize(SHEET_W, SHEET_H, Image.INTERPOLATE_LANCZOS)
			sheet.blit_rect(image, Rect2i(0, 0, SHEET_W, SHEET_H), Vector2i(col * SHEET_W, row * SHEET_H))
	sheet.save_png(OUT + "/planche.png")
	print("rows: ", names)
