@tool
class_name LowpolyTerrainRuntime
extends Node
## In-game companion of a Lowpoly terrain (child of the terrain Node3D).
##
## When the game starts it builds what the scene file does not contain:
##   - a whole new map from `recipe` + `map_seed` when `generate_map` is on;
##   - the details (and/or meshes) the terrain chose not to save
##     (Inspector > Map Generator / Runtime > Runtime Build);
##   - the trunk / mound collision of the detail layers (collision_radius).
## The work is spread over several frames (`frame_budget_ms`), nearest chunks
## first, so the game does not freeze while loading.
##
## Spawn the player on `terrain_ready` (ground + ground collision exist), the
## rest keeps streaming in until `finished`.
##
## `stream_details`: each detail layer is only built on the chunks within its
## draw distance of the camera (or `stream_focus`), and freed again past it
## (+ `unload_margin`), as the player moves. `finished` then means the details
## around the start position are built; the rest follows the player in
## `stream_budget_ms` per frame. Trunk collision only within
## `collision_distance`. Only when the runtime builds the details (not when
## they are saved in the scene); the public rebuild_* calls bypass it.
##
## `stream_ground` (big maps, e.g. 1024 cells): the ground chunks, their
## collision and the waterholes are streamed the same way, within
## `ground_distance` (collision within `ground_collision_distance`). The faces
## of a chunk are computed on worker threads (`ground_threads`); only the mesh
## is made on the main thread. Roads and rivers are cut by chunk (on worker
## threads too): each piece is a child of its chunk (`ROADS_NAME`), shown and
## freed with it, its faces in the chunk's collision; the terrain's single
## road / river mesh stays empty. It streams the details too. `terrain_ready`
## means the ground within `ready_distance` of the start position is built
## with its collision; the rest of `ground_distance` and the far blocks come
## while the game runs. Only when the runtime builds the ground (a generated
## map, or Runtime Build = All).
##
## In the editor it only rebuilds what the scene did not save, so the terrain
## looks the same as when it was saved. A terrain too big to build whole
## (TerrainBuilder.streams_in_editor) is built around the editor camera the
## same way as stream_ground (start_editor_stream); the editor's edits reach
## it through the editor_* calls (TerrainBuilder routes them).

const Meta = preload("../core/terrain_meta.gd")
const TerrainData = preload("../core/terrain_data.gd")
const StylePalette = preload("../styles/style_palette.gd")
const TerrainBuilder = preload("../mesh/terrain_builder.gd")
const TerrainMesher = preload("../mesh/terrain_mesher.gd")
const DetailScatter = preload("../mesh/detail_scatter.gd")
const DetailCollision = preload("../mesh/detail_collision.gd")
const MapGenerator = preload("../generation/map_generator.gd")
const WaterholeStyle = preload("../styles/waterhole_style.gd")
const WaterholeMesher = preload("../mesh/waterhole_mesher.gd")
const LodMesher = preload("../mesh/lod_mesher.gd")
const FeatureMesher = preload("../mesh/feature_mesher.gd")
const MeshUtils = preload("../mesh/mesh_utils.gd")
const TerrainStorage = preload("../core/terrain_storage.gd")
const TerrainShading = preload("../mesh/terrain_shading.gd")

## Ground collision built in game: one concave shape per chunk (shape owners
## of one StaticBody3D), so no single build step stalls a frame.
const GROUND_COLLISION_NAME := "_RuntimeGroundCollision"
## stream_ground: each chunk's ground collision body, child of the chunk.
const CHUNK_COLLISION_NAME := "_GroundCollision"
## stream_ground: worker threads computing chunk faces once loaded (while
## loading: one per core but one).
const STREAM_TASKS := 1
## stream_ground (game): a chunk's piece of the roads and rivers.
const ROADS_NAME := "_Roads"
## stream_ground: container of the low-detail blocks (far_distance).
const FAR_GROUND_NAME := "_FarGround"
## Ground colours kept for the details (when the ground is not built here):
## the last chunks whose details were built, for their next layers.
const SHADING_CACHE_SIZE := 12

## Ground + ground collision are built: safe to spawn the player.
signal terrain_ready
## `done` of `total` build steps finished.
signal progress(done: int, total: int)
## Everything is built. Stats: {seed, steps, ms, detail_shapes, worst_step_ms,
## map: {...} (MapGenerator stats when a map was generated)}.
signal finished(stats: Dictionary)
## stream_details: the detail layers (or trunk collision) of a chunk were
## built or freed.
signal chunk_details_changed(chunk_x: int, chunk_z: int)

## Terrain to build. Empty = the parent node.
@export var terrain: Node3D

@export_group("Map Generator")
## Replace the saved map by a new one made from `recipe` + `map_seed` when the
## game starts (roguelike / procedural levels).
@export var generate_map := false
@export var recipe: LowpolyMapRecipe
@export var map_seed := 0
## Pick a new seed every run (the seed used is in `used_seed` / `finished`).
@export var random_seed := false

@export_group("Build")
## Spread the work over several frames instead of building in one go.
@export var progressive := true
## Work done per frame when progressive (ms).
@export_range(1.0, 100.0, 0.5) var frame_budget_ms := 6.0
## ... until `terrain_ready` (ms): the player is not in yet, a loading view
## can run slower and the ground comes sooner (Tecno phone, 1.5 km open
## world: a frame takes ~45 ms there; terrain_ready after 11.5 s with 6 ms of
## building a frame, 5.4 s with 25 ms). 0 = `frame_budget_ms`.
@export_range(0.0, 200.0, 0.5) var ready_budget_ms := 25.0
## Trunk / mound collision of the detail layers that have collision_radius > 0.
@export var detail_collision := true
## Start building in _ready. Off = call build() yourself (e.g. after picking
## a seed from a menu).
@export var build_on_ready := true

@export_group("Streaming")
## Build each detail layer only on the chunks within its draw distance of the
## camera, and free it again further away, as the player moves (big maps,
## phones). On by default. Off = every detail of every chunk is built at load.
@export var stream_details := true
## Centre of the streaming. Empty = the current camera.
@export var stream_focus: Node3D
## A layer is built when the nearest point of a chunk is closer than its draw
## distance + this (m): built before it can show, even when walking fast.
@export_range(0.0, 200.0, 1.0, "suffix:m") var stream_margin := 16.0
## ... and freed past its draw distance + this (m). Larger than
## `stream_margin`, so walking along a chunk border does not build and free
## it over and over.
@export_range(0.0, 400.0, 1.0, "suffix:m") var unload_margin := 48.0
## Trunk / mound collision only on the chunks this close (m).
@export_range(0.0, 1000.0, 1.0, "suffix:m") var collision_distance := 48.0
## Work done per frame once loaded (ms): smaller than `frame_budget_ms`, the
## game is running.
@export_range(0.5, 50.0, 0.5) var stream_budget_ms := 2.5
## Build the ground only around the camera (or `stream_focus`), and free it
## past `ground_distance` + `unload_margin`. For big maps. Streams the
## details too.
@export var stream_ground := false
## Ground chunks are built within this distance (+ `stream_margin`).
@export_range(32.0, 4000.0, 1.0, "suffix:m") var ground_distance := 250.0
## Ground collision only within this distance, one shape per chunk.
@export_range(0.0, 1000.0, 1.0, "suffix:m") var ground_collision_distance := 96.0
## `terrain_ready` once the ground within this distance of the start is
## built (with its collision): the player can come in while the rest of
## `ground_distance` is still being built. 0 = wait for all of it.
@export_range(0.0, 4000.0, 1.0, "suffix:m") var ready_distance := 96.0
## Compute the faces of the streamed chunks on worker threads. Off: on the
## main thread, one chunk at a time (15 to 30 ms each on a laptop).
@export var ground_threads := true
## Low-detail ground past `ground_distance`, up to this distance: blocks of
## 4 x 4 chunks with one vertex in `far_step`, one draw call each, no
## collision or details. 0 = nothing past `ground_distance`.
@export_range(0.0, 8000.0, 1.0, "suffix:m") var far_distance := 1000.0
## Vertices kept in the far blocks: one in 2, 4 or 8 per side.
@export_range(2, 8, 2) var far_step := 4

## Seed of the last generated map.
var used_seed := 0
var is_ground_ready := false
var is_finished := false
## stream_details: nothing left to build or free around the focus.
var is_streaming_idle := true

