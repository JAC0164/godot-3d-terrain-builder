extends SceneTree
## The game-side example world/navigation_follow.gd (docs: Navigation):
## - first bake once the ground is ready, around the target only;
## - no new bake while the target stays within rebake_distance;
## - a new bake, centred on it, once it moves farther;
## - a new bake after an edit in game (terrain_changed).
## Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_navigation_follow.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainNavigation = preload(ADDON + "navigation/terrain_navigation.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const NavigationFollow = preload("res://world/navigation_follow.gd")

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _initialize() -> void:
	_run.call_deferred()

func _polygon_span(t: Node3D) -> Rect2:
	var region := t.get_node(TerrainNavigation.REGION_NAME) as NavigationRegion3D
	var mesh := region.navigation_mesh
	var vertices := mesh.get_vertices()
	var span := Rect2(Vector2(vertices[0].x, vertices[0].z), Vector2.ZERO)
	for v in vertices:
		span = span.expand(Vector2(v.x, v.z))
	return span

func _run() -> void:
	var root3d := Node3D.new()
	root3d.name = "Root"
	root.add_child(root3d)
	var t := TestTerrain.savanna(root3d)
	TerrainBuilder.new().rebuild_all(t)
	var runtime := LowpolyTerrainRuntime.new()
	runtime.name = "Runtime"
	runtime.build_on_ready = false
	t.add_child(runtime)
	runtime.is_ground_ready = true
	var player := Node3D.new()
	player.name = "Player"
	root3d.add_child(player)
	player.global_position = t.to_global(Vector3(-20.0, 0.0, -20.0))
	var follow := NavigationFollow.new()
	follow.name = "NavigationFollow"
	follow.runtime = runtime
	follow.target = player
	follow.radius = 15.0
	follow.rebake_distance = 10.0
	var bakes: Array[Vector3] = []
	follow.baked.connect(func(centre: Vector3) -> void: bakes.append(centre))
	root3d.add_child(follow)

	var wait := func(count: int) -> void:
		for i in 600:
			if bakes.size() >= count:
				break
			await process_frame
	await wait.call(1)
	var span := _polygon_span(t)
	check("first bake around the target (%d bake, x %.0f..%.0f z %.0f..%.0f)" % [bakes.size(), span.position.x, span.end.x, span.position.y, span.end.y],
		bakes.size() == 1 and span.position.x > -37.0 and span.end.x < -3.0 and span.position.y > -37.0 and span.end.y < -3.0)

	player.global_position = t.to_global(Vector3(-14.0, 0.0, -20.0))
	for i in 30:
		await process_frame
	check("no bake within rebake_distance (%d bake)" % bakes.size(), bakes.size() == 1)

	player.global_position = t.to_global(Vector3(10.0, 0.0, 5.0))
	await wait.call(2)
	span = _polygon_span(t)
	check("moved away: a new bake around it (%d bakes, x %.0f..%.0f)" % [bakes.size(), span.position.x, span.end.x],
		bakes.size() == 2 and span.position.x > -7.0 and span.end.x < 27.0)

	runtime.raise_area(player.global_position, 3.0, 1.0)
	runtime.commit_edits()
	await wait.call(3)
	check("ground edited: baked again (%d bakes)" % bakes.size(), bakes.size() == 3)

	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)
