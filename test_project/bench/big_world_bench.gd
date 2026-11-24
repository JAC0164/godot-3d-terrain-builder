extends Node3D
## Phone benchmark of the open world (series "big_world" of
## bench/phone_bench.gd): the open-world preset (1024 cells, ~1.5 km, seed 7)
## streamed by TerrainRuntime (stream_ground, details streamed, far blocks),
## the player of player/fps_player.tscn dropped on a track, then walking
## (5 m/s) and running (10 m/s) along it, steered like a touch stick.
## Each run measures:
##   - map generation, time to the player standing on the ground, time to
##     the first build finished, loading worst frame;
##   - walking and running: frame ms (mean, p50, p99, worst, frames over
##     33 ms), GPU ms, draw calls, triangles, metres covered, times stuck
##     (teleported on), frames with no ground under the player;
##   - memory (static, video) after each phase.
## The runs of RUNS in a row, results on screen, in the log (adb logcat -s
## godot) and in user://phone_bench_series_big_world.json.
##   godot --path . res://bench/big_world_bench.tscn [-- --quit] [--quick]
## --quick: one run, short walk and run (desktop check).
## Series "big_world_sixty" (autorun text): what it takes for 60 fps on a
## phone (3D scale, sun shadows, glow, fog, sky), shorter walk and run.
## Series "big_world_sixty2": from the light settings, what else costs
## (details, far blocks, ground distance, shadows).
## Series "big_world_sixty3": the light settings, without shadows, with
## phone_quality.gd; each phase also times TerrainRuntime._process per frame
## (two probe nodes around it) and a third phase stands still (no streaming).
## Series "big_world_sixty4": vsync on (Android frame pacing, Swappy, works
## only with it) against off (the project setting), same probes.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainSampler = preload(ADDON + "core/terrain_sampler.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_open_world_map.tres"
const PLAYER_SCENE := "res://player/fps_player.tscn"
const SEED := 7
const WALK_SECONDS := 30.0
const RUN_SECONDS := 45.0
## One run: ground_distance, far_distance, far_step, ground_threads, 3D scale,
## sky scene. The reference = the game's open-world settings (bench/explore.gd
## open_world): ground 160 m, far blocks to 600 m where the fog of
## world/open_world_sky.tscn is total.
## shadows: "on" (the sky scene's sun), "light" (one split, 1024 map, hard
## edges) or "off"; glow, aerial (fog aerial perspective): the sky scene's
## Environment or off; bg: "sky" or "color" (no sky drawn, a flat colour).
const REFERENCE := {"ground": 160.0, "far": 600.0, "far_step": 4, "threads": true, "scale": 1.0,
	"sky": "res://world/open_world_sky.tscn", "ready_budget": 25.0,
	"shadows": "on", "glow": true, "aerial": true, "bg": "sky", "quality": false, "details": 1.0, "vsync": false}