var _builder: TerrainBuilder
var _terrain: Node3D
var _steps: Array[Callable] = []
var _done := 0
var _ground_steps := 0
var _started_us := 0
var _shape_cache: Dictionary = {}
var _detail_shapes := 0
var _map_stats: Dictionary = {}
var _worst_step_ms := 0.0
var _worst_step := -1
## Terrain arrays moved into the packed block while the scene is saved.
var _saved_arrays: Dictionary = {}
var _saved_terrain: Node3D = null
## Streaming (stream_details).
var _streaming := false
var _radii := PackedFloat32Array()
var _collision_layers := 0
var _with_collision := false
var _chunk_count := 0
var _chunk_world := 32.0
var _half := 0.0
## Vector2i chunk -> layer mask (DetailScatter.layer_bit) of the built layers.
var _built: Dictionary = {}
## Vector2i chunk -> layer mask its trunk collision was built from.
var _collided: Dictionary = {}
## [distance, Vector2i chunk, layer mask (0 = collision)], nearest first.
var _stream_queue: Array = []
## Chunk being built: {chunk, mask, job}.
var _stream_job: Dictionary = {}
var _last_focus := Vector2(INF, INF)
## Chunk nodes by index (z * _chunk_count + x), looked up by name once:
## _retarget() goes over every chunk 4 times a second.
var _chunk_nodes: Array = []
var _retarget_in := 0.0
## Vector2i chunk -> its ground colours for the details (top_faces()), or
## null when the ground has none (shading off). Every chunk when the ground
## was built here (~32 KB a chunk), else the last SHADING_CACHE_SIZE.
var _shading_cache: Dictionary = {}
var _keep_all_shading := false

# stream_ground state.
var _ground_streaming := false
var _ground_collision := false
var _ground_focus := Vector2.ZERO
## Vector2i -> true: ground chunks built.
var _ground: Dictionary = {}
## [distance, Vector2i] chunks to build, nearest first.
var _ground_queue: Array = []
## Vector2i chunk or int waterhole -> [task id, [result], snapshot Node3D].
var _ground_tasks: Dictionary = {}
## Road / river jobs on worker threads (FeatureMesher.start_threaded), waited
## for when the runtime goes.
var _feature_jobs: Array[Dictionary] = []
## stream_ground in game: roads and rivers cut by chunk (FeatureMesher split
## job): chunk -> Array of [material, vertices, normals, uvs], chunk ->
## collision faces, and the built chunks still waiting for their piece.
var _split_features := false
## stream_ground: collision faces of the built chunks, made on the worker
## with their mesh (no get_faces() read back on the main thread).
var _chunk_face_cache: Dictionary = {}
var _road_pieces: Dictionary = {}
var _road_faces: Dictionary = {}
var _road_queue: Array = []
## Vector2i -> the chunk's ground collision body (CHUNK_COLLISION_NAME).
var _ground_shapes: Dictionary = {}
## [distance, Vector2i] chunks waiting for their collision shape.
var _shape_queue: Array = []
var _ground_carve := PackedFloat32Array()
var _max_tasks := 1
## Waterhole bounds (terrain-local), those built (index -> true) and those to
## build ([distance, index]).
var _hole_bounds: Array[Rect2] = []
var _holes: Dictionary = {}
var _hole_queue: Array = []
## Far blocks (Vector2i): their node, the chunks left out of their mesh (a
## LodMesher chunk_bit mask), their coarse grid (made once), and those to
## build ([distance, block]). Chunks leaving the detailed ring wait in
## `_leaving` for their block to cover them before they are freed.
var _far_on := false
var _far_blocks: Dictionary = {}
var _far_masks: Dictionary = {}
var _far_data: Dictionary = {}
var _far_queue: Array = []
var _leaving: Dictionary = {}
## Far blocks whose data changed (editor edits): rebuilt even when their
## mask is right.
var _far_dirty: Dictionary = {}

# Editor streaming (start_editor_stream).
var _editor_stream := false
## The editor plugin's builder once it took the terrain: its river carve
## follows the edits.
var _shared_builder: TerrainBuilder = null
## Task keys started before the terrain data changed: their result is
## dropped (the key is queued again).
var _stale: Dictionary = {}
## Chunks whose collision shape no longer matches their mesh (edits).
var _shape_dirty: Dictionary = {}

## The terrain data is packed in the scene file (core/terrain_storage.gd):
## decode it before anything reads it, editor and game alike.
func _enter_tree() -> void:
	TerrainStorage.unpack(_target())

func _notification(what: int) -> void:
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		_saved_terrain = _target()
		_saved_arrays = TerrainStorage.pack(_saved_terrain)
	elif what == NOTIFICATION_EDITOR_POST_SAVE:
		TerrainStorage.restore(_saved_terrain, _saved_arrays)
		_saved_arrays = {}
		_saved_terrain = null
	elif what == NOTIFICATION_PREDELETE:
		# A worker thread may still read a snapshot.
		_drain_ground_tasks()

func _target() -> Node3D:
	return terrain if terrain != null else get_parent() as Node3D

func _ready() -> void:
	# Saved meshes keep the material they were built with: give them the
	# current one (wind on grass, shrubs and trees; Custom Materials).
	var t := _target()
	if t != null and Meta.is_terrain(t):
		TerrainBuilder.refresh_materials(t)
	if Engine.is_editor_hint():
		_editor_restore.call_deferred()
		return
	set_process(false)
	if build_on_ready:
		build.call_deferred()

## Builds (or rebuilds) the terrain. `new_seed` >= 0 overrides `map_seed` for a
## generated map. Returns false when there is no terrain to build.
func build(new_seed: int = -1) -> bool:
	_terrain = terrain if terrain != null else get_parent() as Node3D
	if _terrain == null or (not generate_map and not Meta.is_terrain(_terrain)):
		push_warning("LowpolyTerrainRuntime: no Lowpoly terrain to build (set `terrain` or make this node a child of one).")
		return false
	_reset_build_state()

	var rebuild_ground := false
	var rebuild_details := false
	if generate_map and recipe != null and not _editor_stream:
		used_seed = new_seed if new_seed >= 0 else (randi() & 0x7FFFFFFF if random_seed else map_seed)
		_map_stats = MapGenerator.generate(_terrain, recipe, used_seed)
		_clear_generated(_terrain)
		rebuild_ground = true
	else:
		used_seed = Meta.get_int(_terrain, Meta.DETAIL_SEED, 0)
		TerrainData.ensure_defaults(_terrain)
		var mode := TerrainBuilder.runtime_build(_terrain)
		rebuild_ground = mode == Meta.RUNTIME_BUILD_ALL or _terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME) == null
		rebuild_details = mode == Meta.RUNTIME_BUILD_DETAILS or not _has_details(_terrain)
	var with_collision := detail_collision and DetailCollision.has_collision_layers(_terrain) and not _editor_stream
	_ground_streaming = (stream_ground or _editor_stream) and rebuild_ground

	var order := _chunks_by_distance(_terrain)
	if rebuild_ground:
		_queue_ground_steps(order)
		rebuild_details = true
	_ground_steps = _steps.size()
	if _ground_steps == 0:
		# Ground (and its collision) saved in the scene: ready now, not after
		# every detail step. Deferred, so a script connecting to the signal
		# right after build() still gets it.
		_ground_ready.call_deferred()
	if rebuild_details:
		_queue_detail_steps(order, with_collision)
	elif with_collision:
		# Details saved in the scene: their trunk collision is still built.
		for c in order:
			_steps.append(_build_chunk_collision.bind(c.x, c.y))
	if _ground_streaming and _far_on:
		# The horizon (far blocks) last: `finished` waits for it.
		_steps.append(func() -> bool: return _pump_ground(_slice_usec()))

	if progressive:
		set_process(true)
		_run(_build_budget_ms())
	else:
		_run(INF)
	return true

## Forgets the previous build (a new build() starts from scratch).
func _reset_build_state() -> void:
	_builder = _shared_builder if _shared_builder != null else TerrainBuilder.new()
	_steps.clear()
	_done = 0
	_shape_cache.clear()
	_detail_shapes = 0
	_map_stats = {}
	_worst_step_ms = 0.0
	_worst_step = -1
	is_ground_ready = false
	is_finished = false
	_started_us = Time.get_ticks_usec()
	_streaming = false
	_built.clear()
	_collided.clear()
	_stream_queue.clear()
	_drop_stream_job()
	_last_focus = Vector2(INF, INF)
	_shading_cache.clear()
	_keep_all_shading = false
	is_streaming_idle = true
	_drain_ground_tasks()
	_ground_streaming = false
	_ground.clear()
	_ground_queue.clear()
	_ground_shapes.clear()
	_shape_queue.clear()
	_holes.clear()
	_hole_queue.clear()
	_hole_bounds.clear()
	_ground_carve = PackedFloat32Array()
	_split_features = false
	_chunk_face_cache.clear()
	_road_pieces.clear()
	_road_faces.clear()
	_road_queue.clear()
	_far_on = false
	_far_blocks.clear()
	_far_masks.clear()
	_far_data.clear()
	_far_queue.clear()
	_leaving.clear()
	_far_dirty.clear()
	_stale.clear()
	_shape_dirty.clear()

