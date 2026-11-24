@tool
extends RefCounted
## Turns mouse strokes in the 3D viewport into terrain edits.
##
## A stroke is begin() -> update()* -> end(). Fluidity rules (a 192 m map
## must stay smooth under the brush):
##   - each mouse sample only edits the terrain data (well under 1 ms);
##   - flush() rebuilds the touched chunk meshes, at most once per frame
##     (the plugin calls it deferred), without their grass / trees;
##   - end() scatters the details of the touched chunks once, and only asks
##     for the collision (rebuilt when editing pauses, see TerrainBuilder);
##   - fast strokes are filled with stamps (no gaps between mouse samples).
## end() reports the before/after snapshots and the changed area through
## `undo_handler`, so Undo/Redo rebuilds that area only.

const Meta = preload("../core/terrain_meta.gd")
const TerrainSampler = preload("../core/terrain_sampler.gd")
const TerrainSnapshot = preload("../core/terrain_snapshot.gd")
const StylePalette = preload("../styles/style_palette.gd")
const FeatureStyle = preload("../styles/feature_style.gd")
const TerrainBuilder = preload("../mesh/terrain_builder.gd")
const ToolMode = preload("tool_mode.gd")
const Brush = preload("brush.gd")
const Canvas = preload("canvas.gd")
const FeatureEraser = preload("feature_eraser.gd")
const RiverMesher = preload("../mesh/river_mesher.gd")
const WaterholeStyle = preload("../styles/waterhole_style.gd")

## Gap between two brush stamps, as a fraction of the radius. Mouse samples
## further apart are filled in, so a quick stroke leaves no holes.
const STAMP_SPACING := 0.35
const MAX_STAMPS_PER_SAMPLE := 64

var mode: ToolMode.Mode = ToolMode.Mode.NONE
var brush_radius := 3.0
var brush_strength := 1.0
## What the Vegetation brush paints: Meta.VEGETATION_ALL (every plant layer)
## or one detail layer name.
var vegetation_target := ""

var builder: TerrainBuilder
## Called as undo_handler.call(action_name: String, terrain: Node3D,
## before: Dictionary, after: Dictionary, area: Variant) when a stroke changed
## the terrain. `area` is null (rebuild everything) or
## {rect: Rect2, carve: bool, features: bool, waterholes: bool}.
var undo_handler: Callable = Callable()

var _stroke_active := false
var _stroke_before: Dictionary = {}
var _flatten_height := 0.0
var _feature_points: Array[Vector2] = []
var _waterhole_center := Vector2.ZERO
var _erase_feature_stroke := false
var _stroke_dirty_rect := Rect2()
var _stroke_has_dirty_rect := false
var _max_expand_warned_this_stroke := false
## Last brush stamp (Vector2) of the stroke, null before the first.
var _last_stamp: Variant = null
## Chunk meshes to rebuild at the next flush (Vector2i -> true). With the
## Vegetation brush: chunks whose details to re-scatter (no mesh change).
var _pending_chunks: Dictionary = {}
## Chunks touched by the stroke (Vector2i -> mesher shading), for details.
var _stroke_chunks: Dictionary = {}
## The canvas grew during the stroke: Undo needs a full rebuild.
var _canvas_expanded := false
var _feature_mesh_dirty := false
## Feature erase: rivers or waterholes changed (river carve to recompute).
var _erase_changed_carve := false
var _erase_removed_waterhole := false

func _init(p_builder: TerrainBuilder) -> void:
	builder = p_builder

func is_stroke_active() -> bool:
	return _stroke_active

## True while some mesh work of the stroke waits for flush().
func needs_flush() -> bool:
	return not _pending_chunks.is_empty() or _feature_mesh_dirty

func _feature_type() -> String:
	return FeatureStyle.ROAD if mode == ToolMode.Mode.ROAD else FeatureStyle.RIVER

static func _to_2d(local_position: Vector3) -> Vector2:
	return Vector2(local_position.x, local_position.z)

# -----------------------------------------------------------------------------
# Stroke lifecycle
# -----------------------------------------------------------------------------

