extends SceneTree
## Frame by frame load of the audit's savanna map (as tools/audit_perf.gd
## loads it: real window, game sky, camera over the map): for the slowest
## frames, how long the runtime's steps took in that frame, which steps ran,
## and the rest of the frame ("other": rendering, texture uploads...).
##   godot --path . --position -3000,-3000 --script res://tools/profile_load_frames.gd [-- --frames=12]
## --empty: same scene (sky, camera) without building the terrain, to see what
## the first frames cost without the plugin.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

func _initialize() -> void:
	var shown := 12
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--frames="):
			shown = int(arg.substr(9))
	get_root().size = Vector2i(1280, 720)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var root := Node3D.new()
	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	root.add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(RECIPE), 7)
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var points: Array[Vector2] = []
	for i in 9:
		var t := float(i) / 8.0
		points.append(Vector2(lerpf(-0.42, 0.42, t) * size, sin(t * 5.0) * 0.12 * size + 0.18 * size))
	FeatureStyle.commit(terrain, FeatureStyle.RIVER, points)
	terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	terrain.set_meta(Meta.COLLISION_ENABLED, true)
	var runtime := TerrainRuntime.new()
	# Every detail at load (as the earlier measures; on by default since 2026-11-24).
	runtime.stream_details = false
	runtime.name = String(Meta.RUNTIME_NODE_NAME)
	runtime.build_on_ready = false
	terrain.add_child(runtime)
	root.add_child((load("res://world/savanna_sky.tscn") as PackedScene).instantiate())
	var camera := Camera3D.new()
	camera.fov = 75.0
	camera.far = 800.0
	root.add_child(camera)
	camera.current = true
	camera.look_at_from_position(Vector3(0, 30, 30), Vector3.ZERO)
	get_root().add_child(root)
	if OS.get_cmdline_user_args().has("--empty"):
		terrain.free()
		var last_empty := Time.get_ticks_usec()
		for i in 5:
			await process_frame
			var now_empty := Time.get_ticks_usec()
			print("empty scene frame %d: %.1f ms" % [i, (now_empty - last_empty) / 1000.0])
			last_empty = now_empty
		quit()
		return
	await process_frame
	# [frame ms, steps ms, steps "#first-last kind x n", frame index]
	var frames: Array = []
	var last := Time.get_ticks_usec()
	var first := true
	while first or not runtime.is_finished:
		var before: int = runtime._done
		var t0 := Time.get_ticks_usec()
		if first:
			runtime.build()
			runtime.set_process(false)
			first = false
		else:
			runtime._run(runtime.frame_budget_ms)
		var run_ms := (Time.get_ticks_usec() - t0) / 1000.0
		var ran := ""
		if not runtime.is_finished:
			ran = _kinds(runtime, before, runtime._done)
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append([(now - last) / 1000.0, run_ms, ran, frames.size()])
		last = now
	var total := 0.0
	for f in frames:
		total += f[0]
	print("frames %d, %.0f ms" % [frames.size(), total])
	var slow := frames.duplicate()
	slow.sort_custom(func(a, b): return a[0] > b[0])
	for f in slow.slice(0, shown):
		print("  frame %3d  %6.1f ms  steps %6.1f ms  other %6.1f ms  %s" % [f[3], f[0], f[1], f[0] - f[1], f[2]])
	var over := 0
	for f in frames:
		if f[0] > 33.3:
			over += 1
	print("frames over 33 ms: %d" % over)
	quit()

func _kinds(runtime: Node, from: int, to: int) -> String:
	var counts := {}
	for i in range(from, mini(to + 1, runtime._steps.size())):
		var step: Callable = runtime._steps[i]
		var name := String(step.get_method())
		if name == "" or name.begins_with("<anonymous"):
			name = "lambda"
		counts[name] = counts.get(name, 0) + 1
	var parts: Array[String] = []
	for k in counts:
		parts.append("%s x%d" % [k, counts[k]])
	return "#%d-%d %s" % [from, to, ", ".join(parts)]
