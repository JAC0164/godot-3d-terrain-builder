extends SceneTree
## Showcase renders of the plugin for the README (docs/showcase/): a savanna
## map made by Generate Map (preset Senegal Savanna), lit for beauty shots
## (low warm sun, soft shadows, SSAO, golden haze; Forward+), filmed from
## viewpoints found on the map itself: river, track, waterhole, acacias,
## baobab, overview. Plus "pixel map -> terrain" (assets/pixel_maps) and a
## contact sheet. The lighting is the showcase's, not the plugin's (each game
## lights its own scenes). Real window, kept off screen:
##   godot --path . --rendering-method forward_plus --position -3000,-3000 --resolution 1920x1080 --script res://tools/render_showcase.gd -- [--seed=7] [--only=hero,river]

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const WaterholeStyle = preload(ADDON + "styles/waterhole_style.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")

const OUT := "res://../docs/showcase"
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

var _terrain: Node3D
var _heights: PackedFloat32Array
var _resolution := 0
var _world_size := 0.0
var _caption: Label
var _caption_box: PanelContainer
var _title: Control
var _sun_dir := Vector2.ZERO
var _obstacles: Array[Vector3] = []

func _initialize() -> void:
	var args := {"seed": "7", "only": ""}
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	get_root().msaa_3d = Viewport.MSAA_4X
	get_root().screen_space_aa = Viewport.SCREEN_SPACE_AA_DISABLED
	RenderingServer.directional_shadow_atlas_set_size(8192, true)
	RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_SOFT_HIGH)

	var root := Node3D.new()
	get_root().add_child(root)
	_add_lighting(root)
	_terrain = Node3D.new()
	_terrain.name = "LowpolyTerrain"
	root.add_child(_terrain)
	TerrainData.initialize(_terrain)
	# The savanna preset plus one river (a recipe setting), for the shots.
	var recipe: Resource = (load(RECIPE) as Resource).duplicate()
	recipe.set("river_count", 1)
	recipe.set("river_width", 4.0)
	recipe.set("river_depth", 0.9)
	var stats: Dictionary = MapGenerator.generate(_terrain, recipe, int(args["seed"]))
	print("map: ", stats)
	var builder := TerrainBuilder.new()
	builder.owner_provider = func() -> Node: return root
	builder.rebuild_all(_terrain)
	# The far landscape of the test project (world/map_horizon.gd), so the
	# map does not end in the void.
	var horizon: Node3D = (load("res://world/map_horizon.gd") as GDScript).new()
	horizon.set("boundary_walls", false)
	_terrain.add_child(horizon)
	horizon.call("rebuild")
	_heights = _terrain.get_meta(Meta.HEIGHTS)
	_resolution = _terrain.get_meta(Meta.RESOLUTION)
	_world_size = _terrain.get_meta(Meta.WORLD_SIZE)
	_add_overlay(root)

	var camera := Camera3D.new()
	camera.far = 1500.0
	root.add_child(camera)
	camera.current = true

	var out_dir := ProjectSettings.globalize_path(OUT).simplify_path()
	DirAccess.make_dir_recursive_absolute(out_dir)
	var only: PackedStringArray = String(args["only"]).split(",", false)
	var shots := _shots()
	for shot: Dictionary in shots:
		if not only.is_empty() and not only.has(shot["name"]):
			continue
		camera.fov = shot.get("fov", 55.0)
		camera.look_at_from_position(shot["from"], shot["to"])
		_title.visible = shot["name"] == "hero"
		_caption_box.visible = not _title.visible
		_caption.text = shot["caption"]
		for f in range(30):
			await RenderingServer.frame_post_draw
		var image := get_root().get_texture().get_image()
		image.convert(Image.FORMAT_RGB8)
		image.save_jpg("%s/%s.jpg" % [out_dir, shot["name"]], 0.9)
		print("wrote ", shot["name"])
	if only.is_empty() or only.has("pixel_map"):
		await _pixel_map_shot(root, camera, out_dir)
		_pixel_map_panel(out_dir)
	_sheet(out_dir)
	quit(0)

