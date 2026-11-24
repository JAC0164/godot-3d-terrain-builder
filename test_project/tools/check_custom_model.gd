extends SceneTree
## Your own asset in a biome layer (LowpolyDetailLayer.model): the imported
## res://assets/test_models/hut.glb (tools/make_test_model.gd) scattered on the
## generated savanna map. Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_custom_model.gd
## With a window, `-- --shot` also writes results/custom_model/huts.png:
##   godot --path . --position -3000,-3000 --script res://tools/check_custom_model.gd -- --shot

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const Brush = preload(ADDON + "editing/brush.gd")
const ToolMode = preload(ADDON + "editing/tool_mode.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const MODEL := "res://assets/test_models/hut.glb"

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _huts(terrain: Node3D, builder: TerrainBuilder) -> Array[Transform3D]:
	var out: Array[Transform3D] = []
	var n := TerrainMesher.chunk_count(terrain)
	for cz in n:
		for cx in n:
			for d in DetailScatter.build(terrain, builder.get_river_carve(terrain), cx, cz, builder.chunk_shading(terrain, cx, cz)):
				if String(d[3].name) != "Huts":
					continue
				var b: PackedFloat32Array = d[2]
				for i in int(d[1]):
					var o := i * 16
					out.append(Transform3D(Basis(Vector3(b[o], b[o + 4], b[o + 8]), Vector3(b[o + 1], b[o + 5], b[o + 9]), Vector3(b[o + 2], b[o + 6], b[o + 10])), Vector3(b[o + 3], b[o + 7], b[o + 11])))
	return out

func _initialize() -> void:
	var scene := load(MODEL) as PackedScene
	check("hut.glb imports as a scene", scene != null)
	if scene == null:
		quit(1)
		return
	var layer := LowpolyDetailLayer.new()
	layer.name = "Huts"
	layer.model = scene
	layer.density = 0.002
	layer.scale_min = 0.9
	layer.scale_max = 1.1
	layer.slope_max = 20.0
	layer.collision_radius = 0.45
	layer.collision_height = 0.6
	layer.cast_shadows = true
	var mesh: Mesh = layer.resolved_mesh()
	check("model -> one mesh, one surface per material (%d)" % (mesh.get_surface_count() if mesh else 0), mesh != null and mesh.get_surface_count() == 2)
	var aabb := mesh.get_aabb() if mesh else AABB()
	check("stands on its bottom centre (bottom %.3f, centre %.3f, %.3f)" % [aabb.position.y, aabb.get_center().x, aabb.get_center().z],
		absf(aabb.position.y) < 0.01 and absf(aabb.get_center().x) < 0.01 and absf(aabb.get_center().z) < 0.01)
	check("real size in metres (%.2f m high)" % aabb.size.y, absf(aabb.size.y - 3.4) < 0.05)
	check("keeps its own materials", mesh != null and mesh.surface_get_material(0) != null and mesh.surface_get_material(1) != null and DetailScatter.layer_material(layer) == null)
	layer.model_keep_origin = true
	check("Keep Model Origin: bottom at %.2f m" % layer.resolved_mesh().get_aabb().position.y, absf(layer.resolved_mesh().get_aabb().position.y + 0.9) < 0.01)
	layer.model_keep_origin = false

	var root := Node3D.new()
	get_root().add_child(root)
	var terrain := TestTerrain.savanna(root)
	var biome: Resource = (terrain.get_meta(Meta.BIOME) as Resource).duplicate()
	var layers: Array = biome.detail_layers.duplicate()
	layers.append(layer)
	biome.detail_layers = layers
	terrain.set_meta(Meta.BIOME, biome)
	var builder := TerrainBuilder.new()
	var huts := _huts(terrain, builder)
	var spacing: float = float(terrain.get_meta(Meta.WORLD_SIZE)) / float(int(terrain.get_meta(Meta.RESOLUTION)) - 1)
	var min_scale := INF
	var max_scale := 0.0
	for h in huts:
		min_scale = minf(min_scale, h.basis.y.length())
		max_scale = maxf(max_scale, h.basis.y.length())
	check("huts grow on the generated map (%d)" % huts.size(), huts.size() >= 20)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var carve := builder.get_river_carve(terrain)
	var gap := 0.0
	for h in huts:
		var g := WaterholeMesher.surface_height(heights, carve, int(terrain.get_meta(Meta.RESOLUTION)), float(terrain.get_meta(Meta.WORLD_SIZE)), Vector2(h.origin.x, h.origin.z))
		gap = maxf(gap, absf(h.origin.y - g))
	check("huts stand on the ground (largest gap %.2f m)" % gap, gap < 0.15)
	check("size in metres, not cells (scale %.2f..%.2f, cell %.2f m)" % [min_scale, max_scale, spacing], huts.size() > 0 and min_scale > 0.6 and max_scale < 1.5)

	# Same layer on a map with 2 m cells: a Model keeps its size in metres,
	# a Mesh (cell units) doubles.
	var on_big_cells: Array = DetailScatter._compile(biome, 1.0, 2.0, 0, 2.0)
	var hut_rule: Variant = on_big_cells.filter(func(r) -> bool: return String(r.layer.name) == "Huts").front()
	var grass_rule: Variant = on_big_cells.filter(func(r) -> bool: return String(r.layer.name) == "Dry Grass").front()
	check("2 m cells: Model size kept (%.2f), built-in mesh x2 (%.2f)" % [hut_rule.scale_min, grass_rule.scale_min / minf(grass_rule.layer.scale_min, grass_rule.layer.scale_max)],
		is_equal_approx(hut_rule.scale_min, 0.9) and is_equal_approx(grass_rule.scale_min / minf(grass_rule.layer.scale_min, grass_rule.layer.scale_max), 2.0))

	# Vegetation brush: a click with "Huts" picked grows huts on bare ground
	# (one per placement block under the 3 m brush, like the built-in props).
	terrain.set_meta(Meta.DETAILS_EVERYWHERE, false)
	terrain.set_meta(Meta.CELL_VEGETATION, {})
	check("bare ground: no hut", _huts(terrain, builder).is_empty())
	var spot := Vector2(-20, 15)
	Brush.apply_vegetation(terrain, ToolMode.Mode.VEGETATION, spot, 3.0, 1.0, "Huts")
	var clicked := _huts(terrain, builder).filter(func(h: Transform3D) -> bool: return Vector2(h.origin.x, h.origin.z).distance_to(spot) <= 3.0)
	check("one click with Huts picked: huts where clicked (%d)" % clicked.size(), clicked.size() >= 1 and clicked.size() <= 4)

	if OS.get_cmdline_user_args().has("--shot"):
		await _shot(root, terrain, builder)
	root.free()
	print("RESULT %s (%d failure(s))" % ["OK" if _failures == 0 else "FAILED", _failures])
	quit(1 if _failures > 0 else 0)

## Eye-height picture of a painted village (real window only).
func _shot(root: Node3D, terrain: Node3D, builder: TerrainBuilder) -> void:
	get_root().size = Vector2i(1280, 720)
	var spot := Vector2(-20, 15)
	for k in 6:
		Brush.apply_vegetation(terrain, ToolMode.Mode.VEGETATION, spot + Vector2.RIGHT.rotated(k * 1.1) * 9.0, 3.0, 1.0, "Huts")
	builder.rebuild_all(terrain)
	var world := WorldEnvironment.new()
	world.environment = load("res://world/savanna_environment.tres")
	root.add_child(world)
	var sun := DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.light_color = Color(1, 0.86, 0.68)
	sun.rotation_degrees = Vector3(-24, -40, 0)
	root.add_child(sun)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var ground := func(p: Vector2) -> float:
		return WaterholeMesher.surface_height(heights, PackedFloat32Array(), int(terrain.get_meta(Meta.RESOLUTION)), float(terrain.get_meta(Meta.WORLD_SIZE)), p)
	var camera := Camera3D.new()
	camera.fov = 75.0
	root.add_child(camera)
	camera.current = true
	var from := spot + Vector2(-16, 10)
	camera.look_at_from_position(Vector3(from.x, ground.call(from) + 1.7, from.y), Vector3(spot.x, ground.call(spot) + 1.0, spot.y))
	for i in 20:
		await RenderingServer.frame_post_draw
	var out := "res://results/custom_model"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	get_root().get_texture().get_image().save_png(out + "/huts.png")
	print("wrote %s/huts.png" % out)
