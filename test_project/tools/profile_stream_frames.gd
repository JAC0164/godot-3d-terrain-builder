extends SceneTree
## Main-thread cost of TerrainRuntime per frame while the focus walks the
## open world (seed 7, settings of bench/explore.gd open_world): the
## runtime's _process is called by this tool and timed. Frames over 2, 4 and
## 8 ms, p50 / p99 / worst, and what the worst frames did (ground chunks
## built, collision shapes, road pieces, detail layers, far blocks).
## A phone CPU is ~3x slower than a laptop: 5 ms here = a missed 60 fps frame.
##   godot --path . --position -3000,-3000 --script res://tools/profile_stream_frames.gd [-- --speed=10 --seconds=20]

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_open_world_map.tres"

func _initialize() -> void:
	var speed := 5.0
	var seconds := 20.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--speed="):
			speed = float(arg.substr(8))
		elif arg.begins_with("--seconds="):
			seconds = float(arg.substr(10))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	var level := Node3D.new()
	get_root().add_child(level)
	level.add_child((load("res://world/open_world_sky.tscn") as PackedScene).instantiate())
	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	level.add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(RECIPE), 7)
	terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	terrain.set_meta(Meta.COLLISION_ENABLED, true)
	var camera := Camera3D.new()
	camera.far = 700.0
	level.add_child(camera)
	camera.current = true
	camera.look_at_from_position(Vector3(0, 30, 0), Vector3(0, 28, -10))
	var runtime := TerrainRuntime.new()
	runtime.name = String(Meta.RUNTIME_NODE_NAME)
	runtime.stream_ground = true
	runtime.ground_distance = 160.0
	runtime.far_distance = 600.0
	terrain.add_child(runtime)
	# Load as in the game, then the first build to its end.
	while not runtime.is_finished:
		await process_frame
	await process_frame
	runtime.set_process(false)
	var times := PackedFloat32Array()
	var slow: Array = []
	var elapsed := 0.0
	var last := Time.get_ticks_usec()
	var direction := Vector3(0.6, 0, -0.8).normalized()
	while elapsed < seconds:
		await process_frame
		var now := Time.get_ticks_usec()
		var delta := (now - last) / 1000000.0
		last = now
		elapsed += delta
		camera.global_position += direction * speed * delta
		var before := _counts(runtime)
		var prof: Variant = runtime.get_script().get("PROF")
		if prof is Dictionary:
			(prof as Dictionary).clear()
		var t0 := Time.get_ticks_usec()
		runtime._process(delta)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		times.append(ms)
		if ms > 4.0:
			var after := _counts(runtime)
			var did := PackedStringArray()
			for key: String in after:
				var change: int = int(after[key]) - int(before[key])
				if change != 0:
					did.append("%s %+d" % [key, change])
			if prof is Dictionary:
				for key: String in prof:
					if float(prof[key]) >= 0.3:
						did.append("[%s %.1f]" % [key, float(prof[key])])
			slow.append([ms, ", ".join(did)])
	var sorted := times.duplicate()
	sorted.sort()
	var over := [0, 0, 0]
	var total := 0.0
	for t in times:
		total += t
		for i in 3:
			if t > [2.0, 4.0, 8.0][i]:
				over[i] += 1
	print("stream %.0f m/s, %d frames: mean %.2f ms, p50 %.2f, p99 %.2f, worst %.2f | over 2 ms %d, 4 ms %d, 8 ms %d" % [
		speed, times.size(), total / maxf(times.size(), 1.0), sorted[int(sorted.size() * 0.5)], sorted[int(sorted.size() * 0.99)],
		sorted[sorted.size() - 1], over[0], over[1], over[2]])
	slow.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	for entry: Array in slow.slice(0, 25):
		print("  %6.2f ms  %s" % [entry[0], entry[1]])
	quit()

## What the runtime holds now (private state, read for the profile only).
func _counts(runtime: Node) -> Dictionary:
	var built_layers := 0
	var built: Dictionary = runtime.get("_built")
	for c: Vector2i in built:
		built_layers += _bits(int(built[c]))
	return {
		"ground": (runtime.get("_ground") as Dictionary).size(),
		"shapes": (runtime.get("_ground_shapes") as Dictionary).size(),
		"road_queue": (runtime.get("_road_queue") as Array).size(),
		"ground_queue": (runtime.get("_ground_queue") as Array).size(),
		"tasks": (runtime.get("_ground_tasks") as Dictionary).size(),
		"layers": built_layers,
		"collided": (runtime.get("_collided") as Dictionary).size(),
		"stream_queue": (runtime.get("_stream_queue") as Array).size(),
	}

static func _bits(mask: int) -> int:
	var n := 0
	while mask != 0:
		n += mask & 1
		mask >>= 1
	return n
