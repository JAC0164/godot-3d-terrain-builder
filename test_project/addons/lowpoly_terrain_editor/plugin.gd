@tool
extends EditorPlugin
## Lowpoly Terrain Editor - editor entry point.
##
## Wires the editor (toolbar, Inspector panel, viewport input, Undo/Redo,
## dialogs) to the editing modules. The terrain logic itself lives in:
##   core/        metadata keys, grid math, terrain data, sampling, snapshots
##   styles/      per-cell paint styles, road/river style dictionaries
##   editing/     brushes, canvas growth, feature erasing, stroke controller
##   mesh/        terrain / road / river meshers, node builder, collision
##   materials/   material factory and water shader
##   biomes/      biome / detail layer / ground style Resources (.tres)
##   generation/  pixel-map terrain generator, map recipes + map generator
##   runtime/     LowpolyTerrainRuntime (in-game build, tree collision)
##   io/          level JSON export
##   ui/          toolbar, Inspector panel, level dialogs
##
## Editable data is stored as metadata on the terrain Node3D; generated meshes
## are disposable and rebuilt from it.

const Meta = preload("core/terrain_meta.gd")
const NodeNames = preload("core/node_names.gd")
const TerrainData = preload("core/terrain_data.gd")
const TerrainSnapshot = preload("core/terrain_snapshot.gd")
const ToolMode = preload("editing/tool_mode.gd")
const StrokeController = preload("editing/stroke_controller.gd")
const Canvas = preload("editing/canvas.gd")
const TerrainBuilder = preload("mesh/terrain_builder.gd")
const ImageGenerator = preload("generation/image_generator.gd")
const TerrainToolbar = preload("ui/terrain_toolbar.gd")
const TerrainInspectorPlugin = preload("ui/terrain_inspector_plugin.gd")
const MaterialFactory = preload("materials/material_factory.gd")
const TerrainBiome = preload("biomes/terrain_biome.gd")
const GroundStyle = preload("biomes/ground_style.gd")
const WaterholeStyle = preload("styles/waterhole_style.gd")
const MapGenerator = preload("generation/map_generator.gd")
const MapPresets = preload("generation/map_presets.gd")
const MapRecipe = preload("generation/map_recipe.gd")
const DetailCollision = preload("mesh/detail_collision.gd")
const TerrainRuntime = preload("runtime/terrain_runtime.gd")
const SurfaceRay = preload("editing/surface_ray.gd")
const FeatureEraser = preload("editing/feature_eraser.gd")
const BrushOverlay = preload("ui/brush_overlay.gd")
const EditorCameraFramer = preload("ui/editor_camera_framer.gd")
const TerrainStorage = preload("core/terrain_storage.gd")
const DetailScatter = preload("mesh/detail_scatter.gd")
const GroundBumps = preload("core/ground_bumps.gd")
const TerrainNavigation = preload("navigation/terrain_navigation.gd")
const HeightmapIO = preload("generation/heightmap_io.gd")

## Delay after the last biome edit before the details are re-scattered.
const BIOME_REBUILD_DELAY_MS := 250
const NO_TERRAIN_STATUS := "No terrain selected"
## Biome of a new terrain (relative to the plugin folder): the generic
## Temperate one. Inspector > Look > Biome picks another (e.g. the savanna).
const NEW_TERRAIN_BIOME := "biomes/presets/temperate.tres"
## New terrains: small bumps (m) in the ground, so it is not a dead flat sheet
## (Inspector > Look > Ground Bumps). The ground's texture / style is the
## game's own Ground Material (Inspector > Look).
const NEW_TERRAIN_GROUND_BUMPS := 0.3

var _active_terrain: Node3D = null
var _builder: TerrainBuilder
var _strokes: StrokeController
var _toolbar: TerrainToolbar
## Terrain whose map is being generated (generate_map, a few frames), or null.
var _generating: Node3D = null
## Runtime nodes streaming a big terrain whose loading shows in the toolbar
## (instance id -> their connected progress callable), until `finished`.
var _watched_streams: Dictionary = {}
var _inspector_plugin: TerrainInspectorPlugin
var _last_tuning_signature := ""
## Biome of the active terrain whose `changed` signal is connected.
var _watched_biome: Resource = null
## Last selected terrain: its biome stays watched while the biome itself is
## open in the Inspector (the terrain is then no longer the edited object).
var _biome_terrain: Node3D = null
var _biome_dirty_since_ms := -1
## Shading / waterhole colors of the watched biome at the last rebuild.
var _biome_look_signature := ""
## Brush ring: ground point under the mouse (terrain local, null = none) and
## the camera of the viewport it was computed in.
var _hover_local: Variant = null
var _hover_camera: Camera3D = null
var _hover_over_feature := false
## Tool picked in the toolbar. _strokes.mode is the tool of the click (Ctrl /
## Shift variants, see ToolMode.with_modifiers); _hover_mode what the ring shows.
var _tool: ToolMode.Mode = ToolMode.Mode.NONE
var _hover_mode: ToolMode.Mode = ToolMode.Mode.NONE
## Inspector refresh after the road / river width changed from the toolbar
## (debounced: dragging the field must not rebuild the Inspector each step).
var _inspector_refresh_at_ms := -1
## Collision of edited terrain is rebuilt after this pause (and before saving
## or running the game), never during a stroke.
const COLLISION_IDLE_MS := 1200
## Time per frame given to the chunk work left by a stroke (details, colour
## blur of the neighbours): the editor keeps ~60 fps while it finishes.
const DEFERRED_BUDGET_USEC := 10000
var _stroke_flush_queued := false
## Brush size / strength are kept per project between editor sessions
## (.godot/editor/project_metadata.cfg), saved a moment after the last change.
const SETTINGS_SECTION := "lowpoly_terrain_editor"
const SETTINGS_SAVE_DELAY_MS := 1000
var _brush_settings_save_at_ms := -1

# =============================================================================
# PLUGIN LIFECYCLE
# =============================================================================

func _enter_tree() -> void:
	_builder = TerrainBuilder.new()
	_builder.owner_provider = func() -> Node: return EditorInterface.get_edited_scene_root()

	_strokes = StrokeController.new(_builder)
	_strokes.undo_handler = _register_snapshot_undo
	_load_brush_settings()

	_inspector_plugin = TerrainInspectorPlugin.new(self)
	add_inspector_plugin(_inspector_plugin)

	_create_toolbar()
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)

	set_process(true)
	_update_toolbar_state()

func _exit_tree() -> void:
	if _brush_settings_save_at_ms >= 0:
		_save_brush_settings()
	if _inspector_plugin:
		remove_inspector_plugin(_inspector_plugin)
		_inspector_plugin = null
	if _toolbar:
		remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
		_toolbar.queue_free()
		_toolbar = null
	MaterialFactory.clear_cache()

func _handles(object: Object) -> bool:
	# Return true for ANY Node3D so the toolbar (and "New Terrain") is always
	# available in 3D scenes.
	return object is Node3D

func _edit(object: Object) -> void:
	if Meta.is_terrain(object):
		_active_terrain = object
		_biome_terrain = object
		# Normally done by the runtime node when the scene loads.
		TerrainStorage.unpack(_active_terrain)
		TerrainData.ensure_defaults(_active_terrain)
		# First: a big terrain is built around the camera by this node.
		ensure_runtime_node(_active_terrain)
		# Build once per terrain instance (scene opened: meshes generated by an
		# older version of the plugin are replaced). Selecting it again later
		# must not freeze the editor for a full rebuild.
		if not _builder.is_built(_active_terrain):
			if _restored_on_open(_active_terrain):
				_builder.mark_built(_active_terrain)
			else:
				_builder.rebuild_all(_active_terrain)
		_builder.clear_preview(_active_terrain)
		_last_tuning_signature = TerrainData.tuning_signature(_active_terrain)
		ensure_runtime_node(_active_terrain)
		_watch_stream(_active_terrain)
	else:
		_active_terrain = null
	_update_toolbar_state()
	# The empty-terrain hint depends on the selected terrain.
	update_overlays()