## Load steps of the ground, nearest chunk first: chunk meshes, waterholes,
## roads and rivers, then the ground collision.
func _queue_ground_steps(order: Array[Vector2i]) -> void:
	_ensure_feature_node(_terrain)
	_steps.append(func() -> void:
		StylePalette.ensure_material_data(_terrain)
		_builder.rebuild_river_carve(_terrain)
		_builder._ensure_chunk_container(_terrain))
	# Shaders compile once, each in a step of its own (~25 ms each on a
	# laptop), not in the frame of the first mesh that uses them.
	_steps.append(TerrainBuilder.warm_ground_material.bind(_terrain))
	var feature_job: Array[Dictionary] = [{}]
	# Roads and rivers of a big map (~1 s of work on a laptop for 1.5 km,
	# ~5 s on a phone): each group on a worker thread, all at once, once the
	# ground near the start is built (before, they would hold its threads).
	var threaded_features := _ground_streaming and ground_threads and progressive
	# In game, cut by chunk: each piece comes and goes with its chunk.
	_split_features = threaded_features and not _editor_stream
	# The ground colours of each chunk are made for its mesh: kept for its
	# details (~6 ms a chunk on a laptop not made twice).
	_keep_all_shading = true
	var collision := Meta.get_bool(_terrain, Meta.COLLISION_ENABLED, false)
	if _ground_streaming:
		_queue_ground_stream_start(collision)
	else:
		for c in order:
			_steps.append(func() -> void:
				var parts: Dictionary = _builder.rebuild_chunk(_terrain, c.x, c.y, false)
				_keep_shading(c, parts.get("shading")))
		for i in range(WaterholeStyle.list(_terrain).size()):
			_steps.append(_builder.rebuild_waterhole.bind(_terrain, i))
	var feature_faces: Array[PackedVector3Array] = [PackedVector3Array()]
	# Roads and rivers in slices of the frame budget: a big road network
	# would stall one frame (~200 ms on a laptop for a 128 m savanna).
	_steps.append_array(TerrainBuilder.feature_material_warmups(_terrain))
	_steps.append(func() -> bool:
		if feature_job[0].is_empty():
			if threaded_features:
				feature_job[0] = _builder.start_feature_mesh_threaded(_terrain, _split_features)
				_feature_jobs.append(feature_job[0])
			else:
				feature_job[0] = _builder.start_feature_mesh(_terrain)
		if not _builder.step_feature_mesh(feature_job[0], _slice_usec()):
			return false
		if _split_features:
			_take_road_pieces(feature_job[0])
		else:
			feature_faces[0] = _builder.finish_feature_mesh(_terrain, feature_job[0])
		_feature_jobs.erase(feature_job[0])
		feature_job[0] = {}
		return true)
	if collision:
		if not _ground_streaming:
			_steps.append(_reset_ground_collision)
			for c in order:
				_steps.append(func() -> void: _add_ground_shape(_chunk_faces(c.x, c.y)))
		_steps.append(func() -> void: _add_ground_shape(feature_faces[0]))

## Load steps of the details (all of them, or the start ring when
## streaming) and of the tree trunk collision.
func _queue_detail_steps(order: Array[Vector2i], with_collision: bool) -> void:
	# Detail shaders and meshes are made once, each in a step of its own.
	_steps.append_array(DetailScatter.warmups(_terrain))
	if stream_details or _ground_streaming:
		_queue_stream_start(order, with_collision)
		return
	for c in order:
		_steps.append(_chunk_details_step(c))
		if with_collision:
			_steps.append(_build_chunk_collision.bind(c.x, c.y))

func _process(delta: float) -> void:
	if Engine.is_editor_hint() and not _editor_stream:
		set_process(false)
		return
	if not is_finished:
		_run(_build_budget_ms())
	elif _streaming:
		_stream(delta)

func _run(budget_ms: float) -> void:
	var start := Time.get_ticks_usec()
	# The player is in: the ground past ready_distance and the far blocks
	# keep coming during the detail steps (half of the frame budget).
	if _ground_streaming and is_ground_ready and progressive:
		_pump_ground(maxi(int(budget_ms * 500.0), 1))
	while _done < _steps.size():
		var step_start := Time.get_ticks_usec()
		# A step returning false is not finished: called again next frame.
		var finished_step: Variant = _steps[_done].call()
		var step_ms := (Time.get_ticks_usec() - step_start) / 1000.0
		if step_ms > _worst_step_ms:
			_worst_step_ms = step_ms
			_worst_step = _done
		if finished_step is bool and not finished_step:
			break
		_done += 1
		if _done == _ground_steps:
			_ground_ready()
		if float(Time.get_ticks_usec() - start) / 1000.0 >= budget_ms:
			break
	progress.emit(_done, _steps.size())
	if _done >= _steps.size():
		# Streaming: keeps following the focus.
		set_process(_streaming)
		if _ground_streaming:
			# The ground colours stay kept for every built chunk (freed with
			# it, ~32 KB a chunk): its layers come at different distances,
			# each one would make them again (20 to 100 ms on a laptop).
			# In game, a few threads only: more would take the CPU from the
			# main thread (the frame), not make the ground come faster.
			# The editor uses half the cores: the camera flies fast there.
			_max_tasks = mini(_max_tasks, maxi(OS.get_processor_count() / 2, 1) if _editor_stream else STREAM_TASKS)
		if not is_ground_ready:
			_ground_ready()
		is_finished = true
		finished.emit({
			"seed": used_seed,
			"steps": _steps.size(),
			"ms": (Time.get_ticks_usec() - _started_us) / 1000.0,
			"detail_shapes": _detail_shapes,
			"worst_step_ms": _worst_step_ms,
			"worst_step": _worst_step,
			"map": _map_stats,
		})
		_steps.clear()

## A chunk's details as a step in slices of the frame budget (~25 ms in one
## go on a laptop for a 32 x 32-cell savanna chunk). `mask`: only these
## layers (DetailScatter.layer_bit), -1 = all.
func _chunk_details_step(c: Vector2i, mask: int = -1) -> Callable:
	var job: Array[Dictionary] = [{}]
	return func() -> bool:
		if _ground_streaming and not _ground.has(c):
			return true
		if job[0].is_empty():
			var shading: TerrainShading.Context = _shading_cache.get(c)
			job[0] = _builder.start_chunk_details(_terrain, c.x, c.y, mask, shading)
		if not _builder.step_chunk_details(job[0], _slice_usec()):
			return false
		_builder.finish_chunk_details(job[0])
		if _streaming:
			var built_mask: int = _built.get(c, 0)
			_built[c] = built_mask | mask
			_keep_shading(c, job[0].get("shading"))
		else:
			# Built once: no need to keep them.
			_shading_cache.erase(c)
		return true

# -----------------------------------------------------------------------------
# Streaming (stream_details)
# -----------------------------------------------------------------------------

## Load steps of the streaming: the layers wanted around the start position
## only (nearest chunks first), then _stream() follows the focus.
func _queue_stream_start(order: Array[Vector2i], with_collision: bool) -> void:
	_streaming = true
	_radii = DetailScatter.layer_radii(_terrain)
	if _ground_streaming:
		# No details where there is no ground.
		for i in range(1, _radii.size()):
			_radii[i] = minf(_radii[i], ground_distance)
	_collision_layers = 0
	var biome := DetailScatter.biome_of(_terrain)
	for i in range(1, _radii.size()):
		var layer := biome.detail_layers[i - 1]
		if _radii[i] >= 0.0 and float(layer.collision_radius) > 0.0:
			_collision_layers |= DetailScatter.layer_bit(i)
	_with_collision = with_collision
	if not _ground_streaming:
		_setup_stream_grid()
	var focus: Variant = _focus_xz()
	var at: Vector2 = focus if focus != null else Vector2.ZERO
	# Details already under the chunks (a scene that saved them) past their
	# distance are freed: only what the streaming built is there.
	_steps.append(func() -> void:
		for c in order:
			var chunk := _chunk_node(c)
			if chunk:
				DetailScatter.clear_layers(chunk, ~_layers_within(_chunk_distance(c, at), stream_margin))
				DetailCollision.clear_chunk(chunk))
	for c in order:
		var distance := _chunk_distance(c, at)
		var mask := _layers_within(distance, stream_margin)
		if mask != 0:
			_steps.append(_chunk_details_step(c, mask))
		if with_collision and distance <= collision_distance and (mask & _collision_layers) != 0:
			_steps.append(_stream_collision.bind(c))

