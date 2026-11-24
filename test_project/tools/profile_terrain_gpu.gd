extends SceneTree
## What the TERRAIN costs the GPU, piece by piece, on the explore map (seed 7
## + one river, everything built, game sky of world/savanna_sky.tscn):
## the same 5 views (4 at eye height, 1 overview) measured with parts of the
## terrain hidden or changed, without rebuilding anything:
##   sky only       terrain hidden (what the game costs without the plugin)
##   ground only    every detail layer hidden
##   full           everything
##   - <layer>      full without that detail layer (its cost = full - this)
##   no detail shadows / no ground shadows / ground lite (no specular,
##   Lambert) / details lite (wind materials as Lambert)...
## Each variant is measured twice, in A..Z then Z..A order (drift and noise
## of this laptop: compare the two passes).
##   godot --path . --position -3000,-3000 --script res://tools/profile_terrain_gpu.gd [-- --size=1920x1080 --frames=90]

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

var _terrain: Node3D
var _camera: Camera3D
var _frames := 90
## --shots: views 0 and 4 of every variant saved as user://terrain_gpu_*.png.
var _shots := false
## Hooks that undo the current variant.
var _undo: Array[Callable] = []

func _initialize() -> void:
	var size := Vector2i(1920, 1080)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--size="):
			var parts := arg.substr(7).split("x")
			size = Vector2i(int(parts[0]), int(parts[1]))
		elif arg == "--shots":
			_shots = true
		elif arg.begins_with("--frames="):
			_frames = int(arg.substr(9))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(size)
	get_root().size = size
	await process_frame
	var root := Node3D.new()
	get_root().add_child(root)
	_terrain = Node3D.new()
	_terrain.name = "LowpolyTerrain"
	root.add_child(_terrain)
	TerrainData.initialize(_terrain)
	MapGenerator.generate(_terrain, load(RECIPE), 7)
	var world: float = float(_terrain.get_meta(Meta.WORLD_SIZE))
	var points: Array[Vector2] = []
	for i in 9:
		var t := float(i) / 8.0
		points.append(Vector2(lerpf(-0.42, 0.42, t) * world, sin(t * 5.0) * 0.12 * world + 0.18 * world))
	FeatureStyle.commit(_terrain, FeatureStyle.RIVER, points)
	_terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	root.add_child((load("res://world/savanna_sky.tscn") as PackedScene).instantiate())
	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.far = 800.0
	root.add_child(_camera)
	_camera.current = true
	var runtime := TerrainRuntime.new()
	# Every detail at load (as the earlier measures; on by default since 2026-11-24).
	runtime.stream_details = false
	runtime.build_on_ready = false
	runtime.progressive = false
	runtime.detail_collision = false
	_terrain.add_child(runtime)
	runtime.build()
	RenderingServer.viewport_set_measure_render_time(get_root().get_viewport_rid(), true)
	for i in 30:
		await process_frame

	var views: Array = []
	for k in 4:
		var dir := Vector2.RIGHT.rotated(TAU * float(k) / 4.0 + 0.4)
		var from := -dir * 6.0
		views.append([from, 1.7, from + dir * 30.0, 0.9])
	views.append([Vector2(-world * 0.35, world * 0.35), 45.0, Vector2.ZERO, 0.0])

	var layers := _layer_names()
	var variants: Array = [
		["sky only", func() -> void: _hide(_terrain)],
		["ground only", func() -> void: _hide_details(func(_n: String) -> bool: return true)],
		["full", func() -> void: pass],
	]
	for layer_name: String in layers:
		variants.append(["- " + layer_name, func() -> void: _hide_details(func(n: String) -> bool: return n == layer_name)])
	variants.append(["no detail shadows", func() -> void: _detail_shadows_off()])
	variants.append(["no ground shadows", func() -> void: _ground_shadows_off()])
	variants.append(["ground lite", func() -> void: _ground_lite()])
	variants.append(["ground per vertex", func() -> void: _ground_per_vertex()])
	variants.append(["ground burley", func() -> void: _ground_burley()])
	variants.append(["front face shadows", func() -> void: _front_face_shadows()])
	variants.append(["no sun shadows", func() -> void: _sun_shadows_off()])

	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--ab="):
			await _ab(variants, arg.substr(5).split(","), views)
			quit()
			return
	print("size %dx%d, %d frames per view, %d views, %s" % [size.x, size.y, _frames, views.size(), RenderingServer.get_video_adapter_name()])
	print("triangles full view 0: measured below")
	var results := {}
	for pass_index in 2:
		var order := variants.duplicate()
		if pass_index == 1:
			order.reverse()
		for variant: Array in order:
			(variant[1] as Callable).call()
			var gpu := 0.0
			var tris := 0.0
			for v: Array in views:
				var m := await _measure(v)
				if _shots and pass_index == 0 and (v == views[0] or v == views[4]):
					await RenderingServer.frame_post_draw
					var file := "user://terrain_gpu_%s_%d.png" % [String(variant[0]).replace(" ", "_").replace("-_", "no_"), views.find(v)]
					get_root().get_texture().get_image().save_png(file)
				gpu += m[0]
				tris += m[1]
			_restore()
			var name: String = variant[0]
			if not results.has(name):
				results[name] = []
			results[name].append([gpu / views.size(), tris / views.size()])
	var full_ms: float = (results["full"][0][0] + results["full"][1][0]) * 0.5
	var sky_ms: float = (results["sky only"][0][0] + results["sky only"][1][0]) * 0.5
	print("")
	print("%-22s %8s %8s %8s %9s %8s" % ["variant", "pass 1", "pass 2", "mean", "vs full", "ktris"])
	for variant: Array in variants:
		var r: Array = results[variant[0]]
		var mean: float = (r[0][0] + r[1][0]) * 0.5
		print("%-22s %8.2f %8.2f %8.2f %+9.2f %8.0f" % [variant[0], r[0][0], r[1][0], mean, mean - full_ms, r[0][1] / 1000.0])
	print("")
	print("terrain cost (full - sky only): %.2f ms GPU of %.2f ms" % [full_ms - sky_ms, full_ms])
	quit()

