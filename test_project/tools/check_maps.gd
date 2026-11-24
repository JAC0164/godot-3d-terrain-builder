extends SceneTree
## Checks of the phase-4 game tools: map recipes + MapGenerator, detail seed,
## tree collision (mesh/detail_collision.gd), runtime build modes and
## LowpolyTerrainRuntime. Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_maps.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const DetailCollision = preload(ADDON + "mesh/detail_collision.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const WaterholeStyle = preload(ADDON + "styles/waterhole_style.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const SAVANNA_MAP := ADDON + "generation/presets/senegal_savanna_map.tres"
const ISLAND_MAP := ADDON + "generation/presets/temperate_island_map.tres"
const OPEN_WORLD_MAP := ADDON + "generation/presets/senegal_savanna_open_world_map.tres"
const TerrainSampler = preload(ADDON + "core/terrain_sampler.gd")
const GridMath = preload(ADDON + "core/grid_math.gd")

var _failures := 0

func _check(ok: bool, label: String) -> void:
	print("%s  %s" % ["OK  " if ok else "FAIL", label])
	if not ok:
		_failures += 1

func _new_terrain(parent: Node, owner_node: Node = null) -> Node3D:
	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	parent.add_child(terrain)
	if owner_node:
		terrain.owner = owner_node
	TerrainData.initialize(terrain)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = Meta.GENERATED_MESH_NAME
	terrain.add_child(mesh_instance)
	if owner_node:
		mesh_instance.owner = owner_node
	return terrain

func _data(terrain: Node3D) -> Array:
	return [terrain.get_meta(Meta.HEIGHTS), terrain.get_meta(Meta.CELL_STYLES), terrain.get_meta(Meta.CELL_ACTIVE),
		terrain.get_meta(Meta.ROADS), terrain.get_meta(Meta.WATERHOLES)]

func _instances(terrain: Node3D, part: String) -> PackedVector3Array:
	var points := PackedVector3Array()
	for node in terrain.find_children("_Details*", "MultiMeshInstance3D", true, false):
		if not String(node.name).contains(part):
			continue
		var buffer: PackedFloat32Array = (node as MultiMeshInstance3D).multimesh.buffer
		var chunk_origin: Vector3 = (node.get_parent() as Node3D).position
		for i in range(0, buffer.size(), 16):
			points.append(chunk_origin + Vector3(buffer[i + 3], buffer[i + 7], buffer[i + 11]))
	return points

func _count_collision_instances(terrain: Node3D) -> int:
	var biome: Resource = DetailScatter.biome_of(terrain)
	var total := 0
	for node in terrain.find_children("_Details*", "MultiMeshInstance3D", true, false):
		var index := int(String(node.name).substr(DetailScatter.NODE_PREFIX.length() + 1).get_slice("_", 0))
		var layer: Resource = biome.detail_layers[index - 1]
		if layer.collision_radius > 0.0:
			total += (node as MultiMeshInstance3D).multimesh.instance_count
	return total

func _initialize() -> void:
	_run.call_deferred()