## Chunk grid of the streaming (count, chunk size, cached chunk nodes).
func _setup_stream_grid() -> void:
	_chunk_count = TerrainMesher.chunk_count(_terrain)
	_chunk_nodes.clear()
	_chunk_nodes.resize(_chunk_count * _chunk_count)
	var resolution: int = Meta.get_int(_terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(_terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	_chunk_world = world_size / float(maxi(resolution - 1, 1)) * float(Meta.TERRAIN_CHUNK_CELLS)
	_half = world_size * 0.5

## Streaming once loaded: frees what the focus left behind and builds what
## it came near, in `stream_budget_ms` per frame.
func _stream(delta: float) -> void:
	var start := Time.get_ticks_usec()
	var budget := int((frame_budget_ms if _editor_stream else stream_budget_ms) * 1000.0)
	var focus: Variant = _focus_xz()
	if focus == null:
		return
	var focus_point: Vector2 = focus
	_retarget_in -= delta
	# Every quarter second, or at once when the focus moved far (teleport).
	if _retarget_in <= 0.0 or focus_point.distance_to(_last_focus) > _chunk_world * 0.25:
		_retarget(focus_point)
	var ground_idle := true
	if _ground_streaming:
		ground_idle = _pump_ground(maxi(budget, 1))
	while Time.get_ticks_usec() - start < budget:
		if _stream_job.is_empty():
			if _stream_queue.is_empty():
				break
			var entry: Array = _stream_queue.pop_front()
			var c: Vector2i = entry[1]
			var mask: int = entry[2]
			if mask == 0:
				# Trunk collision, sliced like the details.
				var collision_chunk := _chunk_node(c)
				if collision_chunk == null:
					continue
				_stream_job = {"chunk": c, "mask": 0, "built": _built.get(c, 0),
					"collision": DetailCollision.begin_chunk(_terrain, collision_chunk)}
			else:
				var shading: TerrainShading.Context = _shading_cache.get(c)
				_stream_job = {"chunk": c, "mask": mask, "job": _builder.start_chunk_details(_terrain, c.x, c.y, mask, shading)}
		var left := budget - (Time.get_ticks_usec() - start)
		if _stream_job.has("collision"):
			var collision_job: Dictionary = _stream_job["collision"]
			if not DetailCollision.step_chunk(collision_job, _shape_cache, maxi(left, 1)):
				break
			var collided_chunk: Vector2i = _stream_job["chunk"]
			_detail_shapes += DetailCollision.finish_chunk(collision_job)
			var built_then: int = _stream_job["built"]
			_collided[collided_chunk] = built_then & _collision_layers
			_stream_job = {}
			chunk_details_changed.emit(collided_chunk.x, collided_chunk.y)
			continue
		var job: Dictionary = _stream_job["job"]
		if not _builder.step_chunk_details(job, maxi(left, 1)):
			break
		var done_chunk: Vector2i = _stream_job["chunk"]
		_builder.finish_chunk_details(job)
		_keep_shading(done_chunk, job.get("shading"))
		var built_mask: int = _built.get(done_chunk, 0)
		var job_mask: int = _stream_job["mask"]
		_built[done_chunk] = built_mask | job_mask
		_stream_job = {}
		chunk_details_changed.emit(done_chunk.x, done_chunk.y)
		# Its trunk collision can come next.
		_retarget_in = 0.0
		# The next chunk starts with its ground colours (~7 ms on a laptop in
		# one go): not in the frame that just made this one's MultiMeshes.
		break
	is_streaming_idle = ground_idle and _stream_queue.is_empty() and _stream_job.is_empty()

## Frees the layers past their distance and queues the missing ones, nearest
## chunk first.
func _retarget(focus: Vector2) -> void:
	_last_focus = focus
	_retarget_in = 0.25
	_stream_queue.clear()
	if _ground_streaming:
		_retarget_ground(focus)
	var job_chunk := Vector2i(-1, -1)
	var job_mask := 0
	var job_collision := _stream_job.has("collision")
	if not _stream_job.is_empty():
		job_chunk = _stream_job["chunk"]
		job_mask = _stream_job["mask"]
	# Streamed ground: only its built chunks can hold details.
	var candidates: Array = _ground.keys() if _ground_streaming else _all_chunks()
	for candidate: Vector2i in candidates:
		var c := candidate
		var x := c.x
		var z := c.y
		var chunk := _chunk_node(c)
		if chunk == null:
			continue
		var distance := _chunk_distance(c, focus)
		var built: int = _built.get(c, 0)
		var keep := _layers_within(distance, unload_margin)
		var drop := built & ~keep
		if drop != 0:
			DetailScatter.clear_layers(chunk, drop)
			built &= ~drop
			_built[c] = built
			chunk_details_changed.emit(x, z)
		var want := _layers_within(distance, stream_margin) & ~built
		if want != 0:
			# With the layers about to be wanted too: one job (one ground
			# colour pass) instead of one per layer.
			want |= _layers_within(distance, (stream_margin + unload_margin) * 0.5) & ~built
		if c == job_chunk and not job_collision:
			if (keep & job_mask) == 0:
				# Not wanted any more (the player turned back, teleport).
				_drop_stream_job()
			else:
				want &= ~job_mask
		if want != 0:
			_stream_queue.append([distance, c, want])
		if not _with_collision:
			continue
		if distance > collision_distance + unload_margin:
			if c == job_chunk and job_collision:
				_drop_stream_job()
			if _collided.has(c):
				DetailCollision.clear_chunk(chunk)
				_collided.erase(c)
				chunk_details_changed.emit(x, z)
		elif distance <= collision_distance and (want & _collision_layers) == 0 and c != job_chunk:
			# Built from the collision layers there now (again when they
			# changed).
			var collided_mask: int = _collided.get(c, -1)
			if collided_mask != (built & _collision_layers):
				_stream_queue.append([distance, c, 0])
	_stream_queue.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])
	is_streaming_idle = _stream_queue.is_empty() and _stream_job.is_empty()

## Every chunk of the grid, row by row.
func _all_chunks() -> Array:
	var chunks: Array = []
	for z in range(_chunk_count):
		for x in range(_chunk_count):
			chunks.append(Vector2i(x, z))
	return chunks

# -----------------------------------------------------------------------------
# Ground streaming (stream_ground)
# -----------------------------------------------------------------------------

## Load steps of the streamed ground: the ring around the start position
## (chunks, their collision, waterholes), worker threads computing the faces.
func _queue_ground_stream_start(collision: bool) -> void:
	_setup_stream_grid()
	_ground_collision = collision
	_max_tasks = clampi(OS.get_processor_count() - 1, 1, 8) if ground_threads else 0
	_far_on = far_distance > ground_distance
	var focus: Variant = _focus_xz()
	var at: Vector2 = focus if focus != null else Vector2.ZERO
	_steps.append(func() -> void:
		_ground_carve = _builder.get_river_carve(_terrain)
		TerrainMesher.prepare_threads(_terrain)
		var holes := WaterholeStyle.list(_terrain)
		for i in range(holes.size()):
			_hole_bounds.append(WaterholeStyle.bounds_of(_terrain, i))
		if _ground_collision:
			_reset_ground_collision()
		_retarget_ground(at))
	# Not finished (false) until the ground within ready_distance is built:
	# called again next frame. The rest of the ring and the far blocks come
	# with the next steps (_run): terrain_ready does not wait for the
	# horizon (~100 ms of thread time a block).
	_steps.append(func() -> bool: return _pump_ground(_slice_usec(), false) or _near_ground_built())

