extends SceneTree
## Rivers never climb hills: their water level only goes down from each end
## (RiverMesher.water_levels) and the channel is cut through higher ground.
## Checked on the generated savanna map with the river of tools/audit_perf.gd
## (it crosses hills), and on a plain slope (carve unchanged there).
## Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_river_level.gd
## With a window, `-- --shot --tag=after` also writes pictures of the deepest
## cut and of the whole river to results/river_level/<tag>_*.png:
##   godot --path . --position -3000,-3000 --script res://tools/check_river_level.gd -- --shot --tag=after

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainSampler = preload(ADDON + "core/terrain_sampler.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _initialize() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var terrain := TestTerrain.savanna(root)
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var points: Array[Vector2] = []
	for i in 9:
		var t := float(i) / 8.0
		points.append(Vector2(lerpf(-0.42, 0.42, t) * size, sin(t * 5.0) * 0.12 * size + 0.18 * size))
	FeatureStyle.commit(terrain, FeatureStyle.RIVER, points)
	# A second river straight over the highest hill of the map (north-south).
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var resolution: int = int(terrain.get_meta(Meta.RESOLUTION))
	var top := 0
	for i in heights.size():
		var gx := i % resolution
		var gz := i / resolution
		if gx > resolution / 5 and gx < resolution * 4 / 5 and gz > resolution / 5 and gz < resolution * 4 / 5 and heights[i] > heights[top]:
			top = i
	var spacing := size / float(resolution - 1)
	var summit := Vector2(float(top % resolution) * spacing - size * 0.5, float(top / resolution) * spacing - size * 0.5)
	var hill_points: Array[Vector2] = []
	for i in 9:
		hill_points.append(summit + Vector2(sin(float(i)) * 2.0, lerpf(-32.0, 32.0, float(i) / 8.0)))
	FeatureStyle.commit(terrain, FeatureStyle.RIVER, hill_points)
	var builder := TerrainBuilder.new()
	builder.rebuild_all(terrain)

	var river: Dictionary = (terrain.get_meta(Meta.RIVERS) as Array)[1]
	var t0 := Time.get_ticks_usec()
	builder.rebuild_river_carve(terrain)
	var t1 := Time.get_ticks_usec()
	builder.rebuild_feature_mesh(terrain)
	print("timing: river carve %.1f ms, road + river mesh %.1f ms" % [(t1 - t0) / 1000.0, (Time.get_ticks_usec() - t1) / 1000.0])
	var line := RiverMesher.water_levels(heights, resolution, size, river["points"])
	var levels: PackedFloat32Array = line["levels"]
	var ground: PackedFloat32Array = line["ground"]
	var dense: Array[Vector2] = line["points"]
	var ends_top := maxf(ground[0], ground[ground.size() - 1])
	var highest := -INF
	var above_ground := 0.0
	var deepest_cut := 0.0
	var deepest_at := 0
	for i in levels.size():
		highest = maxf(highest, levels[i])
		above_ground = maxf(above_ground, levels[i] - ground[i])
		if ground[i] - levels[i] > deepest_cut:
			deepest_cut = ground[i] - levels[i]
			deepest_at = i
	var ground_top := -INF
	for g in ground:
		ground_top = maxf(ground_top, g)
	print("river: %d samples, ground %.2f .. %.2f m along it, ends %.2f / %.2f m, deepest cut %.2f m" % [levels.size(), Array(ground).min(), ground_top, ground[0], ground[ground.size() - 1], deepest_cut])
	check("the river crosses higher ground than its ends (%.2f m above them)" % (ground_top - ends_top), ground_top - ends_top > 1.0)
	check("water never higher than its higher end (%.2f <= %.2f m)" % [highest, ends_top], highest <= ends_top + 0.001)
	check("water never above the ground it runs in (%.3f m)" % above_ground, above_ground < 0.001)

	# Bed under the water all along the centre line, water mesh as low.
	var carve := builder.get_river_carve(terrain)
	var drop: float = float(river.get("surface_drop", Meta.DEFAULT_RIVER_SURFACE_DROP))
	var dry := 0
	for i in dense.size():
		var bed := TerrainSampler.effective_height_in(heights, carve, resolution, size, dense[i])
		if bed > levels[i] - drop - 0.05:
			dry += 1
	check("bed under the water along the whole river (%d dry samples of %d)" % [dry, dense.size()], dry == 0)
	# The first river (a stream running down to a hill end) keeps its slope.
	var first: Dictionary = (terrain.get_meta(Meta.RIVERS) as Array)[0]
	var first_line := RiverMesher.water_levels(heights, resolution, size, first["points"])
	var first_ground: PackedFloat32Array = first_line["ground"]
	var first_levels: PackedFloat32Array = first_line["levels"]
	var first_end := first_levels.size() - 1
	check("a river running down from a hill keeps its slope (end level %.2f m = ground %.2f m)" % [first_levels[first_end], first_ground[first_end]],
		absf(first_levels[first_end] - first_ground[first_end]) < 0.001 and absf(first_levels[0] - first_ground[0]) < 0.001)
	# Water mesh near the summit: not higher than the river's higher end.
	var water_top := -INF
	var mesh := (terrain.get_node(Meta.GENERATED_MESH_NAME) as MeshInstance3D).mesh
	for s in mesh.get_surface_count():
		# Water surfaces only (the feature mesh also holds the roads).
		var material := mesh.surface_get_material(s) as ShaderMaterial
		if material == null or not material.shader.resource_path.contains("river_water"):
			continue
		for v: Vector3 in mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]:
			if Vector2(v.x, v.z).distance_to(summit) < 12.0 and _distance_to_line(Vector2(v.x, v.z), first["points"]) > 8.0:
				water_top = maxf(water_top, v.y)
	check("water over the hill top at %.2f m <= higher end %.2f m (hill %.2f m)" % [water_top, ends_top, ground_top], water_top <= ends_top + 0.01)

	_check_plain_slope(root)

	if OS.get_cmdline_user_args().has("--shot"):
		await _shot(root, terrain, builder, dense[deepest_at], dense[mini(deepest_at + 4, dense.size() - 1)] - dense[maxi(deepest_at - 4, 0)])
	root.free()
	print("RESULT %s (%d failure(s))" % ["OK" if _failures == 0 else "FAILED", _failures])
	quit(1 if _failures > 0 else 0)