## Phase 4 of the open-world plan: the open-world preset (1 024 cells, border
## hills, rivers, track network) is deterministic and its features are
## where they should be.
func _check_open_world(stage: Node3D) -> void:
	var recipe: Resource = load(OPEN_WORLD_MAP)
	var a := _new_terrain(stage)
	var b := _new_terrain(stage)
	var stats := MapGenerator.generate(a, recipe, 7)
	MapGenerator.generate(b, recipe, 7)
	print("      open world %d cells generated in %.0f ms: %s" % [stats["size"], stats["ms"], stats])
	_check(_data(a) == _data(b) and a.get_meta(Meta.RIVERS) == b.get_meta(Meta.RIVERS), "open world: same seed, same map (rivers too)")
	var half: float = float(a.get_meta(Meta.WORLD_SIZE)) * 0.5
	var cell: float = recipe.cell_size
	var border_height: float = recipe.border_height

	# Rivers: the first from edge to edge, the others from an edge into the
	# first; a valley through the border hills where each leaves the map.
	var rivers: Array = a.get_meta(Meta.RIVERS)
	var ends_out := 0
	var ends_low := 0
	var joined := 0
	var main_points: Array = (rivers[0] as Dictionary)["points"] if not rivers.is_empty() else []
	for r in range(rivers.size()):
		var points: Array = (rivers[r] as Dictionary)["points"]
		for end: Vector2 in [points[0], points[points.size() - 1]]:
			if maxf(absf(end.x), absf(end.y)) < half - 2.0 * cell:
				if r > 0 and GridMath.distance_to_polyline(end, main_points) < 12.0 * cell:
					joined += 1
				continue
			ends_out += 1
			# Just inside the border: the valley, not the hill top.
			var inside := end - end.normalized() * 10.0 * cell
			if TerrainSampler.uncarved_height(a, inside) < border_height * 0.4:
				ends_low += 1
	_check(rivers.size() == int(recipe.river_count) and ends_out == rivers.size() + 1 and joined == rivers.size() - 1,
		"open world: %d rivers, the first from edge to edge, %d tributaries joining it (%d ends out)" % [rivers.size(), joined, ends_out])
	_check(ends_low == ends_out, "open world: a valley through the border where each river leaves (%d of %d low)" % [ends_low, ends_out])

	# Border: high at the edge, away from the rivers; the plain stays low.
	var edge_sum := 0.0
	var edge_count := 0
	var middle_sum := 0.0
	var middle_count := 0
	for k in range(64):
		var along := -half + (float(k) + 0.5) * half * 2.0 / 64.0
		for point: Vector2 in [Vector2(along, -half + cell), Vector2(along, half - cell), Vector2(-half + cell, along), Vector2(half - cell, along)]:
			edge_sum += TerrainSampler.uncarved_height(a, point)
			edge_count += 1
		middle_sum += TerrainSampler.uncarved_height(a, Vector2(along * 0.5, along * 0.3))
		middle_count += 1
	var edge_mean := edge_sum / edge_count
	var middle_mean := middle_sum / middle_count
	_check(edge_mean > border_height * 0.6 and middle_mean < border_height * 0.3, "open world: border hills (edge %.1f m, plain %.1f m)" % [edge_mean, middle_mean])

	# Waterholes off the border; the network reaches the stops.
	var holes: Array = a.get_meta(Meta.WATERHOLES)
	var roads: Array = a.get_meta(Meta.ROADS)
	var on_border := 0
	var served := 0
	for hole: Dictionary in holes:
		var centre: Vector2 = hole["center"]
		var radius: float = hole["radius"]
		if TerrainSampler.uncarved_height(a, centre) > border_height * 0.4:
			on_border += 1
		for road: Dictionary in roads:
			var points: Array = road["points"]
			var first: Vector2 = points[0]
			var last: Vector2 = points[points.size() - 1]
			if minf(first.distance_to(centre), last.distance_to(centre)) < radius * 1.6 + 3.0 * cell:
				served += 1
				break
	var stops := mini(int(recipe.track_network_stops), holes.size())
	_check(on_border == 0, "open world: no waterhole on the border (%d holes)" % holes.size())
	_check(roads.size() >= stops and served >= stops, "open world: track network, %d tracks, %d waterholes reached (stops %d)" % [roads.size(), served, stops])

	# Tracks go round the plateaus (inside the border).
	var track_points := 0
	var high := 0
	for road: Dictionary in roads:
		for point: Vector2 in road["points"]:
			if maxf(absf(point.x), absf(point.y)) > half - float(recipe.border_width) * cell * 1.6:
				continue
			track_points += 1
			if TerrainSampler.uncarved_height(a, point) > float(recipe.plateau_height) * 0.7:
				high += 1
	_check(track_points > 0 and float(high) / float(track_points) < 0.05, "open world: tracks stay off the plateaus (%d of %d points high)" % [high, track_points])
	a.free()
	b.free()