## The game settings, at 3D scale 0.75, the first phone settings (ground
## 250 m, far 1 km, the small map's sky whose fog is total at 320 m), the
## game settings again (drift as the phone warms up).
## ready_budget: TerrainRuntime.ready_budget_ms (work per frame until the
## player is in).
const RUNS := [
	{},
	{"ready_budget": 50.0},
	{"ready_budget": 0.0},
	{"scale": 0.75},
	{},
]
## Series big_world_sixty: 3D scale 0.67 alone, then with each lighter
## setting, scale 0.5, everything light, the reference again (drift).
const RUNS_SIXTY := [
	{},
	{"quality": true},
	{"scale": 0.67},
	{"scale": 0.67, "shadows": "light"},
	{"scale": 0.67, "shadows": "off"},
	{"scale": 0.67, "glow": false, "aerial": false},
	{"scale": 0.67, "bg": "color"},
	{"scale": 0.5},
	{"scale": 0.67, "shadows": "light", "glow": false, "aerial": false, "bg": "color"},
	{"scale": 0.5, "shadows": "light", "glow": false, "aerial": false, "bg": "color"},
	{},
]
## quality: world/phone_quality.gd as in the game (dynamic 3D scale, lighter
## shadows, 60 fps cap); the run reports the mean 3D scale.
const PhoneQuality = preload("res://world/phone_quality.gd")
## Series big_world_sixty2: the light settings of phone_sixty_v1.json (3D
## scale 0.67, light shadows, no glow, no aerial perspective) alone, then
## with phone_quality.gd, without details, half details, far blocks to 400 m,
## far blocks at 1/8, ground to 120 m, no shadows, light settings again.
## details: detail density factor (0 = none).
const LIGHT := {"scale": 0.67, "shadows": "light", "glow": false, "aerial": false}
const RUNS_SIXTY2 := [
	LIGHT,
	{"quality": true},
	{"details": 0.0},
	{"details": 0.5},
	{"far": 400.0},
	{"far_step": 8},
	{"ground": 120.0},
	{"shadows": "off"},
	LIGHT,
]
const RUNS_SIXTY3 := [
	LIGHT,
	{"shadows": "off"},
	{"quality": true},
]
const RUNS_SIXTY4 := [
	{"vsync": true},
	{"vsync": true, "shadows": "off"},
	{"vsync": false},
	{"vsync": true},
]
const STILL_SECONDS := 10.0
## Series name -> runs (the others: RUNS).
const SERIES_RUNS := {"big_world_sixty": RUNS_SIXTY, "big_world_sixty2": RUNS_SIXTY2,
	"big_world_sixty3": RUNS_SIXTY3, "big_world_sixty4": RUNS_SIXTY4}

## Writes the time when its _process runs (around the runtime's, by
## process_priority).
class Probe extends Node:
	var marks: Dictionary
	var key := ""
	func _process(_delta: float) -> void:
		marks[key] = Time.get_ticks_usec()
const SIXTY_WALK_SECONDS := 20.0
const SIXTY_RUN_SECONDS := 25.0

## The series to run (phone_bench.gd sets it from the autorun text).
static var series := "big_world"

var _label: Label
var _lines := PackedStringArray()
var _level: Node3D
var _terrain: Node3D
var _runtime: TerrainRuntime
var _player: FpsPlayer
var _path := PackedVector2Array()
var _target := 0
## Probe times ("before" / "after" the runtime's _process), series sixty3.
var _marks := {}
var _direction := 1

func _ready() -> void:
	_build_ui()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	var quick := OS.get_cmdline_user_args().has("--quick")
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--series="):
			series = arg.substr(9)
	# sixty*: short walk and run; 2-4: from the light settings; 3-4: probes.
	var sixty := series.begins_with("big_world_sixty")
	var light_base := sixty and series != "big_world_sixty"
	var probes := series in ["big_world_sixty3", "big_world_sixty4"]
	var runs: Array = [{}] if quick else SERIES_RUNS.get(series, RUNS)
	var reports: Array = []
	var summary := PackedStringArray()
	for i in runs.size():
		var options: Dictionary = REFERENCE.merged(runs[i], true)
		if light_base and not bool(options["quality"]):
			# Each run = the light settings + its change.
			options = REFERENCE.merged(LIGHT, true).merged(runs[i], true)
		var report := await _run(options, quick, sixty, probes)
		reports.append(report)
		var walk: Dictionary = report["walk"]
		var run: Dictionary = report["run"]
		var line := "%d. sol %.1f s | marche %.0f img/s p99 %.0f ms pire %.0f | course %.0f img/s p99 %.0f ms pire %.0f | GPU %.1f ms CPU rendu %.1f | %.0f Mo | %s" % [
			i + 1, float(report["load"]["on_ground_ms"]) / 1000.0,
			1000.0 / maxf(float(walk["frame_ms"]), 0.001), walk["p99_ms"], walk["worst_ms"],
			1000.0 / maxf(float(run["frame_ms"]), 0.001), run["p99_ms"], run["worst_ms"],
			run["gpu_ms"], run["cpu_ms"], run["static_mem_mb"], _options_label(options)]
		summary.append(line)
		print("SERIES ", line)
	var path := "user://phone_bench_series_%s.json" % series
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(reports, "  "))
		file.close()
	_lines = PackedStringArray(["Série %s finie (%s)" % [series, OS.get_model_name()]])
	_lines.append_array(summary)
	_lines.append("Détails : %s" % ProjectSettings.globalize_path(path))
	_show()
	print("SERIES done")
	if OS.get_cmdline_user_args().has("--quit"):
		get_tree().quit()

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 10
	add_child(layer)
	var height := float(get_viewport().get_visible_rect().size.y)
	var font_size := maxi(14, int(height / 40.0))
	_label = Label.new()
	_label.position = Vector2(font_size, font_size) * 0.5
	_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", maxi(4, font_size / 4))
	layer.add_child(_label)

