extends Node
## Phone benchmark, the Android export's first scene (project setting
## application/run/main_scene.android). Same level as tools/audit_perf.gd:
## the generated savanna map (seed 7) with one river, built at runtime by
## TerrainRuntime (All at runtime, progressive, collision on), lit by
## world/savanna_sky.tscn. Measures:
##   - loading: map generation, time to walkable ground / everything built,
##     worst frame and frames over 33 ms;
##   - per view: frame ms, GPU / render CPU ms, draw calls, triangles;
##   - an acacia forest painted at full density (rebuild time + two views).
## Results on screen, in the log (adb logcat -s godot) and in
## user://phone_bench_<shadows on/off>_<3D scale>.json (one file per setting,
## the latest run of each). Buttons: run again, shadows on / off, 3D scale,
## two series, each run in a row then the first one again to see if the phone
## got slower as it warmed up (user://phone_bench_series_<name>.json):
##   "Série" (SERIES_SETTINGS): shadows and 3D scale;
##   "Série géométrie" (SERIES_GEOMETRY): detail draw distance, no grass, no
##   details at all, to see what the drawn geometry costs;
##   "Série environnement" (SERIES_ENV): sky only (no terrain = Godot's floor),
##   no glow, no fog, no sky (plain colour), no river water;
##   "Série optimisations" (SERIES_OPTIM): fixes added one by one (Mobile
##   Water, no glow, fog without aerial perspective, lighting without the sky
##   while the sky is still drawn), then the same at 3D scale 0.75;
##   "Série finale" (SERIES_FINAL): the defaults after those fixes (phones get
##   Mobile Water by themselves, the game sky no longer lights the scene),
##   3D scale 0.75, no glow, no shadows.
## A series also starts by itself when user://autorun_series exists (its text
## = the series name, empty = settings):
##   adb shell run-as com.lte.perftest sh -c 'echo geometry > files/autorun_series' 
## On a phone the Mobile project defaults apply by themselves (2048 sun
## shadow map, hard shadow edges). Phones often keep vsync on: frame ms then
## stops at the screen rate (16.7 ms at 60 Hz); GPU ms is the real cost.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const WaterholeStyle = preload(ADDON + "styles/waterhole_style.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const Brush = preload(ADDON + "editing/brush.gd")
const ToolMode = preload(ADDON + "editing/tool_mode.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"
const SEED := 7
## Series "big_world": the open world, walked and run (bench/big_world_bench.gd).
const BIG_WORLD_SCENE := "res://bench/big_world_bench.tscn"
const BigWorldBench = preload("res://bench/big_world_bench.gd")
const SCALES: Array[float] = [1.0, 0.75, 0.5]
const WARMUP_FRAMES := 30
const MEASURED_FRAMES := 120
## One run: shadows, index in SCALES, every detail layer's draw distance x
## "distance", grass layers on / off, details on / off.
const REFERENCE := {"shadows": true, "scale": 0, "distance": 1.0, "grass": true, "details": true,
	"terrain": true, "glow": true, "fog": true, "sky": true, "river": true,
	"mobile_water": false, "aerial": true, "sky_light": true, "stream": false,
	"post": true, "ground_lite": false, "vertex_shading": false, "shadow_lite": false,
	"ground_shadows": true, "detail_shadows": true, "front_shadows": false,
	"grass_half": false, "grass_thin": false, "detail_receive": true}
const SERIES_SETTINGS := [
	{}, {"scale": 1}, {"scale": 2}, {"shadows": false}, {},
]
const SERIES_GEOMETRY := [
	{}, {"distance": 0.6}, {"grass": false}, {"details": false}, {"scale": 1, "distance": 0.6}, {},
]
const SERIES_ENV := [
	{}, {"terrain": false}, {"glow": false}, {"fog": false}, {"sky": false}, {"river": false}, {},
]
const SERIES_OPTIM := [
	{},
	{"mobile_water": true},
	{"mobile_water": true, "glow": false},
	{"mobile_water": true, "glow": false, "aerial": false},
	{"mobile_water": true, "glow": false, "aerial": false, "sky_light": false},
	{"mobile_water": true, "glow": false, "aerial": false, "sky_light": false, "scale": 1},
	{},
]
const SERIES_FINAL := [
	{}, {"scale": 1}, {"glow": false}, {"shadows": false}, {},
]
## Details built around the camera only (TerrainRuntime.stream_details) vs
## all of them: load time, and the views once the camera moved there.
const SERIES_STREAM := [
	{}, {"stream": true}, {}, {"stream": true},
]
## Toward 60 fps: each lever alone, then together (+ 3D scale 0.75, + per
## vertex lighting), the reference again at the end (drift between runs).
##   post: glow + colour adjustment off (extra full-screen passes on Mobile);
##   ground_lite: ground materials without specular, Lambert diffuse;
##   shadow_lite: one shadow split, 1024 shadow map;
##   vertex_shading: ground materials lit per vertex (flat low-poly faces).
const SIXTY_ALL := {"ground_lite": true, "post": false, "aerial": false, "shadow_lite": true}
const SERIES_SIXTY := [
	{}, {"ground_lite": true}, {"post": false}, {"aerial": false}, {"shadow_lite": true},
	SIXTY_ALL,
	{"ground_lite": true, "post": false, "aerial": false, "shadow_lite": true, "scale": 1},
	{"ground_lite": true, "post": false, "aerial": false, "shadow_lite": true, "vertex_shading": true},
	{},
]
## What the terrain costs on the phone (same as tools/profile_terrain_gpu.gd
## on PC): full, sky only (the game without the plugin), ground only, without
## the ground's shadows (plugin option Meta.GROUND_SHADOWS), then the same
## without any sun shadow, the reference again at the end.
const SERIES_SHARE := [
	{}, {"terrain": false}, {"details": false}, {"ground_shadows": false},
	{"terrain": false, "shadows": false}, {"shadows": false}, {},
]
## Who pays for the sun shadows: the ground casting from its front faces
## (before MeshUtils.back_face_caster), the details' shadows off, the
## ground's off, both off (what is left = receiving the shadows), the
## reference again at the end.
const SERIES_CASTERS := [
	{}, {"front_shadows": true}, {"detail_shadows": false}, {"ground_shadows": false},
	{"ground_shadows": false, "detail_shadows": false}, {"shadows": false}, {},
]
## What the grass costs on a tile GPU (fragment-bound, no depth prepass):
## no grass, half the tufts, the tufts thinned with the distance (each
## shrinks to nothing between 40 % of the draw distance and the draw
## distance), details that do not receive the sun's shadow, the reference
## again at the end.
const SERIES_GRASS := [
	{}, {"grass": false}, {"grass_half": true}, {"grass_thin": true},
	{"detail_receive": false}, {"shadows": false}, {},
]
const GRASS_LAYERS: Array[String] = ["Dry Grass", "Green Grass"]

var _shadows := true
var _scale_index := 0
var _distance := 1.0
var _grass := true
var _details := true
## terrain / glow / fog / sky / river switches of the current run.
var _opts := REFERENCE.duplicate()
var _running := false
var _in_series := false
## --shots: each run of a series saves user://shot_<prefix>_<view>.png.
var _shot_prefix := ""
var _level: Node3D
var _terrain: Node3D
var _camera: Camera3D
var _label: Label
var _buttons: HBoxContainer
var _shadow_button: Button
var _scale_button: Button
var _lines := PackedStringArray()
var _report := {}

func _ready() -> void:
	_build_ui()
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	if FileAccess.file_exists("user://autorun_series"):
		var series_name := FileAccess.get_file_as_string("user://autorun_series").strip_edges()
		DirAccess.remove_absolute(ProjectSettings.globalize_path("user://autorun_series"))
		if series_name.begins_with("big_world"):
			BigWorldBench.series = series_name
			get_tree().change_scene_to_file.call_deferred(BIG_WORLD_SCENE)
			return
		_series(series_name if series_name in ["geometry", "env", "optim", "final", "stream", "sixty", "share", "casters", "grass"] else "settings")
	else:
		_run()

func _build_ui() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	var height := float(get_viewport().get_visible_rect().size.y)
	var font_size := maxi(16, int(height / 34.0))
	# Dark panel behind the text, readable over any view.
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.45)
	style.set_content_margin_all(font_size * 0.5)
	style.set_corner_radius_all(font_size / 3)
	panel.add_theme_stylebox_override("panel", style)
	panel.position = Vector2(font_size, font_size) * 0.5
	layer.add_child(panel)
	var box := VBoxContainer.new()
	panel.add_child(box)
	_label = Label.new()
	# Monospaced, so the view table's columns line up.
	var mono := SystemFont.new()
	mono.font_names = PackedStringArray(["monospace", "Droid Sans Mono", "Roboto Mono", "Consolas"])
	_label.add_theme_font_override("font", mono)
	_label.add_theme_font_size_override("font_size", font_size)
	_label.add_theme_color_override("font_color", Color.WHITE)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", maxi(4, font_size / 4))
	box.add_child(_label)
	_buttons = HBoxContainer.new()
	_buttons.add_theme_constant_override("separation", font_size)
	box.add_child(_buttons)
	_add_button("Relancer", font_size, func() -> void: _run())
	_add_button("Série", font_size, func() -> void: _series("settings"))
	_add_button("Série géométrie", font_size, func() -> void: _series("geometry"))
	_add_button("Série environnement", font_size, func() -> void: _series("env"))
	_add_button("Série optimisations", font_size, func() -> void: _series("optim"))
	_add_button("Série finale", font_size, func() -> void: _series("final"))
	_add_button("Série streaming", font_size, func() -> void: _series("stream"))
	_add_button("Série 60 fps", font_size, func() -> void: _series("sixty"))
	_add_button("Série part du terrain", font_size, func() -> void: _series("share"))
	_add_button("Série ombres du terrain", font_size, func() -> void: _series("casters"))
	_add_button("Série herbe", font_size, func() -> void: _series("grass"))
	_add_button("Série monde ouvert", font_size, func() -> void: get_tree().change_scene_to_file(BIG_WORLD_SCENE))
	_shadow_button = _add_button("", font_size, func() -> void:
		_shadows = not _shadows
		_refresh_buttons())
	_scale_button = _add_button("", font_size, func() -> void:
		_scale_index = (_scale_index + 1) % SCALES.size()
		_refresh_buttons())
	_refresh_buttons()

