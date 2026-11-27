@tool
extends RefCounted
## Turns terrain metadata into generated child nodes (chunk meshes, feature
## mesh, preview mesh, collision body) and keeps the derived caches.
##
## Child node layout under the terrain Node3D:
##   _GeneratedTerrainChunks/Chunk_X_Z     MeshInstance3D per 32x32-cell chunk,
##       /_GroundShadow                    its shadow caster (back faces),
##       /_Details_<index>_<layer name>    a MultiMesh per detail layer,
##       /_DetailCollision                 tree trunks (game, TerrainRuntime)
##   _GeneratedTerrainMesh                 roads + rivers (must already exist)
##   _GeneratedTerrainFeaturePreview       stroke being drawn
##   _GeneratedWaterholes/Waterhole_N      mud plates of each dried waterhole
##   _GeneratedTerrainCollision            optional StaticBody3D
##       /Chunk_X_Z, /Features             a shape per chunk + roads / rivers
##
## A terrain too big to build whole (streams_in_editor) is built around the
## editor camera by its LowpolyTerrainRuntime node instead: the calls below
## hand it the work (editor_stream), only its detailed chunks are rebuilt.

const Meta = preload("../core/terrain_meta.gd")
const NodeNames = preload("../core/node_names.gd")
const StylePalette = preload("../styles/style_palette.gd")
const TerrainMesher = preload("terrain_mesher.gd")
const MeshUtils = preload("mesh_utils.gd")
const TerrainShading = preload("terrain_shading.gd")
const DetailScatter = preload("detail_scatter.gd")
const MaterialFactory = preload("../materials/material_factory.gd")
const RiverMesher = preload("river_mesher.gd")
const FeatureMesher = preload("feature_mesher.gd")
const WaterholeMesher = preload("waterhole_mesher.gd")
const WaterholeStyle = preload("../styles/waterhole_style.gd")
const FeatureEraser = preload("../editing/feature_eraser.gd")
const LodMesher = preload("lod_mesher.gd")

## Terrains with more chunks than this a side are built around the editor
## camera (LowpolyTerrainRuntime.start_editor_stream): built whole, 1024
## cells take ~40 s and 2 M triangles.
const EDITOR_STREAM_CHUNKS := 16
## Collision body shape of the roads / rivers (the others: one per chunk,
## named like it).
const FEATURE_COLLISION_SHAPE_NAME := "Features"

## Returns the node that should own generated children (the edited scene
## root in the editor) so they are saved with the scene. May return null.
var owner_provider: Callable = Callable()

# Derived data, deliberately not saved into terrain metadata or undo snapshots.
# Keyed by terrain instance id.
var _river_carve_cache: Dictionary = {}
var _feature_collision_cache: Dictionary = {}
## Road / river groups kept between edits (FeatureMesher.build_cached),
## terrain instance id -> cache. Editor only: the game builds them once.
var _feature_cache: Dictionary = {}
var feature_cache_enabled := Engine.is_editor_hint()
## Terrains fully built by this builder (instance id -> true).
var _built: Dictionary = {}
## Editor: collision waiting to be rebuilt (instance id -> WeakRef). Only
## physics needs it, so strokes do not pay for it (see request_collision).
var _collision_pending: Dictionary = {}
var _collision_requested_ms := 0
## Collision body: chunks whose mesh changed since their shape was made
## (instance id -> {chunk name: true}), and the faces of the roads / rivers
## shape (instance id -> faces), see rebuild_collision.
var _collision_dirty: Dictionary = {}
var _feature_shape_faces: Dictionary = {}
## Editor: chunk work finished over the next frames after a stroke
## ("terrain id|x|z" -> {terrain: WeakRef, key: Vector2i, mesh: bool,
## shading: Variant}), see defer_chunk() / process_deferred().
var _deferred: Dictionary = {}

func _scene_owner() -> Node:
	return owner_provider.call() if owner_provider.is_valid() else null

## Adds a generated node, saved with the scene unless the terrain rebuilds
## that kind of node at runtime (Meta.RUNTIME_BUILD).
func _add_generated_child(terrain: Node3D, parent: Node, child: Node, is_detail: bool = false) -> void:
	NodeNames.add(parent, child)
	var scene_root := _scene_owner()
	if scene_root and _saved(terrain, is_detail) and editor_stream(terrain) == null:
		child.owner = scene_root

## Child `node_name` of `parent` (a plain Node3D), created as a generated
## child when missing. `folded`: kept folded in the Scene dock (hundreds of
## children).
func _ensure_container(terrain: Node3D, parent: Node, node_name: String, folded: bool = false) -> Node3D:
	var container := parent.get_node_or_null(node_name) as Node3D
	if container == null:
		container = Node3D.new()
		container.name = node_name
		_add_generated_child(terrain, parent, container)
		if folded:
			container.set_display_folded(true)
	return container

## Mesh child `node_name` of `parent`, created when missing without a shadow
## (chunks cast theirs from their own caster, waterhole plates are too thin).
func _ensure_mesh_child(terrain: Node3D, parent: Node, node_name: String) -> MeshInstance3D:
	var node := parent.get_node_or_null(node_name) as MeshInstance3D
	if node == null:
		node = MeshInstance3D.new()
		node.name = node_name
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_add_generated_child(terrain, parent, node)
	return node

static func runtime_build(terrain: Node3D) -> int:
	return Meta.get_int(terrain, Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_NOTHING)

static func _saved(terrain: Node3D, is_detail: bool) -> bool:
	var mode := runtime_build(terrain)
	return mode == Meta.RUNTIME_BUILD_NOTHING or (mode == Meta.RUNTIME_BUILD_DETAILS and not is_detail)

## Gives every generated node the owner matching the terrain's runtime build
## setting (after that setting changed).
func apply_ownership(terrain: Node3D) -> void:
	var scene_root := _scene_owner()
	if scene_root == null or editor_stream(terrain) != null:
		return
	for node_name: String in [Meta.GENERATED_CHUNKS_NAME, Meta.GENERATED_WATERHOLES_NAME, Meta.GENERATED_COLLISION_BODY_NAME, Meta.GENERATED_MESH_NAME]:
		var top := terrain.get_node_or_null(node_name)
		if top == null:
			continue
		_set_owner_tree(top, scene_root, terrain)

