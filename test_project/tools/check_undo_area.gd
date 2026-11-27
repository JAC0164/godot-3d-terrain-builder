extends SceneTree
## Undo history by area (TerrainSnapshot.delta_pair, used by the plugin's
## _register_snapshot_undo): strokes through the real StrokeController
## (Raise, Erase, Paint back, Vegetation, Road), then for each:
## - the delta pair is much smaller than the two full snapshots;
## - undo (delta "before") gives back exactly the data before the stroke,
##   redo (delta "after") exactly the data after;
## - a Road keeps only its roads list (no grid block);
## - a grid size change (canvas grown) gives no delta (full snapshots kept).
## Also on a 513 x 513 copy: size and time of one delta.
## Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_undo_area.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainSnapshot = preload(ADDON + "core/terrain_snapshot.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const StrokeController = preload(ADDON + "editing/stroke_controller.gd")
const ToolMode = preload(ADDON + "editing/tool_mode.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

var _failures := 0
var _recorded: Array = []

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _initialize() -> void:
	_run.call_deferred()

func _record(_name: String, _terrain: Node3D, before: Dictionary, after: Dictionary, _area: Variant) -> void:
	_recorded = [before, after]

func _stroke(t: Node3D, strokes: StrokeController, mode: ToolMode.Mode, from: Vector3, to: Vector3) -> void:
	_recorded = []
	strokes.mode = mode
	strokes.begin(t, from)
	for i in range(1, 11):
		strokes.update(t, from.lerp(to, i / 10.0))
	strokes.end(t)

func _run() -> void:
	var root3d := Node3D.new()
	root3d.name = "Root"
	root.add_child(root3d)
	var t := TestTerrain.savanna(root3d)
	var builder := TerrainBuilder.new()
	builder.rebuild_all(t)
	var strokes := StrokeController.new(builder)
	strokes.brush_radius = 3.0
	strokes.undo_handler = _record
	var cases := [
		[ToolMode.Mode.RAISE, "Raise", Vector3(-10, 0, -4), Vector3(6, 0, 2)],
		[ToolMode.Mode.ERASE, "Erase", Vector3(10, 0, 10), Vector3(14, 0, 18)],
		[ToolMode.Mode.PAINT, "Paint", Vector3(10, 0, 10), Vector3(14, 0, 18)],
		[ToolMode.Mode.VEGETATION, "Vegetation", Vector3(-20, 0, 15), Vector3(-12, 0, 15)],
		[ToolMode.Mode.ROAD, "Road", Vector3(-30, 0, -30), Vector3(-5, 0, -20)],
	]
	for entry: Array in cases:
		var label: String = entry[1]
		_stroke(t, strokes, entry[0], entry[2], entry[3])
		if _recorded.is_empty():
			check("%s: the stroke changed the terrain" % label, false)
			continue
		var before: Dictionary = _recorded[0]
		var after: Dictionary = _recorded[1]
		var pair := TerrainSnapshot.delta_pair(before, after)
		if pair.is_empty():
			check("%s: delta made" % label, false)
			continue
		var full_bytes := var_to_bytes(before).size() + var_to_bytes(after).size()
		var delta_bytes := var_to_bytes(pair[0]).size() + var_to_bytes(pair[1]).size()
		check("%s: delta %d bytes vs %d full (%.1f %%)" % [label, delta_bytes, full_bytes, 100.0 * delta_bytes / full_bytes], delta_bytes * 5 < full_bytes)
		TerrainSnapshot.apply(t, pair[0])
		check("%s: undo gives the data before" % label, TerrainSnapshot.equal(TerrainSnapshot.capture(t), before))
		TerrainSnapshot.apply(t, pair[1])
		check("%s: redo gives the data after" % label, TerrainSnapshot.equal(TerrainSnapshot.capture(t), after))
		if label == "Road":
			check("Road: only the roads list in the delta", pair[1].has("roads") and not pair[1].has("vertex_rect") and not pair[1].has("cell_rect"))
		if label == "Raise":
			check("Raise: no cell block, no road list", not pair[1].has("cell_rect") and not pair[1].has("roads"))
		if label == "Paint":
			check("Paint: cell block", pair[1].has("cell_rect") and pair[1].has("cell_active"))

	# A grid size change keeps the full snapshots.
	var before := TerrainSnapshot.capture(t)
	var grown := before.duplicate()
	grown["resolution"] = int(before["resolution"]) + 2
	check("grid size changed: no delta", TerrainSnapshot.delta_pair(before, grown).is_empty())

	# A big map: one stroke-sized change on 513 x 513.
	var big := 513
	var heights := PackedFloat32Array()
	heights.resize(big * big)
	var mask := PackedFloat32Array()
	mask.resize(big * big)
	mask.fill(1.0)
	var styles := PackedInt32Array()
	styles.resize((big - 1) * (big - 1))
	var active := PackedByteArray()
	active.resize((big - 1) * (big - 1))
	var a := {"resolution": big, "world_size": 768.0, "mask": mask, "heights": heights, "cell_styles": styles, "cell_active": active,
		"roads": [], "rivers": [], "waterholes": [], "cell_vegetation": {}, "style_palette": []}
	var b := a.duplicate()
	var changed := heights.duplicate()
	for z in range(200, 220):
		for x in range(300, 330):
			changed[z * big + x] = 2.0
	b["heights"] = changed
	var start := Time.get_ticks_usec()
	var big_pair := TerrainSnapshot.delta_pair(a, b)
	var ms := (Time.get_ticks_usec() - start) / 1000.0
	var rect: Rect2i = big_pair[1].get("vertex_rect", Rect2i()) if not big_pair.is_empty() else Rect2i()
	check("513 x 513: changed rectangle found exactly (%s) in %.1f ms" % [rect, ms], rect == Rect2i(300, 200, 30, 20))
	var big_bytes := var_to_bytes(big_pair[0]).size() + var_to_bytes(big_pair[1]).size() if not big_pair.is_empty() else 0
	check("513 x 513: delta %d bytes vs %d full" % [big_bytes, var_to_bytes(a).size() * 2], big_bytes > 0 and big_bytes < 20000)

	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)
