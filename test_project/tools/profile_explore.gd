extends SceneTree
## Frame rate of bench/explore.tscn as played on a computer: once the player
## stands, it walks forward (turning slowly) for `--seconds`, vsync off, and
## the frame time is split into GPU, process, physics and the rest.
##   godot --path . --position -3000,-3000 --script res://tools/profile_explore.gd [-- --size=1920x1080 --seconds=10 --fly]

func _initialize() -> void:
	var size := Vector2i(1920, 1080)
	var seconds := 10.0
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--size="):
			var parts := arg.substr(7).split("x")
			size = Vector2i(int(parts[0]), int(parts[1]))
		elif arg.begins_with("--seconds="):
			seconds = float(arg.substr(10))
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	DisplayServer.window_set_size(size)
	get_root().size = size
	await process_frame
	var explore: Script = load("res://bench/explore.gd")
	explore.set("stream", not OS.get_cmdline_user_args().has("--no-stream"))
	var scene := (load("res://bench/explore.tscn") as PackedScene).instantiate()
	get_root().add_child(scene)
	var load_start := Time.get_ticks_msec()
	var player: Node3D = null
	while player == null:
		await process_frame
		for child in scene.get_children():
			if child is CharacterBody3D:
				player = child
	var runtime := scene.find_child("*Runtime*", true, false)
	while runtime != null and not runtime.is_finished:
		await process_frame
	print("loaded in %.1f s" % ((Time.get_ticks_msec() - load_start) / 1000.0))
	for i in 60:
		await process_frame
	if OS.get_cmdline_user_args().has("--hide-terrain"):
		(scene.get_node("LowpolyTerrain") as Node3D).visible = false
	# --no-detail-collision: trunks / rocks without collision bodies.
	if OS.get_cmdline_user_args().has("--no-detail-collision"):
		for body in scene.find_children("_DetailCollision", "", true, false):
			body.queue_free()
	# --flat-collision: the ground's concave shapes replaced by one plane at
	# the player's height (what the physics costs without the terrain).
	if OS.get_cmdline_user_args().has("--flat-collision"):
		for body in scene.find_children("*", "StaticBody3D", true, false):
			body.queue_free()
		var floor_body := StaticBody3D.new()
		var plane := CollisionShape3D.new()
		plane.shape = WorldBoundaryShape3D.new()
		floor_body.add_child(plane)
		floor_body.position.y = player.global_position.y - 1.0
		scene.add_child(floor_body)
	var physics_us := [0]
	var physics_ticks := [0]
	RenderingServer.viewport_set_measure_render_time(get_root().get_viewport_rid(), true)
	# Walks forward (the stick of the touch controls).
	player.set("touch_move", Vector2(0, -1))
	var vp := get_root().get_viewport_rid()
	var events: Array = [0]
	if runtime != null:
		runtime.chunk_details_changed.connect(func(_x: int, _z: int) -> void: events[0] += 1)
	var slow: Array = []
	var frames: Array[float] = []
	var gpu := 0.0
	var render_cpu := 0.0
	var process := 0.0
	var physics := 0.0
	var start := Time.get_ticks_usec()
	var last := start
	while Time.get_ticks_usec() - start < int(seconds * 1e6):
		await process_frame
		var now := Time.get_ticks_usec()
		frames.append((now - last) / 1000.0)
		last = now
		if frames[-1] > 12.0:
			slow.append("frame %d at %.2f s: %.1f ms (%d chunk changes, gpu %.1f)" % [frames.size(), (now - start) / 1e6, frames[-1], events[0], RenderingServer.viewport_get_measured_render_time_gpu(vp)])
		events[0] = 0
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		render_cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		process += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		physics += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		player.rotate_y(0.002)
	var n := float(frames.size())
	var total := 0.0
	for f in frames:
		total += f
	frames.sort()
	print("size %dx%d, %d frames in %.1f s: %.0f fps (mean %.2f ms, 1%% low %.2f ms, worst %.2f ms)" % [
		size.x, size.y, frames.size(), seconds, 1000.0 / (total / n), total / n, frames[int(n * 0.99)], frames[-1]])
	print("per frame: GPU %.2f ms, render CPU %.2f ms, process %.2f ms, physics %.2f ms" % [gpu / n, render_cpu / n, process / n, physics / n])
	print("draw calls %d, triangles %dk, objects %d" % [
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000,
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)])
	print("physics step (PhysicsServer3D, measured from Performance): %.3f ms per tick" % (physics / n))
	print("physics: %d active bodies, %d collision pairs" % [
		Performance.get_monitor(Performance.PHYSICS_3D_ACTIVE_OBJECTS), Performance.get_monitor(Performance.PHYSICS_3D_COLLISION_PAIRS)])
	print("frames > 12 ms: %d" % slow.size())
	for line in slow.slice(0, 15):
		print("  ", line)
	quit()