## Frees the ground the focus left behind (chunks with their details,
## collision shapes, waterholes) and queues what it came near, nearest first.
func _retarget_ground(focus: Vector2) -> void:
	_ground_focus = focus
	var build_distance := ground_distance + stream_margin
	var free_distance := ground_distance + unload_margin
	for key: Vector2i in _ground.keys():
		var distance := _chunk_distance(key, focus)
		if distance > free_distance:
			# Freed once its far block covers it (no hole meanwhile).
			if _far_blocks.has(_block_of(key)):
				_leaving[key] = true
			else:
				_free_ground(key)
			continue
		_leaving.erase(key)
		if _ground_collision and _ground_shapes.has(key) and distance > ground_collision_distance + unload_margin:
			_remove_chunk_shape(key)
	_ground_queue.clear()
	_shape_queue.clear()
	# Only the chunks of the square around the focus can be wanted.
	var reach := int(ceilf(build_distance / _chunk_world)) + 1
	var centre := Vector2i(floori((focus.x + _half) / _chunk_world), floori((focus.y + _half) / _chunk_world))
	for z in range(maxi(centre.y - reach, 0), mini(centre.y + reach + 1, _chunk_count)):
		for x in range(maxi(centre.x - reach, 0), mini(centre.x + reach + 1, _chunk_count)):
			var c := Vector2i(x, z)
			var distance := _chunk_distance(c, focus)
			if _ground.has(c):
				if _ground_collision and distance <= ground_collision_distance and not _ground_shapes.has(c) and not _leaving.has(c):
					_shape_queue.append([distance, c])
			elif distance <= build_distance and not _ground_tasks.has(c):
				_ground_queue.append([distance, c])
	var nearest_first := func(a: Array, b: Array) -> bool: return a[0] < b[0]
	_ground_queue.sort_custom(nearest_first)
	_shape_queue.sort_custom(nearest_first)
	_hole_queue.clear()
	for i in range(_hole_bounds.size()):
		var bounds := _hole_bounds[i]
		var distance := focus.clamp(bounds.position, bounds.end).distance_to(focus)
		if _holes.has(i):
			if distance > free_distance:
				_free_waterhole(i)
		elif distance <= build_distance:
			if not _ground_tasks.has(i):
				_hole_queue.append([distance, i])
		elif _editor_stream:
			# Edited out of range: its old plates go.
			_free_waterhole(i)
	_hole_queue.sort_custom(nearest_first)
	if _far_on:
		_retarget_far(focus)

## Far blocks: frees those past far_distance + unload_margin, queues those
## in range whose mesh does not leave out exactly the detailed chunks.
func _retarget_far(focus: Vector2) -> void:
	var block_world := _chunk_world * LodMesher.BLOCK_CHUNKS
	for block: Vector2i in _far_blocks.keys():
		if _block_distance(block, focus) > far_distance + unload_margin:
			_free_far_block(block)
	_far_queue.clear()
	var blocks := LodMesher.block_count(_terrain)
	var reach := int(ceilf((far_distance + stream_margin) / block_world)) + 1
	var centre := Vector2i(floori((focus.x + _half) / block_world), floori((focus.y + _half) / block_world))
	for z in range(maxi(centre.y - reach, 0), mini(centre.y + reach + 1, blocks)):
		for x in range(maxi(centre.x - reach, 0), mini(centre.x + reach + 1, blocks)):
			var block := Vector2i(x, z)
			var distance := _block_distance(block, focus)
			if distance > far_distance + stream_margin or _ground_tasks.has(Vector3i(x, z, 0)):
				continue
			if not _far_blocks.has(block) or _far_masks[block] != _far_mask_wanted(block) or _far_dirty.has(block):
				_far_queue.append([distance, block])
	_far_queue.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

## Builds what _retarget_ground() queued: puts on their nodes the chunks and
## waterholes the worker threads finished, starts new tasks, adds collision
## shapes, while `budget_usec` lasts (0 = all of it now, waiting for the
## threads). True when nothing is left to do. Without `with_far`, the far
## blocks wait (finished ones are still put in place).
func _pump_ground(budget_usec: int, with_far: bool = true) -> bool:
	var start := Time.get_ticks_usec()
	var blocking := budget_usec <= 0
	# The materials' looks for pack_chunk(), read once per call.
	var looks := {}
	while true:
		# Collision first (the player may walk there), one shape per frame
		# at most: a shape and a chunk upload are the two heavy steps.
		if not _shape_queue.is_empty() and not blocking:
			_next_shape()
			if _over(start, budget_usec):
				return false
		# Then finished tasks: their faces are ready.
		for key: Variant in _ground_tasks.keys():
			var entry: Array = _ground_tasks[key]
			var task_id: int = entry[0]
			if not blocking and not WorkerThreadPool.is_task_completed(task_id):
				continue
			WorkerThreadPool.wait_for_task_completion(task_id)
			var snapshot: Node3D = entry[2]
			snapshot.free()
			_ground_tasks.erase(key)
			var result: Array = entry[1]
			_finish_task(key, result[0])
			if _over(start, budget_usec):
				return false
		# New tasks (or the next one on the main thread): chunks, then
		# waterholes, then far blocks.
		while true:
			var far_waiting := with_far and not _far_queue.is_empty()
			if _ground_queue.is_empty() and _hole_queue.is_empty() and not far_waiting:
				break
			if _max_tasks > 0 and _ground_tasks.size() >= _max_tasks:
				break
			if _max_tasks == 0 and _over(start, budget_usec):
				return false
			if not _ground_queue.is_empty():
				var queued: Array = _ground_queue.pop_front()
				var c: Vector2i = queued[1]
				if _ground.has(c) or _ground_tasks.has(c):
					continue
				var carve := _ground_carve
				var skirt_step := _far_step() if _far_on else 0
				# The final arrays, shadow caster and collision faces on the
				# worker too: the main thread only uploads (_finish_ground).
				if looks.is_empty():
					looks = TerrainMesher.chunk_looks(_terrain)
				var chunk_looks := looks
				_run_task(c, func(source: Node3D) -> Variant:
					var chunk_arrays := TerrainMesher.build_chunk_arrays(source, carve, c.x, c.y)
					if skirt_step > 0 and not chunk_arrays.is_empty():
						LodMesher.add_chunk_skirt(source, carve, chunk_arrays, c.x, c.y, skirt_step)
					return TerrainMesher.pack_chunk(chunk_arrays, chunk_looks))
			elif _hole_queue.is_empty():
				var queued_block: Array = _far_queue.pop_front()
				var block: Vector2i = queued_block[1]
				var key := Vector3i(block.x, block.y, 0)
				if _ground_tasks.has(key):
					continue
				var mask := _far_mask_wanted(block)
				var data: Dictionary = _far_data.get(block, {})
				var far_carve := _ground_carve
				var step := _far_step()
				_run_task(key, func(source: Node3D) -> Variant:
					var block_data := data if not data.is_empty() else LodMesher.block_data(source, far_carve, block.x, block.y, step)
					return {"data": block_data, "mask": mask, "arrays": LodMesher.block_arrays(block_data, mask)})
			else:
				var queued_hole: Array = _hole_queue.pop_front()
				var index: int = queued_hole[1]
				if _holes.has(index) or _ground_tasks.has(index):
					continue
				var hole: Variant = WaterholeStyle.list(_terrain)[index]
				var hole_carve := _ground_carve
				_run_task(index, func(source: Node3D) -> Variant:
					return WaterholeMesher.build_arrays(source, hole_carve, hole))
		while not _shape_queue.is_empty() and not _over(start, budget_usec):
			_next_shape()
		while not _road_queue.is_empty() and not _over(start, budget_usec):
			var queued_road: Array = _road_queue.pop_front()
			var road_chunk: Vector2i = queued_road[1]
			_attach_roads(road_chunk)
		var far_done := _far_queue.is_empty() or not with_far
		var done := _ground_queue.is_empty() and _hole_queue.is_empty() and far_done and _ground_tasks.is_empty() \
			and _shape_queue.is_empty() and _road_queue.is_empty()
		if done or not blocking:
			return done
	return true

## Makes the collision of the next queued chunk (if still built and without).
func _next_shape() -> void:
	var queued: Array = _shape_queue.pop_front()
	var c: Vector2i = queued[1]
	if _ground.has(c) and not _ground_shapes.has(c):
		_add_chunk_shape(c)

## True when no ground chunk within ready_distance of the focus is still
## queued or being built, nor its collision shape (waterholes not waited for).
func _near_ground_built() -> bool:
	if ready_distance <= 0.0:
		return false
	var limit := minf(ready_distance, ground_distance)
	for entry: Array in _ground_queue:
		var queued_distance: float = entry[0]
		if queued_distance <= limit:
			return false
	for entry: Array in _shape_queue:
		var shape_distance: float = entry[0]
		if shape_distance <= limit:
			return false
	for entry: Array in _road_queue:
		var road_distance: float = entry[0]
		if road_distance <= limit:
			return false
	for key: Variant in _ground_tasks.keys():
		if key is Vector2i:
			var c: Vector2i = key
			if _chunk_distance(c, _ground_focus) <= limit:
				return false
	return true

## Keeps the road / river pieces of a finished split job (FeatureMesher
## start_threaded split) and gives them to the chunks already built: their
## piece queued (one upload each, within the budget), the road faces added
## to their collision body.
func _take_road_pieces(job: Dictionary) -> void:
	var chunks: Dictionary = job["chunks"]
	var chunk_faces: Dictionary = job["chunk_faces"]
	for index: int in chunks:
		_road_pieces[Vector2i(index % _chunk_count, index / _chunk_count)] = chunks[index]
	for index: int in chunk_faces:
		_road_faces[Vector2i(index % _chunk_count, index / _chunk_count)] = chunk_faces[index]
	for key: Vector2i in _ground.keys():
		var distance := _chunk_distance(key, _ground_focus)
		if _road_pieces.has(key):
			_road_queue.append([distance, key])
		if _road_faces.has(key) and _ground_shapes.has(key):
			# A second shape on its body (never a moment without ground).
			var body: StaticBody3D = _ground_shapes[key]
			var shape := ConcavePolygonShape3D.new()
			shape.backface_collision = true
			var road_faces: PackedVector3Array = _road_faces[key]
			shape.set_faces(road_faces)
			body.shape_owner_add_shape(body.create_shape_owner(body), shape)
	_road_queue.sort_custom(func(a: Array, b: Array) -> bool: return a[0] < b[0])