## The savanna built from the pixel map (scenes/savane_image.tscn, made by
## tools/build_savanna_from_image.gd), same light, seen from the bottom of the
## image so both read the same way round.
func _pixel_map_shot(root: Node3D, camera: Camera3D, out_dir: String) -> void:
	var scene := load("res://scenes/savane_image.tscn") as PackedScene
	if scene == null:
		print("pixel map shot skipped (run tools/build_savanna_from_image.gd first)")
		return
	_terrain.queue_free()
	var map := scene.instantiate()
	root.add_child(map)
	camera.fov = 42.0
	camera.look_at_from_position(Vector3(0, 62, 92), Vector3(0, -2, 4))
	_title.visible = false
	_caption_box.visible = true
	_caption.text = "Generate from Image: one pixel = one terrain cell"
	for f in range(30):
		await RenderingServer.frame_post_draw
	var image := get_root().get_texture().get_image()
	image.convert(Image.FORMAT_RGB8)
	image.save_jpg(out_dir + "/pixel_map_terrain.jpg", 0.9)
	print("wrote pixel_map_terrain")

# --- Look -----------------------------------------------------------------------

## The project's savanna look (world/savanna_environment.tres) with a lower,
## warmer sun, finer shadows and contact shadows (SSAO) for still images.
func _add_lighting(root: Node3D) -> void:
	var environment := (load("res://world/savanna_environment.tres") as Environment).duplicate(true)
	var sky_material := environment.sky.sky_material as ProceduralSkyMaterial
	sky_material.sky_top_color = Color(0.22, 0.43, 0.78)
	sky_material.sky_horizon_color = Color(0.86, 0.78, 0.66)
	sky_material.ground_horizon_color = Color(0.86, 0.78, 0.66)
	environment.ssao_enabled = true
	environment.ssao_radius = 1.4
	environment.ssao_intensity = 1.4
	environment.fog_depth_begin = 120.0
	environment.fog_depth_end = 650.0
	environment.fog_sky_affect = 0.12
	environment.adjustment_saturation = 1.0
	var world_environment := WorldEnvironment.new()
	world_environment.environment = environment
	root.add_child(world_environment)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-26.0, -40.0, 0.0)
	sun.light_color = Color(1.0, 0.86, 0.68)
	sun.light_energy = 1.6
	sun.light_angular_distance = 0.5
	sun.shadow_enabled = true
	sun.shadow_blur = 1.0
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 200.0
	root.add_child(sun)
	# Where the light goes, on the ground plane (to film the props side-lit).
	var light := -sun.transform.basis.z
	_sun_dir = Vector2(light.x, light.z).normalized()

## Title on the hero shot, a small caption on the others.
func _add_overlay(root: Node3D) -> void:
	var layer := CanvasLayer.new()
	root.add_child(layer)
	var title := VBoxContainer.new()
	title.position = Vector2(64, 56)
	var name_label := _label("Lowpoly Terrain Editor", 76)
	var line := _label("Low poly 3D terrain for Godot 4: paint it, generate it, play it", 32)
	title.add_child(name_label)
	title.add_child(line)
	layer.add_child(title)
	_title = title
	_caption_box = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.08, 0.06, 0.04, 0.55)
	style.set_corner_radius_all(10)
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 10
	style.content_margin_bottom = 12
	_caption_box.add_theme_stylebox_override("panel", style)
	_caption_box.position = Vector2(48, 960)
	_caption = _label("", 40)
	_caption_box.add_child(_caption)
	layer.add_child(_caption_box)

func _label(text: String, size: int) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", Color(1.0, 0.97, 0.9))
	label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.55))
	label.add_theme_constant_override("shadow_offset_x", 2)
	label.add_theme_constant_override("shadow_offset_y", 3)
	label.add_theme_constant_override("shadow_outline_size", 6)
	return label

# --- Viewpoints -------------------------------------------------------------------

func _ground(p: Vector2) -> float:
	return WaterholeMesher.surface_height(_heights, PackedFloat32Array(), _resolution, _world_size, p)

func _at(p: Vector2, lift: float) -> Vector3:
	return Vector3(p.x, _ground(p) + lift, p.y)

## Largest instance of the detail layer whose node name contains `part`,
## preferring the middle of the map.
func _biggest(part: String) -> Vector2:
	var best := -INF
	var found := Vector2.ZERO
	for node in _terrain.find_children("_Details*", "MultiMeshInstance3D", true, false):
		if not String(node.name).contains(part):
			continue
		var buffer: PackedFloat32Array = (node as MultiMeshInstance3D).multimesh.buffer
		for i in range(0, buffer.size(), 16):
			var scale := Vector3(buffer[i], buffer[i + 4], buffer[i + 8]).length()
			var p := Vector2(buffer[i + 3], buffer[i + 11])
			var score := scale - p.length() * 0.02
			if score > best:
				best = score
				found = p
	return found