func _set_owner_tree(node: Node, scene_root: Node, terrain: Node3D) -> void:
	var is_detail := node is MultiMeshInstance3D and String(node.name).begins_with(DetailScatter.NODE_PREFIX)
	node.owner = scene_root if _saved(terrain, is_detail) else null
	for child in node.get_children():
		_set_owner_tree(child, scene_root, terrain)

# -----------------------------------------------------------------------------
# Full rebuild
# -----------------------------------------------------------------------------

## Rebuilds every generated node from the terrain data.
func rebuild_all(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return
	# Biome ground styles edited: painted cells follow them.
	StylePalette.sync_with_biome(terrain)
	if streams_in_editor(terrain) and _start_stream(terrain):
		return
	_stop_stream(terrain)

	StylePalette.ensure_material_data(terrain)
	rebuild_river_carve(terrain)
	rebuild_all_chunks(terrain)
	var feature_collision_faces := rebuild_feature_mesh(terrain)
	rebuild_waterholes(terrain)
	rebuild_collision(terrain, feature_collision_faces)
	apply_ownership(terrain)
	if not _built.has(terrain.get_instance_id()):
		# Scenes saved before generated nodes were folded.
		for node_name: String in [Meta.GENERATED_CHUNKS_NAME, Meta.GENERATED_WATERHOLES_NAME]:
			var top := terrain.get_node_or_null(node_name)
			if top:
				top.set_display_folded(true)
	_built[terrain.get_instance_id()] = true
	_drop_deferred(terrain)

## Gives the built meshes the current materials (Custom Materials changed):
## the vertex-colour surfaces of the chunks and waterholes, and the details
## (and the current shadow setting of the road / river mesh).
## Geometry and colours are not rebuilt. Surfaces that already have the right
## material are left alone (opening a scene does not modify it).
static func refresh_materials(terrain: Node3D) -> void:
	var ground := MaterialFactory.terrain_vertex_color_material(terrain)
	for container_name: String in [Meta.GENERATED_CHUNKS_NAME, Meta.GENERATED_WATERHOLES_NAME]:
		var container := terrain.get_node_or_null(container_name)
		if container == null:
			continue
		for node in container.find_children("*", "MeshInstance3D", true, false):
			var mesh := (node as MeshInstance3D).mesh as ArrayMesh
			if mesh == null:
				continue
			for surface in mesh.get_surface_count():
				# Vertex colours only: not the blended textures (CUSTOM0) nor
				# textured cliffs with baked greys (UVs).
				var format := mesh.surface_get_format(surface)
				if format & Mesh.ARRAY_FORMAT_COLOR and not (format & (Mesh.ARRAY_FORMAT_CUSTOM0 | Mesh.ARRAY_FORMAT_TEX_UV)) \
						and mesh.surface_get_material(surface) != ground:
					mesh.surface_set_material(surface, ground)
	apply_ground_shadows(terrain)
	# Scenes saved before roads / rivers stopped casting a shadow.
	var features := terrain.get_node_or_null(Meta.GENERATED_MESH_NAME) as GeometryInstance3D
	if features != null and features.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
		features.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	if MaterialFactory.phone_water():
		_phone_river_water(terrain)
	DetailScatter.refresh_materials(terrain)

## Phones: river meshes saved in the scene (built on a computer) keep the
## refraction water shader; they get the one without screen copy, as a river
## built on the phone (MaterialFactory.river_material).
static func _phone_river_water(terrain: Node3D) -> void:
	for node in terrain.find_children("*", "MeshInstance3D", true, false):
		var mesh := (node as MeshInstance3D).mesh
		if mesh == null:
			continue
		for surface in mesh.get_surface_count():
			var material := mesh.surface_get_material(surface) as ShaderMaterial
			if material != null and material.shader == MaterialFactory.RiverWaterShader:
				material.shader = MaterialFactory.RiverWaterMobileShader

## True once rebuild_all ran for this terrain instance (selecting it again does
## not need a new full build).
func is_built(terrain: Node3D) -> bool:
	return _built.has(terrain.get_instance_id())

## The meshes were built this session by another builder (the runtime node
## restores "Everything at runtime" terrains when the scene opens). A runtime
## node streaming it takes this builder (shared river carve).
func mark_built(terrain: Node3D) -> void:
	_built[terrain.get_instance_id()] = true
	var stream := editor_stream(terrain)
	if stream != null:
		stream.call(&"share_builder", self)

# -----------------------------------------------------------------------------
# Editor streaming (big terrains)
# -----------------------------------------------------------------------------

## Built around the editor camera rather than whole (editor only).
static func streams_in_editor(terrain: Node3D) -> bool:
	return Engine.is_editor_hint() and TerrainMesher.chunk_count(terrain) > EDITOR_STREAM_CHUNKS

## The runtime node building `terrain` around the editor camera, or null.
static func editor_stream(terrain: Node3D) -> Node:
	var runtime := _runtime_of(terrain)
	return runtime if runtime != null and runtime.call(&"is_editor_streaming") else null

static func _runtime_of(terrain: Node3D) -> Node:
	var runtime := terrain.get_node_or_null(Meta.RUNTIME_NODE_NAME)
	if runtime != null and runtime.has_method(&"is_editor_streaming"):
		return runtime
	for child in terrain.get_children():
		if child.has_method(&"is_editor_streaming"):
			return child
	return null

## Hands a big terrain to its runtime node (false without one: built whole
## then). Nothing generated is saved for it: Runtime Build = Everything, and
## the game streams its ground too.
func _start_stream(terrain: Node3D) -> bool:
	var runtime := _runtime_of(terrain)
	if runtime == null:
		return false
	if runtime_build(terrain) != Meta.RUNTIME_BUILD_ALL:
		terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
		print("Lowpoly Terrain: big map, Runtime Build set to Everything (built around the camera, never saved).")
	if not runtime.get(&"stream_ground"):
		runtime.set(&"stream_ground", true)
		print("Lowpoly Terrain: big map, %s.stream_ground turned on (the game builds the ground around the player)." % runtime.name)
	StylePalette.ensure_material_data(terrain)
	rebuild_river_carve(terrain)
	runtime.call(&"start_editor_stream", self)
	_built[terrain.get_instance_id()] = true
	_drop_deferred(terrain)
	return true

## A terrain streamed in the editor that became small enough: back to a
## whole build.
func _stop_stream(terrain: Node3D) -> void:
	var stream := editor_stream(terrain)
	if stream != null:
		stream.call(&"stop_editor_stream")

## Chunk (chunk_x, chunk_z) of a streamed terrain changed: rebuilt at once
## when shown in detail (as the runtime builds it, with its skirt), else the
## runtime makes it (or its far block) again from the new data.
func _rebuild_streamed_chunk(stream: Node, terrain: Node3D, chunk_x: int, chunk_z: int, with_details: bool) -> Dictionary:
	var c := Vector2i(chunk_x, chunk_z)
	var changed: Array[Vector2i] = [c]
	stream.call(&"editor_chunks_changed", changed)
	_deferred.erase(_deferred_id(terrain, c))
	if not stream.call(&"editor_has_chunk", c):
		return {}
	var carve := get_river_carve(terrain)
	var arrays := TerrainMesher.build_chunk_arrays(terrain, carve, chunk_x, chunk_z)
	if arrays.is_empty():
		return {}
	var skirt_step: int = stream.call(&"editor_skirt_step")
	if skirt_step > 0:
		LodMesher.add_chunk_skirt(terrain, carve, arrays, chunk_x, chunk_z, skirt_step)
	var parts := TerrainMesher.assemble_chunk(terrain, arrays)
	var mesh: ArrayMesh = parts["mesh"]
	var caster: Array = parts["caster"]
	apply_chunk_mesh(terrain, chunk_x, chunk_z, mesh, caster)
	stream.call(&"editor_chunk_rebuilt", c, parts["shading"])
	if with_details:
		apply_chunk_details(terrain, chunk_x, chunk_z, parts["shading"])
	return parts

## Rebuilds what lies in `rect` (terrain-local X/Z) after its data changed:
## chunk meshes + details (with the shading margin), the road / river mesh
## when a feature crosses the area, waterhole plates, then asks for collision.
## options: carve (rivers / waterholes changed), features (roads / rivers
## changed), waterholes (waterhole list changed: rebuild every plate), defer
## (editor: chunks rebuilt over the next frames, see process_deferred).
func rebuild_area(terrain: Node3D, rect: Rect2, options: Dictionary = {}) -> void:
	if not is_instance_valid(terrain):
		return
	StylePalette.ensure_material_data(terrain)
	var keys := chunks_for_local_rect(terrain, rect)
	# A river's level depends on the ground along it: heights changed near a
	# river (undo of a sculpt stroke) can move its whole channel.
	if options.get("carve", false) or RiverMesher.any_river_near(terrain, rect):
		for key in rebuild_river_carve(terrain):
			if not keys.has(key):
				keys.append(key)
	# "details": false = ground only, the details stay as they are (Undo /
	# Redo of a sculpt stroke: strokes never touch them).
	var details: bool = options.get("details", true)
	for key in keys:
		if options.get("defer", false):
			defer_chunk(terrain, key, true, null, details)
		else:
			rebuild_chunk(terrain, key.x, key.y, details)
	if options.get("features", false) or FeatureEraser.any_feature_intersects(terrain, rect):
		rebuild_feature_mesh(terrain, rect)
	if options.get("waterholes", false):
		rebuild_waterholes(terrain)
	else:
		rebuild_waterholes(terrain, rect)
	request_collision(terrain)

# -----------------------------------------------------------------------------
# River carve cache
# -----------------------------------------------------------------------------

## River beds + waterhole depressions (one carve array, see TerrainSampler).
## Returns the chunks whose carve changed (none when the grid size changed:
## the caller rebuilds everything then).
func rebuild_river_carve(terrain: Node3D) -> Array[Vector2i]:
	var previous: PackedFloat32Array = _river_carve_cache.get(terrain.get_instance_id(), PackedFloat32Array())
	var carve := RiverMesher.compute_carve(terrain)
	WaterholeMesher.add_carve(terrain, carve)
	_river_carve_cache[terrain.get_instance_id()] = carve
	if previous != carve:
		# Roads and rivers stand on the carved ground.
		_feature_cache.erase(terrain.get_instance_id())
	var stream := editor_stream(terrain)
	if stream != null:
		stream.call(&"editor_carve_changed")
	var changed: Array[Vector2i] = []
	if previous.size() != carve.size() or previous == carve:
		return changed
	# Changed vertices, gathered in blocks of 8 x 8, then their chunks.
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var blocks: Dictionary = {}
	for index in carve.size():
		if carve[index] != previous[index]:
			blocks[Vector2i((index % resolution) >> 3, (index / resolution) >> 3)] = true
	for block: Vector2i in blocks:
		var bounds := {"min_x": block.x * 8, "min_z": block.y * 8, "max_x": mini(block.x * 8 + 7, resolution - 1), "max_z": mini(block.y * 8 + 7, resolution - 1)}
		for key in chunks_for_vertex_bounds(terrain, bounds):
			if not changed.has(key):
				changed.append(key)
	return changed

## Cached carve depths, recomputed when the grid size changed.
func get_river_carve(terrain: Node3D) -> PackedFloat32Array:
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var terrain_id := terrain.get_instance_id()
	var carve: PackedFloat32Array = _river_carve_cache.get(terrain_id, PackedFloat32Array())
	if carve.size() != resolution * resolution:
		rebuild_river_carve(terrain)
		carve = _river_carve_cache.get(terrain_id, PackedFloat32Array())
	return carve

# -----------------------------------------------------------------------------
# Terrain chunks
# -----------------------------------------------------------------------------

func _ensure_chunk_container(terrain: Node3D) -> Node3D:
	return _ensure_container(terrain, terrain, Meta.GENERATED_CHUNKS_NAME, true)

## Its shadow comes from its back-face caster (_update_ground_caster).
func _get_or_create_chunk_node(terrain: Node3D, chunk_x: int, chunk_z: int) -> MeshInstance3D:
	return _ensure_mesh_child(terrain, _ensure_chunk_container(terrain), TerrainMesher.chunk_name(chunk_x, chunk_z))

static func _ground_shadow_setting(terrain: Node3D) -> GeometryInstance3D.ShadowCastingSetting:
	return GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if Meta.get_bool(terrain, Meta.GROUND_SHADOWS, true) else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

## The shadow of a ground chunk: a shadow-only child holding its back faces
## (MeshUtils.back_face_caster), saved with the chunk. Measured on the
## explore map: same shadows (mounds included) for ~85 % less GPU time than
## the chunk casting its own (front-face) shadow.
static func _update_ground_caster(terrain: Node3D, chunk: MeshInstance3D, caster_arrays: Array = []) -> void:
	chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var caster := chunk.get_node_or_null(Meta.GROUND_SHADOW_NAME) as MeshInstance3D
	if chunk.mesh == null:
		if caster != null:
			chunk.remove_child(caster)
			caster.queue_free()
		return
	if caster == null:
		caster = MeshInstance3D.new()
		caster.name = Meta.GROUND_SHADOW_NAME
		NodeNames.add(chunk, caster)
		if chunk.owner != null:
			caster.owner = chunk.owner
	if not caster_arrays.is_empty():
		caster.mesh = MeshUtils.caster_mesh(caster_arrays)
	else:
		caster.mesh = MeshUtils.back_face_caster(chunk.mesh as ArrayMesh) if chunk.mesh is ArrayMesh else null
	caster.cast_shadow = _ground_shadow_setting(terrain)

## Gives every ground chunk the terrain's Ground Casts Shadows setting
## (Meta.GROUND_SHADOWS), without rebuilding the ground. Chunks of scenes
## saved before the back-face casters get theirs here.
static func apply_ground_shadows(terrain: Node3D) -> void:
	var container := terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME)
	if container == null:
		return
	var setting := _ground_shadow_setting(terrain)
	for child in container.get_children():
		var chunk := child as MeshInstance3D
		if chunk == null:
			continue
		var caster := chunk.get_node_or_null(Meta.GROUND_SHADOW_NAME) as MeshInstance3D
		if caster == null:
			_update_ground_caster(terrain, chunk)
		else:
			chunk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			if caster.cast_shadow != setting:
				caster.cast_shadow = setting