## "Everything at runtime" terrain whose meshes the runtime node just built
## when the scene opened (with this plugin version: nothing to replace).
func _restored_on_open(terrain: Node3D) -> bool:
	if TerrainBuilder.runtime_build(terrain) != Meta.RUNTIME_BUILD_ALL:
		return false
	var chunks := terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME)
	return chunks != null and chunks.owner == null and chunks.get_child_count() > 0

func _make_visible(visible: bool) -> void:
	if _toolbar:
		_toolbar.visible = visible

## Rebuilds the meshes when geometry settings were changed from outside the
## plugin's own controls (e.g. the raw metadata editor).
func _process(delta: float) -> void:
	# Button held with the mouse still: the brush keeps working in place.
	if _strokes.is_stroke_active() and is_instance_valid(_active_terrain):
		_strokes.hold(_active_terrain, delta)
		_queue_stroke_flush()
	if _brush_settings_save_at_ms >= 0 and Time.get_ticks_msec() >= _brush_settings_save_at_ms:
		_save_brush_settings()
	if _inspector_refresh_at_ms >= 0 and Time.get_ticks_msec() >= _inspector_refresh_at_ms:
		_inspector_refresh_at_ms = -1
		if is_instance_valid(_active_terrain):
			_active_terrain.notify_property_list_changed()
	# End-of-stroke chunk work, a slice per frame (never during a stroke).
	if _builder.has_deferred() and not _strokes.is_stroke_active():
		_builder.process_deferred(DEFERRED_BUDGET_USEC)
	if _builder.has_pending_collision() and not _strokes.is_stroke_active() and _builder.collision_request_age_ms() >= COLLISION_IDLE_MS:
		_builder.flush_collision()

	# Generate Map writes its settings step by step: no rebuild of the half
	# written map (it rebuilds once at the end).
	if _generating != null:
		pass
	elif is_instance_valid(_active_terrain):
		var signature := TerrainData.tuning_signature(_active_terrain)
		if signature != _last_tuning_signature:
			_last_tuning_signature = signature
			_biome_dirty_since_ms = -1
			_builder.rebuild_all(_active_terrain)
	else:
		_last_tuning_signature = ""

	# Live biome editing, a moment after the last change so dragging a slider
	# stays responsive: shading / waterhole colors rebuild the terrain, other
	# edits (layers, styles) re-scatter the details only.
	var biome_terrain := _active_terrain if is_instance_valid(_active_terrain) else _biome_terrain
	if not is_instance_valid(biome_terrain) or not biome_terrain.is_inside_tree():
		_biome_terrain = null
		_watch_biome(null)
		return
	var watched_object: Object = Meta.get_optional(biome_terrain, Meta.BIOME)
	_watch_biome(watched_object as Resource)
	if _biome_dirty_since_ms >= 0 and Time.get_ticks_msec() - _biome_dirty_since_ms >= BIOME_REBUILD_DELAY_MS:
		_biome_dirty_since_ms = -1
		var look := _watched_look_signature()
		if look != _biome_look_signature:
			_biome_look_signature = look
			_builder.rebuild_all(biome_terrain)
		else:
			_builder.rebuild_all_details(biome_terrain)
		_refresh_vegetation_targets()
		_refresh_ground_styles()

## Vegetation target list = the enabled detail layers of the active terrain's
## biome (layer renamed or removed: back to All plants).
func _refresh_vegetation_targets() -> void:
	if _toolbar == null:
		return
	var names := PackedStringArray()
	if is_instance_valid(_active_terrain):
		var biome := DetailScatter.biome_of(_active_terrain)
		if biome:
			for layer in biome.detail_layers:
				if layer != null and layer.enabled and not names.has(String(layer.name)):
					names.append(String(layer.name))
	_strokes.vegetation_target = _toolbar.set_vegetation_targets(names, _strokes.vegetation_target)

## Ground styles of the active terrain's biome (built-in Temperate if none).
func _ground_styles() -> Array:
	if not is_instance_valid(_active_terrain):
		return []
	return _styles_of(_active_terrain)

func _styles_of(terrain: Node3D) -> Array:
	var biome_object: Object = Meta.get_optional(terrain, Meta.BIOME)
	var biome: TerrainBiome = biome_object as Resource
	if biome == null:
		biome = TerrainBiome.default_biome()
	return biome.ground_styles.filter(func(style: Resource) -> bool: return style != null)

## Fills the Ground style list and selects the style the brush holds (same
## colors and textures), else "Custom". A brush never set takes the biome's
## first style, so the first stroke matches the map.
func _refresh_ground_styles() -> void:
	if _toolbar == null:
		return
	var styles := _ground_styles()
	if not styles.is_empty() and not _active_terrain.has_meta(Meta.BRUSH_TOP_COLOR):
		var first_style: Resource = styles[0]
		_load_brush(_active_terrain, first_style)
	var names := PackedStringArray()
	var colors: Array = []
	var selected := -1
	for i in styles.size():
		var style: GroundStyle = styles[i]
		names.append(String(style.name))
		colors.append([style.top_color, style.side_color])
		if selected < 0 and _brush_matches(style):
			selected = i
	_toolbar.set_ground_styles(names, colors, selected)

## True when the brush is unset or holds one of the terrain biome's styles:
## it then follows a biome change (see _follow_biome_brush).
func _brush_follows_biome(terrain: Node3D) -> bool:
	if not terrain.has_meta(Meta.BRUSH_TOP_COLOR):
		return true
	return _styles_of(terrain).any(func(style: Resource) -> bool: return _brush_matches(style, terrain))

## After a biome change: a brush that held an old biome style takes the new
## biome's first style; Custom colours are kept.
func _follow_biome_brush(terrain: Node3D, follows: bool) -> void:
	var styles := _styles_of(terrain)
	if not follows or styles.is_empty():
		return
	if not styles.any(func(style: Resource) -> bool: return _brush_matches(style, terrain)):
		var first_style: Resource = styles[0]
		_load_brush(terrain, first_style)

func _brush_matches(style: Resource, terrain: Node3D = null) -> bool:
	var t := terrain if terrain != null else _active_terrain
	var ground_style: GroundStyle = style
	var brush_top_color: Color = t.get_meta(Meta.BRUSH_TOP_COLOR, Meta.DEFAULT_TOP_COLOR)
	if not brush_top_color.is_equal_approx(ground_style.top_color):
		return false
	var brush_cliff_color: Color = t.get_meta(Meta.BRUSH_CLIFF_COLOR, Meta.DEFAULT_CLIFF_COLOR)
	return (brush_cliff_color.is_equal_approx(ground_style.side_color)
		and Meta.get_optional(t, Meta.BRUSH_TOP_TEXTURE) == ground_style.top_texture
		and Meta.get_optional(t, Meta.BRUSH_CLIFF_TEXTURE) == ground_style.side_texture)

## Toolbar Ground list: a biome style, or Custom (the brush as it is).
func _on_ground_style_picked(index: int) -> void:
	if not is_instance_valid(_active_terrain):
		return
	var styles := _ground_styles()
	if index >= 0 and index < styles.size():
		var style: Resource = styles[index]
		use_ground_style(_active_terrain, style)
	else:
		if _tool != ToolMode.Mode.PAINT:
			_set_tool(ToolMode.Mode.PAINT)
		_set_status("Custom ground style", "Its colors / textures: Inspector > Advanced > Custom Ground Style.")

func _watch_biome(biome: Resource) -> void:
	if biome == _watched_biome:
		return
	if is_instance_valid(_watched_biome) and _watched_biome.changed.is_connected(_on_biome_changed):
		_watched_biome.changed.disconnect(_on_biome_changed)
	_watched_biome = biome
	_biome_look_signature = _watched_look_signature()
	if biome != null:
		biome.changed.connect(_on_biome_changed)

func _watched_look_signature() -> String:
	if not is_instance_valid(_watched_biome):
		return ""
	var watched: TerrainBiome = _watched_biome
	return watched.look_signature()

