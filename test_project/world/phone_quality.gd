extends Node
## Game-side quality for a phone (the plugin stays out of it). Measured on a
## Tecno CL6k, Mali-G57 (results/big_world/README.md, phone_sixty_v1.json):
##   - lighter effects: no glow, no fog aerial perspective (the fog keeps its
##     own colour): -4.4 ms of GPU at 3D scale 0.67, the biggest gain;
##   - no sun shadows (`sun_shadows` off: -2.7 ms, 48 -> 52-54 fps), or
##     lighter ones (`light_shadows`: one split, 1024 map, hard edges,
##     -1.5 ms);
##   - dynamic 3D resolution: the 3D scale follows the GPU time, between
##     `min_scale` and 1.0, so a frame costs about `target_gpu_ms`. Below 0.67
##     it gains nothing there (part of the GPU work does not shrink with the
##     pixels, and the GPU clocks down when it has room);
##   - frame rate capped at `max_fps` (battery, steady frames).
## Add it to the scene once the sky is in (it changes its DirectionalLight3D
## and WorldEnvironment). `scale_text()` says the current 3D scale, for an
## on-screen counter.

## GPU time aimed at (ms): under 16.6 ms leaves room for the CPU side.
@export var target_gpu_ms := 15.0
@export_range(0.3, 1.0, 0.05) var min_scale := 0.67
## Sun shadows at all (off on a phone: the GPU cost that matters most).
@export var sun_shadows := false
## When `sun_shadows` is on: lighter ones.
@export var light_shadows := true
@export var light_effects := true
@export var max_fps := 60

var _viewport_rid: RID
var _gpu_sum := 0.0
var _frames := 0
var _elapsed := 0.0
var _calm := 0.0

func _ready() -> void:
	var viewport := get_viewport()
	_viewport_rid = viewport.get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)
	viewport.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	Engine.max_fps = max_fps
	if not sun_shadows:
		for node in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
			(node as DirectionalLight3D).shadow_enabled = false
	elif light_shadows:
		RenderingServer.directional_shadow_atlas_set_size(1024, true)
		RenderingServer.directional_soft_shadow_filter_set_quality(RenderingServer.SHADOW_QUALITY_HARD)
		for node in get_tree().root.find_children("*", "DirectionalLight3D", true, false):
			(node as DirectionalLight3D).directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	if light_effects:
		for node in get_tree().root.find_children("*", "WorldEnvironment", true, false):
			var world := node as WorldEnvironment
			if world.environment == null:
				continue
			# A copy: the Environment resource on disk stays as it is.
			var environment: Environment = world.environment.duplicate()
			environment.glow_enabled = false
			environment.fog_aerial_perspective = 0.0
			world.environment = environment

func _process(delta: float) -> void:
	_gpu_sum += RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
	_frames += 1
	_elapsed += delta
	# Every half second, from the mean GPU time of that half second.
	if _elapsed < 0.5:
		return
	var gpu := _gpu_sum / maxf(float(_frames), 1.0)
	_gpu_sum = 0.0
	_frames = 0
	_elapsed = 0.0
	if gpu <= 0.0:
		return
	var viewport := get_viewport()
	var scale := viewport.scaling_3d_scale
	if gpu > target_gpu_ms * 1.05:
		# Pixels ~ scale^2, but part of the cost does not shrink with them:
		# half the step a pure pixel cost would ask for.
		var wanted := scale * sqrt(target_gpu_ms / gpu)
		scale = maxf(min_scale, scale - maxf((scale - wanted) * 0.5, 0.02))
		_calm = 0.0
	elif gpu < target_gpu_ms * 0.8:
		# Up again slowly, after 2 s with room to spare (no back and forth).
		_calm += 0.5
		if _calm >= 2.0:
			scale = minf(1.0, scale + 0.05)
			_calm = 0.0
	else:
		_calm = 0.0
	viewport.scaling_3d_scale = snappedf(scale, 0.01)

## "3D 72 %": the current 3D scale.
func scale_text() -> String:
	return "3D %d %%" % roundi(get_viewport().scaling_3d_scale * 100.0)