## `with_details` false: ground only, the detail nodes are kept (they are in
## terrain space, so they stay in place when chunk keys change).
func rebuild_all_chunks(terrain: Node3D, with_details: bool = true) -> void:
	if editor_stream(terrain) != null or streams_in_editor(terrain):
		# Streamed: made again around the camera (a grown canvas).
		if streams_in_editor(terrain) and _start_stream(terrain):
			return
		_stop_stream(terrain)
	var chunk_count := TerrainMesher.chunk_count(terrain)
	var container := _ensure_chunk_container(terrain)
	var expected: Dictionary = {}

	for chunk_z in range(chunk_count):
		for chunk_x in range(chunk_count):
			expected[TerrainMesher.chunk_name(chunk_x, chunk_z)] = true
			rebuild_chunk(terrain, chunk_x, chunk_z, with_details)

	# Remove chunks left over after a smaller image generation / undo / resize.
	for child in container.get_children():
		if child is MeshInstance3D and not expected.has(child.name):
			container.remove_child(child)
			child.queue_free()

## Chunks (Vector2i) whose mesh depends on the vertices of `vertex_bounds`.
## Without `shading_margin`: only the chunks whose geometry changes (strokes
## refresh the colour blur of the neighbours once, at the end).
func chunks_for_vertex_bounds(terrain: Node3D, vertex_bounds: Dictionary, shading_margin: bool = true) -> Array[Vector2i]:
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	if resolution < 2:
		return []
	# One extra cell catches shared vertices and cliffs at chunk boundaries;
	# baked shading (colour blur, border noise, AO) reaches a few cells further.
	var margin := TerrainShading.influence_margin(terrain) if shading_margin else 0
	var min_x: int = vertex_bounds["min_x"]
	var min_z: int = vertex_bounds["min_z"]
	var max_x: int = vertex_bounds["max_x"]
	var max_z: int = vertex_bounds["max_z"]
	return chunks_in_cell_rect(
		clampi(min_x - 1 - margin, 0, resolution - 2),
		clampi(min_z - 1 - margin, 0, resolution - 2),
		clampi(max_x + margin, 0, resolution - 2),
		clampi(max_z + margin, 0, resolution - 2)
	)