## Puts a built chunk's piece of the roads and rivers under it (once).
func _attach_roads(c: Vector2i) -> void:
	var chunk := _chunk_node(c)
	if chunk == null or not _road_pieces.has(c) or chunk.has_node(ROADS_NAME):
		return
	var mesh := ArrayMesh.new()
	for piece: Array in _road_pieces[c]:
		var material: Material = piece[0]
		var vertices: PackedVector3Array = piece[1]
		var normals: PackedVector3Array = piece[2]
		var uvs: PackedVector2Array = piece[3]
		MeshUtils.add_packed_surface(mesh, vertices, normals, material, uvs)
	var roads := MeshInstance3D.new()
	roads.name = ROADS_NAME
	roads.mesh = mesh
	# Flat on the ground: their shadow would cost a pass for nothing.
	roads.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	chunk.add_child(roads)

## Runs `work` (a Callable(terrain) -> arrays) for `key` on a worker thread,
## on a snapshot of the terrain; without threads, at once on the terrain.
func _run_task(key: Variant, work: Callable) -> void:
	if _max_tasks == 0:
		_finish_task(key, work.call(_terrain))
		return
	var snapshot := TerrainMesher.thread_snapshot(_terrain)
	var result: Array = [null]
	var task := WorkerThreadPool.add_task(func() -> void: result[0] = work.call(snapshot))
	_ground_tasks[key] = [task, result, snapshot]

func _over(start_usec: int, budget_usec: int) -> bool:
	return budget_usec > 0 and Time.get_ticks_usec() - start_usec >= budget_usec

## Puts the faces of a chunk (TerrainMesher.build_chunk_arrays) on its node,
## unless the focus left it behind meanwhile.
func _finish_ground(c: Vector2i, arrays: Dictionary) -> void:
	var distance := _chunk_distance(c, _ground_focus)
	if arrays.is_empty() or distance > ground_distance + unload_margin:
		return
	# pack_chunk() arrays (worker): only the uploads here.
	var parts := TerrainMesher.assemble_packed(_terrain, arrays)
	var mesh: ArrayMesh = parts["mesh"]
	var caster: Array = parts["caster"]
	var chunk := _builder.apply_chunk_mesh(_terrain, c.x, c.y, mesh, caster)
	_chunk_face_cache[c] = parts["faces"]
	# Its far block still shows it: hidden until the block is rebuilt
	# without it (_finish_far_block), then swapped in the same frame.
	var block := _block_of(c)
	var far_mask: int = _far_masks.get(block, -1)
	chunk.visible = not _far_blocks.has(block) or (far_mask & LodMesher.chunk_bit(c.x, c.y)) != 0
	_ground[c] = true
	_built.erase(c)
	_collided.erase(c)
	_keep_shading(c, parts.get("shading"))
	_attach_roads(c)
	if _ground_collision and distance <= ground_collision_distance:
		# Its collision in a frame of its own, before any other shape.
		_shape_queue.push_front([distance, c])
	# Its details can come next.
	_retarget_in = 0.0

## The arrays of a finished task on their node: a chunk (Vector2i key) or a
## waterhole (int key).
func _finish_task(key: Variant, arrays: Variant) -> void:
	if _stale.has(key):
		# Made from the data before an edit: queued again with the new one.
		_stale.erase(key)
		_retarget_in = 0.0
		return
	if key is Vector2i:
		var c: Vector2i = key
		var chunk_arrays: Dictionary = arrays
		_finish_ground(c, chunk_arrays)
	elif key is Vector3i:
		var block_key: Vector3i = key
		var block_result: Dictionary = arrays
		_finish_far_block(Vector2i(block_key.x, block_key.y), block_result)
	else:
		var index: int = key
		var hole_arrays: Array = arrays
		_finish_waterhole(index, hole_arrays)

## Puts the plates of a waterhole (WaterholeMesher.build_arrays) on its node,
## unless the focus left it behind meanwhile.
func _finish_waterhole(index: int, arrays: Array) -> void:
	var bounds := _hole_bounds[index]
	if _ground_focus.clamp(bounds.position, bounds.end).distance_to(_ground_focus) > ground_distance + unload_margin:
		return
	_builder.apply_waterhole_mesh(_terrain, index, WaterholeMesher.assemble(_terrain, arrays))
	_holes[index] = true

## Frees a ground chunk with its details and detail collision.
func _free_ground(c: Vector2i) -> void:
	var chunk := _chunk_node(c)
	if chunk:
		chunk.get_parent().remove_child(chunk)
		chunk.queue_free()
	_chunk_nodes[c.y * _chunk_count + c.x] = null
	_ground.erase(c)
	_leaving.erase(c)
	_built.erase(c)
	_collided.erase(c)
	_shading_cache.erase(c)
	_chunk_face_cache.erase(c)
	# Its collision body went with it.
	_ground_shapes.erase(c)
	if not _stream_job.is_empty():
		var job_chunk: Vector2i = _stream_job["chunk"]
		if job_chunk == c:
			_drop_stream_job()
	chunk_details_changed.emit(c.x, c.y)

## Puts a far block's mesh on its node, then swaps the detailed chunks of the
## block in the same frame: shown when the mesh leaves them out, hidden (or
## freed when leaving) when it covers them.
func _finish_far_block(block: Vector2i, result: Dictionary) -> void:
	var data: Dictionary = result["data"]
	_far_data[block] = data
	_far_dirty.erase(block)
	if _block_distance(block, _ground_focus) > far_distance + unload_margin:
		return
	var container := _terrain.get_node_or_null(FAR_GROUND_NAME) as Node3D
	if container == null:
		container = Node3D.new()
		container.name = FAR_GROUND_NAME
		_terrain.add_child(container)
	var node: MeshInstance3D = _far_blocks.get(block)
	if node == null:
		node = MeshInstance3D.new()
		node.name = "Far_%d_%d" % [block.x, block.y]
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		container.add_child(node)
		_far_blocks[block] = node
	var arrays: Array = result["arrays"]
	node.mesh = LodMesher.assemble(_terrain, arrays)
	var mask: int = result["mask"]
	_far_masks[block] = mask
	for c in _block_chunks(block):
		if not _ground.has(c):
			continue
		var shown := (mask & LodMesher.chunk_bit(c.x, c.y)) != 0
		if not shown and _leaving.has(c):
			_free_ground(c)
		else:
			_chunk_node(c).visible = shown
	if mask != _far_mask_wanted(block):
		# The ring moved meanwhile: again with the chunks of now.
		_retarget_in = 0.0

func _free_far_block(block: Vector2i) -> void:
	var node: Node = _far_blocks[block]
	_far_blocks.erase(block)
	_far_masks.erase(block)
	_far_dirty.erase(block)
	if is_instance_valid(node):
		node.get_parent().remove_child(node)
		node.queue_free()
	# Nothing covers its chunks any more.
	for c in _block_chunks(block):
		if _leaving.has(c):
			_free_ground(c)
		elif _ground.has(c):
			_chunk_node(c).visible = true

## Chunks a far block must leave out: the detailed ones staying.
func _far_mask_wanted(block: Vector2i) -> int:
	var mask := 0
	for c in _block_chunks(block):
		if _ground.has(c) and not _leaving.has(c):
			mask |= LodMesher.chunk_bit(c.x, c.y)
	return mask

func _block_of(c: Vector2i) -> Vector2i:
	return Vector2i(c.x / LodMesher.BLOCK_CHUNKS, c.y / LodMesher.BLOCK_CHUNKS)

func _block_chunks(block: Vector2i) -> Array[Vector2i]:
	var chunks: Array[Vector2i] = []
	for z in range(block.y * LodMesher.BLOCK_CHUNKS, mini((block.y + 1) * LodMesher.BLOCK_CHUNKS, _chunk_count)):
		for x in range(block.x * LodMesher.BLOCK_CHUNKS, mini((block.x + 1) * LodMesher.BLOCK_CHUNKS, _chunk_count)):
			chunks.append(Vector2i(x, z))
	return chunks