func _add_button(text: String, font_size: int, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.add_theme_font_size_override("font_size", font_size)
	button.custom_minimum_size = Vector2(font_size * 6, font_size * 2.4)
	button.pressed.connect(action)
	_buttons.add_child(button)
	return button

func _refresh_buttons() -> void:
	_shadow_button.text = "Ombres : %s" % ("oui" if _shadows else "non")
	_scale_button.text = "Échelle 3D : %.2f" % SCALES[_scale_index]

func _show(status: String = "") -> void:
	_label.text = "\n".join(_lines) + ("\n" + status if status != "" else "")

func _add_line(line: String) -> void:
	_lines.append(line)
	print(line)
	_show()

func _ground(p: Vector2) -> float:
	return WaterholeMesher.surface_height(_terrain.get_meta(Meta.HEIGHTS), PackedFloat32Array(), int(_terrain.get_meta(Meta.RESOLUTION)), float(_terrain.get_meta(Meta.WORLD_SIZE)), p)

func _run() -> void:
	if _running:
		return
	_running = true
	_buttons.visible = false
	if _level != null:
		_level.free()
		_level = null
	_lines = PackedStringArray()
	_report = {}
	var scale: float = SCALES[_scale_index]
	get_viewport().scaling_3d_scale = scale
	var screen := get_viewport().get_visible_rect().size
	_report["device"] = {
		"model": OS.get_model_name(), "cpu": OS.get_processor_name(), "gpu": RenderingServer.get_video_adapter_name(),
		"driver": RenderingServer.get_current_rendering_driver_name(), "method": RenderingServer.get_current_rendering_method(),
		"screen": "%dx%d" % [screen.x, screen.y], "refresh_hz": DisplayServer.screen_get_refresh_rate(),
	}
	_report["settings"] = {"shadows": _shadows, "scale_3d": scale, "detail_distance": _distance, "grass": _grass, "details": _details,
		"terrain": _opt("terrain"), "glow": _opt("glow"), "fog": _opt("fog"), "sky": _opt("sky"), "river": _opt("river"),
		"mobile_water": _opt("mobile_water", false), "aerial": _opt("aerial"), "sky_light": _opt("sky_light"),
		"stream": _opt("stream", false), "post": _opt("post"), "ground_lite": _opt("ground_lite", false),
		"vertex_shading": _opt("vertex_shading", false), "shadow_lite": _opt("shadow_lite", false),
		"ground_shadows": _opt("ground_shadows"), "detail_shadows": _opt("detail_shadows"), "front_shadows": _opt("front_shadows", false),
		"grass_half": _opt("grass_half", false), "grass_thin": _opt("grass_thin", false), "detail_receive": _opt("detail_receive")}
	_add_line("%s | %s | %s %s" % [OS.get_model_name(), RenderingServer.get_video_adapter_name(), RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_current_rendering_method()])
	_add_line("Écran %dx%d à %.0f Hz | ombres %s | échelle 3D %.2f | %s" % [screen.x, screen.y, DisplayServer.screen_get_refresh_rate(), "oui" if _shadows else "non", scale, _geometry_label()])
	_show("Génération de la carte…")
	await get_tree().process_frame
	await get_tree().process_frame

	_level = Node3D.new()
	_level.name = "Level"
	_terrain = Node3D.new()
	_terrain.name = "LowpolyTerrain"
	_level.add_child(_terrain)
	TerrainData.initialize(_terrain)
	var t0 := Time.get_ticks_usec()
	MapGenerator.generate(_terrain, load(RECIPE), SEED)
	var generate_ms := (Time.get_ticks_usec() - t0) / 1000.0
	_report["map_generate_ms"] = generate_ms
	var size: float = float(_terrain.get_meta(Meta.WORLD_SIZE))
	# One river across the map (the generator draws none), as in the audit.
	var points: Array[Vector2] = []
	for i in 9:
		var t := float(i) / 8.0
		points.append(Vector2(lerpf(-0.42, 0.42, t) * size, sin(t * 5.0) * 0.12 * size + 0.18 * size))
	if _opt("river"):
		FeatureStyle.commit(_terrain, FeatureStyle.RIVER, points)
	_apply_geometry()
	_terrain.set_meta(Meta.RIVER_MOBILE_WATER, _opt("mobile_water", false))
	_terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	_terrain.set_meta(Meta.COLLISION_ENABLED, true)
	_terrain.set_meta(Meta.GROUND_SHADOWS, _opt("ground_shadows"))
	# No terrain: the map data only (for the camera heights), nothing built.
	var runtime: TerrainRuntime = null
	if _opt("terrain"):
		runtime = TerrainRuntime.new()
		runtime.name = String(Meta.RUNTIME_NODE_NAME)
		runtime.stream_details = _opt("stream", false)
		_terrain.add_child(runtime)
	var sky := (load("res://world/savanna_sky.tscn") as PackedScene).instantiate()
	_level.add_child(sky)
	for sun in sky.find_children("*", "DirectionalLight3D", true, false):
		(sun as DirectionalLight3D).shadow_enabled = _shadows
		if _opt("shadow_lite", false):
			(sun as DirectionalLight3D).directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	var shadow_size := int(ProjectSettings.get_setting_with_override("rendering/lights_and_shadows/directional_shadow/size"))
	RenderingServer.directional_shadow_atlas_set_size(1024 if _opt("shadow_lite", false) else shadow_size, true)
	for world in sky.find_children("*", "WorldEnvironment", true, false):
		# A copy: the loaded Environment is shared by every run.
		var env: Environment = (world as WorldEnvironment).environment.duplicate()
		if not _opt("glow"):
			env.glow_enabled = false
		if not _opt("post"):
			env.glow_enabled = false
			env.adjustment_enabled = false
		if not _opt("fog"):
			env.fog_enabled = false
		if not _opt("aerial"):
			env.fog_aerial_perspective = 0.0
		if not _opt("sky_light"):
			# The sky is still drawn; it no longer lights the scene.
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		if not _opt("sky"):
			env.background_mode = Environment.BG_COLOR
			env.background_color = Color(0.62, 0.74, 0.9)
			env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
			env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED
		(world as WorldEnvironment).environment = env
	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.far = 800.0
	_level.add_child(_camera)
	_camera.current = true
	_camera.look_at_from_position(Vector3(0, 30, 30), Vector3.ZERO)

	# Loading, frame by frame, as a game sees it.
	var runtime_stats := {}
	if runtime != null:
		runtime.finished.connect(func(stats: Dictionary) -> void: runtime_stats.merge(stats))
	var load_start := Time.get_ticks_usec()
	add_child(_level)
	move_child(_level, 0)
	var worst := 0.0
	var slow := 0
	var frames := 0
	var ground_ms := -1.0
	var last := Time.get_ticks_usec()
	while runtime != null and not runtime.is_finished:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var frame_ms := (now - last) / 1000.0
		last = now
		frames += 1
		worst = maxf(worst, frame_ms)
		if frame_ms > 33.3:
			slow += 1
		if ground_ms < 0.0 and runtime.is_ground_ready:
			ground_ms = (now - load_start) / 1000.0
		_show("Chargement… %d images" % frames)
	var finished_ms := (Time.get_ticks_usec() - load_start) / 1000.0
	_report["load"] = {"ground_ready_ms": ground_ms, "finished_ms": finished_ms, "frames": frames,
		"worst_frame_ms": worst, "frames_over_33ms": slow,
		"worst_step_ms": runtime_stats.get("worst_step_ms", -1), "steps": runtime_stats.get("steps", -1)}
	_apply_ground_materials()
	_apply_casters()
	_apply_grass()
	_add_line("Carte générée en %.0f ms ; sol prêt %.2f s ; tout construit %.2f s" % [generate_ms, ground_ms / 1000.0, finished_ms / 1000.0])
	_add_line("Chargement : %d images, pire %.0f ms, %d au-dessus de 33 ms, pire étape %.0f ms" % [frames, worst, slow, float(runtime_stats.get("worst_step_ms", -1))])

	# Views at a player's eyes (1.7 m) and one from above (as the audit).
	var eye := 1.7
	var views := {}
	for k in 4:
		var dir := Vector2.RIGHT.rotated(TAU * float(k) / 4.0 + 0.4)
		var from := -dir * 6.0
		views["eye_%d" % k] = [from, eye, from + dir * 30.0, eye - 0.8]
	views["overview"] = [Vector2(-size * 0.35, size * 0.35), 45.0, Vector2.ZERO, 0.0]
	var holes := WaterholeStyle.shapes(_terrain)
	if not holes.is_empty():
		var h: Vector2 = holes[0].bounds.get_center()
		views["waterhole"] = [h + Vector2(-14, 9), eye, h, 0.0]
	var rivers: Array = _terrain.get_meta(Meta.RIVERS, [])
	if not rivers.is_empty():
		var p: Vector2 = (rivers[0]["points"] as Array)[4]
		views["river"] = [p + Vector2(-6, -14), eye, p + Vector2(8, 10), 0.0]
	_report["views"] = {}
	_add_line("%-9s %6s %6s %6s %6s %6s %8s" % ["vue", "img/s", "image", "pire", "GPU", "draws", "triangles"])
	for view_name in views:
		_report["views"][view_name] = await _measure(view_name, views[view_name])

	# Worst case: an acacia forest painted at full density.
	if runtime == null:
		await _finish_run(scale)
		return
	_show("Forêt peinte…")
	await get_tree().process_frame
	var spot := Vector2(10, -10)
	for k in 12:
		var at := spot + Vector2.RIGHT.rotated(k * 0.52) * float(k % 3) * 6.0
		Brush.apply_vegetation(_terrain, ToolMode.Mode.VEGETATION, at, 8.0, 1.0)
		Brush.apply_vegetation(_terrain, ToolMode.Mode.VEGETATION, at, 8.0, 1.0, "Acacias")
	var rebuild_start := Time.get_ticks_usec()
	TerrainBuilder.new().rebuild_all_details(_terrain)
	var rebuild_ms := (Time.get_ticks_usec() - rebuild_start) / 1000.0
	_report["forest_details_rebuild_ms"] = rebuild_ms
	_add_line("Forêt : détails de toute la carte refaits en %.0f ms" % rebuild_ms)
	_report["views"]["forest"] = await _measure("forest", [spot + Vector2(-16, 12), eye, spot, eye - 0.5])
	_report["views"]["forest_top"] = await _measure("forest_top", [spot + Vector2(-0.5, 9), 28.0, spot, 0.0])
	await _finish_run(scale)

func _finish_run(scale: float) -> void:
	var path := "user://phone_bench_%s_%d%s.json" % ["shadows" if _shadows else "noshadows", roundi(scale * 100.0), _geometry_suffix()]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(_report, "  "))
		file.close()
	_add_line("Fini. Résultats : %s" % ProjectSettings.globalize_path(path))
	print("PHONE_BENCH_JSON ", JSON.stringify(_report))
	_buttons.visible = true
	_running = false
	# Desktop check: godot --path . res://bench/phone_bench.tscn -- --quit
	if OS.get_cmdline_user_args().has("--quit") and not _in_series:
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://phone_bench.png")
		get_tree().quit()