func _show(status: String = "") -> void:
	_label.text = "\n".join(_lines) + ("\n" + status if status != "" else "")

func _add_line(line: String) -> void:
	_lines.append(line)
	print(line)
	_show()

func _run(options: Dictionary, quick: bool, short := false, probes := false) -> Dictionary:
	if _level != null:
		_level.free()
		_level = null
	_lines = PackedStringArray()
	var report := {}
	var scale := float(options["scale"])
	get_viewport().scaling_3d_scale = scale
	# A "quality" run before capped it.
	Engine.max_fps = 0
	var screen := get_viewport().get_visible_rect().size
	report["device"] = {"model": OS.get_model_name(), "cpu": OS.get_processor_name(), "cores": OS.get_processor_count(),
		"gpu": RenderingServer.get_video_adapter_name(), "method": RenderingServer.get_current_rendering_method(),
		"screen": "%dx%d" % [screen.x, screen.y], "refresh_hz": DisplayServer.screen_get_refresh_rate()}
	report["settings"] = options.duplicate()
	_add_line("%s | %s | %s" % [OS.get_model_name(), RenderingServer.get_video_adapter_name(), _options_label(options)])
	_show("Génération du monde ouvert…")
	await get_tree().process_frame
	await get_tree().process_frame

	_level = Node3D.new()
	_level.name = "Level"
	_terrain = Node3D.new()
	_terrain.name = "LowpolyTerrain"
	_level.add_child(_terrain)
	TerrainData.initialize(_terrain)
	var t0 := Time.get_ticks_usec()
	var stats := MapGenerator.generate(_terrain, load(RECIPE), SEED)
	var generate_ms := (Time.get_ticks_usec() - t0) / 1000.0
	report["map_generate_ms"] = generate_ms
	report["map_cells"] = stats.get("size", 0)
	_terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	_terrain.set_meta(Meta.COLLISION_ENABLED, true)
	var details := float(options["details"])
	if details <= 0.0:
		_terrain.set_meta(Meta.DETAIL_ENABLED, false)
	elif details != 1.0:
		_terrain.set_meta(Meta.DETAIL_DENSITY, Meta.get_float(_terrain, Meta.DETAIL_DENSITY, Meta.DEFAULT_DETAIL_DENSITY) * details)
	_path = _track_path()
	_target = 1
	_direction = 1
	var spawn := _path[0]

	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_ENABLED if bool(options["vsync"]) else DisplayServer.VSYNC_DISABLED)
	var sky := (load(String(options["sky"])) as PackedScene).instantiate()
	_light_options(sky, options)
	_level.add_child(sky)
	if bool(options["quality"]):
		_level.add_child(PhoneQuality.new())
	# A view over the spawn while the ground around it is built (the
	# streaming centre is the current camera).
	var camera := Camera3D.new()
	camera.far = float(options["far"]) + 200.0
	_level.add_child(camera)
	_runtime = TerrainRuntime.new()
	_runtime.name = String(Meta.RUNTIME_NODE_NAME)
	_runtime.stream_ground = true
	_runtime.stream_details = true
	_runtime.ground_distance = float(options["ground"])
	_runtime.far_distance = float(options["far"])
	_runtime.far_step = int(options["far_step"])
	_runtime.ground_threads = bool(options["threads"])
	_runtime.ready_budget_ms = float(options["ready_budget"])
	_terrain.add_child(_runtime)
	var first_build := {}
	_runtime.finished.connect(func(build_stats: Dictionary) -> void: first_build.merge(build_stats))
	var ready_state := {"ms": -1.0}
	# When each load step ends until the player is in: [step, ms].
	var timeline: Array = []
	var last_done := [0]

	# Placed before the level enters the tree: the runtime starts its first
	# ring around the camera when it is added.
	var spawn_point := Vector3(spawn.x, TerrainSampler.uncarved_height(_terrain, spawn), spawn.y)
	camera.transform = Transform3D(Basis(), spawn_point + Vector3(0, 25, 0)).looking_at(_point(_path[mini(8, _path.size() - 1)]))
	camera.current = true
	var load_start := Time.get_ticks_usec()
	add_child(_level)
	move_child(_level, 0)
	_runtime.terrain_ready.connect(func() -> void: ready_state["ms"] = (Time.get_ticks_usec() - load_start) / 1000.0, CONNECT_ONE_SHOT)
	_runtime.progress.connect(func(done: int, _total: int) -> void:
		if float(ready_state["ms"]) < 0.0 and done != last_done[0]:
			last_done[0] = done
			timeline.append([done, roundi((Time.get_ticks_usec() - load_start) / 1000.0)]))
	var worst := 0.0
	var slow := 0
	var frames := 0
	var last := Time.get_ticks_usec()
	while float(ready_state["ms"]) < 0.0 and frames < 6000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var frame_ms := (now - last) / 1000.0
		last = now
		frames += 1
		worst = maxf(worst, frame_ms)
		if frame_ms > 33.3:
			slow += 1
		_show("Chargement… %d images" % frames)

	# The player drops in as soon as the ground around the spawn is ready.
	_player = (load(PLAYER_SCENE) as PackedScene).instantiate() as FpsPlayer
	_player.touch_mode = true
	_level.add_child(_player)
	_player.global_position = spawn_point + Vector3.UP * 2.0
	_player.camera.far = float(options["far"]) + 200.0
	_player.camera.current = true
	_face(_path[1])
	camera.queue_free()
	var on_ground_ms := -1.0
	while on_ground_ms < 0.0 and frames < 6000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var frame_ms := (now - last) / 1000.0
		last = now
		frames += 1
		worst = maxf(worst, frame_ms)
		if frame_ms > 33.3:
			slow += 1
		if _player.is_on_floor():
			on_ground_ms = (now - load_start) / 1000.0
	# The rest of the first build (far blocks, details), standing still.
	while not _runtime.is_finished and frames < 12000:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var frame_ms := (now - last) / 1000.0
		last = now
		frames += 1
		worst = maxf(worst, frame_ms)
		if frame_ms > 33.3:
			slow += 1
		_show("Fin du chargement… %d images" % frames)
	var finished_ms := (Time.get_ticks_usec() - load_start) / 1000.0
	report["load"] = {"terrain_ready_ms": ready_state["ms"], "on_ground_ms": on_ground_ms, "finished_ms": finished_ms,
		"frames": frames, "worst_frame_ms": worst, "frames_over_33ms": slow,
		"worst_step_ms": first_build.get("worst_step_ms", -1), "worst_step": first_build.get("worst_step", -1),
		"static_mem_mb": _static_mb(), "video_mem_mb": _video_mb(), "ready_timeline": timeline}
	_add_line("Carte %.1f s ; sol prêt %.1f s ; joueur au sol %.1f s ; tout %.1f s ; pire image %.0f ms (%d > 33 ms) ; %.0f Mo" % [
		generate_ms / 1000.0, float(ready_state["ms"]) / 1000.0, on_ground_ms / 1000.0, finished_ms / 1000.0, worst, slow, _static_mb()])
	_add_line("%-7s %6s %6s %6s %6s %6s %6s %8s %6s %5s %5s" % ["phase", "img/s", "p50", "p99", "pire", ">33", "GPU", "triangles", "m", "bloqué", "trou"])
	if probes:
		# Runtime alone at its priority, a probe just before and just after.
		_runtime.process_priority = 1000
		for key in ["before", "after"]:
			var probe := Probe.new()
			probe.marks = _marks
			probe.key = key
			probe.process_priority = 999 if key == "before" else 1001
			_level.add_child(probe)
	report["walk"] = await _move("marche", false, 8.0 if quick else (SIXTY_WALK_SECONDS if short else WALK_SECONDS))
	report["run"] = await _move("course", true, 8.0 if quick else (SIXTY_RUN_SECONDS if short else RUN_SECONDS))
	if probes:
		report["still"] = await _move("immobile", false, STILL_SECONDS, false)
	return report