## Trees, baobabs and mounds (x, z, radius): a camera must not stand in one
## or look through one.
func _collect_obstacles() -> void:
	_obstacles.clear()
	for node in _terrain.find_children("_Details*", "MultiMeshInstance3D", true, false):
		var node_name := String(node.name)
		var reach := 0.0
		if node_name.contains("Acacia"):
			reach = 0.55
		elif node_name.contains("Baobab"):
			reach = 0.35
		elif node_name.contains("Termite") or node_name.contains("Dead"):
			reach = 0.3
		else:
			continue
		var buffer: PackedFloat32Array = (node as MultiMeshInstance3D).multimesh.buffer
		for i in range(0, buffer.size(), 16):
			var scale := Vector3(buffer[i], buffer[i + 4], buffer[i + 8]).length()
			_obstacles.append(Vector3(buffer[i + 3], buffer[i + 11], maxf(scale * reach, 1.2)))

func _blocked(from: Vector2, to: Vector2) -> bool:
	for o in _obstacles:
		var p := Vector2(o.x, o.y)
		# Nothing right next to the camera (it would fill the frame).
		if p.distance_to(from) < o.z + 3.0:
			return true
		if p.distance_to(to) < 3.0:
			continue
		if Geometry2D.get_closest_point_to_segment(p, from, to).distance_to(p) < o.z + 0.6:
			return true
	return false

## A camera `distance` from `target`, `lift` above the ground, with a clear
## line of sight and the sun from the side (props read well).
func _view(target: Vector2, distance: float, lift: float, target_lift: float, fov: float = 55.0) -> Dictionary:
	var best := {}
	var best_score := -INF
	var half := _world_size * 0.5 - 6.0
	for step in 24:
		var angle := TAU * float(step) / 24.0
		var from := target + Vector2.from_angle(angle) * distance
		if absf(from.x) > half or absf(from.y) > half or _blocked(from, target):
			continue
		var look := (target - from).normalized()
		var score := -absf(look.dot(_sun_dir) - 0.35)
		if score > best_score:
			best_score = score
			best = {"from": _at(from, lift), "to": _at(target, target_lift), "fov": fov}
	if best.is_empty():
		best = {"from": _at(target + Vector2(distance, distance) * 0.7, lift + 4.0), "to": _at(target, target_lift), "fov": fov}
	return best

## Along a polyline: the first point from `t` on where a camera `back` metres
## behind it (and `side` to the side) sees it clearly.
func _along_view(points: Array, t: float, back: float, side: float, lift: float, ahead: float) -> Dictionary:
	for k in 12:
		var tt := fposmod(t + float(k) * 0.07, 0.8) + 0.1
		var i := clampi(int(tt * float(points.size() - 1)), 1, points.size() - 2)
		var p: Vector2 = points[i]
		var d: Vector2 = ((points[i + 1] as Vector2) - (points[i - 1] as Vector2)).normalized()
		var from := p - d * back + d.orthogonal() * side
		var to := p + d * ahead
		# On flat ground (not on a plateau slope above the line).
		var flat := absf(_ground(from) - _ground(p)) < 0.8 and absf(_ground(to) - _ground(p)) < 0.8
		if flat and not _blocked(from, to):
			return {"from": _at(from, lift), "to": _at(to, 0.3)}
	var p0: Vector2 = points[points.size() / 2]
	return {"from": _at(p0 + Vector2(back, back), lift + 4.0), "to": _at(p0, 0.0)}