func _measure(view_name: String, v: Array) -> Dictionary:
	var from: Vector2 = v[0]
	var to: Vector2 = v[2]
	_camera.look_at_from_position(Vector3(from.x, _ground(from) + float(v[1]), from.y), Vector3(to.x, _ground(to) + float(v[3]), to.y))
	_show("Mesure de la vue %s…" % view_name)
	for i in WARMUP_FRAMES:
		await get_tree().process_frame
	# Streaming: the details around the new view are built first (as a
	# player walking there would find them), at most 10 s.
	var runtime := _terrain.get_node_or_null(String(Meta.RUNTIME_NODE_NAME)) as TerrainRuntime
	var waited := 0
	while runtime != null and runtime.stream_details and not runtime.is_streaming_idle and waited < 600:
		await get_tree().process_frame
		waited += 1
	var vp := get_viewport().get_viewport_rid()
	var gpu := 0.0
	var cpu := 0.0
	var total := 0.0
	var worst := 0.0
	var last := Time.get_ticks_usec()
	for i in MEASURED_FRAMES:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		var frame_ms := (now - last) / 1000.0
		last = now
		total += frame_ms
		worst = maxf(worst, frame_ms)
		gpu += RenderingServer.viewport_get_measured_render_time_gpu(vp)
		cpu += RenderingServer.viewport_get_measured_render_time_cpu(vp)
	if OS.get_cmdline_user_args().has("--shots") and _shot_prefix != "" and view_name in ["eye_0", "forest", "overview"]:
		_label.visible = false
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://shot_%s_%s.png" % [_shot_prefix, view_name])
		_label.visible = true
	var result := {
		"frame_ms": total / MEASURED_FRAMES, "worst_frame_ms": worst,
		"gpu_ms": gpu / MEASURED_FRAMES, "render_cpu_ms": cpu / MEASURED_FRAMES,
		"draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		"triangles": Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		"video_mem_mb": Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
	}
	_add_line("%-9s %6.0f %6.1f %6.1f %6.1f %6d %8d" % [view_name, 1000.0 / maxf(result["frame_ms"], 0.001), result["frame_ms"], worst, result["gpu_ms"], result["draw_calls"], result["triangles"]])
	return result