func _run() -> void:
	var savanna_recipe: Resource = load(SAVANNA_MAP)
	var island_recipe: Resource = load(ISLAND_MAP)
	_check(savanna_recipe != null and savanna_recipe.biome != null, "savanna map recipe loads with its biome")
	var stage := Node3D.new()
	get_root().add_child(stage)

	# --- Determinism + coverage -------------------------------------------
	var a := _new_terrain(stage)
	var b := _new_terrain(stage)
	var stats_a := MapGenerator.generate(a, savanna_recipe, 42)
	MapGenerator.generate(b, savanna_recipe, 42)
	_check(_data(a) == _data(b), "same recipe + seed = same map")
	MapGenerator.generate(b, savanna_recipe, 43)
	_check(_data(a)[0] != _data(b)[0], "another seed = another map")
	var n: int = savanna_recipe.size
	print("      savanna %dx%d generated in %.1f ms: %s" % [n, n, stats_a["ms"], stats_a])
	_check(a.get_meta(Meta.RESOLUTION) == n + 1 and is_equal_approx(float(a.get_meta(Meta.WORLD_SIZE)), n * savanna_recipe.cell_size), "grid size from the recipe")
	var plateau_share := float(stats_a["plateau_cells"]) / float(n * n)
	_check(absf(plateau_share - savanna_recipe.plateau_coverage) < 0.03, "plateau coverage %.3f ~ %.2f" % [plateau_share, savanna_recipe.plateau_coverage])
	var lowland_share := float(stats_a["lowland_cells"]) / float(n * n)
	_check(absf(lowland_share - savanna_recipe.lowland_coverage) < 0.04, "lowland coverage %.3f ~ %.2f" % [lowland_share, savanna_recipe.lowland_coverage])
	_check(int(stats_a["tracks"]) >= 1, "tracks generated (%d)" % stats_a["tracks"])
	_check(int(stats_a["waterholes"]) >= 2, "waterholes generated (%d)" % stats_a["waterholes"])
	var palette: Array = a.get_meta(Meta.STYLE_PALETTE)
	var used: Dictionary = {}
	for style_id in (a.get_meta(Meta.CELL_STYLES) as PackedInt32Array):
		used[style_id] = true
	_check(used.size() >= 5, "map uses %d ground styles (palette %d)" % [used.size(), palette.size()])
	_check(a.get_meta(Meta.BIOME) == savanna_recipe.biome and int(a.get_meta(Meta.DETAIL_SEED)) == 42, "biome + detail seed written")
	var heights: PackedFloat32Array = a.get_meta(Meta.HEIGHTS)
	var spacing := float(a.get_meta(Meta.WORLD_SIZE)) / float(n)
	var on_plateau := 0
	for hole in WaterholeStyle.list(a):
		var c: Vector2 = hole["center"]
		var gx := clampi(roundi((c.x + n * spacing * 0.5) / spacing), 0, n)
		var gz := clampi(roundi((c.y + n * spacing * 0.5) / spacing), 0, n)
		# Plain relief stays within +/-0.25, plateaus are 2.2 high.
		if heights[gz * (n + 1) + gx] > savanna_recipe.plateau_height * 0.4:
			on_plateau += 1
	_check(on_plateau == 0, "no waterhole centre on a plateau")

	var island := _new_terrain(stage)
	var island_stats := MapGenerator.generate(island, island_recipe, 7)
	var active: PackedByteArray = island.get_meta(Meta.CELL_ACTIVE)
	var inactive := active.count(0)
	var island_n: int = island_recipe.size
	_check(inactive > island_n * island_n / 5 and active[0] == 0 and active[(island_n / 2) * island_n + island_n / 2] == 1, "island outline: %d empty cells, corner empty, centre ground" % inactive)
	print("      island %dx%d generated in %.1f ms" % [island_n, island_n, island_stats["ms"]])

	_check_open_world(stage)

	# --- Build + detail seed ----------------------------------------------
	var builder := TerrainBuilder.new()
	var t0 := Time.get_ticks_usec()
	builder.rebuild_all(a)
	print("      savanna build (meshes + details + waterholes) %.0f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	var chunk_count := TerrainMesher.chunk_count(a)
	_check(a.get_node(Meta.GENERATED_CHUNKS_NAME).get_child_count() == chunk_count * chunk_count, "%d chunks built" % (chunk_count * chunk_count))
	var acacias := _instances(a, "Acacias")
	_check(acacias.size() > 20, "acacias scattered (%d)" % acacias.size())
	a.set_meta(Meta.DETAIL_SEED, 1042)
	builder.rebuild_all_details(a)
	var acacias_other := _instances(a, "Acacias")
	_check(acacias_other != acacias and acacias_other.size() > 20, "another detail seed moves the trees (%d)" % acacias_other.size())
	a.set_meta(Meta.DETAIL_SEED, 42)
	builder.rebuild_all_details(a)
	_check(_instances(a, "Acacias") == acacias, "detail seed back = same trees")

	# --- Tree collision ---------------------------------------------------
	t0 = Time.get_ticks_usec()
	var shapes := DetailCollision.build_all(a)
	var collision_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var expected := _count_collision_instances(a)
	_check(shapes == expected and shapes > 0, "one collision cylinder per tree / mound (%d of %d) in %.1f ms" % [shapes, expected, collision_ms])
	_check(DetailCollision.count_shapes(a) == shapes, "shape owners counted back")
	var shared: Dictionary = {}
	for body in a.find_children(Meta.DETAIL_COLLISION_NAME, "StaticBody3D", true, false):
		for owner_id in body.get_shape_owners():
			shared[body.shape_owner_get_shape(owner_id, 0)] = true
	print("      %d shapes share %d CylinderShape3D resources" % [shapes, shared.size()])
	_check(shared.size() < shapes, "cylinder shapes are shared")
	await physics_frame
	await physics_frame
	var space := (a.get_world_3d() as World3D).direct_space_state
	var baobabs := _instances(a, "Baobabs")
	var tree: Vector3 = baobabs[0] if not baobabs.is_empty() else acacias[0]
	var from := a.to_global(tree + Vector3(-6.0, 0.6, 0.0))
	var to := a.to_global(tree + Vector3(6.0, 0.6, 0.0))
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var ground_body := a.get_node_or_null(Meta.GENERATED_COLLISION_BODY_NAME) as CollisionObject3D
	if ground_body:
		query.exclude = [ground_body.get_rid()]
	var hit := space.intersect_ray(query)
	_check(not hit.is_empty() and hit["collider"].name == Meta.DETAIL_COLLISION_NAME, "a horizontal ray hits the %s trunk" % ("baobab" if not baobabs.is_empty() else "acacia"))
	var grass_free := space.intersect_ray(PhysicsRayQueryParameters3D.create(a.to_global(Vector3(0, 50, 0)), a.to_global(Vector3(0, 49, 0))))
	_check(grass_free.is_empty(), "no collision in the open sky")
	a.queue_free()
	b.queue_free()
	island.queue_free()

	# --- Runtime build modes: saved scene size ----------------------------
	var sizes: Dictionary = {}
	for mode in [Meta.RUNTIME_BUILD_NOTHING, Meta.RUNTIME_BUILD_DETAILS, Meta.RUNTIME_BUILD_ALL]:
		var scene_root := Node3D.new()
		scene_root.name = "Level"
		get_root().add_child(scene_root)
		var terrain := _new_terrain(scene_root, scene_root)
		MapGenerator.generate(terrain, savanna_recipe, 42)
		terrain.set_meta(Meta.RUNTIME_BUILD, mode)
		var owned_builder := TerrainBuilder.new()
		owned_builder.owner_provider = func() -> Node: return scene_root
		owned_builder.rebuild_all(terrain)
		var runtime := TerrainRuntime.new()
		runtime.name = Meta.RUNTIME_NODE_NAME
		terrain.add_child(runtime)
		runtime.owner = scene_root
		var packed := PackedScene.new()
		packed.pack(scene_root)
		var path := "user://check_maps_mode_%d.tscn" % mode
		ResourceSaver.save(packed, path)
		sizes[mode] = FileAccess.get_file_as_bytes(path).size()
		scene_root.queue_free()
	print("      saved .tscn: all %.1f MB | details at runtime %.1f MB | everything at runtime %.1f MB" % [
		sizes[0] / 1048576.0, sizes[1] / 1048576.0, sizes[2] / 1048576.0])
	_check(sizes[1] < sizes[0] and sizes[2] < sizes[1], "runtime build modes shrink the scene file")
	await process_frame

	# --- LowpolyTerrainRuntime: load the smallest scene and build it ------
	for mode in [Meta.RUNTIME_BUILD_DETAILS, Meta.RUNTIME_BUILD_ALL]:
		var level: Node = (load("user://check_maps_mode_%d.tscn" % mode) as PackedScene).instantiate()
		var terrain: Node3D = level.get_node("LowpolyTerrain")
		_check(terrain.find_children("_Details*", "", true, false).is_empty(), "mode %d: no detail node in the saved scene" % mode)
		_check((terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME) == null) == (mode == Meta.RUNTIME_BUILD_ALL), "mode %d: chunk meshes saved = %s" % [mode, mode != Meta.RUNTIME_BUILD_ALL])
		var runtime: Node = terrain.get_node(Meta.RUNTIME_NODE_NAME)
		runtime.frame_budget_ms = 4.0
		var events: Array[String] = []
		runtime.terrain_ready.connect(func() -> void: events.append("ready"))
		runtime.finished.connect(func(stats: Dictionary) -> void: events.append("finished %s" % stats))
		var started := Time.get_ticks_usec()
		get_root().add_child(level)
		var frames := 0
		var worst := 0.0
		while not runtime.is_finished and frames < 2000:
			var frame_start := Time.get_ticks_usec()
			await process_frame
			worst = maxf(worst, (Time.get_ticks_usec() - frame_start) / 1000.0)
			frames += 1
		var total_ms := (Time.get_ticks_usec() - started) / 1000.0
		_check(runtime.is_finished, "mode %d: runtime finished in %d frames, %.0f ms (worst frame %.1f ms)" % [mode, frames, total_ms, worst])
		_check(events.size() == 2 and events[0] == "ready", "mode %d: terrain_ready then finished" % mode)
		_check(not _instances(terrain, "Acacias").is_empty() and DetailCollision.count_shapes(terrain) > 0, "mode %d: trees + tree collision built in game" % mode)
		if mode == Meta.RUNTIME_BUILD_ALL:
			var body := terrain.get_node_or_null(TerrainRuntime.GROUND_COLLISION_NAME) as StaticBody3D
			_check(terrain.get_node(Meta.GENERATED_CHUNKS_NAME).get_child_count() > 0, "mode 2: chunk meshes rebuilt")
			_check(body != null and body.get_shape_owners().size() == TerrainMesher.chunk_count(terrain) ** 2 + 1, "mode 2: ground collision rebuilt per chunk (%d shapes)" % (body.get_shape_owners().size() if body else 0))
			await physics_frame
			await physics_frame
			var ground_hit := terrain.get_world_3d().direct_space_state.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(3.3, 60, -7.7), Vector3(3.3, -60, -7.7)))
			_check(not ground_hit.is_empty(), "mode 2: a falling ray lands on the ground")
		print("      %s" % ", ".join(events))
		level.queue_free()
		await process_frame

	# --- Runtime map generation from a seed (no saved map) ----------------
	var game := Node3D.new()
	get_root().add_child(game)
	var empty := Node3D.new()
	empty.name = "LowpolyTerrain"
	var gen_runtime := TerrainRuntime.new()
	gen_runtime.generate_map = true
	gen_runtime.recipe = savanna_recipe
	gen_runtime.map_seed = 99
	gen_runtime.frame_budget_ms = 6.0
	empty.add_child(gen_runtime)
	game.add_child(empty)
	var gen_frames := 0
	var gen_started := Time.get_ticks_usec()
	while not gen_runtime.is_finished and gen_frames < 3000:
		await process_frame
		gen_frames += 1
	_check(gen_runtime.is_finished and Meta.is_terrain(empty) and gen_runtime.used_seed == 99, "runtime generates seed 99 from nothing (%d frames, %.0f ms)" % [gen_frames, (Time.get_ticks_usec() - gen_started) / 1000.0])
	var reference := _new_terrain(stage)
	MapGenerator.generate(reference, savanna_recipe, 99)
	_check(_data(reference) == _data(empty), "runtime map = editor map for the same seed")
	_check(empty.get_node(Meta.GENERATED_CHUNKS_NAME).get_child_count() == TerrainMesher.chunk_count(empty) * TerrainMesher.chunk_count(empty), "runtime built every chunk")
	var level_before := _data(empty)
	gen_runtime.build(100)
	while not gen_runtime.is_finished:
		await process_frame
	_check(_data(empty) != level_before and gen_runtime.used_seed == 100, "build(seed) regenerates a new level")

	print("RESULT %s (%d failure(s))" % ["OK" if _failures == 0 else "FAILED", _failures])
	quit(1 if _failures > 0 else 0)