func begin(terrain: Node3D, local_position: Vector3) -> void:
	_stroke_active = true
	_stroke_before = TerrainSnapshot.capture(terrain)
	_erase_feature_stroke = false
	_stroke_dirty_rect = Rect2()
	_stroke_has_dirty_rect = false
	_max_expand_warned_this_stroke = false
	_last_stamp = null
	_pending_chunks.clear()
	_stroke_chunks.clear()
	_canvas_expanded = false
	_feature_mesh_dirty = false
	_erase_changed_carve = false
	_erase_removed_waterhole = false
	var point := _to_2d(local_position)

	if mode == ToolMode.Mode.ERASE:
		# An erase stroke that starts over a road/river erases features only.
		_erase_feature_stroke = FeatureEraser.has_feature_at(terrain, point, brush_radius)
		if _erase_feature_stroke:
			_erase_features(terrain, point)
			return

	if ToolMode.is_feature_tool(mode):
		_feature_points.clear()
		_feature_points.append(point)
		return

	if mode == ToolMode.Mode.WATERHOLE:
		# Placed on release, at the press position, with the brush radius.
		_waterhole_center = point
		return

	if mode == ToolMode.Mode.FLATTEN:
		_flatten_height = TerrainSampler.base_height(terrain, point)

	apply_brush(terrain, local_position)

func update(terrain: Node3D, local_position: Vector3) -> void:
	var point := _to_2d(local_position)
	if mode == ToolMode.Mode.ERASE and _erase_feature_stroke:
		_erase_features(terrain, point)
		return

	if mode == ToolMode.Mode.WATERHOLE:
		return

	if ToolMode.is_feature_tool(mode):
		if _feature_points.is_empty() or _feature_points[-1].distance_to(point) >= Meta.FEATURE_SAMPLE_DISTANCE:
			_feature_points.append(point)
			# The preview is isolated from committed roads/rivers, so existing
			# features are not regenerated on every mouse sample.
			builder.show_preview(terrain, FeatureStyle.make_preview(terrain, _feature_type(), _feature_points))
		return

	# Fill the gap since the last stamp (fast mouse moves).
	if _last_stamp != null:
		var from: Vector2 = _last_stamp
		var step := maxf(brush_radius * STAMP_SPACING, 0.05)
		var count := mini(int(ceilf(from.distance_to(point) / step)), MAX_STAMPS_PER_SAMPLE)
		for i in range(1, count):
			var stamp := from.lerp(point, float(i) / float(count))
			apply_brush(terrain, Vector3(stamp.x, local_position.y, stamp.y))
	apply_brush(terrain, local_position)