## Chunks (Vector2i) whose mesh depends on the area `rect` (terrain-local X/Z).
func chunks_for_local_rect(terrain: Node3D, rect: Rect2) -> Array[Vector2i]:
	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	if resolution < 2:
		return []
	var spacing := world_size / float(resolution - 1)
	var half := world_size * 0.5
	var margin := TerrainShading.influence_margin(terrain) + 1
	return chunks_in_cell_rect(
		clampi(int(floorf((rect.position.x + half) / spacing)) - margin, 0, resolution - 2),
		clampi(int(floorf((rect.position.y + half) / spacing)) - margin, 0, resolution - 2),
		clampi(int(floorf((rect.end.x + half) / spacing)) + margin, 0, resolution - 2),
		clampi(int(floorf((rect.end.y + half) / spacing)) + margin, 0, resolution - 2)
	)

static func chunks_in_cell_rect(min_cell_x: int, min_cell_z: int, max_cell_x: int, max_cell_z: int) -> Array[Vector2i]:
	var keys: Array[Vector2i] = []
	if max_cell_x < min_cell_x or max_cell_z < min_cell_z:
		return keys
	var size := float(Meta.TERRAIN_CHUNK_CELLS)
	for chunk_z in range(floori(min_cell_z / size), floori(max_cell_z / size) + 1):
		for chunk_x in range(floori(min_cell_x / size), floori(max_cell_x / size) + 1):
			keys.append(Vector2i(chunk_x, chunk_z))
	return keys