## The player follows the path (a stick held forward, turned toward the next
## point) for `seconds`; frame times and what was drawn.
func _move(phase: String, running: bool, seconds: float, moving := true) -> Dictionary:
	var vp := get_viewport().get_viewport_rid()
	var times := PackedFloat32Array()
	# Runtime _process ms of each frame (probes), -1 when not measured.
	var runtime_times := PackedFloat32Array()
	var gpu := 0.0
	var cpu := 0.0
	var draws := 0.0
	var triangles := 0.0
	var covered := 0.0
	var stuck := 0
	var holes := 0
	var busy := 0
	var previous := _player.global_position
	var still_since := 0.0
	var elapsed := 0.0
	_player.touch_move = Vector2(0, -1) if moving else Vector2.ZERO
	_player.touch_run = running
	var last := Time.get_ticks_usec()
	_marks.clear()
	while elapsed < seconds:
		if moving:
			_steer()
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var frame_ms := (now - last) / 1000.0
		last = now
		elapsed += frame_ms / 1000.0
		times.append(frame_ms)
		# The frame just measured ran the runtime between the two probes.
		if _marks.has("before") and _marks.has("after"):
			runtime_times.append((int(_marks["after"]) - int(_marks["before"])) / 1000.0)
			_marks.clear()
		else:
			runtime_times.append(-1.0)
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
		draws += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		triangles += Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)
		if not _runtime.is_streaming_idle:
			busy += 1
		var position := _player.global_position
		var step := Vector2(position.x - previous.x, position.z - previous.z).length()
		covered += step
		previous = position
		# No ground under the feet: a hole in the streamed collision.
		if times.size() % 10 == 0 and _player.ground_below(position) == position:
			holes += 1
		# Stuck against a slope: teleported onto the next point.
		still_since = still_since + frame_ms / 1000.0 if step < 0.02 and moving else 0.0
		if still_since > 1.5:
			stuck += 1
			still_since = 0.0
			_player.teleport(_point(_path[_target]) + Vector3.UP * 0.5)
		_show("%s %.0f / %.0f s" % [phase.capitalize(), elapsed, seconds])
	_player.touch_move = Vector2.ZERO
	_player.touch_run = false
	var count := maxf(float(times.size()), 1.0)
	var total := 0.0
	var slow := 0
	for t in times:
		total += t
		if t > 33.3:
			slow += 1
	var sorted := times.duplicate()
	sorted.sort()
	var result := {
		"seconds": elapsed, "frames": times.size(), "frame_ms": total / count,
		"p50_ms": _percentile(sorted, 0.5), "p99_ms": _percentile(sorted, 0.99), "worst_ms": sorted[sorted.size() - 1] if not sorted.is_empty() else 0.0,
		"frames_over_33ms": slow, "gpu_ms": gpu / count,
		"cpu_ms": cpu / count, "scale_3d": get_viewport().scaling_3d_scale, "draw_calls": draws / count, "triangles": triangles / count,
		"metres": covered, "stuck": stuck, "no_ground_checks": holes, "streaming_busy_frames": busy,
		"static_mem_mb": _static_mb(), "video_mem_mb": _video_mb(),
	}
	if runtime_times.count(-1.0) < runtime_times.size():
		result["runtime"] = _runtime_stats(times, runtime_times)
	_add_line("%-7s %6.0f %6.1f %6.1f %6.0f %6d %6.1f %8.0f %6.0f %5d %5d" % [phase, 1000.0 / maxf(float(result["frame_ms"]), 0.001),
		result["p50_ms"], result["p99_ms"], result["worst_ms"], slow, result["gpu_ms"], result["triangles"], covered, stuck, holes])
	return result