## --ab=name,name: full and each named variant in turn, 8 rounds, all views;
## prints each variant's median difference to full (the round's own full).
func _ab(variants: Array, names: PackedStringArray, views: Array) -> void:
	var diffs := {}
	for round_index in 8:
		var full := 0.0
		for v: Array in views:
			full += (await _measure(v))[0]
		for variant: Array in variants:
			if not names.has(String(variant[0])):
				continue
			(variant[1] as Callable).call()
			var gpu := 0.0
			for v: Array in views:
				gpu += (await _measure(v))[0]
			_restore()
			if not diffs.has(variant[0]):
				diffs[variant[0]] = []
			diffs[variant[0]].append((gpu - full) / views.size())
	for name in diffs:
		var d: Array = diffs[name]
		d.sort()
		print("A/B %-20s median %+.2f ms (rounds: %s)" % [name, (d[3] + d[4]) * 0.5, ", ".join(d.map(func(x: float) -> String: return "%+.2f" % x))])

## [gpu ms, triangles] of one view.
func _measure(v: Array) -> Array:
	var from: Vector2 = v[0]
	var to: Vector2 = v[2]
	_camera.look_at_from_position(Vector3(from.x, _ground(from) + float(v[1]), from.y), Vector3(to.x, _ground(to) + float(v[3]), to.y))
	for i in 20:
		await process_frame
	var vp := get_root().get_viewport_rid()
	var gpu := 0.0
	for i in _frames:
		await process_frame
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
	return [gpu / _frames, Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)]

func _ground(p: Vector2) -> float:
	return WaterholeMesher.surface_height(_terrain.get_meta(Meta.HEIGHTS), PackedFloat32Array(), int(_terrain.get_meta(Meta.RESOLUTION)), float(_terrain.get_meta(Meta.WORLD_SIZE)), p)

func _layer_names() -> Array[String]:
	var names: Array[String] = []
	for chunk in _chunks():
		for child in chunk.get_children():
			var n := String(child.name)
			if n.begins_with(DetailScatter.NODE_PREFIX) and not names.has(n.get_slice("_", 3)):
				names.append(n.get_slice("_", 3))
	return names

func _chunks() -> Array[Node]:
	return _terrain.get_node(String(Meta.GENERATED_CHUNKS_NAME)).get_children()

func _details() -> Array[MultiMeshInstance3D]:
	var nodes: Array[MultiMeshInstance3D] = []
	for chunk in _chunks():
		for child in chunk.get_children():
			if child is MultiMeshInstance3D and String(child.name).begins_with(DetailScatter.NODE_PREFIX):
				nodes.append(child)
	return nodes

func _hide(node: Node3D) -> void:
	node.visible = false
	_undo.append(func() -> void: node.visible = true)

func _hide_details(which: Callable) -> void:
	for node in _details():
		if which.call(String(node.name).get_slice("_", 3)):
			_hide(node)

func _detail_shadows_off() -> void:
	for node in _details():
		var before := node.cast_shadow
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_undo.append(func() -> void: node.cast_shadow = before)

func _ground_meshes() -> Array[MeshInstance3D]:
	var meshes: Array[MeshInstance3D] = []
	for node in _terrain.find_children("*", "MeshInstance3D", true, false):
		if not (node is MultiMeshInstance3D):
			meshes.append(node)
	return meshes

func _ground_shadows_off() -> void:
	for node in _ground_meshes():
		var before := node.cast_shadow
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_undo.append(func() -> void: node.cast_shadow = before)

func _ground_materials(change: Callable) -> void:
	var copies := {}
	for node in _ground_meshes():
		if node.mesh == null:
			continue
		for i in node.mesh.get_surface_count():
			var original := node.get_active_material(i) as StandardMaterial3D
			if original == null:
				continue
			var copy: StandardMaterial3D = copies.get(original)
			if copy == null:
				copy = original.duplicate()
				change.call(copy)
				copies[original] = copy
			node.set_surface_override_material(i, copy)
			var index := i
			_undo.append(func() -> void: node.set_surface_override_material(index, null))

func _ground_lite() -> void:
	_ground_materials(func(m: StandardMaterial3D) -> void:
		m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		m.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT)

## The ground materials as they were before they became matte (Burley
## diffuse + Schlick GGX specular): what the matte default saves.
func _ground_burley() -> void:
	_ground_materials(func(m: StandardMaterial3D) -> void:
		m.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
		m.diffuse_mode = BaseMaterial3D.DIFFUSE_BURLEY)

func _ground_per_vertex() -> void:
	_ground_materials(func(m: StandardMaterial3D) -> void:
		m.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX)

## The ground's shadow as before the back-face casters: each chunk casts
## its own (front-face) shadow, its _GroundShadow child none.
func _front_face_shadows() -> void:
	for node in _ground_meshes():
		if String(node.name) == "_GroundShadow":
			var before := node.cast_shadow
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			_undo.append(func() -> void: node.cast_shadow = before)
		elif String(node.name).begins_with("Chunk"):
			node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
			_undo.append(func() -> void: node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)

func _sun_shadows_off() -> void:
	for sun in get_root().find_children("*", "DirectionalLight3D", true, false):
		var light := sun as DirectionalLight3D
		light.shadow_enabled = false
		_undo.append(func() -> void: light.shadow_enabled = true)

func _restore() -> void:
	for undo in _undo:
		undo.call()
	_undo.clear()