## Rebuilds one chunk mesh and, unless `with_details` is false, its details.
## Returns the mesher parts ({mesh, shading}; empty when out of the grid):
## strokes keep the shading to scatter the details at the end.
func rebuild_chunk(terrain: Node3D, chunk_x: int, chunk_z: int, with_details: bool = true) -> Dictionary:
	var stream := editor_stream(terrain)
	if stream != null:
		return _rebuild_streamed_chunk(stream, terrain, chunk_x, chunk_z, with_details)
	var carve := get_river_carve(terrain)
	var parts := TerrainMesher.build_chunk_parts(terrain, carve, chunk_x, chunk_z)
	if parts.is_empty():
		return parts
	var mesh: ArrayMesh = parts["mesh"]
	var caster: Array = parts["caster"]
	apply_chunk_mesh(terrain, chunk_x, chunk_z, mesh, caster)
	if with_details:
		apply_chunk_details(terrain, chunk_x, chunk_z, parts["shading"])
		# Up to date now: a deferred job for it would only redo older work.
		_deferred.erase(_deferred_id(terrain, Vector2i(chunk_x, chunk_z)))
	return parts

## Puts a chunk mesh (TerrainMesher.assemble_chunk) on its chunk node,
## created when missing. Returns the node.
## `caster`: its MeshUtils.back_face_arrays() when already made (worker).
func apply_chunk_mesh(terrain: Node3D, chunk_x: int, chunk_z: int, mesh: ArrayMesh, caster: Array = []) -> MeshInstance3D:
	var chunk := _get_or_create_chunk_node(terrain, chunk_x, chunk_z)
	chunk.mesh = mesh
	if terrain.has_node(Meta.GENERATED_COLLISION_BODY_NAME):
		# Its collision shape is outdated (rebuild_collision makes it again).
		var dirty: Dictionary = _collision_dirty.get_or_add(terrain.get_instance_id(), {})
		dirty[String(chunk.name)] = true
	_update_ground_caster(terrain, chunk, caster)
	return chunk

# -----------------------------------------------------------------------------
# Deferred chunk work (editor)
# -----------------------------------------------------------------------------

## Queues the details of a chunk whose mesh is current (`shading` from its
## last mesher run), or with `mesh` the whole chunk (with its details unless
## `details` is false). A stroke ends in ~1 ms and this work runs in the next
## frames (process_deferred), so strokes can follow each other without a pause.
func defer_chunk(terrain: Node3D, key: Vector2i, mesh: bool, shading: Variant = null, details: bool = true) -> void:
	var id := _deferred_id(terrain, key)
	var previous: Dictionary = _deferred.get(id, {})
	var previous_mesh: bool = previous.get("mesh", false)
	var previous_details: bool = previous.get("details", false)
	_deferred[id] = {
		"terrain": weakref(terrain),
		"key": key,
		"mesh": mesh or previous_mesh,
		"details": details or previous_details,
		"shading": shading,
	}

func has_deferred() -> bool:
	return not _deferred.is_empty()

## Runs deferred jobs until `budget_usec` is spent (at least one job).
func process_deferred(budget_usec: int) -> void:
	var start := Time.get_ticks_usec()
	while not _deferred.is_empty():
		var id: String = _deferred.keys()[0]
		var job: Dictionary = _deferred[id]
		_deferred.erase(id)
		var terrain_ref: WeakRef = job["terrain"]
		# The terrain, or null once it is freed.
		var terrain_object: Object = terrain_ref.get_ref()
		var terrain := terrain_object as Node3D
		if is_instance_valid(terrain) and terrain.is_inside_tree():
			var key: Vector2i = job["key"]
			var details: bool = job["details"]
			if job["mesh"]:
				rebuild_chunk(terrain, key.x, key.y, details)
			elif job["details"]:
				apply_chunk_details(terrain, key.x, key.y, job["shading"])
		if Time.get_ticks_usec() - start >= budget_usec:
			return

func flush_deferred() -> void:
	process_deferred(1 << 62)

func _drop_deferred(terrain: Node3D) -> void:
	var prefix := "%d|" % terrain.get_instance_id()
	for id: String in _deferred.keys():
		if String(id).begins_with(prefix):
			_deferred.erase(id)

static func _deferred_id(terrain: Node3D, key: Vector2i) -> String:
	return "%d|%d|%d" % [terrain.get_instance_id(), key.x, key.y]

## Scatters the details of an existing chunk from its mesher shading.
func apply_chunk_details(terrain: Node3D, chunk_x: int, chunk_z: int, shading: Variant) -> void:
	var chunk := TerrainMesher.find_chunk(terrain, chunk_x, chunk_z)
	if chunk == null:
		return
	# Detail MultiMeshes (biome layers) are children of the chunk (same lifetime).
	# `shading` is a TerrainShading.Context or null (chunk_shading(), mesher parts).
	var context: TerrainShading.Context = shading
	var details := DetailScatter.build(terrain, get_river_carve(terrain), chunk_x, chunk_z, context)
	DetailScatter.apply(terrain, chunk, details, _detail_adder(terrain))
	_details_built(terrain, chunk_x, chunk_z)

## A streamed terrain's runtime knows chunk (chunk_x, chunk_z) has all its
## detail layers now.
static func _details_built(terrain: Node3D, chunk_x: int, chunk_z: int) -> void:
	var stream := editor_stream(terrain)
	if stream != null:
		stream.call(&"editor_details_built", Vector2i(chunk_x, chunk_z))

## Re-scatters the details of every chunk without rebuilding the terrain
## meshes (live biome editing). Ground colours are recomputed (no mesh).
func rebuild_all_details(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return
	var stream := editor_stream(terrain)
	if stream != null:
		# Streamed: made again as the camera sees them.
		stream.call(&"editor_details_changed")
		return
	var container := terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME) as Node3D
	if container == null:
		return
	var chunk_count := TerrainMesher.chunk_count(terrain)
	for chunk_z in range(chunk_count):
		for chunk_x in range(chunk_count):
			rebuild_chunk_details(terrain, chunk_x, chunk_z)