## Runtime _process time per frame against the frame times: mean, p99,
## worst, frames over 4 / 8 ms, and how many of the frames over 20 / 33 ms
## had the runtime over 4 ms (a frame over 16.7 ms misses the 60 Hz screen).
## frame_ms_by_runtime: mean frame ms when the runtime took < 1, 1-4, 4-8,
## > 8 ms.
func _runtime_stats(times: PackedFloat32Array, runtime_times: PackedFloat32Array) -> Dictionary:
	var measured := PackedFloat32Array()
	var over := {4: 0, 8: 0}
	var slow20 := 0
	var slow20_busy := 0
	var slow33 := 0
	var slow33_busy := 0
	var bands := [[0.0, 0], [0.0, 0], [0.0, 0], [0.0, 0]]
	for i in times.size():
		var r := runtime_times[i]
		if r < 0.0:
			continue
		measured.append(r)
		if r > 4.0:
			over[4] += 1
		if r > 8.0:
			over[8] += 1
		if times[i] > 20.0:
			slow20 += 1
			if r > 4.0:
				slow20_busy += 1
		if times[i] > 33.3:
			slow33 += 1
			if r > 4.0:
				slow33_busy += 1
		var band := 0 if r < 1.0 else (1 if r < 4.0 else (2 if r < 8.0 else 3))
		bands[band][0] += times[i]
		bands[band][1] += 1
	var total := 0.0
	for r in measured:
		total += r
	var sorted := measured.duplicate()
	sorted.sort()
	var by_band := []
	for b: Array in bands:
		by_band.append([float(b[0]) / maxf(float(b[1]), 1.0), b[1]])
	return {"frames": measured.size(), "mean_ms": total / maxf(float(measured.size()), 1.0),
		"p99_ms": _percentile(sorted, 0.99), "worst_ms": sorted[sorted.size() - 1] if not sorted.is_empty() else 0.0,
		"over_4ms": over[4], "over_8ms": over[8], "frames_over_20ms": slow20, "over_20ms_with_runtime_over_4ms": slow20_busy,
		"frames_over_33ms": slow33, "over_33ms_with_runtime_over_4ms": slow33_busy,
		"frame_ms_by_runtime": by_band}