## Every run of a series in a row; a summary line per run at the end.
func _series(series_name: String) -> void:
	if _running:
		return
	_in_series = true
	var runs: Array = {"geometry": SERIES_GEOMETRY, "env": SERIES_ENV, "optim": SERIES_OPTIM, "final": SERIES_FINAL, "stream": SERIES_STREAM, "sixty": SERIES_SIXTY, "share": SERIES_SHARE, "casters": SERIES_CASTERS, "grass": SERIES_GRASS}.get(series_name, SERIES_SETTINGS)
	var reports := []
	var summary := PackedStringArray()
	for i in runs.size():
		var run: Dictionary = REFERENCE.merged(runs[i], true)
		_shadows = run["shadows"]
		_scale_index = run["scale"]
		_distance = run["distance"]
		_grass = run["grass"]
		_details = run["details"]
		_opts = run
		_shot_prefix = "%s_%d" % [series_name, i + 1]
		_refresh_buttons()
		await _run()
		reports.append(_report.duplicate(true))
		var gpu := []
		var fps := []
		var tris := []
		for view in _report["views"].values():
			gpu.append(view["gpu_ms"])
			fps.append(1000.0 / maxf(view["frame_ms"], 0.001))
			tris.append(view["triangles"])
		var line := "%d. GPU %4.1f ms (%4.1f-%4.1f), %4.1f img/s, %3.0fk tri, tout %4.1f s | ombres %s, éch. %.2f, %s" % [
			i + 1, _mean(gpu), gpu.min(), gpu.max(), _mean(fps), _mean(tris) / 1000.0, _report["load"]["finished_ms"] / 1000.0,
			"oui" if _shadows else "non", SCALES[_scale_index], _geometry_label()]
		summary.append(line)
		print("SERIES ", line)
	_distance = 1.0
	_grass = true
	_details = true
	_opts = REFERENCE.duplicate()
	var path := "user://phone_bench_series_%s.json" % series_name
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(reports, "  "))
		file.close()
	_lines = PackedStringArray(["Série %s finie (%s)" % [series_name, OS.get_model_name()]])
	_lines.append_array(summary)
	_lines.append("Détails : %s" % ProjectSettings.globalize_path(path))
	_show()
	print("SERIES done")
	_in_series = false
	if OS.get_cmdline_user_args().has("--quit"):
		get_tree().quit()

