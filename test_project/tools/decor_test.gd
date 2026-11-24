extends SceneTree
## Decor test: the same generated map (open-world recipe at 256 cells, seed 7)
## with the built-in low-poly decor and with real 3D models from
## assets/models/polyhaven (Poly Haven, CC0, glTF 1K) in some detail layers
## (LowpolyDetailLayer.model). Each model is scaled to the size of the
## built-in mesh it replaces. wild_rooibos_bush_1k.gltf was edited: its leaf
## alpha (a separate map on Poly Haven) merged into a PNG, alpha MASK instead
## of BLEND. Notes: results/decor/README.md. Real window, kept off screen:
##   godot --path . --rendering-method mobile --position -3000,-3000 --resolution 1280x720 --script res://tools/decor_test.gd
## Writes res://results/decor/<variant>_<view>.png, planche.png (rows =
## views, columns = variants) and costs.txt (GPU ms, draw calls, triangles,
## texture memory per view, on this PC).

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const DetailMeshes = preload(ADDON + "mesh/detail_meshes.gd")
const ModelMesh = preload(ADDON + "mesh/model_mesh.gd")

const RECIPE := ADDON + "generation/presets/senegal_savanna_open_world_map.tres"
const MODEL := "res://assets/models/polyhaven/%s/%s_1k.gltf"
const OUT := "res://results/decor"
const SIZE := 256
const SEED := 7
## Detail layer name -> Poly Haven model.
const LAYER_MODELS := {
	"Acacias": "quiver_tree_02",
	"Rocks": "namaqualand_boulder_04",
	"Shrubs": "wild_rooibos_bush",
	"Dead Trees": "dead_quiver_trunk",
}
const VARIANTS := ["decor_actuel", "modeles_3d"]
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

## A model's layer scale giving it the height of the built-in mesh: built-in
## meshes are in cells (scale x cell size), models in metres (scale x 1).
func _recipe(variant: String) -> Resource:
	var recipe: Resource = (load(RECIPE) as Resource).duplicate()
	recipe.set("size", SIZE)
	if variant == "decor_actuel":
		return recipe
	var biome: Resource = (recipe.get("biome") as Resource).duplicate()
	var layers: Array = (biome.get("detail_layers") as Array).duplicate()
	for i in layers.size():
		var layer: Resource = (layers[i] as Resource).duplicate()
		var id: String = LAYER_MODELS.get(String(layer.get("name")), "")
		if not id.is_empty():
			var scene: PackedScene = load(MODEL % [id, id])
			var builtin_h := DetailMeshes.builtin(int(layer.get("builtin_mesh"))).get_aabb().size.y * _spacing
			var model_h := ModelMesh.mesh_of(scene).get_aabb().size.y
			var k := builtin_h / maxf(model_h, 0.01)
			print("%s: built-in %.2f m (scale 1), model %s %.2f m -> x%.2f" % [layer.get("name"), builtin_h, id, model_h, k])
			layer.set("model", scene)
			layer.set("scale_min", float(layer.get("scale_min")) * k)
			layer.set("scale_max", float(layer.get("scale_max")) * k)
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

## Local position of the instance of `layer_name` closest to the centre.
func _nearest_instance(layer_name: String) -> Vector3:
	var best := Vector3(INF, 0, INF)
	for node in _terrain.find_children("*", "MultiMeshInstance3D", true, false):
		if not String(node.name).contains(layer_name.replace(" ", "")) and not String(node.name).contains(layer_name):
			continue
		var mm: MultiMesh = (node as MultiMeshInstance3D).multimesh
		if mm == null:
			continue
		for i in mm.visible_instance_count if mm.visible_instance_count >= 0 else mm.instance_count:
			var p := _terrain.to_local((node as Node3D).to_global(mm.get_instance_transform(i).origin))
			if Vector2(p.x, p.z).length() < Vector2(best.x, best.z).length():
				best = p
	return best

func _views() -> Dictionary:
	var views := {
		"vue_haute": [Vector3(0, 95, 125), Vector3(0, 0, 0)],
		"hauteur_yeux": [_at(Vector2(-10, 20), 1.7), _at(Vector2(15, -15), 1.2)],
		"gros_plan": [_at(Vector2(-10, 20), 1.4), _at(Vector2(-8, 17), 0.0)],
	}
	for layer_name in ["Acacias", "Rocks", "Shrubs"]:
		var p := _nearest_instance(layer_name)
		if is_finite(p.x):
			var c := Vector2(p.x, p.z)
			var far := {"Acacias": 14.0, "Rocks": 4.0, "Shrubs": 4.0}[layer_name] as float
			var look_h := {"Acacias": 3.0, "Rocks": 0.3, "Shrubs": 0.5}[layer_name] as float
			var eye := c + Vector2(far, far * 0.6)
			views["proche_" + String(layer_name).to_lower()] = [_at(eye, 1.7), Vector3(p.x, p.y + look_h, p.z)]
	var road := _feature_points(Meta.ROADS)
	if road.size() >= 2:
		var seg := _along(road, 25.0)
		views["route"] = [_at(seg[0], 1.7), _at(seg[1], 0.8)]
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
	var lines: Array[String] = ["variant view gpu_ms draw_calls triangles texture_mb"]
	var names: Array = []
	# Same camera places for both variants: the views of the first one.
	var views := {}
	for variant in VARIANTS:
		var ms := _build(variant)
		print("%s built in %d ms" % [variant, ms])
		lines.append("%s build_ms %d" % [variant, ms])
		if views.is_empty():
			views = _views()
			names = views.keys()
		for view_name in names:
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
			var tris := Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
			var tex_mb := Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0
			lines.append("%s %s %.2f %d %d %.1f" % [variant, view_name, gpu / frames, calls, tris, tex_mb])
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