## Turns the player toward the path's next point; at the path's end, back.
func _steer() -> void:
	var p := Vector2(_player.global_position.x, _player.global_position.z)
	while p.distance_to(_path[_target]) < 3.0:
		if _target + _direction < 0 or _target + _direction >= _path.size():
			_direction = -_direction
		_target += _direction
	_face(_path[_target])

func _face(point: Vector2) -> void:
	var d := point - Vector2(_player.global_position.x, _player.global_position.z)
	if d.length() > 0.01:
		# The body walks along its -Z.
		_player.rotation.y = atan2(-d.x, -d.y)

## The longest track, from its middle point to its far end (local X / Z,
## the terrain sits at the origin).
func _track_path() -> PackedVector2Array:
	var best: Array = []
	for road: Dictionary in _terrain.get_meta(Meta.ROADS, []):
		var points: Array = road["points"]
		if points.size() > best.size():
			best = points
	var out := PackedVector2Array()
	if best.size() < 4:
		var half := float(_terrain.get_meta(Meta.WORLD_SIZE)) * 0.4
		for i in 32:
			out.append(Vector2.RIGHT.rotated(TAU * i / 32.0) * half)
		return out
	for i in range(best.size() / 2, best.size()):
		out.append(best[i])
	return out

func _point(p: Vector2) -> Vector3:
	return Vector3(p.x, TerrainSampler.uncarved_height(_terrain, p), p.y)