## Re-scatters the details of one existing chunk (no terrain mesh rebuild).
func rebuild_chunk_details(terrain: Node3D, chunk_x: int, chunk_z: int) -> void:
	var chunk := TerrainMesher.find_chunk(terrain, chunk_x, chunk_z)
	if chunk == null:
		return
	var carve := get_river_carve(terrain)
	DetailScatter.apply(terrain, chunk, DetailScatter.build(terrain, carve, chunk_x, chunk_z, chunk_shading(terrain, chunk_x, chunk_z)), _detail_adder(terrain))
	_details_built(terrain, chunk_x, chunk_z)

## Compiles the ground's vertex-colour material (or the Ground Material), so
## the first chunk does not (TerrainRuntime runs it as a step of its own).
static func warm_ground_material(terrain: Node3D) -> void:
	MaterialFactory.compile(MaterialFactory.terrain_vertex_color_material(terrain))

## One Callable per road and river that compiles its material (~25 ms the
## first time a kind of material is compiled; materials with the same
## features share the shader, so the next ones are free), so the road / river
## mesh step does not.
static func feature_material_warmups(terrain: Node3D) -> Array[Callable]:
	var warmups: Array[Callable] = []
	for road: Variant in terrain.get_meta(Meta.ROADS, []):
		warmups.append(_compile_road_material.bind(terrain, road))
	var mobile_water := Meta.get_bool(terrain, Meta.RIVER_MOBILE_WATER, false)
	var rivers: Array = terrain.get_meta(Meta.RIVERS, [])
	if not rivers.is_empty():
		# The generated wave texture (~20 ms), in a step of its own.
		warmups.append(MaterialFactory.generated_water_normal)
	for river: Variant in rivers:
		warmups.append(_compile_river_material.bind(terrain, river, mobile_water))
	return warmups

static func _compile_road_material(terrain: Node3D, road: Variant) -> void:
	MaterialFactory.compile(MaterialFactory.road_material(terrain, road))

static func _compile_river_material(terrain: Node3D, river: Variant, mobile_water: bool) -> void:
	MaterialFactory.compile(MaterialFactory.river_material(terrain, river, mobile_water))

## rebuild_chunk_details() in slices, for a game loading over several frames
## (TerrainRuntime): job := start_chunk_details(), step_chunk_details(job,
## budget) until it returns true, then finish_chunk_details(job). Same details
## however it is sliced (DetailScatter.build_begin / build_step).
## `layer_mask` (DetailScatter.layer_bit()): only these layers, the chunk's
## other detail nodes are kept as they are (-1 = all layers). `shading`: the
## chunk's chunk_shading() when the caller kept it (job["shading"] once
## started), null = made by the first step.
func start_chunk_details(terrain: Node3D, chunk_x: int, chunk_z: int, layer_mask: int = -1, shading: TerrainShading.Context = null) -> Dictionary:
	return {"terrain": terrain, "x": chunk_x, "z": chunk_z, "scatter": {}, "mask": layer_mask, "shading": shading}

## True when the job is done; `budget_usec` > 0 returns after about that long
## (the chunk's ground colours, ~7 ms on a laptop, are one slice).
func step_chunk_details(job: Dictionary, budget_usec: int = 0) -> bool:
	var start := Time.get_ticks_usec()
	var scatter: Dictionary = job["scatter"]
	if scatter.is_empty():
		var terrain: Node3D = job["terrain"]
		var chunk_x: int = job["x"]
		var chunk_z: int = job["z"]
		var shading: TerrainShading.Context = job.get("shading")
		if shading == null:
			shading = chunk_shading(terrain, chunk_x, chunk_z)
			job["shading"] = shading
		var layer_mask: int = job.get("mask", -1)
		scatter = DetailScatter.build_begin(terrain, get_river_carve(terrain), chunk_x, chunk_z, shading, layer_mask)
		job["scatter"] = scatter
	var left := budget_usec - (Time.get_ticks_usec() - start)
	if budget_usec > 0 and left <= 0:
		var done: bool = scatter["done"]
		return done
	return DetailScatter.build_step(scatter, maxi(left, 0) if budget_usec > 0 else 0)

## Puts a finished job's details under its chunk.
func finish_chunk_details(job: Dictionary) -> void:
	var terrain: Node3D = job["terrain"]
	var chunk_x: int = job["x"]
	var chunk_z: int = job["z"]
	var chunk := TerrainMesher.find_chunk(terrain, chunk_x, chunk_z)
	if chunk == null:
		return
	var scatter: Dictionary = job["scatter"]
	var layer_mask: int = job.get("mask", -1)
	DetailScatter.apply(terrain, chunk, DetailScatter.build_result(scatter), _detail_adder(terrain), layer_mask)

## Ground colours of one chunk, without building its mesh (for re-scatters).
func chunk_shading(terrain: Node3D, chunk_x: int, chunk_z: int) -> TerrainShading.Context:
	var cell_count: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION) - 1
	var min_x := chunk_x * Meta.TERRAIN_CHUNK_CELLS
	var min_z := chunk_z * Meta.TERRAIN_CHUNK_CELLS
	return TerrainShading.prepare(
		terrain, get_river_carve(terrain), min_x, min_z,
		mini(min_x + Meta.TERRAIN_CHUNK_CELLS, cell_count), mini(min_z + Meta.TERRAIN_CHUNK_CELLS, cell_count)
	)

func _detail_adder(terrain: Node3D) -> Callable:
	return func(parent: Node, child: Node) -> void: _add_generated_child(terrain, parent, child, true)

# -----------------------------------------------------------------------------
# Roads / rivers
# -----------------------------------------------------------------------------