## Distance (terrain-local XZ) from `focus` to the nearest point of a block.
func _block_distance(block: Vector2i, focus: Vector2) -> float:
	var size := _chunk_world * LodMesher.BLOCK_CHUNKS
	var min_corner := Vector2(block.x * size - _half, block.y * size - _half)
	return focus.clamp(min_corner, min_corner + Vector2(size, size)).distance_to(focus)

func _far_step() -> int:
	return 8 if far_step >= 8 else (4 if far_step >= 4 else 2)

## The chunk's ground collision: a body of its own under the chunk, filled
## before it enters the tree (with Jolt, a shape added to a body in the tree
## rebuilds the whole body).
func _add_chunk_shape(c: Vector2i) -> void:
	var chunk := _chunk_node(c)
	var faces: PackedVector3Array
	if _chunk_face_cache.has(c):
		var cached: PackedVector3Array = _chunk_face_cache[c]
		faces = cached.duplicate()
	else:
		faces = _chunk_faces(c.x, c.y)
	if _road_faces.has(c):
		var road_faces: PackedVector3Array = _road_faces[c]
		faces.append_array(road_faces)
	if chunk == null or faces.is_empty():
		return
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	var body := StaticBody3D.new()
	body.name = CHUNK_COLLISION_NAME
	var layer_number := clampi(Meta.get_int(_terrain, Meta.COLLISION_LAYER, 1), 1, 32)
	body.collision_layer = 1 << (layer_number - 1)
	body.collision_mask = 0
	body.shape_owner_add_shape(body.create_shape_owner(body), shape)
	chunk.add_child(body)
	_ground_shapes[c] = body

func _remove_chunk_shape(c: Vector2i) -> void:
	var body: Node = _ground_shapes[c]
	_ground_shapes.erase(c)
	if is_instance_valid(body):
		body.get_parent().remove_child(body)
		body.queue_free()

func _free_waterhole(index: int) -> void:
	_holes.erase(index)
	var container := _terrain.get_node_or_null(Meta.GENERATED_WATERHOLES_NAME)
	var node := container.get_node_or_null("Waterhole_%d" % index) if container else null
	if node:
		container.remove_child(node)
		node.queue_free()

## Waits for the worker threads still computing chunk faces, and frees their
## snapshots.
func _drain_ground_tasks() -> void:
	for job in _feature_jobs:
		FeatureMesher.wait_threads(job)
	_feature_jobs.clear()
	for key: Variant in _ground_tasks.keys():
		var entry: Array = _ground_tasks[key]
		var task_id: int = entry[0]
		WorkerThreadPool.wait_for_task_completion(task_id)
		var snapshot: Node3D = entry[2]
		snapshot.free()
	_ground_tasks.clear()

## Keeps a chunk's ground colours for its details (only what DetailScatter
## reads: the top faces).
func _keep_shading(c: Vector2i, shading: Variant) -> void:
	if shading == null:
		return
	_shading_cache.erase(c)
	var context: TerrainShading.Context = shading
	_shading_cache[c] = TerrainShading.top_faces(context)
	if not _keep_all_shading and _shading_cache.size() > SHADING_CACHE_SIZE:
		_shading_cache.erase(_shading_cache.keys()[0])

## Trunk collision of a chunk in one go (a load step of the start ring).
func _stream_collision(c: Vector2i) -> void:
	var chunk := _chunk_node(c)
	if chunk == null:
		return
	_detail_shapes += DetailCollision.build_chunk(_terrain, chunk, _shape_cache)
	var built_mask: int = _built.get(c, 0)
	_collided[c] = built_mask & _collision_layers
	chunk_details_changed.emit(c.x, c.y)

## Drops the streaming job under way (a trunk collision body not yet in the
## tree is freed).
func _drop_stream_job() -> void:
	if _stream_job.has("collision"):
		var collision_job: Dictionary = _stream_job["collision"]
		DetailCollision.cancel_chunk(collision_job)
	_stream_job = {}

## Layers whose draw distance + `margin` reaches `distance`.
func _layers_within(distance: float, margin: float) -> int:
	var mask := 0
	for i in range(1, _radii.size()):
		var radius := _radii[i]
		if radius >= 0.0 and distance <= radius + margin:
			mask |= DetailScatter.layer_bit(i)
	return mask

## Distance (terrain-local XZ) from `focus` to the nearest point of a chunk.
func _chunk_distance(c: Vector2i, focus: Vector2) -> float:
	var min_corner := Vector2(c.x * _chunk_world - _half, c.y * _chunk_world - _half)
	var nearest := focus.clamp(min_corner, min_corner + Vector2(_chunk_world, _chunk_world))
	return nearest.distance_to(focus)

## Streaming centre in terrain-local XZ (`stream_focus`, else the current
## camera), null when there is none.
func _focus_xz() -> Variant:
	if _terrain == null or not _terrain.is_inside_tree():
		return null
	var node: Node3D = stream_focus if is_instance_valid(stream_focus) and stream_focus.is_inside_tree() else null
	if _editor_stream:
		node = _editor_camera()
	elif node == null:
		var viewport := get_viewport()
		node = viewport.get_camera_3d() if viewport else null
	if node == null:
		return null
	var local := _terrain.to_local(node.global_position)
	return Vector2(local.x, local.z)

func _chunk_node(c: Vector2i) -> Node3D:
	var index := c.y * _chunk_count + c.x
	var cached: Variant = _chunk_nodes[index]
	if is_instance_valid(cached):
		var cached_chunk: Node3D = cached
		if not cached_chunk.is_queued_for_deletion():
			return cached_chunk
	var chunk := TerrainMesher.find_chunk(_terrain, c.x, c.y)
	_chunk_nodes[index] = chunk
	return chunk

## Time a sliced step may take (0 = all at once when not progressive).
func _slice_usec() -> int:
	return int(_build_budget_ms() * 1000.0) if progressive else 0

## Work per frame while building: ready_budget_ms until terrain_ready.
func _build_budget_ms() -> float:
	return ready_budget_ms if ready_budget_ms > 0.0 and not is_ground_ready else frame_budget_ms

func _ground_ready() -> void:
	if is_ground_ready:
		return
	is_ground_ready = true
	terrain_ready.emit()

## Fresh ground collision body (the editor's single-shape body is removed:
## the runtime one replaces it).
func _reset_ground_collision() -> void:
	for node_name: String in [Meta.GENERATED_COLLISION_BODY_NAME, GROUND_COLLISION_NAME]:
		var old := _terrain.get_node_or_null(node_name)
		if old:
			_terrain.remove_child(old)
			old.queue_free()
	var body := StaticBody3D.new()
	body.name = GROUND_COLLISION_NAME
	var layer_number := clampi(Meta.get_int(_terrain, Meta.COLLISION_LAYER, 1), 1, 32)
	body.collision_layer = 1 << (layer_number - 1)
	body.collision_mask = 0
	_terrain.add_child(body)

func _chunk_faces(chunk_x: int, chunk_z: int) -> PackedVector3Array:
	var chunk := TerrainMesher.find_chunk(_terrain, chunk_x, chunk_z)
	return chunk.mesh.get_faces() if chunk != null and chunk.mesh != null else PackedVector3Array()

func _add_ground_shape(faces: PackedVector3Array) -> void:
	var body := _terrain.get_node_or_null(GROUND_COLLISION_NAME) as StaticBody3D
	if body == null or faces.is_empty():
		return
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	body.shape_owner_add_shape(body.create_shape_owner(body), shape)

func _build_chunk_collision(chunk_x: int, chunk_z: int) -> void:
	var chunk := TerrainMesher.find_chunk(_terrain, chunk_x, chunk_z)
	if chunk:
		_detail_shapes += DetailCollision.build_chunk(_terrain, chunk, _shape_cache)

