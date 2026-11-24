extends Node3D
## Walk the generated savanna map in first person (phone: touch controls,
## computer: mouse + keyboard of player/fps_player.gd). The map is built at
## runtime by TerrainRuntime as in bench/phone_bench.gd (seed `map_seed`, one
## river, collision on); the player drops in as soon as the ground is ready.
##   godot --path . res://bench/explore.tscn [-- --touch --shot]
## --touch: touch controls on a computer too (to see them), --shot: save
## user://explore.png once the player stands, then quit, --open-world: the
## open world (as `open_world`), --phone-quality: world/phone_quality.gd on a
## computer too (on a phone it is always on: dynamic 3D resolution, no glow,
## no sun shadows: 52-54 fps on a Tecno CL6k).

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const TouchControls = preload("res://player/touch_controls.gd")
const PhoneQuality = preload("res://world/phone_quality.gd")
const PLAYER_SCENE := "res://player/fps_player.tscn"
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"
const OPEN_WORLD_RECIPE := ADDON + "generation/presets/senegal_savanna_open_world_map.tres"
## The open world's game settings (bench/big_world_bench.gd measured them on
## a phone): ground within 160 m, far blocks to 600 m, where the fog of
## world/open_world_sky.tscn is total (it hides their end).
const OPEN_WORLD_GROUND := 160.0
const OPEN_WORLD_FAR := 600.0
const MENU_SCENE := "res://bench/phone_menu.tscn"

## Seed of the map to explore (the menu sets it before opening this scene).
static var map_seed := 7
## Details built around the player only (TerrainRuntime.stream_details).
static var stream := true
## The open world (1024 cells, ~1.5 km) instead of the small map: ground
## streamed around the player (TerrainRuntime.stream_ground).
static var open_world := false

var _terrain: Node3D
var _camera: Camera3D
var _status: Label
var _fps_label: Label
var _quality: PhoneQuality
var _controls: TouchControls

func _process(_delta: float) -> void:
	var scale_text := _quality.scale_text() if _quality != null else ""
	if _fps_label != null:
		_fps_label.text = "%d img/s" % roundi(Engine.get_frames_per_second()) + ("
" + scale_text if scale_text != "" else "")
	if _controls != null:
		_controls.status_text = scale_text

func _ready() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_status = Label.new()
	_status.set_anchors_preset(Control.PRESET_CENTER)
	_status.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_status.grow_vertical = Control.GROW_DIRECTION_BOTH
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var height := float(get_viewport().get_visible_rect().size.y)
	_status.add_theme_font_size_override("font_size", maxi(18, int(height / 22.0)))
	_status.add_theme_color_override("font_outline_color", Color.BLACK)
	_status.add_theme_constant_override("outline_size", maxi(4, int(height / 150.0)))
	if OS.get_cmdline_user_args().has("--open-world"):
		open_world = true
	_status.text = ("Génération du monde ouvert %d…" if open_world else "Génération de la carte %d…") % map_seed
	layer.add_child(_status)
	# Let the text show before the generation (a fraction of a second).
	await get_tree().process_frame
	await get_tree().process_frame

	_terrain = Node3D.new()
	_terrain.name = "LowpolyTerrain"
	add_child(_terrain)
	TerrainData.initialize(_terrain)
	MapGenerator.generate(_terrain, load(OPEN_WORLD_RECIPE if open_world else RECIPE), map_seed)
	var size: float = float(_terrain.get_meta(Meta.WORLD_SIZE))
	if not open_world:
		# One river across the map (the generator draws none).
		var points: Array[Vector2] = []
		for i in 9:
			var t := float(i) / 8.0
			points.append(Vector2(lerpf(-0.42, 0.42, t) * size, sin(t * 5.0) * 0.12 * size + 0.18 * size))
		FeatureStyle.commit(_terrain, FeatureStyle.RIVER, points)
	_terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	_terrain.set_meta(Meta.COLLISION_ENABLED, true)
	add_child((load("res://world/open_world_sky.tscn" if open_world else "res://world/savanna_sky.tscn") as PackedScene).instantiate())
	if OS.has_feature("mobile") or OS.get_cmdline_user_args().has("--phone-quality"):
		_quality = PhoneQuality.new()
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--gpu-target="):
				# A low target makes a computer scale down too (to check it).
				_quality.target_gpu_ms = float(arg.substr(13))
		add_child(_quality)
	# A view over the map while the ground is built. Open world: above the
	# spawn, where the runtime starts its first ring.
	_camera = Camera3D.new()
	_camera.fov = 75.0
	_camera.far = OPEN_WORLD_FAR + 100.0 if open_world else 800.0
	add_child(_camera)
	_camera.current = true
	if open_world:
		_camera.look_at_from_position(Vector3(0, 40, 0), Vector3(0, 0, -60))
	else:
		_camera.look_at_from_position(Vector3(0, 40, size * 0.3), Vector3.ZERO)
	var runtime := TerrainRuntime.new()
	runtime.name = String(Meta.RUNTIME_NODE_NAME)
	# Details built around the player only, following them.
	runtime.stream_details = stream
	if open_world:
		runtime.stream_ground = true
		runtime.ground_distance = OPEN_WORLD_GROUND
		runtime.far_distance = OPEN_WORLD_FAR
	runtime.terrain_ready.connect(_spawn_player)
	runtime.progress.connect(func(done: int, total: int) -> void:
		if _camera != null:
			_status.text = "Chargement %d %%" % roundi(100.0 * done / maxf(total, 1.0)))
	runtime.finished.connect(func(_stats: Dictionary) -> void: _status.text = "")
	_terrain.add_child(runtime)

func _spawn_player() -> void:
	var player := (load(PLAYER_SCENE) as PackedScene).instantiate()
	var touch := OS.has_feature("mobile") or OS.get_cmdline_user_args().has("--touch")
	if touch:
		player.touch_mode = true
	add_child(player)
	if open_world:
		(player as FpsPlayer).camera.far = OPEN_WORLD_FAR + 100.0
	# Drops onto the ground on its first physics frame (snap_to_ground).
	player.global_position = Vector3(0, 80, 0)
	_camera.queue_free()
	_camera = null
	_status.text = ""
	if touch:
		var layer := CanvasLayer.new()
		add_child(layer)
		var controls := TouchControls.new()
		_controls = controls
		controls.player = player
		controls.menu_pressed.connect(func() -> void: get_tree().change_scene_to_file(MENU_SCENE))
		layer.add_child(controls)
	else:
		# Frame rate top right (touch_controls.gd draws it on a phone).
		var fps_layer := CanvasLayer.new()
		add_child(fps_layer)
		_fps_label = Label.new()
		_fps_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
		_fps_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
		_fps_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		_fps_label.offset_left = -220.0
		_fps_label.offset_right = -16.0
		_fps_label.offset_top = 10.0
		var height := float(get_viewport().get_visible_rect().size.y)
		_fps_label.add_theme_font_size_override("font_size", maxi(16, int(height / 28.0)))
		_fps_label.add_theme_color_override("font_outline_color", Color.BLACK)
		_fps_label.add_theme_constant_override("outline_size", 4)
		fps_layer.add_child(_fps_label)
	if OS.get_cmdline_user_args().has("--shot"):
		for i in 90:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://explore.png")
		get_tree().quit()