static func _distance_to_line(p: Vector2, line: Array) -> float:
	var best := INF
	for i in line.size() - 1:
		best = minf(best, Geometry2D.get_closest_point_to_segment(p, line[i], line[i + 1]).distance_to(p))
	return best

## On ground that only goes down along the river and is flat across it, the
## channel is the same as before water levels existed: Depth x smooth falloff.
func _check_plain_slope(root: Node3D) -> void:
	var terrain := Node3D.new()
	root.add_child(terrain)
	TerrainData.initialize(terrain)
	var resolution: int = int(terrain.get_meta(Meta.RESOLUTION))
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var spacing := size / float(resolution - 1)
	for z in resolution:
		for x in resolution:
			heights[z * resolution + x] = 3.0 - float(x) * spacing * 0.05
	terrain.set_meta(Meta.HEIGHTS, heights)
	var a := Vector2(-size * 0.35, 0.3)
	var b := Vector2(size * 0.35, -0.4)
	FeatureStyle.commit(terrain, FeatureStyle.RIVER, [a, b])
	var river: Dictionary = (terrain.get_meta(Meta.RIVERS) as Array)[0]
	var radius: float = float(river["width"]) * 0.62
	var depth: float = float(river["depth"])
	var carve := RiverMesher.compute_carve(terrain)
	var gap := 0.0
	var carved := 0
	for z in resolution:
		for x in resolution:
			var p := Vector2(float(x) * spacing - size * 0.5, float(z) * spacing - size * 0.5)
			var along := (p - a).dot(b - a) / (b - a).length_squared()
			if along < 0.0 or along > 1.0:
				continue # round ends: the upstream one is now cut into the rising ground
			var d := Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p)
			var expected := depth * smoothstep(0.0, 1.0, 1.0 - clampf(d / radius, 0.0, 1.0)) if d < radius else 0.0
			gap = maxf(gap, absf(carve[z * resolution + x] - expected))
			if expected > 0.0:
				carved += 1
	check("plain slope: channel as before (%d vertices, largest gap %.4f m)" % [carved, gap], carved > 0 and gap < 0.005)
	terrain.free()

## Eye-height picture of the deepest cut, and the river from above (real window only).
func _shot(root: Node3D, terrain: Node3D, builder: TerrainBuilder, spot: Vector2, along: Vector2) -> void:
	get_root().size = Vector2i(1280, 720)
	var tag := "shot"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--tag="):
			tag = arg.substr(6)
	var sky := (load("res://world/savanna_sky.tscn") as PackedScene).instantiate()
	root.add_child(sky)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var resolution: int = int(terrain.get_meta(Meta.RESOLUTION))
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var ground := func(p: Vector2) -> float:
		return TerrainSampler.uncarved_height_in(heights, resolution, size, p)
	var camera := Camera3D.new()
	camera.fov = 70.0
	camera.far = 800.0
	root.add_child(camera)
	camera.current = true
	var out := "res://results/river_level"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(out))
	var side := along.normalized().orthogonal()
	var views := {
		"cut": [spot - along.normalized() * 14.0 + side * 5.0, 6.0, spot, 0.0],
		"side": [spot + side * 22.0, 7.0, spot, 0.0],
		"overview": [Vector2(0, size * 0.18) + Vector2(0, -size * 0.45), 55.0, Vector2(0, size * 0.18), 0.0],
	}
	for view_name in views:
		var v: Array = views[view_name]
		var from: Vector2 = v[0]
		var target: Vector2 = v[2]
		camera.look_at_from_position(Vector3(from.x, ground.call(from) + float(v[1]), from.y), Vector3(target.x, ground.call(target) + float(v[3]), target.y))
		for i in 12:
			await RenderingServer.frame_post_draw
		get_root().get_texture().get_image().save_png("%s/%s_%s.png" % [out, tag, view_name])
	print("wrote %s/%s_*.png" % [out, tag])