func _on_biome_changed() -> void:
	_biome_dirty_since_ms = Time.get_ticks_msec()

# =============================================================================
# TOOLBAR
# =============================================================================

func _create_toolbar() -> void:
	_toolbar = TerrainToolbar.new(_strokes.brush_radius, _strokes.brush_strength)
	_toolbar.new_terrain_pressed.connect(_create_new_terrain)
	_toolbar.tool_pressed.connect(func(mode: ToolMode.Mode) -> void:
		# Clicking the active tool deselects it; another tool switches at once.
		_set_tool(ToolMode.Mode.NONE if _tool == mode else mode)
	)
	_toolbar.brush_radius_changed.connect(_set_size)
	_toolbar.brush_strength_changed.connect(func(value: float) -> void:
		_strokes.brush_strength = value
		_brush_settings_changed()
		update_overlays())
	_toolbar.vegetation_target_changed.connect(func(target: String) -> void:
		_strokes.vegetation_target = target
		# Picking a decor type means painting it.
		if not ToolMode.is_vegetation_tool(_tool):
			_set_tool(ToolMode.Mode.VEGETATION)
		update_overlays())
	_toolbar.ground_style_changed.connect(_on_ground_style_picked)

func _set_tool(mode: ToolMode.Mode) -> void:
	_tool = mode
	_hover_mode = mode
	if not _strokes.is_stroke_active():
		_strokes.mode = mode
	_toolbar.set_active_tool(mode)
	_update_toolbar_state()
	update_overlays()

## Size field / [ ] keys: the brush radius, or the width of new roads /
## rivers when that tool is active (the ring shows it).
func _size_value() -> float:
	if ToolMode.is_feature_tool(_tool) and is_instance_valid(_active_terrain):
		return ToolMode.feature_width(_active_terrain, _tool)
	return _strokes.brush_radius

func _set_size(value: float) -> void:
	if ToolMode.is_feature_tool(_tool) and is_instance_valid(_active_terrain):
		_active_terrain.set_meta(ToolMode.feature_width_key(_tool), value)
		_inspector_refresh_at_ms = Time.get_ticks_msec() + 400
	else:
		_strokes.brush_radius = value
		_brush_settings_changed()
	update_overlays()

func _load_brush_settings() -> void:
	var settings := EditorInterface.get_editor_settings()
	var saved_radius: float = settings.get_project_metadata(SETTINGS_SECTION, "brush_radius", _strokes.brush_radius)
	_strokes.brush_radius = clampf(saved_radius, ToolMode.BRUSH_RADIUS_MIN, ToolMode.BRUSH_RADIUS_MAX)
	var saved_strength: float = settings.get_project_metadata(SETTINGS_SECTION, "brush_strength", _strokes.brush_strength)
	_strokes.brush_strength = clampf(saved_strength, ToolMode.BRUSH_STRENGTH_MIN, ToolMode.BRUSH_STRENGTH_MAX)

func _brush_settings_changed() -> void:
	_brush_settings_save_at_ms = Time.get_ticks_msec() + SETTINGS_SAVE_DELAY_MS

func _save_brush_settings() -> void:
	_brush_settings_save_at_ms = -1
	var settings := EditorInterface.get_editor_settings()
	settings.set_project_metadata(SETTINGS_SECTION, "brush_radius", _strokes.brush_radius)
	settings.set_project_metadata(SETTINGS_SECTION, "brush_strength", _strokes.brush_strength)

func _update_toolbar_state() -> void:
	if not _toolbar:
		return
	var has_terrain := is_instance_valid(_active_terrain)
	_toolbar.set_terrain_controls_enabled(has_terrain)
	_toolbar.set_tool_context(_tool, _size_value())
	_refresh_vegetation_targets()
	_refresh_ground_styles()
	if not has_terrain:
		_toolbar.set_status(NO_TERRAIN_STATUS)
	elif _toolbar.get_status() == NO_TERRAIN_STATUS:
		# The active tool is shown by its button and the brush ring, an empty
		# terrain by a hint in the 3D view (_draw_empty_hint). Other messages
		# (e.g. the Generate Map summary) stay until the next one.
		_toolbar.set_status("")

func _set_status(text: String, detail: String = "") -> void:
	if _toolbar:
		_toolbar.set_status(text, detail)