static func _percentile(sorted: PackedFloat32Array, q: float) -> float:
	if sorted.is_empty():
		return 0.0
	return sorted[clampi(int(q * float(sorted.size() - 1)), 0, sorted.size() - 1)]

static func _static_mb() -> float:
	return Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0

static func _video_mb() -> float:
	return Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0

## The sun shadows, glow, fog aerial perspective and sky of `options` on the
## sky scene (its Environment copied: the loaded one is shared by the runs).
static func _light_options(sky: Node, options: Dictionary) -> void:
	var shadows := String(options["shadows"])
	for node in sky.find_children("*", "DirectionalLight3D", true, false):
		var sun := node as DirectionalLight3D
		sun.shadow_enabled = shadows != "off"
		if shadows == "light":
			sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	var shadow_size := int(ProjectSettings.get_setting_with_override("rendering/lights_and_shadows/directional_shadow/size"))
	RenderingServer.directional_shadow_atlas_set_size(1024 if shadows == "light" else shadow_size, true)
	var filter := int(ProjectSettings.get_setting_with_override("rendering/lights_and_shadows/directional_shadow/soft_shadow_filter_quality"))
	RenderingServer.directional_soft_shadow_filter_set_quality(
		RenderingServer.SHADOW_QUALITY_HARD if shadows == "light" else filter as RenderingServer.ShadowQuality)
	for node in sky.find_children("*", "WorldEnvironment", true, false):
		var world := node as WorldEnvironment
		var env: Environment = world.environment.duplicate()
		if not bool(options["glow"]):
			env.glow_enabled = false
		if not bool(options["aerial"]):
			env.fog_aerial_perspective = 0.0
		if String(options["bg"]) == "color":
			env.background_mode = Environment.BG_COLOR
			env.background_color = Color(0.62, 0.7, 0.8)
		world.environment = env

static func _options_label(options: Dictionary) -> String:
	return "sol %.0f m, loin %.0f m (1/%d), threads %s, éch. %.2f, budget chargement %s, %s" % [float(options["ground"]), float(options["far"]),
		int(options["far_step"]), "oui" if bool(options["threads"]) else "non", float(options["scale"]),
		"%.0f ms" % float(options["ready_budget"]) if float(options["ready_budget"]) > 0.0 else "normal",
		String(options["sky"]).get_file().get_basename()] + _light_label(options)

static func _light_label(options: Dictionary) -> String:
	var parts := PackedStringArray()
	if String(options["shadows"]) != "on":
		parts.append("ombres " + ("légères" if String(options["shadows"]) == "light" else "non"))
	if not bool(options["glow"]):
		parts.append("sans lueur")
	if not bool(options["aerial"]):
		parts.append("brume simple")
	if String(options["bg"]) == "color":
		parts.append("fond uni")
	if bool(options["quality"]):
		parts.append("qualité téléphone")
	if float(options["details"]) != 1.0:
		parts.append("détails x%.1f" % float(options["details"]))
	if bool(options["vsync"]):
		parts.append("vsync")
	return (", " + ", ".join(parts)) if not parts.is_empty() else ""
