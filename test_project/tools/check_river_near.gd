extends SceneTree
## RiverMesher.any_river_near (which edits must recompute the river beds),
## on the open world (1 024 cells, rivers + tributaries, seed 7):
## - safe: an edit it calls "far" never changes the river carve (compared
##   with a full TerrainBuilder.rebuild_river_carve after each edit);
## - useful: most edits away from the water are "far" (the river's bounding
##   box, the old test, called nearly all of them near), and edits on a
##   river do change it (30 edits placed 0 to 25 m from a river);
## - segment cases: crossing a box without an end inside, parallel outside.
## Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_river_near.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const TerrainEdits = preload(ADDON + "runtime/terrain_edits.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_open_world_map.tres"

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _initialize() -> void:
	_run.call_deferred()

## The old test: the river's whole bounding box.
static func _bbox_near(terrain: Node3D, rect: Rect2) -> bool:
	for river_variant: Variant in terrain.get_meta(Meta.RIVERS, []):
		var river: Dictionary = river_variant
		var points: Array = river.get("points", [])
		if points.is_empty():
			continue
		var first_point: Vector2 = points[0]
		var bounds := Rect2(first_point, Vector2.ZERO)
		for point: Vector2 in points:
			bounds = bounds.expand(point)
		var river_width: float = river.get("width", Meta.DEFAULT_RIVER_WIDTH)
		if bounds.grow(river_width * 0.5 + RiverMesher.MAX_BANK_REACH + 1.0).intersects(rect, true):
			return true
	return false

func _run() -> void:
	check("segment crossing a box, no end inside", RiverMesher._segment_touches(Vector2(-5, 0), Vector2(5, 1), Rect2(-1, -1, 2, 2)))
	check("segment parallel to a box, outside", not RiverMesher._segment_touches(Vector2(-5, 3), Vector2(5, 3), Rect2(-1, -1, 2, 2)))
	check("segment ending inside a box", RiverMesher._segment_touches(Vector2(0, 0), Vector2(5, 5), Rect2(-1, -1, 2, 2)))
	check("diagonal segment passing a corner", not RiverMesher._segment_touches(Vector2(2, -1), Vector2(4, 1), Rect2(-1, -1, 2, 2)))

	var t := Node3D.new()
	t.name = "LowpolyTerrain"
	root.add_child(t)
	TerrainData.initialize(t)
	MapGenerator.generate(t, load(RECIPE), 7)
	var builder := TerrainBuilder.new()
	builder.rebuild_river_carve(t)
	var size: float = Meta.get_float(t, Meta.WORLD_SIZE, 64.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var far := 0
	var bbox_far := 0
	var near_changed := 0
	var unsafe := 0
	var count := 60
	var near_ms := 0.0
	var rivers: Array = t.get_meta(Meta.RIVERS, [])
	for i in count + 30:
		var center := Vector2(rng.randf_range(-0.47, 0.47), rng.randf_range(-0.47, 0.47)) * size
		if i >= count:
			# Near the water: a point of a river, 0 to 25 m off.
			var river: Dictionary = rivers[rng.randi() % rivers.size()]
			var points: Array = river["points"]
			var on: Vector2 = points[rng.randi() % points.size()]
			center = on + Vector2.from_angle(rng.randf() * TAU) * rng.randf_range(0.0, 25.0)
		var rect := TerrainEdits.shape(t, TerrainEdits.Op.RAISE, center, 6.0, -2.0)
		if not rect.has_area():
			continue
		var t0 := Time.get_ticks_usec()
		var near := RiverMesher.any_river_near(t, rect)
		near_ms += (Time.get_ticks_usec() - t0) / 1000.0
		var changed := builder.rebuild_river_carve(t)
		if not near:
			far += 1
			if not changed.is_empty():
				unsafe += 1
				print("  unsafe: edit at %s changed %d chunks of carve" % [center, changed.size()])
		elif not changed.is_empty():
			near_changed += 1
		if not _bbox_near(t, rect):
			bbox_far += 1
	check("safe: %d edits called far, none changed the carve (%d unsafe)" % [far, unsafe], unsafe == 0)
	check("useful: %d of %d edits far from the rivers (bounding box: %d), %d near ones changed the carve, %.2f ms a test" % [far, count + 30, bbox_far, near_changed, near_ms / (count + 30)], far > bbox_far and far >= count / 3 and near_changed > 0)
	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)