func _shots() -> Array[Dictionary]:
	_collect_obstacles()
	var half := _world_size * 0.5
	var rivers: Array = _terrain.get_meta(Meta.RIVERS, [])
	var roads: Array = _terrain.get_meta(Meta.ROADS, [])
	var holes: Array = WaterholeStyle.list(_terrain)
	var river: Array = (rivers[0] as Dictionary)["points"] if not rivers.is_empty() else [Vector2(-10, 0), Vector2(0, 0), Vector2(10, 0)]
	var road: Array = (roads[0] as Dictionary)["points"] if not roads.is_empty() else [Vector2(0, -10), Vector2(0, 0), Vector2(0, 10)]
	# The waterhole nearest the centre.
	var hole: Dictionary = {}
	for h: Variant in holes:
		var candidate: Dictionary = WaterholeStyle.migrate(h)
		if hole.is_empty() or (candidate["center"] as Vector2).length() < (hole["center"] as Vector2).length():
			hole = candidate
	if hole.is_empty():
		hole = {"center": Vector2.ZERO, "radius": 6.0}
	var hc: Vector2 = hole["center"]
	var hr: float = hole["radius"]
	var baobab := _biggest("Baobab")
	var acacia := _biggest("Acacia")
	# Hero: high over the river, looking along it to the skyline.
	var m := river.size() / 2
	var mid: Vector2 = river[m]
	var river_dir: Vector2 = ((river[mini(m + 2, river.size() - 1)] as Vector2) - (river[maxi(m - 2, 0)] as Vector2)).normalized()
	var hero := {"from": _at(mid - river_dir * 55.0 + river_dir.orthogonal() * 18.0, 24.0), "to": _at(mid + river_dir * 60.0, 2.0), "fov": 55.0}
	var shots: Array[Dictionary] = [
		hero.merged({"name": "hero", "caption": ""}),
		_along_view(river, 0.35, 13.0, 3.0, 1.8, 22.0).merged({"name": "river", "caption": "Rivers carve their bed and never flow uphill"}),
		_along_view(road, 0.4, 11.0, 2.0, 2.0, 18.0).merged({"name": "track", "caption": "Tracks follow the ground"}),
		_view(hc, hr * 2.1, hr * 0.7, -0.3).merged({"name": "waterhole", "caption": "Dried waterholes with cracked mud"}),
		_view(acacia, 13.0, 1.8, 3.2).merged({"name": "acacias", "caption": "Biomes: what grows where, with wind"}),
		_view(baobab, 26.0, 1.8, 5.5).merged({"name": "baobab", "caption": "Built-in low poly props, or your own models"}),
		{"name": "overview", "caption": "Generate Map: a whole map from a seed", "fov": 45.0,
			"from": Vector3(-half * 0.9, half * 0.75, half * 0.95), "to": Vector3(0, 0, -half * 0.1)},
	]
	return shots

# --- Panels -----------------------------------------------------------------------

## The pixel map next to the terrain built from it (results/savane_image).
func _pixel_map_panel(out_dir: String) -> void:
	var render_path := out_dir + "/pixel_map_terrain.jpg"
	var pixel := Image.load_from_file(ProjectSettings.globalize_path("res://assets/pixel_maps/savane_anneau.png"))
	if not FileAccess.file_exists(render_path) or pixel == null:
		print("pixel panel skipped")
		return
	var panel := Image.create(1920, 1080, false, Image.FORMAT_RGB8)
	panel.fill(Color(0.13, 0.11, 0.09))
	pixel.convert(Image.FORMAT_RGB8)
	pixel.resize(576, 576, Image.INTERPOLATE_NEAREST)
	panel.blit_rect(pixel, Rect2i(0, 0, 576, 576), Vector2i(90, 252))
	var render := Image.load_from_file(render_path)
	render.convert(Image.FORMAT_RGB8)
	render.resize(1120, 630, Image.INTERPOLATE_LANCZOS)
	panel.blit_rect(render, Rect2i(0, 0, 1120, 630), Vector2i(740, 225))
	# Arrow between them.
	for y in range(-26, 27):
		for x in range(0, 34 - absi(y)):
			panel.set_pixel(690 + x, 540 + y, Color(0.95, 0.85, 0.65))
	panel.save_jpg(out_dir + "/pixel_map.jpg", 0.9)
	print("wrote pixel_map")

## Hero on top, the other shots in a 3 x 2 grid below.
func _sheet(out_dir: String) -> void:
	var names := ["river", "track", "waterhole", "acacias", "baobab", "overview"]
	var sheet := Image.create(1920, 1080 + 720, false, Image.FORMAT_RGB8)
	var hero := Image.load_from_file(out_dir + "/hero.jpg")
	if hero == null:
		return
	hero.convert(Image.FORMAT_RGB8)
	sheet.blit_rect(hero, Rect2i(0, 0, 1920, 1080), Vector2i.ZERO)
	for i in names.size():
		var img := Image.load_from_file("%s/%s.jpg" % [out_dir, names[i]])
		if img == null:
			continue
		img.convert(Image.FORMAT_RGB8)
		img.resize(640, 360, Image.INTERPOLATE_LANCZOS)
		sheet.blit_rect(img, Rect2i(0, 0, 640, 360), Vector2i((i % 3) * 640, 1080 + (i / 3) * 360))
	sheet.save_jpg(out_dir + "/showcase.jpg", 0.88)
	print("wrote showcase")