## Detail draw distance / grass / details of the current run, on a copy of
## the biome (the preset file is not changed).
func _apply_geometry() -> void:
	if not _details:
		_terrain.set_meta(Meta.DETAIL_ENABLED, false)
		return
	if is_equal_approx(_distance, 1.0) and _grass:
		return
	# Layers at -1 follow the terrain's Draw Distance.
	var terrain_distance := float(_terrain.get_meta(Meta.DETAIL_DRAW_DISTANCE, Meta.DEFAULT_DETAIL_DRAW_DISTANCE))
	_terrain.set_meta(Meta.DETAIL_DRAW_DISTANCE, terrain_distance * _distance)
	var biome: Resource = (_terrain.get_meta(Meta.BIOME) as Resource).duplicate(true)
	for layer in biome.detail_layers:
		if layer == null:
			continue
		if not _grass and GRASS_LAYERS.has(String(layer.name)):
			layer.enabled = false
		if layer.draw_distance > 0.0:
			layer.draw_distance *= _distance
	_terrain.set_meta(Meta.BIOME, biome)

## ground_lite / vertex_shading: copies of the ground's StandardMaterial3Ds
## (the originals are shared, cached by the plugin) set on its meshes.
## detail_shadows: no detail casts a shadow; front_shadows: the ground's
## chunks cast their own shadow (front faces) instead of their back-face
## caster (_GroundShadow), as before.
func _apply_casters() -> void:
	for node in _terrain.find_children("*", "GeometryInstance3D", true, false):
		if node is MultiMeshInstance3D:
			if not _opt("detail_shadows"):
				(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		elif _opt("front_shadows", false) and _opt("ground_shadows"):
			if String(node.name) == "_GroundShadow":
				(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			elif String(node.name).begins_with("Chunk"):
				(node as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON

## grass_half: only the first half of each grass node's tufts drawn;
## grass_thin: the two-sided wind material (grass, reeds) with the tufts
## shrinking to nothing with the distance; detail_receive false: detail
## materials that do not receive shadows (shadows_disabled).
func _apply_grass() -> void:
	var half := _opt("grass_half", false)
	var thin := _opt("grass_thin", false)
	var receive := _opt("detail_receive")
	if not half and not thin and receive:
		return
	var include := (load("res://addons/lowpoly_terrain_editor/materials/detail_wind.gdshaderinc") as ShaderInclude).code
	if thin:
		include = include.replace("uniform float wind_scale = 1.0;", "uniform float wind_scale = 1.0;
uniform float fade_start = 0.0;
uniform float fade_end = 0.0;")
		include = include.replace("		VERTEX += (local_dir * strength * sway + shiver) * bend;
	}
}", """		VERTEX += (local_dir * strength * sway + shiver) * bend;
	}
	if (fade_end > 0.0) {
		vec3 o = MODEL_MATRIX[3].xyz;
		float h = fract(sin(dot(o.xz, vec2(12.9898, 78.233))) * 43758.5453);
		VERTEX *= clamp((mix(fade_start, fade_end, h) - distance(o, CAMERA_POSITION_WORLD)) / 3.0, 0.0, 1.0);
	}
}""")
	var copies := {}
	for node in _terrain.find_children("*", "MultiMeshInstance3D", true, false):
		var detail := node as MultiMeshInstance3D
		var original := detail.material_override
		var grass := original is ShaderMaterial and (original as ShaderMaterial).shader.code.contains("TWO_SIDED")
		if half and grass:
			detail.multimesh.visible_instance_count = detail.multimesh.instance_count / 2
		if not ((thin and grass) or not receive) or original == null:
			continue
		var key := [original, detail.visibility_range_end]
		var copy: Material = copies.get(key)
		if copy == null:
			copy = original.duplicate()
			if copy is StandardMaterial3D:
				(copy as StandardMaterial3D).disable_receive_shadows = true
			elif copy is ShaderMaterial:
				var material := copy as ShaderMaterial
				var code := material.shader.code.replace("#include \"detail_wind.gdshaderinc\"", include if (thin and grass) else (load("res://addons/lowpoly_terrain_editor/materials/detail_wind.gdshaderinc") as ShaderInclude).code)
				if not receive:
					code = code.replace("specular_disabled;", "specular_disabled, shadows_disabled;")
				var shader := Shader.new()
				shader.code = code
				material.shader = shader
				if thin and grass:
					material.set_shader_parameter("fade_start", detail.visibility_range_end * 0.4)
					material.set_shader_parameter("fade_end", detail.visibility_range_end)
			copies[key] = copy
		detail.material_override = copy

func _apply_ground_materials() -> void:
	var lite := _opt("ground_lite", false)
	var per_vertex := _opt("vertex_shading", false)
	if not lite and not per_vertex:
		return
	var copies := {}
	for node in _terrain.find_children("*", "MeshInstance3D", true, false):
		var mesh_node := node as MeshInstance3D
		if mesh_node.mesh == null:
			continue
		for i in mesh_node.mesh.get_surface_count():
			var original := mesh_node.get_active_material(i) as StandardMaterial3D
			if original == null:
				continue
			var copy: StandardMaterial3D = copies.get(original)
			if copy == null:
				copy = original.duplicate()
				if lite:
					copy.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
					copy.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT
				if per_vertex:
					copy.shading_mode = BaseMaterial3D.SHADING_MODE_PER_VERTEX
				copies[original] = copy
			mesh_node.set_surface_override_material(i, copy)

func _opt(name: String, default := true) -> bool:
	return bool(_opts.get(name, default))

func _geometry_label() -> String:
	var parts: Array[String] = []
	if _opt("mobile_water", false):
		parts.append("eau mobile")
	if _opt("stream", false):
		parts.append("streaming")
	if not _opt("post"):
		parts.append("sans post")
	if _opt("ground_lite", false):
		parts.append("sol léger")
	if _opt("shadow_lite", false):
		parts.append("ombres légères")
	if _opt("vertex_shading", false):
		parts.append("lumière par sommet")
	if not _opt("ground_shadows"):
		parts.append("sol sans ombres")
	if not _opt("detail_shadows"):
		parts.append("détails sans ombres")
	if _opt("front_shadows", false):
		parts.append("ombre du sol par l'avant")
	if _opt("grass_half", false):
		parts.append("moitié de l'herbe")
	if _opt("grass_thin", false):
		parts.append("herbe éclaircie au loin")
	if not _opt("detail_receive"):
		parts.append("détails sans ombre reçue")
	for key in ["terrain", "glow", "fog", "sky", "river", "aerial", "sky_light"]:
		if not _opt(key):
			parts.append({"terrain": "ciel seul", "glow": "sans lueur", "fog": "sans brume", "sky": "sans ciel", "river": "sans rivière",
				"aerial": "brume simple", "sky_light": "lumière sans ciel"}[key])
	if not _details:
		parts.append("sans détails")
		return ", ".join(parts)
	if not is_equal_approx(_distance, 1.0):
		parts.append("détails x%.1f" % _distance)
	if not _grass:
		parts.append("sans herbe")
	return ", ".join(parts) if not parts.is_empty() else "détails normaux"

func _geometry_suffix() -> String:
	var env := "_mobilewater" if _opt("mobile_water", false) else ""
	for key in ["terrain", "glow", "fog", "sky", "river", "aerial", "sky_light"]:
		if not _opt(key):
			env += "_no" + key
	if not _details:
		return env + "_nodetails"
	return env + ("_dist%d" % roundi(_distance * 100.0) if not is_equal_approx(_distance, 1.0) else "") + ("" if _grass else "_nograss")

func _mean(values: Array) -> float:
	var total := 0.0
	for v in values:
		total += float(v)
	return total / maxf(float(values.size()), 1.0)