## A big terrain streamed around the camera: its loading (ground, then
## details and the far ground) shows as a progress bar until it is done.
func _watch_stream(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return
	var runtime := TerrainBuilder.editor_stream(terrain)
	if runtime == null or _watched_streams.has(runtime.get_instance_id()):
		return
	var loaded: bool = runtime.get(&"is_finished")
	if loaded:
		return
	var on_progress := _on_stream_progress.bind(runtime)
	_watched_streams[runtime.get_instance_id()] = on_progress
	runtime.connect(&"progress", on_progress)
	runtime.connect(&"finished", _on_stream_finished.bind(runtime), CONNECT_ONE_SHOT)

func _on_stream_progress(done: int, total: int, runtime: Node) -> void:
	if not _toolbar or _generating != null:
		return
	# Only the selected terrain's loading.
	if not is_instance_valid(_active_terrain) or TerrainBuilder.editor_stream(_active_terrain) != runtime:
		return
	var ground_ready: bool = runtime.get(&"is_ground_ready")
	var text := "Loading details..." if ground_ready else "Loading ground..."
	_toolbar.set_progress(float(done) / float(maxi(total, 1)), text)

func _on_stream_finished(_stats: Dictionary, runtime: Node) -> void:
	var on_progress: Callable = _watched_streams.get(runtime.get_instance_id(), Callable())
	_watched_streams.erase(runtime.get_instance_id())
	if on_progress.is_valid() and runtime.is_connected(&"progress", on_progress):
		runtime.disconnect(&"progress", on_progress)
	if _toolbar and _generating == null:
		_toolbar.set_progress(-1.0)

# =============================================================================
# UNDO / REDO
# =============================================================================

func _get_active_undo_history() -> UndoRedo:
	var manager := get_undo_redo()
	var context: Object = _active_terrain if is_instance_valid(_active_terrain) else EditorInterface.get_edited_scene_root()
	if context == null:
		return null
	var history_id: int = manager.get_object_history_id(context)
	return manager.get_history_undo_redo(history_id)

## Undo / Redo of the terrain's history (same as Ctrl+Z / Ctrl+Shift+Z; the
## test harness uses them).
func _toolbar_undo() -> void:
	var history := _get_active_undo_history()
	if history != null and history.has_undo():
		history.undo()

func _toolbar_redo() -> void:
	var history := _get_active_undo_history()
	if history != null and history.has_redo():
		history.redo()

## Registers an already-applied edit as an Undo/Redo action.
## `area` (see StrokeController.undo_handler): the part of the terrain the
## action changed, so Undo / Redo rebuild only that; null = everything.
## The history keeps only what changed (TerrainSnapshot.delta_pair) when the
## grid size did not change.
func _register_snapshot_undo(action_name: String, terrain: Node3D, before: Dictionary, after: Dictionary, area: Variant = null) -> void:
	var pair := TerrainSnapshot.delta_pair(before, after)
	if not pair.is_empty():
		before = pair[0]
		after = pair[1]
	var undo_redo := get_undo_redo()
	undo_redo.create_action(action_name, UndoRedo.MERGE_DISABLE, terrain)
	undo_redo.add_do_method(self, "_restore_snapshot", terrain, after, area)
	undo_redo.add_undo_method(self, "_restore_snapshot", terrain, before, area)
	undo_redo.commit_action(false)

func _restore_snapshot(terrain: Node3D, snapshot: Dictionary, area: Variant = null) -> void:
	if not is_instance_valid(terrain):
		return
	var snapshot_resolution: int = snapshot.get("resolution", -1)
	var snapshot_world_size: float = snapshot.get("world_size", -1.0)
	var same_grid := (
		area is Dictionary
		and snapshot_resolution == Meta.get_int(terrain, Meta.RESOLUTION, -2)
		and is_equal_approx(snapshot_world_size, Meta.get_float(terrain, Meta.WORLD_SIZE, -2.0))
	)
	TerrainSnapshot.apply(terrain, snapshot)
	if same_grid and _builder.is_built(terrain):
		# Chunks over the next frames: Undo answers at once.
		var area_options: Dictionary = area
		var options: Dictionary = area_options.duplicate()
		options["defer"] = true
		var rect: Rect2 = area_options["rect"]
		_builder.rebuild_area(terrain, rect, options)
	else:
		_builder.rebuild_all(terrain)

## Godot calls this before saving and before running the game: the collision
## shape must be current in the saved scene.
func _apply_changes() -> void:
	if _builder:
		_builder.flush_deferred()
		if _builder.has_pending_collision():
			_builder.flush_collision()

## Mesh refresh of the current stroke, once per frame (several mouse samples
## of one frame share it), see StrokeController.flush().
func _queue_stroke_flush() -> void:
	if _stroke_flush_queued or not _strokes.needs_flush():
		return
	_stroke_flush_queued = true
	_flush_stroke.call_deferred()

func _flush_stroke() -> void:
	_stroke_flush_queued = false
	if _strokes.is_stroke_active() and is_instance_valid(_active_terrain):
		_strokes.flush(_active_terrain)

# =============================================================================
# TERRAIN CREATION
# =============================================================================

func _create_new_terrain() -> void:
	var scene_root := EditorInterface.get_edited_scene_root()
	if not scene_root:
		push_warning("Lowpoly Terrain Editor: create or open a scene before creating terrain.")
		return

	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	# LowpolyTerrain2, 3... when the scene already has one (core/node_names.gd).
	NodeNames.add(scene_root, terrain)
	terrain.owner = scene_root

	TerrainData.initialize(terrain)
	# New terrains keep only their data in the scene file (a few KB): meshes,
	# details and collision are rebuilt when the scene opens / the game starts.
	# Inspector > Game > Runtime Build changes it.
	terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	# Ground painted by hand stays bare: trees and props come from Generate
	# Map or the Vegetation tool (Inspector > Advanced > Details).
	terrain.set_meta(Meta.DETAILS_EVERYWHERE, false)
	# Walkable at once, like a generated map (Inspector > Game > Walkable
	# Collision). With "All at runtime" it is built when the game starts.
	terrain.set_meta(Meta.COLLISION_ENABLED, true)
	# Small bumps in the ground (Inspector > Look > Ground Bumps).
	GroundBumps.set_amount(terrain, NEW_TERRAIN_GROUND_BUMPS)
	# New terrains start in the generic Temperate biome, so the ground list
	# and the proposed Map Preset agree from the start (Inspector > Look > Biome).
	var plugin_script: Script = get_script()
	var biome_path: String = plugin_script.resource_path.get_base_dir().path_join(NEW_TERRAIN_BIOME)
	if ResourceLoader.exists(biome_path):
		Meta.set_optional(terrain, Meta.BIOME, load(biome_path))
		# The default brush is the Temperate grass: take the biome's first style.
		_follow_biome_brush(terrain, true)

	_builder.rebuild_all(terrain)
	_last_tuning_signature = TerrainData.tuning_signature(terrain)

	var undo_redo := get_undo_redo()
	undo_redo.create_action("Create Lowpoly Terrain", UndoRedo.MERGE_DISABLE, terrain)
	undo_redo.add_do_reference(terrain)
	undo_redo.add_undo_method(scene_root, "remove_child", terrain)
	undo_redo.add_do_method(scene_root, "add_child", terrain)
	undo_redo.add_do_method(self, "_restore_terrain_owners", terrain, scene_root)
	undo_redo.commit_action(false)

	var selection := EditorInterface.get_selection()
	selection.clear()
	selection.add_node(terrain)

	_active_terrain = terrain
	_set_tool(ToolMode.Mode.PAINT)

## Redo of New Terrain: remove_child (its Undo) cleared the owner of the
## terrain and of every node under it, which would vanish from the Scene dock
## and the saved file. The runtime node and nodes added by the user are the
## scene's again; the generated nodes follow Runtime Build.
func _restore_terrain_owners(terrain: Node3D, scene_root: Node) -> void:
	if not is_instance_valid(terrain) or not terrain.is_inside_tree():
		return
	terrain.owner = scene_root
	var generated := [Meta.GENERATED_CHUNKS_NAME, Meta.GENERATED_WATERHOLES_NAME, Meta.GENERATED_COLLISION_BODY_NAME, Meta.GENERATED_MESH_NAME]
	for child in terrain.get_children():
		if String(child.name) in generated:
			continue
		child.owner = scene_root
		for node in child.find_children("*", "", true, false):
			node.owner = scene_root
	_builder.apply_ownership(terrain)

# =============================================================================
# VIEWPORT INPUT
# =============================================================================

func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	# No stroke while a map is being generated (its data is half written).
	if not is_instance_valid(_active_terrain) or _tool == ToolMode.Mode.NONE or _generating != null:
		_clear_hover()
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventKey:
		return _viewport_key(event as InputEventKey)

	var mouse_button := event as InputEventMouseButton
	if mouse_button != null and mouse_button.button_index == MOUSE_BUTTON_LEFT:
		if mouse_button.pressed:
			# Camera navigation first: Alt+LMB orbits (Maya / Modo schemes),
			# and a click while RMB / MMB holds the camera is not a stroke.
			if mouse_button.alt_pressed or Input.is_mouse_button_pressed(MOUSE_BUTTON_RIGHT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			var local_hit: Variant = _mouse_to_local_terrain(viewport_camera, mouse_button.position)
			if local_hit == null:
				# Sky / horizon: nothing to edit, but do not let the click
				# deselect the terrain (the tool would vanish).
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			var press_hit: Vector3 = local_hit
			_strokes.mode = _modified_tool(mouse_button)
			_strokes.begin(_active_terrain, press_hit)
			_queue_stroke_flush()
			_set_hover(viewport_camera, press_hit, _strokes.mode)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		elif _strokes.is_stroke_active():
			_end_stroke()
			return EditorPlugin.AFTER_GUI_INPUT_STOP

	var mouse_motion := event as InputEventMouseMotion
	if mouse_motion != null:
		# Button released outside the 3D view: no release event reached us.
		if _strokes.is_stroke_active() and not (mouse_motion.button_mask & MOUSE_BUTTON_MASK_LEFT):
			_end_stroke()
		var local_hit: Variant = _mouse_to_local_terrain(viewport_camera, mouse_motion.position)
		if local_hit == null:
			_clear_hover()
		else:
			var hover_hit: Vector3 = local_hit
			_set_hover(viewport_camera, hover_hit, _strokes.mode if _strokes.is_stroke_active() else _modified_tool(mouse_motion))
		if _strokes.is_stroke_active():
			if local_hit != null:
				var stroke_hit: Vector3 = local_hit
				_strokes.update(_active_terrain, stroke_hit)
				_queue_stroke_flush()
			return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_PASS

## Keys over the 3D view while a tool is active.
##   [ ]  size (radius, or road / river width)    - =  strength
##   Esc  leave the tool    Ctrl / Shift  the ring shows the variant at once
func _viewport_key(event: InputEventKey) -> int:
	if event.keycode in [KEY_CTRL, KEY_SHIFT, KEY_META] and not _strokes.is_stroke_active():
		if _hover_local != null:
			_hover_mode = _modified_tool(event)
			update_overlays()
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not event.pressed or event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	match event.keycode:
		KEY_BRACKETLEFT, KEY_BRACKETRIGHT:
			var factor := 1.0 / 1.2 if event.keycode == KEY_BRACKETLEFT else 1.2
			var size := _size_value() * factor
			if ToolMode.is_feature_tool(_tool):
				size = clampf(snappedf(size, ToolMode.FEATURE_WIDTH_STEP), ToolMode.FEATURE_WIDTH_MIN, ToolMode.FEATURE_WIDTH_MAX)
			else:
				size = clampf(snappedf(size, ToolMode.BRUSH_RADIUS_STEP), ToolMode.BRUSH_RADIUS_MIN, ToolMode.BRUSH_RADIUS_MAX)
			_set_size(size)
			_toolbar.set_brush_radius(size)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_MINUS, KEY_KP_SUBTRACT, KEY_EQUAL, KEY_KP_ADD:
			if not ToolMode.is_brush_tool(_tool):
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			var up: bool = event.keycode == KEY_EQUAL or event.keycode == KEY_KP_ADD
			_strokes.brush_strength = clampf(snappedf(_strokes.brush_strength * (1.25 if up else 0.8), ToolMode.BRUSH_STRENGTH_STEP), ToolMode.BRUSH_STRENGTH_MIN, ToolMode.BRUSH_STRENGTH_MAX)
			_toolbar.set_brush_strength(_strokes.brush_strength)
			_brush_settings_changed()
			update_overlays()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		KEY_ESCAPE:
			if _strokes.is_stroke_active():
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			_set_tool(ToolMode.Mode.NONE)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	return EditorPlugin.AFTER_GUI_INPUT_PASS

func _modified_tool(event: InputEventWithModifiers) -> ToolMode.Mode:
	return ToolMode.with_modifiers(_tool, event.is_command_or_control_pressed(), event.shift_pressed)

func _end_stroke() -> void:
	_strokes.end(_active_terrain)
	_strokes.mode = _tool
	_hover_mode = _tool
	update_overlays()

func _set_hover(camera: Camera3D, local_hit: Vector3, mode: ToolMode.Mode = _tool) -> void:
	_hover_local = local_hit
	_hover_camera = camera
	_hover_mode = mode
	_hover_over_feature = false
	if mode == ToolMode.Mode.ERASE and not _strokes.is_stroke_active():
		_hover_over_feature = FeatureEraser.has_feature_at(_active_terrain, Vector2(local_hit.x, local_hit.z), _strokes.brush_radius)
	update_overlays()

func _clear_hover() -> void:
	if _hover_local != null:
		_hover_local = null
		update_overlays()

## Brush ring over the 3D viewport (see ui/brush_overlay.gd), and the hint
## of an empty terrain.
func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if is_instance_valid(_active_terrain):
		var cells: PackedByteArray = _active_terrain.get_meta(Meta.CELL_ACTIVE, PackedByteArray())
		if not cells.has(1):
			_draw_empty_hint(overlay)
	if _hover_local == null or not is_instance_valid(_active_terrain) or not is_instance_valid(_hover_camera):
		return
	if _tool == ToolMode.Mode.NONE:
		return
	# Hide it once the mouse has left this viewport.
	if not Rect2(Vector2.ZERO, overlay.size).has_point(overlay.get_local_mouse_position()) and not _strokes.is_stroke_active():
		return
	var hover_point: Vector3 = _hover_local
	BrushOverlay.draw(overlay, _hover_camera, _active_terrain, _strokes.mode if _strokes.is_stroke_active() else _hover_mode, hover_point, {
		"radius": _strokes.brush_radius,
		"strength": _strokes.brush_strength,
		"stroke_active": _strokes.is_stroke_active(),
		"carve": _builder.get_river_carve(_active_terrain),
		"over_feature": _hover_over_feature,
		"vegetation_target": _strokes.vegetation_target,
	})

## One line at the top of the 3D view while the terrain has no ground yet (it
## goes away with the first Paint stroke or a generated map).
const EMPTY_HINT := "Empty terrain: drag in the view to add ground  ·  or Inspector > Generate Map"

func _draw_empty_hint(overlay: Control) -> void:
	var font := overlay.get_theme_font("font", "Label")
	var font_size := overlay.get_theme_font_size("font_size", "Label")
	var scale := EditorInterface.get_editor_scale()
	var padding := Vector2(12.0, 6.0) * scale
	var max_width := maxf(overlay.size.x - 2.0 * padding.x - 16.0 * scale, 64.0)
	var text_size := font.get_multiline_string_size(EMPTY_HINT, HORIZONTAL_ALIGNMENT_CENTER, max_width, font_size)
	var top_left := Vector2((overlay.size.x - text_size.x) * 0.5, 52.0 * scale)
	overlay.draw_rect(Rect2(top_left - padding, text_size + 2.0 * padding), Color(0.0, 0.0, 0.0, 0.65))
	overlay.draw_multiline_string(font, top_left + Vector2(0.0, font.get_ascent(font_size)), EMPTY_HINT,
		HORIZONTAL_ALIGNMENT_CENTER, text_size.x, font_size, -1, Color(1.0, 1.0, 1.0, 0.92))

## Ground point under the mouse in terrain local space: the terrain surface
## (heights, river carving), or the terrain's zero plane when the ray misses
## it. Returns null when both miss.
func _mouse_to_local_terrain(camera: Camera3D, screen_position: Vector2) -> Variant:
	if not is_instance_valid(_active_terrain):
		return null

	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_direction := camera.project_ray_normal(screen_position)
	var surface_hit: Variant = SurfaceRay.hit(_active_terrain, _builder.get_river_carve(_active_terrain), ray_origin, ray_direction)
	if surface_hit != null:
		return surface_hit

	var plane_normal := _active_terrain.global_transform.basis.y.normalized()
	var plane := Plane(plane_normal, plane_normal.dot(_active_terrain.global_position))
	var world_hit: Variant = plane.intersects_ray(ray_origin, ray_direction)

	if world_hit == null:
		return null
	var world_point: Vector3 = world_hit
	return _active_terrain.to_local(world_point)

# =============================================================================
# INSPECTOR ACTIONS (called by ui/terrain_inspector_plugin.gd)
# =============================================================================

## Rebuilds the whole terrain and records the settings it was built with,
## so _process() does not see a "changed" signature and rebuild it a second
## time on the next frame.
func _rebuild_all(terrain: Node3D) -> void:
	# A big terrain is built around the camera by this node.
	ensure_runtime_node(terrain)
	_builder.rebuild_all(terrain)
	_watch_stream(terrain)
	if terrain == _active_terrain:
		_last_tuning_signature = TerrainData.tuning_signature(terrain)
		# Same for its biome: watched from now on, so an edit made right after
		# (even in this frame) is seen and rebuilds again.
		var watched_object: Object = Meta.get_optional(terrain, Meta.BIOME)
		_watch_biome(watched_object as Resource)
		_biome_look_signature = _watched_look_signature()

## Writes a geometry setting and rebuilds the terrain. Undoable; changes of
## the same setting in a row (spin box steps) merge into one Undo. The height
## limits clamp the ground: their Undo gives the clamped heights back.
func set_tuning_setting(terrain: Node3D, key: String, value: Variant) -> void:
	if not is_instance_valid(terrain):
		return
	var old_value: Variant = terrain.get_meta(key, null)
	if typeof(old_value) == typeof(value) and old_value == value:
		return
	var clamps := key == Meta.HEIGHT_MIN or key == Meta.HEIGHT_MAX
	var before := TerrainSnapshot.capture(terrain) if clamps else {}
	terrain.set_meta(key, value)
	if clamps:
		TerrainData.clamp_heights_to_limits(terrain)
	var after := TerrainSnapshot.capture(terrain) if clamps else {}

	_rebuild_all(terrain)
	terrain.notify_property_list_changed()
	var undo_redo := get_undo_redo()
	undo_redo.create_action("Lowpoly Terrain: %s" % key.trim_prefix("_lte_").capitalize(), UndoRedo.MERGE_ENDS, terrain)
	undo_redo.add_do_method(self, "_restore_tuning_setting", terrain, key, value, after)
	undo_redo.add_undo_method(self, "_restore_tuning_setting", terrain, key, old_value, before)
	undo_redo.commit_action(false)

func _restore_tuning_setting(terrain: Node3D, key: String, value: Variant, snapshot: Dictionary) -> void:
	if not is_instance_valid(terrain):
		return
	Meta.set_optional(terrain, key, value)
	if not snapshot.is_empty():
		TerrainSnapshot.apply(terrain, snapshot)
	_rebuild_all(terrain)
	terrain.notify_property_list_changed()

## Look > Ground Bumps: new height of the small bumps (the relief painted on
## top stays). Undoable; changes made in a row merge into one Undo.
func set_ground_bumps(terrain: Node3D, value: float) -> void:
	if not is_instance_valid(terrain) or is_equal_approx(value, GroundBumps.amount(terrain)):
		return
	var old_amount := GroundBumps.amount(terrain)
	var before := TerrainSnapshot.capture(terrain)
	GroundBumps.set_amount(terrain, value)
	var after := TerrainSnapshot.capture(terrain)
	_rebuild_all(terrain)
	var undo_redo := get_undo_redo()
	undo_redo.create_action("Lowpoly Terrain: Ground Bumps", UndoRedo.MERGE_ENDS, terrain)
	undo_redo.add_do_method(terrain, "set_meta", Meta.GROUND_BUMPS, GroundBumps.amount(terrain))
	undo_redo.add_do_method(self, "_restore_snapshot", terrain, after)
	undo_redo.add_do_method(terrain, "notify_property_list_changed")
	undo_redo.add_undo_method(terrain, "set_meta", Meta.GROUND_BUMPS, old_amount)
	undo_redo.add_undo_method(self, "_restore_snapshot", terrain, before)
	undo_redo.add_undo_method(terrain, "notify_property_list_changed")
	undo_redo.commit_action(false)

## Roads, Rivers & Waterholes > Customise Road / Customise Water: puts an
## editable road material / copy of the built-in water in the terrain's biome
## (an editable Temperate first when it has none) and opens it. The roads /
## rivers that follow the biome take it. Undoable (the material slot).
func customise_feature_material(terrain: Node3D, water: bool) -> void:
	if not is_instance_valid(terrain):
		return
	if not (Meta.get_optional(terrain, Meta.BIOME) is TerrainBiome):
		terrain.set_meta(Meta.BIOME, TerrainBiome.make_temperate())
		EditorInterface.mark_scene_as_unsaved()
	var biome := TerrainBiome.of(terrain)
	var property := "water_material" if water else "road_material"
	var material: Material = biome.get(property)
	if material == null:
		material = MaterialFactory.editable_water_material(biome.water_color) if water else MaterialFactory.editable_road_material(biome.road_color)
		var undo_redo := get_undo_redo()
		undo_redo.create_action("Lowpoly Terrain: Customise %s" % ("Water" if water else "Road"), UndoRedo.MERGE_DISABLE, terrain)
		undo_redo.add_do_property(biome, property, material)
		undo_redo.add_undo_property(biome, property, null)
		undo_redo.commit_action()
	# Deferred: the Inspector button that called this is still emitting.
	EditorInterface.edit_resource.call_deferred(material)

## Game > Ground Casts Shadows: applied to the ground chunks at once, no
## rebuild. Undoable.
func set_ground_shadows(terrain: Node3D, enabled: bool) -> void:
	if not is_instance_valid(terrain) or enabled == Meta.get_bool(terrain, Meta.GROUND_SHADOWS, true):
		return
	var undo_redo := get_undo_redo()
	undo_redo.create_action("Lowpoly Terrain: Ground Casts Shadows", UndoRedo.MERGE_DISABLE, terrain)
	undo_redo.add_do_method(terrain, "set_meta", Meta.GROUND_SHADOWS, enabled)
	undo_redo.add_do_method(self, "_apply_ground_shadows", terrain)
	undo_redo.add_do_method(terrain, "notify_property_list_changed")
	undo_redo.add_undo_method(terrain, "set_meta", Meta.GROUND_SHADOWS, not enabled)
	undo_redo.add_undo_method(self, "_apply_ground_shadows", terrain)
	undo_redo.add_undo_method(terrain, "notify_property_list_changed")
	undo_redo.commit_action()

## Look > Replace Details: re-scatters grass, rocks, trees and props on the
## current ground. Painting and sculpting leave the details as they are.
## The details follow from the terrain data (nothing to undo).
func replace_details(terrain: Node3D) -> void:
	if not is_instance_valid(terrain) or not _builder.is_built(terrain):
		return
	var start := Time.get_ticks_msec()
	_builder.flush_deferred()
	_builder.rebuild_all_details(terrain)
	_set_status("Details replaced", "Grass, rocks, trees and props put on the current ground in %d ms." % (Time.get_ticks_msec() - start))

## Game > Bake Navigation: the terrain's NavigationRegion3D child
## ("Navigation", made once) gets a navigation mesh of the walkable ground
## (TerrainNavigation), baked on a worker thread.
func bake_navigation(terrain: Node3D) -> void:
	if not is_instance_valid(terrain) or not _builder.is_built(terrain):
		return
	_builder.flush_deferred()
	var region := TerrainNavigation.ensure_region(terrain, EditorInterface.get_edited_scene_root())
	var start := Time.get_ticks_msec()
	var done := func() -> void:
		var polygons := region.navigation_mesh.get_polygon_count() if is_instance_valid(region) and region.navigation_mesh else 0
		_set_status("Navigation baked", "%d polygons in %d ms (node %s). Bake again after editing the ground." % [polygons, Time.get_ticks_msec() - start, TerrainNavigation.REGION_NAME])
		EditorInterface.mark_scene_as_unsaved()
	if TerrainNavigation.bake(terrain, region, _builder.get_river_carve(terrain), AABB(), true, done):
		_set_status("Baking navigation...")
	else:
		_set_status("Navigation", "A bake is already running.")

func _apply_ground_shadows(terrain: Node3D) -> void:
	if is_instance_valid(terrain):
		TerrainBuilder.apply_ground_shadows(terrain)

## Assigns a biome (null = built-in Temperate) and rebuilds: the terrain's
## shading and waterhole colors are the biome's.
func set_biome(terrain: Node3D, biome: Resource) -> void:
	if not is_instance_valid(terrain):
		return
	if biome != null and biome.get_script() != TerrainBiome:
		push_warning("Lowpoly Terrain Editor: the Biome must be a LowpolyTerrainBiome resource.")
		return
	var brush_follows := _brush_follows_biome(terrain)
	Meta.set_optional(terrain, Meta.BIOME, biome)
	_follow_biome_brush(terrain, brush_follows)
	_rebuild_all(terrain)
	ensure_runtime_node(terrain)
	# Other biome = other ground styles and detail layers in the toolbar lists.
	_refresh_vegetation_targets()
	_refresh_ground_styles()
	terrain.notify_property_list_changed()
	EditorInterface.mark_scene_as_unsaved()

## Gives the terrain its own copy of its biome (a biome file is shared by
## every terrain using it), then opens it in the Inspector. Same look, so no
## rebuild. Undo restores the shared biome.
func copy_biome_to_terrain(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return
	var before: Variant = Meta.get_optional(terrain, Meta.BIOME)
	var own: TerrainBiome = TerrainBiome.of(terrain).duplicate(true)
	own.name = "%s (%s)" % [own.name, terrain.name]
	var undo_redo := get_undo_redo()
	undo_redo.create_action("Lowpoly Terrain: Copy Biome to Terrain", UndoRedo.MERGE_DISABLE, terrain)
	undo_redo.add_do_method(self, "_swap_biome", terrain, own)
	undo_redo.add_undo_method(self, "_swap_biome", terrain, before)
	undo_redo.commit_action()
	# Deferred: the Inspector button that called this is still emitting.
	EditorInterface.edit_resource.call_deferred(own)

## Same-look biome swap (no rebuild): the copy holds the same values.
func _swap_biome(terrain: Node3D, biome: Variant) -> void:
	if not is_instance_valid(terrain):
		return
	Meta.set_optional(terrain, Meta.BIOME, biome)
	_last_tuning_signature = TerrainData.tuning_signature(terrain) if terrain == _active_terrain else _last_tuning_signature
	_refresh_toolbar_lists(terrain)
	terrain.notify_property_list_changed()

## True when the terrain's biome is a file of the project (shared by every
## terrain that uses it), false for a biome stored in the scene.
static func biome_is_shared(terrain: Node3D) -> bool:
	var biome_object: Object = Meta.get_optional(terrain, Meta.BIOME)
	var biome := biome_object as Resource
	return biome != null and biome.resource_path != "" and not biome.resource_path.contains("::")

## Gives every existing waterhole the current Dried Waterholes settings
## (Undo/Redo supported).
func apply_waterhole_settings(terrain: Node3D) -> void:
	if not is_instance_valid(terrain) or WaterholeStyle.list(terrain).is_empty():
		return
	var before := TerrainSnapshot.capture(terrain)
	WaterholeStyle.apply_settings_to_all(terrain)
	var after := TerrainSnapshot.capture(terrain)
	_rebuild_all(terrain)
	if not TerrainSnapshot.equal(before, after):
		_register_snapshot_undo("Lowpoly Terrain: Update Waterholes", terrain, before, after)

# =============================================================================
# MAP GENERATOR / RUNTIME
# =============================================================================

## The Map Recipes of generation/presets/ (Inspector "Map Preset" list).
func get_map_presets() -> Array[Resource]:
	var plugin_script: Script = get_script()
	return MapPresets.list(plugin_script.resource_path.get_base_dir().path_join("generation/presets"))

## Recipe Generate Map uses when none is assigned: the preset of the terrain's
## biome, else the first preset.
func default_map_recipe(terrain: Node3D) -> Resource:
	return MapPresets.default_for(terrain, get_map_presets(), Meta.BIOME)

## Message the user sees at once (editor toast), also kept in the Output log.
func _notify(text: String) -> void:
	_set_status(text)
	EditorInterface.get_editor_toaster().push_toast("Lowpoly Terrain: " + text, EditorToaster.SEVERITY_WARNING)

## Replaces the terrain by a map made from its Map Recipe (none = the default
## preset, see default_map_recipe) and Map Seed, with Undo/Redo (every
## terrain setting the generator writes is restored).
func generate_map(terrain: Node3D, new_seed: int = -1) -> void:
	if not is_instance_valid(terrain) or _generating != null:
		return
	var before := _capture_all_meta(terrain)
	if new_seed >= 0:
		terrain.set_meta(Meta.MAP_SEED, new_seed)
	var recipe_object: Object = Meta.get_optional(terrain, Meta.MAP_RECIPE)
	var recipe := recipe_object as Resource
	if recipe == null:
		recipe = default_map_recipe(terrain)
		if recipe == null:
			_notify("no Map Recipe: pick one in Inspector > Map > Map Preset.")
			return
		terrain.set_meta(Meta.MAP_RECIPE, recipe)
	var map_seed := Meta.get_int(terrain, Meta.MAP_SEED, 0)
	var brush_follows := _brush_follows_biome(terrain)
	# One step a frame, with a progress bar (< 1 s for 1 024 x 1 024 cells).
	var generation := MapGenerator.start(terrain, recipe, map_seed)
	_generating = terrain
	var finished := false
	while not finished:
		if _toolbar:
			_toolbar.set_progress(generation.progress(), "Map: %s..." % generation.next_step().to_lower())
		await get_tree().process_frame
		if not is_instance_valid(terrain):
			_generating = null
			if _toolbar:
				_toolbar.set_progress(-1.0)
			return
		finished = MapGenerator.step(generation)
	_generating = null
	if _toolbar:
		_toolbar.set_progress(-1.0)
	var stats := generation.stats
	_follow_biome_brush(terrain, brush_follows)
	var after := _capture_all_meta(terrain)
	_rebuild_all(terrain)
	ensure_runtime_node(terrain)
	terrain.notify_property_list_changed()
	_frame_map(terrain)
	_refresh_toolbar_lists(terrain)
	update_overlays()
	# Short line (the end of the toolbar holds ~17 characters), the rest in
	# its tooltip.
	var map_recipe: MapRecipe = recipe
	_set_status("Map seed %d" % map_seed, "Map %s, seed %d: %d x %d cells, plateaus %d, lowlands %d, tracks %d, waterholes %d, %.0f ms." % [
		map_recipe.name, map_seed, stats["size"], stats["size"], stats["plateau_cells"], stats["lowland_cells"],
		stats["tracks"], stats["waterholes"], stats["ms"]])
	var undo_redo := get_undo_redo()
	undo_redo.create_action("Lowpoly Terrain: Generate Map", UndoRedo.MERGE_DISABLE, terrain)
	undo_redo.add_do_method(self, "_restore_all_meta", terrain, after)
	undo_redo.add_undo_method(self, "_restore_all_meta", terrain, before)
	undo_redo.commit_action(false)

## Brings the map into view when it is not on screen (new map, other size,
## camera looking elsewhere). The view angle is kept.
func _frame_map(terrain: Node3D) -> void:
	var aabb := EditorCameraFramer.terrain_aabb(terrain, Meta.GENERATED_CHUNKS_NAME)
	if aabb.size == Vector3.ZERO or EditorCameraFramer.is_in_view(aabb):
		return
	EditorCameraFramer.frame(self, aabb)

## New random Map Seed, then Generate Map (its Undo gives the old seed back).
func generate_random_map(terrain: Node3D) -> void:
	if not is_instance_valid(terrain) or _generating != null:
		return
	await generate_map(terrain, randi() % 1000000)

func _capture_all_meta(terrain: Node3D) -> Dictionary:
	var values: Dictionary = {}
	for key in terrain.get_meta_list():
		if String(key).begins_with("_lte_"):
			var value: Variant = terrain.get_meta(key)
			if value is Array:
				var array_value: Array = value
				value = array_value.duplicate(true)
			elif value is Dictionary:
				var dictionary_value: Dictionary = value
				value = dictionary_value.duplicate(true)
			values[key] = value
	return values

func _restore_all_meta(terrain: Node3D, values: Dictionary) -> void:
	if not is_instance_valid(terrain):
		return
	for key in terrain.get_meta_list():
		if String(key).begins_with("_lte_") and not values.has(key):
			terrain.remove_meta(key)
	for key: StringName in values:
		var value: Variant = values[key]
		if value is Array:
			var array_value: Array = value
			value = array_value.duplicate(true)
		elif value is Dictionary:
			var dictionary_value: Dictionary = value
			value = dictionary_value.duplicate(true)
		terrain.set_meta(key, value)
	_rebuild_all(terrain)
	_refresh_toolbar_lists(terrain)
	terrain.notify_property_list_changed()

## Biome-dependent toolbar lists (ground styles, plants) of the active terrain.
func _refresh_toolbar_lists(terrain: Node3D) -> void:
	if terrain == _active_terrain:
		_refresh_vegetation_targets()
		_refresh_ground_styles()

## What the scene file stores (Meta.RUNTIME_BUILD_*); the rest is rebuilt by
## the terrain's LowpolyTerrainRuntime child when the scene loads.
func set_runtime_build(terrain: Node3D, mode: int) -> void:
	if not is_instance_valid(terrain):
		return
	terrain.set_meta(Meta.RUNTIME_BUILD, mode)
	_last_tuning_signature = TerrainData.tuning_signature(terrain)
	_builder.apply_ownership(terrain)
	ensure_runtime_node(terrain)
	terrain.notify_property_list_changed()
	EditorInterface.mark_scene_as_unsaved()

## Adds the LowpolyTerrainRuntime child when the terrain needs it in game
## (runtime build mode, or detail layers with collision). Returns it.
func ensure_runtime_node(terrain: Node3D) -> Node:
	if not is_instance_valid(terrain):
		return null
	var existing := terrain.get_node_or_null(Meta.RUNTIME_NODE_NAME)
	if existing:
		return existing
	for child in terrain.get_children():
		if child.get_script() == TerrainRuntime:
			return child
	var needed := TerrainBuilder.runtime_build(terrain) != Meta.RUNTIME_BUILD_NOTHING or DetailCollision.has_collision_layers(terrain)
	var scene_root := EditorInterface.get_edited_scene_root()
	if scene_root == null or not (terrain == scene_root or scene_root.is_ancestor_of(terrain)):
		return null
	# Terrains of this scene always get it: it also packs the terrain data
	# compactly when the scene is saved (core/terrain_storage.gd). A terrain
	# of an instanced scene only when its game build needs it.
	var own_terrain := terrain == scene_root or terrain.owner == scene_root
	if not needed and not own_terrain:
		return null
	var runtime := TerrainRuntime.new()
	runtime.name = Meta.RUNTIME_NODE_NAME
	NodeNames.add(terrain, runtime)
	runtime.owner = scene_root
	if needed:
		# Technical note for the Output log only (the toolbar keeps its line
		# for what the user did).
		print("Lowpoly Terrain: added %s (in-game build + tree collision)." % Meta.RUNTIME_NODE_NAME)
	return runtime

## Gives the terrain its own editable copy of the built-in Temperate biome
## (embedded in the scene; save it as a .tres from its Inspector to reuse it).
func create_biome(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return
	var biome := TerrainBiome.make_temperate()
	terrain.set_meta(Meta.BIOME, biome)
	_rebuild_all(terrain)
	terrain.notify_property_list_changed()
	EditorInterface.mark_scene_as_unsaved()
	# Deferred: the Inspector button that called this is still emitting.
	EditorInterface.edit_resource.call_deferred(biome)

## Loads a biome ground style into the Custom Ground Style (what the Ground
## tool paints) and selects the Ground tool.
func use_ground_style(terrain: Node3D, style: Resource) -> void:
	if not is_instance_valid(terrain) or style == null:
		return
	_load_brush(terrain, style)
	var ground_style: GroundStyle = style
	_set_status("Brush: %s" % ground_style.name)
	if terrain == _active_terrain:
		if _tool != ToolMode.Mode.PAINT:
			_set_tool(ToolMode.Mode.PAINT)
		_refresh_ground_styles()
	terrain.notify_property_list_changed()

func _load_brush(terrain: Node3D, style: Resource) -> void:
	var ground_style: GroundStyle = style
	terrain.set_meta(Meta.BRUSH_TOP_COLOR, ground_style.top_color)
	terrain.set_meta(Meta.BRUSH_CLIFF_COLOR, ground_style.side_color)
	Meta.set_optional(terrain, Meta.BRUSH_TOP_TEXTURE, ground_style.top_texture)
	Meta.set_optional(terrain, Meta.BRUSH_CLIFF_TEXTURE, ground_style.side_texture)
	terrain.set_meta(Meta.BRUSH_TOP_TILE_SIZE, ground_style.top_tile_size)
	terrain.set_meta(Meta.BRUSH_CLIFF_TILE_SIZE, ground_style.side_tile_size)

## Grows the canvas by one Expansion Chunk on every side.
func grow_canvas(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return
	var cells_per_side := Canvas.cells_for_grow_step(terrain)
	if cells_per_side <= 0:
		push_warning("Lowpoly Terrain Editor: the terrain reached its Maximum Cells (Inspector > Advanced > Terrain Size).")
		return
	var before := TerrainSnapshot.capture(terrain)
	Canvas.expand(terrain, cells_per_side)
	_rebuild_all(terrain)
	terrain.notify_property_list_changed()
	_register_snapshot_undo("Lowpoly Terrain: Grow Terrain", terrain, before, TerrainSnapshot.capture(terrain))

## Advanced > Terrain Size > Import Heightmap: the heights from an EXR / PNG /
## raw file (HeightmapIO), resized to the grid, with Undo/Redo.
func import_heightmap(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return
	_open_file_dialog(EditorFileDialog.FILE_MODE_OPEN_FILE, "Import Heightmap",
		PackedStringArray(["*.exr ; OpenEXR (metres)", "*.png ; PNG (8 or 16 bit)", "*.r16, *.raw ; 16-bit raw"]),
		func(path: String) -> void:
			if not is_instance_valid(terrain):
				return
			var before := TerrainSnapshot.capture(terrain)
			var stats := HeightmapIO.import_file(terrain, path)
			if stats.has("error"):
				_notify(str(stats["error"]))
				return
			_rebuild_all(terrain)
			var after := TerrainSnapshot.capture(terrain)
			if not TerrainSnapshot.equal(before, after):
				_register_snapshot_undo("Lowpoly Terrain: Import Heightmap", terrain, before, after)
			var source_range: Vector2 = stats["range"]
			var clamped: int = stats["clamped"]
			var detail := "%s (%d x %d)%s." % [path.get_file(), stats["width"], stats["height"],
				"" if stats["metres"] else ", black %.2f m to white %.2f m" % [source_range.x, source_range.y]]
			if clamped > 0:
				detail += " %d points cut to the Lowest / Highest Ground (Advanced > Heights & Offsets)." % clamped
			_set_status("Heightmap imported", detail))

## Advanced > Terrain Size > Export Heightmap: <name>.exr (metres), .png
## (16-bit) and .json (its range).
func export_heightmap(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return
	_open_file_dialog(EditorFileDialog.FILE_MODE_SAVE_FILE, "Export Heightmap",
		PackedStringArray(["*.exr ; OpenEXR (+ 16-bit PNG and JSON)"]),
		func(path: String) -> void:
			if not is_instance_valid(terrain):
				return
			var error := HeightmapIO.export_files(terrain, path)
			if not error.is_empty():
				_notify(error)
				return
			var base := path.get_basename().get_file()
			_set_status("Heightmap exported", "%s.exr (metres), %s.png (16-bit) and %s.json (its range)." % [base, base, base])
			EditorInterface.get_resource_filesystem().scan())

## A one-use file dialog on the whole file system; `on_file` gets the path.
func _open_file_dialog(mode: EditorFileDialog.FileMode, title: String, filters: PackedStringArray, on_file: Callable) -> void:
	var dialog := EditorFileDialog.new()
	dialog.name = "LowpolyHeightmapDialog"
	dialog.file_mode = mode
	dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	dialog.title = title
	dialog.filters = filters
	var close := func() -> void:
		if is_instance_valid(dialog):
			dialog.queue_free()
	dialog.file_selected.connect(func(path: String) -> void:
		close.call()
		on_file.call(path))
	dialog.canceled.connect(close)
	NodeNames.add(EditorInterface.get_base_control(), dialog)
	dialog.popup_file_dialog()

## Rebuilds the terrain from its Source Pixel Map, with Undo/Redo.
func generate_from_image(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return

	var texture_object: Object = Meta.get_optional(terrain, Meta.GENERATOR_IMAGE)
	var texture := texture_object as Texture2D
	if texture == null:
		_notify("assign a Source Image first (Inspector > Advanced > Pixel Map).")
		return

	var image: Image = texture.get_image()
	var error := ImageGenerator.validate_image(image)
	if not error.is_empty():
		_notify(error)
		return

	var before := TerrainSnapshot.capture(terrain)
	var stats := ImageGenerator.apply(terrain, image)
	_rebuild_all(terrain)
	terrain.notify_property_list_changed()

	var unknown_pixels: int = stats["unknown"]
	if unknown_pixels > 0:
		push_warning("Lowpoly Terrain Editor: %d pixel(s) did not match white/green/red/blue within tolerance and were treated as empty." % stats["unknown"])
	_set_status("Image %d x %d" % [stats["width"], stats["height"]], "Generated from a %d x %d image: %d green, %d red, %d blue pixels." % [stats["width"], stats["height"], stats["green"], stats["red"], stats["blue"]])

	var after := TerrainSnapshot.capture(terrain)
	if not TerrainSnapshot.equal(before, after):
		_register_snapshot_undo("Lowpoly Terrain: Generate from Image", terrain, before, after)