## Rebuilds the road/river mesh and returns its collision faces. Does nothing
## when the terrain has no _GeneratedTerrainMesh child. `ground_changed`:
## where the ground changed since the last call, for the editor's cache
## (feature_cache_enabled): true = anywhere (all made again), a Rect2
## (terrain-local X/Z) = only there (the road bands there are redone), false
## = nowhere (only the roads / rivers that changed). Same mesh either way.
func rebuild_feature_mesh(terrain: Node3D, ground_changed: Variant = true) -> PackedVector3Array:
	if not feature_cache_enabled:
		var job := start_feature_mesh(terrain)
		step_feature_mesh(job)
		return finish_feature_mesh(terrain, job)
	var id := terrain.get_instance_id()
	var cache: Dictionary = _feature_cache.get(id, {})
	if ground_changed is bool and ground_changed:
		cache.clear()
	_feature_cache[id] = cache
	var dirty: Variant = ground_changed if ground_changed is Rect2 else null
	return _put_feature_mesh(terrain, FeatureMesher.build_cached(terrain, get_river_carve(terrain), cache, dirty))

## rebuild_feature_mesh() in slices (FeatureMesher.start / step / finish), for
## a game loading over several frames (TerrainRuntime).
func start_feature_mesh(terrain: Node3D) -> Dictionary:
	return FeatureMesher.start(terrain, get_river_carve(terrain))

## start_feature_mesh() with the groups computed on worker threads
## (FeatureMesher.start_threaded): step / finish the same way.
func start_feature_mesh_threaded(terrain: Node3D, split: bool = false) -> Dictionary:
	return FeatureMesher.start_threaded(terrain, get_river_carve(terrain), split)

## True when the job is done; `budget_usec` > 0 returns after about that long.
func step_feature_mesh(job: Dictionary, budget_usec: int = 0) -> bool:
	return FeatureMesher.step(job, budget_usec)

## Puts a finished job's mesh on the terrain; returns its collision faces.
func finish_feature_mesh(terrain: Node3D, job: Dictionary) -> PackedVector3Array:
	return _put_feature_mesh(terrain, FeatureMesher.finish(job))

## Puts a FeatureMesher result ({mesh, collision_faces}) on the terrain.
func _put_feature_mesh(terrain: Node3D, result: Dictionary) -> PackedVector3Array:
	var mesh_instance := terrain.get_node_or_null(Meta.GENERATED_MESH_NAME) as MeshInstance3D
	if not mesh_instance:
		# Not in the scene file when the terrain rebuilds everything at runtime.
		mesh_instance = MeshInstance3D.new()
		mesh_instance.name = Meta.GENERATED_MESH_NAME
		_add_generated_child(terrain, terrain, mesh_instance)

	# Roads and rivers lie flat on the ground: their shadow would only cost
	# a shadow pass (tens of thousands of triangles) for nothing visible.
	mesh_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var collision_faces: PackedVector3Array = result["collision_faces"]
	mesh_instance.mesh = result["mesh"]
	_feature_collision_cache[terrain.get_instance_id()] = collision_faces
	return collision_faces

## Feature collision faces from the last feature rebuild (rebuilds if none).
func get_feature_collision_faces(terrain: Node3D) -> PackedVector3Array:
	var terrain_id := terrain.get_instance_id()
	if _feature_collision_cache.has(terrain_id):
		return _feature_collision_cache[terrain_id]
	return rebuild_feature_mesh(terrain)

## The road / river preview only exists while drawing: not owned by the
## scene (not saved, hidden from the Scene dock) and freed by clear_preview(),
## so no empty MeshInstance3D is left behind (Godot shows a "requires a Mesh"
## warning on those).
func show_preview(terrain: Node3D, preview_feature: Dictionary) -> void:
	if preview_feature.is_empty():
		clear_preview(terrain)
		return
	var preview := terrain.get_node_or_null(Meta.GENERATED_PREVIEW_MESH_NAME) as MeshInstance3D
	if not preview:
		preview = MeshInstance3D.new()
		preview.name = Meta.GENERATED_PREVIEW_MESH_NAME
		preview.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		NodeNames.add(terrain, preview)
	preview.mesh = FeatureMesher.build_preview(terrain, get_river_carve(terrain), preview_feature)

## Also removes the empty preview node that older versions left (and saved).
func clear_preview(terrain: Node3D) -> void:
	var preview := terrain.get_node_or_null(Meta.GENERATED_PREVIEW_MESH_NAME)
	if preview:
		terrain.remove_child(preview)
		preview.queue_free()

# -----------------------------------------------------------------------------
# Dried waterholes
# -----------------------------------------------------------------------------

## Rebuilds the mud plate meshes, only of the waterholes touching `rect`
## (terrain-local X/Z) when given. Removes the container when there are none.
func rebuild_waterholes(terrain: Node3D, rect: Variant = null) -> void:
	var stream := editor_stream(terrain)
	if stream != null:
		stream.call(&"editor_holes_changed", rect)
		return
	var holes := WaterholeStyle.list(terrain)
	var container := terrain.get_node_or_null(Meta.GENERATED_WATERHOLES_NAME) as Node3D
	if holes.is_empty():
		if container:
			terrain.remove_child(container)
			container.queue_free()
		return
	container = _ensure_container(terrain, terrain, Meta.GENERATED_WATERHOLES_NAME, true)

	var carve := get_river_carve(terrain)
	var expected: Dictionary = {}
	for i in range(holes.size()):
		var node_name := "Waterhole_%d" % i
		expected[node_name] = true
		var node := container.get_node_or_null(node_name) as MeshInstance3D
		if node != null and rect != null:
			var area: Rect2 = rect
			if not WaterholeStyle.shape_in(terrain, holes[i]).bounds.intersects(area, true):
				continue
		node = _ensure_mesh_child(terrain, container, node_name)
		node.mesh = WaterholeMesher.build(terrain, carve, holes[i])
	for child in container.get_children():
		if not expected.has(child.name):
			container.remove_child(child)
			child.queue_free()

## Builds the plates of waterhole `index` only (LowpolyTerrainRuntime: one
## waterhole per build step).
func rebuild_waterhole(terrain: Node3D, index: int) -> void:
	var holes := WaterholeStyle.list(terrain)
	if index < 0 or index >= holes.size():
		return
	apply_waterhole_mesh(terrain, index, WaterholeMesher.build(terrain, get_river_carve(terrain), holes[index]))