## Chunks sorted by distance to the active camera (nearest first).
func _chunks_by_distance(t: Node3D) -> Array[Vector2i]:
	var count := TerrainMesher.chunk_count(t)
	var resolution: int = Meta.get_int(t, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(t, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var chunk_world := world_size / float(maxi(resolution - 1, 1)) * float(Meta.TERRAIN_CHUNK_CELLS)
	var focus := Vector2.ZERO
	var viewport := get_viewport()
	var camera := _editor_camera() if _editor_stream else (viewport.get_camera_3d() if viewport else null)
	if camera != null and t.is_inside_tree():
		var local := t.to_local(camera.global_position)
		focus = Vector2(local.x, local.z)
	var chunks: Array[Vector2i] = []
	for z in range(count):
		for x in range(count):
			chunks.append(Vector2i(x, z))
	var half := world_size * 0.5
	chunks.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		var ca := Vector2((a.x + 0.5) * chunk_world - half, (a.y + 0.5) * chunk_world - half)
		var cb := Vector2((b.x + 0.5) * chunk_world - half, (b.y + 0.5) * chunk_world - half)
		return ca.distance_squared_to(focus) < cb.distance_squared_to(focus))
	return chunks

static func _has_details(t: Node3D) -> bool:
	var container := t.get_node_or_null(Meta.GENERATED_CHUNKS_NAME)
	if container == null:
		return false
	for chunk in container.get_children():
		for child in chunk.get_children():
			if String(child.name).begins_with(DetailScatter.NODE_PREFIX):
				return true
	# No detail node anywhere: either never built or the biome has none.
	var biome := DetailScatter.biome_of(t)
	return biome == null or biome.detail_layers.is_empty()

static func _clear_generated(t: Node3D) -> void:
	for node_name: String in [Meta.GENERATED_CHUNKS_NAME, Meta.GENERATED_WATERHOLES_NAME, GROUND_COLLISION_NAME, FAR_GROUND_NAME]:
		var node := t.get_node_or_null(node_name)
		if node:
			t.remove_child(node)
			node.queue_free()

static func _ensure_feature_node(t: Node3D) -> void:
	if t.get_node_or_null(Meta.GENERATED_MESH_NAME) == null:
		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = Meta.GENERATED_MESH_NAME
		t.add_child(mesh_instance)

## Editor: rebuild what the scene file did not store (runtime build modes),
## without collision and without generating a new map.
func _editor_restore() -> void:
	var t := terrain if terrain != null else get_parent() as Node3D
	if t == null or not Meta.is_terrain(t) or not t.is_inside_tree():
		return
	var mode := TerrainBuilder.runtime_build(t)
	if mode == Meta.RUNTIME_BUILD_NOTHING or _editor_stream:
		return
	TerrainData.ensure_defaults(t)
	if mode == Meta.RUNTIME_BUILD_ALL and TerrainBuilder.streams_in_editor(t):
		start_editor_stream()
		return
	var builder := TerrainBuilder.new()
	if t.get_node_or_null(Meta.GENERATED_CHUNKS_NAME) == null:
		_ensure_feature_node(t)
		StylePalette.ensure_material_data(t)
		builder.rebuild_river_carve(t)
		builder.rebuild_all_chunks(t)
		var faces := builder.rebuild_feature_mesh(t)
		builder.rebuild_waterholes(t)
		builder.rebuild_collision(t, faces)
	elif not _has_details(t):
		builder.rebuild_all_details(t)

# -----------------------------------------------------------------------------
# Editor streaming (terrains too big to build whole)
# -----------------------------------------------------------------------------

## True while the editor builds this terrain around its camera.
func is_editor_streaming() -> bool:
	return _editor_stream

## Builds the terrain around the editor camera, as stream_ground does in game,
## from scratch (generated nodes replaced, nothing saved with the scene).
## `builder`: the editor plugin's (TerrainBuilder), whose river carve the
## edits update; null keeps the one shared before (else one of its own).
func start_editor_stream(builder: TerrainBuilder = null) -> void:
	if builder != null:
		_shared_builder = builder
	var t := _target()
	if t == null or not Meta.is_terrain(t) or not t.is_inside_tree():
		return
	_drain_ground_tasks()
	_editor_stream = true
	_clear_generated(t)
	var editor_body := t.get_node_or_null(Meta.GENERATED_COLLISION_BODY_NAME)
	if editor_body:
		t.remove_child(editor_body)
		editor_body.queue_free()
	build()
	set_process(true)

## Back to a terrain built whole (now small enough): frees what the streaming
## built.
func stop_editor_stream() -> void:
	_reset_build_state()
	_editor_stream = false
	_shared_builder = null
	var t := _target()
	if t != null:
		_clear_generated(t)
	set_process(false)

## The editor plugin's builder takes over (its river carve follows the edits).
func share_builder(builder: TerrainBuilder) -> void:
	_shared_builder = builder
	_builder = builder
	if _terrain != null and _ground_streaming:
		_ground_carve = builder.get_river_carve(_terrain)

## The chunk is shown in full detail: an edit rebuilds it at once.
func editor_has_chunk(c: Vector2i) -> bool:
	return _ground.has(c)

## Skirt depth (in cells) of the detailed chunks, 0 = none (no far blocks).
func editor_skirt_step() -> int:
	return _far_step() if _far_on else 0

## The data of these chunks changed (a stroke, an Undo): work started from the
## old data is dropped, their far blocks are made again, the chunks not built
## yet will be built from the new data.
func editor_chunks_changed(keys: Array[Vector2i]) -> void:
	for c in keys:
		if _ground_tasks.has(c):
			_stale[c] = true
		if _ground_shapes.has(c):
			_shape_dirty[c] = true
		# Its collision is made again from the new ground, not the old faces.
		_chunk_face_cache.erase(c)
		if not _ground.has(c):
			_shading_cache.erase(c)
		var block := _block_of(c)
		_far_data.erase(block)
		var block_key := Vector3i(block.x, block.y, 0)
		if _ground_tasks.has(block_key):
			_stale[block_key] = true
		if _far_blocks.has(block):
			_far_dirty[block] = true
	_retarget_in = 0.0

## Chunk `c` was rebuilt from the new data: its ground colours, for its
## details.
func editor_chunk_rebuilt(c: Vector2i, shading: Variant) -> void:
	if _ground.has(c):
		_keep_shading(c, shading)

## Chunk `c` got all its detail layers (TerrainBuilder.apply_chunk_details):
## those past their distance go at the next retarget.
func editor_details_built(c: Vector2i) -> void:
	if _ground.has(c):
		_built[c] = _layers_within(0.0, 0.0)
		_retarget_in = 0.0

## The detail layers changed (biome): all made again, as the camera sees them.
func editor_details_changed() -> void:
	if _terrain == null or not _streaming:
		return
	for c: Vector2i in _ground:
		var chunk := _chunk_node(c)
		if chunk:
			DetailScatter.clear_layers(chunk, -1)
	_built.clear()
	_drop_stream_job()
	_stream_queue.clear()
	_radii = DetailScatter.layer_radii(_terrain)
	for i in range(1, _radii.size()):
		_radii[i] = minf(_radii[i], ground_distance)
	_retarget_in = 0.0

## The river carve changed (the shared builder holds the new one).
func editor_carve_changed() -> void:
	if _terrain != null and _ground_streaming:
		_ground_carve = _builder.get_river_carve(_terrain)

## The waterhole list, or the plates in `rect` (Rect2, null = all), changed:
## made again from the new data (kept on screen until then).
func editor_holes_changed(rect: Variant = null) -> void:
	if _terrain == null or not _ground_streaming:
		return
	var holes := WaterholeStyle.list(_terrain)
	_hole_bounds.clear()
	for i in range(holes.size()):
		_hole_bounds.append(WaterholeStyle.bounds_of(_terrain, i))
	for index: int in _holes.keys():
		if index >= holes.size():
			_free_waterhole(index)
		elif rect == null or _hole_bounds[index].intersects(_as_rect(rect), true):
			_holes.erase(index)
	# Indices may have moved: no plate made from the old list is put.
	for key: Variant in _ground_tasks:
		if key is int:
			_stale[key] = true
	if holes.is_empty():
		var container := _terrain.get_node_or_null(Meta.GENERATED_WATERHOLES_NAME)
		if container:
			_terrain.remove_child(container)
			container.queue_free()
	_retarget_in = 0.0

## Collision of the edited chunks and of the roads again (once editing
## pauses, TerrainBuilder.flush_collision).
func editor_refresh_collision(feature_faces: PackedVector3Array) -> void:
	if _terrain == null or not _ground_collision:
		_shape_dirty.clear()
		return
	for c: Vector2i in _shape_dirty:
		if _ground_shapes.has(c):
			_remove_chunk_shape(c)
			_add_chunk_shape(c)
	_shape_dirty.clear()
	var body := _terrain.get_node_or_null(GROUND_COLLISION_NAME) as StaticBody3D
	if body:
		for owner_id in body.get_shape_owners():
			body.remove_shape_owner(owner_id)
		_add_ground_shape(feature_faces)

## The 3D editor's camera (EditorInterface looked up by name: this script
## also runs in exported games, where it does not exist).
static func _editor_camera() -> Camera3D:
	if not Engine.has_singleton(&"EditorInterface"):
		return null
	var editor: Object = Engine.get_singleton(&"EditorInterface")
	var found: Object = editor.call(&"get_editor_viewport_3d", 0)
	var viewport := found as Viewport
	return viewport.get_camera_3d() if viewport != null else null

static func _as_rect(value: Variant) -> Rect2:
	var rect: Rect2 = value
	return rect