## Rebuilds the chunk meshes (and the road / river mesh) changed since the
## last flush. Cheap to call when nothing is pending.
func flush(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		_pending_chunks.clear()
		_feature_mesh_dirty = false
		return
	if ToolMode.is_vegetation_tool(mode):
		# Only the details change: re-scatter them live (ground colours are
		# computed once per chunk and stroke).
		for key: Vector2i in _pending_chunks:
			if not _stroke_chunks.has(key):
				_stroke_chunks[key] = builder.chunk_shading(terrain, key.x, key.y)
			builder.apply_chunk_details(terrain, key.x, key.y, _stroke_chunks[key])
		_pending_chunks.clear()
		return
	for key: Vector2i in _pending_chunks:
		var parts := builder.rebuild_chunk(terrain, key.x, key.y, false)
		if not parts.is_empty():
			_stroke_chunks[key] = parts["shading"]
	_pending_chunks.clear()
	if _feature_mesh_dirty:
		_feature_mesh_dirty = false
		# Roads / rivers erased: the ground did not move (a river's carve
		# empties the cache itself).
		builder.rebuild_feature_mesh(terrain, false)

## Ends the stroke: adds the road / river / waterhole it drew, records the
## Undo step and queues the rebuild of what it changed.
func end(terrain: Node3D) -> void:
	if not _stroke_active:
		return
	flush(terrain)
	var feature_rect := _commit_feature(terrain)
	var waterhole_area := _commit_waterhole(terrain)
	_record_undo(terrain, feature_rect, waterhole_area)

	_feature_points.clear()
	_stroke_before = {}
	_stroke_active = false
	var feature_erase_finished := _erase_feature_stroke
	_erase_feature_stroke = false
	builder.clear_preview(terrain)

	if ToolMode.is_feature_tool(mode):
		_rebuild_after_feature(terrain, feature_rect)
	elif feature_erase_finished:
		_rebuild_after_feature_erase(terrain)
	elif mode == ToolMode.Mode.WATERHOLE:
		_rebuild_after_waterhole(terrain, waterhole_area)
	elif ToolMode.is_vegetation_tool(mode):
		pass # Details already re-scattered by flush(); ground and collision unchanged.
	else:
		_rebuild_after_ground_stroke(terrain)
	_stroke_chunks.clear()

## Road / River tool: adds the drawn line to the data. Returns the area the
## new feature changes (empty when nothing was added).
func _commit_feature(terrain: Node3D) -> Rect2:
	if ToolMode.is_feature_tool(mode) and FeatureStyle.commit(terrain, _feature_type(), _feature_points):
		return _points_rect(_feature_points).grow(_feature_margin(terrain))
	return Rect2()

## Waterhole tool: adds the waterhole to the data. Returns its area (empty
## when none was added).
func _commit_waterhole(terrain: Node3D) -> Rect2:
	if mode == ToolMode.Mode.WATERHOLE and WaterholeStyle.commit(terrain, _waterhole_center, brush_radius):
		return WaterholeStyle.bounds_of(terrain, WaterholeStyle.list(terrain).size() - 1)
	return Rect2()

## Hands the before / after snapshots to undo_handler when the stroke changed
## anything.
func _record_undo(terrain: Node3D, feature_rect: Rect2, waterhole_area: Rect2) -> void:
	var after := TerrainSnapshot.capture(terrain)
	if not TerrainSnapshot.equal(_stroke_before, after) and undo_handler.is_valid():
		undo_handler.call("Lowpoly Terrain: %s" % ToolMode.display_name(mode), terrain, _stroke_before, after,
			_undo_area(feature_rect, waterhole_area))

## A new road / river: its own mesh, the ground it carves (rivers) and the
## details it pushes away, in its area only.
func _rebuild_after_feature(terrain: Node3D, feature_rect: Rect2) -> void:
	if feature_rect.has_area():
		builder.rebuild_area(terrain, feature_rect, {"carve": mode == ToolMode.Mode.RIVER, "features": true, "defer": true})

## A stroke that removed roads / rivers / waterholes (Ctrl+drag with Ground).
func _rebuild_after_feature_erase(terrain: Node3D) -> void:
	if _stroke_has_dirty_rect:
		builder.rebuild_area(terrain, _stroke_dirty_rect, {
			"carve": _erase_changed_carve,
			"features": true,
			"waterholes": _erase_removed_waterhole,
			"defer": true,
		})

func _rebuild_after_waterhole(terrain: Node3D, waterhole_area: Rect2) -> void:
	if not waterhole_area.has_area():
		return
	builder.rebuild_waterhole_area(terrain, waterhole_area)
	if FeatureEraser.any_feature_intersects(terrain, waterhole_area):
		builder.rebuild_feature_mesh(terrain, waterhole_area)
	builder.request_collision(terrain)

## Painting / sculpting shapes the ground only: the details (grass, rocks,
## trees) stay as they are, Inspector > Replace Details puts them on the new
## ground. Erase takes away the details of the ground it removes (placement
## is fixed per cell: nothing new appears). The touched chunk meshes are
## already rebuilt (flush()); what is left is queued, done over the next
## frames (TerrainBuilder.process_deferred).
func _rebuild_after_ground_stroke(terrain: Node3D) -> void:
	var details := _stroke_moves_details()
	if details:
		for key: Vector2i in _stroke_chunks:
			builder.defer_chunk(terrain, key, false, _stroke_chunks[key])
	# A grown canvas was rebuilt whole already.
	var local_rebuild := _stroke_has_dirty_rect and not _canvas_expanded
	# Neighbours reached by the colour blur get their mesh.
	if local_rebuild:
		for key in builder.chunks_for_local_rect(terrain, _stroke_dirty_rect):
			if not _stroke_chunks.has(key):
				builder.defer_chunk(terrain, key, true, null, details)
	# Sculpting near a river can change its water level along its whole
	# length: new carve, and the chunks where it changed (also those rebuilt
	# live with the old carve).
	if local_rebuild and RiverMesher.any_river_near(terrain, _stroke_dirty_rect):
		for key in builder.rebuild_river_carve(terrain):
			builder.defer_chunk(terrain, key, true, null, details)
	# Roads / rivers are rebuilt only when the stroke overlaps one, so
	# unrelated edits stay cheap on busy maps.
	if _stroke_has_dirty_rect and FeatureEraser.any_feature_intersects(terrain, _stroke_dirty_rect):
		builder.rebuild_feature_mesh(terrain, _stroke_dirty_rect)
	# Mud plates follow the ground: refresh those under the stroke.
	if _stroke_has_dirty_rect and not WaterholeStyle.shapes(terrain, _stroke_dirty_rect).is_empty():
		builder.rebuild_waterholes(terrain, _stroke_dirty_rect)
	builder.request_collision(terrain)

## Area for Undo/Redo (see undo_handler), null = rebuild everything.
func _undo_area(feature_rect: Rect2, waterhole_area: Rect2) -> Variant:
	if _canvas_expanded:
		return null
	if ToolMode.is_feature_tool(mode):
		return {"rect": feature_rect, "carve": mode == ToolMode.Mode.RIVER, "features": true} if feature_rect.has_area() else null
	if mode == ToolMode.Mode.WATERHOLE:
		return {"rect": waterhole_area, "carve": true, "waterholes": true} if waterhole_area.has_area() else null
	if not _stroke_has_dirty_rect:
		return null
	if _erase_feature_stroke:
		return {"rect": _stroke_dirty_rect, "carve": _erase_changed_carve, "features": true, "waterholes": _erase_removed_waterhole}
	return {"rect": _stroke_dirty_rect, "details": _stroke_moves_details()}

## True if this stroke's end updates the details: Vegetation (that is its
## job) and Erase (removed ground loses its details); not the tools that
## paint / sculpt the ground.
func _stroke_moves_details() -> bool:
	return ToolMode.is_vegetation_tool(mode) or mode == ToolMode.Mode.ERASE

func _feature_margin(terrain: Node3D) -> float:
	return maxf(ToolMode.feature_width(terrain, mode), 1.0) + 1.0

static func _points_rect(points: Array[Vector2]) -> Rect2:
	if points.is_empty():
		return Rect2()
	var rect := Rect2(points[0], Vector2.ZERO)
	for p in points:
		rect = rect.expand(p)
	return rect

# -----------------------------------------------------------------------------
# Feature erase (roads, rivers, waterholes)
# -----------------------------------------------------------------------------

## One erase sample over features. Only the data changes here; the feature
## mesh is rebuilt at the next flush, the ground at the end of the stroke.
func _erase_features(terrain: Node3D, point: Vector2) -> void:
	var hole := WaterholeStyle.find_at(terrain, point)
	if hole >= 0:
		# A click erases the whole waterhole: show it gone right away.
		var hole_area := WaterholeStyle.bounds_of(terrain, hole)
		FeatureEraser.erase_at(terrain, point, brush_radius)
		_erase_changed_carve = true
		_erase_removed_waterhole = true
		_accumulate_rect(hole_area)
		builder.rebuild_river_carve(terrain)
		for key in builder.chunks_for_local_rect(terrain, hole_area):
			builder.rebuild_chunk(terrain, key.x, key.y)
		builder.rebuild_waterholes(terrain)
		return

	var area: Variant = FeatureEraser.erase_area(terrain, point, brush_radius)
	if area == null:
		return
	if FeatureEraser.erase_at(terrain, point, brush_radius):
		var erased: Dictionary = area
		var erased_rect: Rect2 = erased["rect"]
		var erased_rivers: bool = erased["rivers"]
		_accumulate_rect(erased_rect)
		_erase_changed_carve = _erase_changed_carve or erased_rivers
		_feature_mesh_dirty = true

# -----------------------------------------------------------------------------
# Brush sample
# -----------------------------------------------------------------------------

## Applies one brush stamp of the current mode to the terrain data and marks
## the chunks to rebuild at the next flush().
func apply_brush(terrain: Node3D, local_position: Vector3) -> void:
	if not is_instance_valid(terrain):
		return

	# Paint can grow the canvas. Other sculpt/erase tools intentionally operate
	# only on terrain that already exists.
	var canvas_expanded := false
	if mode == ToolMode.Mode.PAINT:
		canvas_expanded = _grow_canvas_for_paint(terrain, local_position)

	var target_pos := _to_2d(local_position)
	_last_stamp = target_pos
	if ToolMode.is_vegetation_tool(mode):
		if Brush.apply_vegetation(terrain, mode, target_pos, brush_radius, brush_strength, vegetation_target):
			_accumulate_dirty_rect(target_pos, brush_radius + 1.0)
			for key in builder.chunks_for_vertex_bounds(terrain, Brush.vertex_bounds(terrain, target_pos, brush_radius, 1), false):
				_pending_chunks[key] = true
		return
	_accumulate_dirty_rect(target_pos, brush_radius + 1.0)
	Brush.apply_vertex_brush(terrain, mode, target_pos, brush_radius, brush_strength, _flatten_height)

	if mode == ToolMode.Mode.PAINT:
		var activated_cells := Brush.sync_cell_active_near(terrain, target_pos, brush_radius, true)
		if not activated_cells.is_empty():
			StylePalette.assign_paint_style_to_cells(terrain, activated_cells)
	elif mode == ToolMode.Mode.ERASE:
		# Erase is destructive only: it may deactivate existing cells, but must
		# never activate empty cells from the shared vertex mask around them.
		Brush.sync_cell_active_near(terrain, target_pos, brush_radius, false)

	if mode == ToolMode.Mode.SMOOTH:
		Brush.apply_smooth(terrain, target_pos, brush_radius, brush_strength)

	if canvas_expanded:
		# Expansion recentres every old cell inside a larger grid, so chunk
		# coordinates change globally and every chunk must be rebuilt once.
		_canvas_expanded = true
		_pending_chunks.clear()
		_stroke_chunks.clear()
		builder.rebuild_river_carve(terrain)
		builder.rebuild_all_chunks(terrain, false)
	else:
		# Only the chunks intersecting this brush need new terrain geometry.
		# Geometry only; the shading margin chunks are refreshed at the end.
		for key in builder.chunks_for_vertex_bounds(terrain, Brush.vertex_bounds(terrain, target_pos, brush_radius, 2), false):
			_pending_chunks[key] = true

func _grow_canvas_for_paint(terrain: Node3D, local_position: Vector3) -> bool:
	var cells_per_side := Canvas.cells_needed_for_paint(terrain, local_position, brush_radius)
	if cells_per_side == Canvas.BLOCKED_BY_MAX_RESOLUTION:
		if not _max_expand_warned_this_stroke:
			push_warning("Lowpoly Terrain Editor: the terrain reached its Maximum Cells (%d) while painting. Increase it in Inspector > Advanced > Terrain Size > Maximum Cells." % Canvas.max_resolution(terrain))
			_max_expand_warned_this_stroke = true
		return false
	if cells_per_side <= 0:
		return false

	Canvas.expand(terrain, cells_per_side)
	terrain.notify_property_list_changed()
	return true

func _accumulate_dirty_rect(center: Vector2, radius: float) -> void:
	var r := maxf(radius, 0.0)
	_accumulate_rect(Rect2(center - Vector2(r, r), Vector2(r * 2.0, r * 2.0)))

func _accumulate_rect(rect: Rect2) -> void:
	if not _stroke_has_dirty_rect:
		_stroke_dirty_rect = rect
		_stroke_has_dirty_rect = true
	else:
		_stroke_dirty_rect = _stroke_dirty_rect.merge(rect)