## Puts the plates of waterhole `index` (WaterholeMesher.assemble) on its node.
func apply_waterhole_mesh(terrain: Node3D, index: int, mesh: ArrayMesh) -> void:
	var container := _ensure_container(terrain, terrain, Meta.GENERATED_WATERHOLES_NAME, true)
	var node := _ensure_mesh_child(terrain, container, "Waterhole_%d" % index)
	node.mesh = mesh

## After adding / changing waterholes inside `rect`: new carve, then only the
## chunks and plates of that area.
func rebuild_waterhole_area(terrain: Node3D, rect: Rect2) -> void:
	rebuild_river_carve(terrain)
	for key in chunks_for_local_rect(terrain, rect):
		rebuild_chunk(terrain, key.x, key.y)
	rebuild_waterholes(terrain, rect)

# -----------------------------------------------------------------------------
# Collision
# -----------------------------------------------------------------------------

## Editor: marks the collision of `terrain` as outdated. The plugin rebuilds
## it (flush_collision) once editing pauses, and before saving / running, so a
## stroke never waits for the whole-map collision shape (~150 ms on 192 m).
func request_collision(terrain: Node3D) -> void:
	_collision_pending[terrain.get_instance_id()] = weakref(terrain)
	_collision_requested_ms = Time.get_ticks_msec()

func has_pending_collision() -> bool:
	return not _collision_pending.is_empty()

## Milliseconds since the last request_collision().
func collision_request_age_ms() -> int:
	return Time.get_ticks_msec() - _collision_requested_ms

func flush_collision() -> void:
	# Collision is built from the chunk meshes: finish them first.
	flush_deferred()
	var pending := _collision_pending
	_collision_pending = {}
	for id: int in pending:
		var terrain_ref: WeakRef = pending[id]
		# The terrain, or null once it is freed.
		var terrain_object: Object = terrain_ref.get_ref()
		var terrain := terrain_object as Node3D
		if is_instance_valid(terrain) and terrain.is_inside_tree():
			rebuild_collision(terrain, get_feature_collision_faces(terrain))

## Rebuilds the optional collision body: one shape per chunk mesh (named like
## the chunk) and one for the roads / rivers (`feature_faces`). Only the
## chunks whose mesh changed since (or without a shape) get a new one: a
## stroke on a big map no longer rebuilds the whole-map shape.
## When collision is disabled the shapes are emptied (made again when it is
## turned back on: the meshes may change meanwhile).
func rebuild_collision(terrain: Node3D, feature_faces: PackedVector3Array = PackedVector3Array()) -> void:
	var id := terrain.get_instance_id()
	_collision_pending.erase(id)
	var dirty: Dictionary = _collision_dirty.get(id, {})
	_collision_dirty.erase(id)
	var stream := editor_stream(terrain)
	if stream != null:
		# One body per detailed chunk (the runtime's), the edited ones again.
		stream.call(&"editor_refresh_collision", feature_faces)
		return
	var enabled: bool = Meta.get_bool(terrain, Meta.COLLISION_ENABLED, false)
	var body := terrain.get_node_or_null(Meta.GENERATED_COLLISION_BODY_NAME) as StaticBody3D

	if not enabled:
		if body:
			for child in body.get_children():
				if child is CollisionShape3D:
					(child as CollisionShape3D).shape = null
					(child as CollisionShape3D).disabled = true
		_feature_shape_faces.erase(id)
		return

	if not body:
		body = StaticBody3D.new()
		body.name = Meta.GENERATED_COLLISION_BODY_NAME
		_add_generated_child(terrain, terrain, body)
	# Scenes saved with a single whole-map shape.
	var legacy := body.get_node_or_null(Meta.GENERATED_COLLISION_SHAPE_NAME)
	if legacy:
		body.remove_child(legacy)
		legacy.queue_free()

	var layer_number := clampi(Meta.get_int(terrain, Meta.COLLISION_LAYER, 1), 1, 32)
	body.collision_layer = 1 << (layer_number - 1)
	body.collision_mask = 0

	var wanted := {FEATURE_COLLISION_SHAPE_NAME: true}
	var container := terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME) as Node3D
	if container:
		for child in container.get_children():
			var chunk := child as MeshInstance3D
			if chunk == null:
				continue
			var shape_name := String(chunk.name)
			wanted[shape_name] = true
			var shape_node := _collision_shape_node(terrain, body, shape_name)
			if shape_node.shape != null and not dirty.has(shape_name):
				shape_node.disabled = false
				continue
			_set_collision_faces(shape_node, chunk.mesh.get_faces() if chunk.mesh != null else PackedVector3Array())

	var features := _collision_shape_node(terrain, body, FEATURE_COLLISION_SHAPE_NAME)
	var previous: Variant = _feature_shape_faces.get(id)
	if features.shape == null or not (previous is PackedVector3Array) or previous != feature_faces:
		_set_collision_faces(features, feature_faces)
		_feature_shape_faces[id] = feature_faces
	elif features.shape != null:
		features.disabled = false

	# Shapes of chunks that no longer exist (smaller map).
	for child in body.get_children():
		if child is CollisionShape3D and not wanted.has(String(child.name)):
			body.remove_child(child)
			child.queue_free()

## Shape node `shape_name` of the collision body, created when missing.
func _collision_shape_node(terrain: Node3D, body: StaticBody3D, shape_name: String) -> CollisionShape3D:
	var node := body.get_node_or_null(shape_name) as CollisionShape3D
	if node == null:
		node = CollisionShape3D.new()
		node.name = shape_name
		_add_generated_child(terrain, body, node)
	return node

static func _set_collision_faces(node: CollisionShape3D, faces: PackedVector3Array) -> void:
	if faces.is_empty():
		node.shape = null
		node.disabled = true
		return
	var concave := ConcavePolygonShape3D.new()
	concave.backface_collision = true
	concave.set_faces(faces)
	node.shape = concave
	node.disabled = false
