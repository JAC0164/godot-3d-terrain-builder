extends SceneTree
## Prints, per painted sparse layer of the savanna terrain, the block side and
## minimum gap (DetailLayer.paint_spacing), then times the detail rebuild of
## the acacia forest painted by tools/audit_perf.gd (headless, no drawing).
##   godot --headless --path . --script res://tools/print_paint_blocks.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const Brush = preload(ADDON + "editing/brush.gd")
const ToolMode = preload(ADDON + "editing/tool_mode.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

func _initialize() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var terrain := TestTerrain.savanna(root)
	var resolution: int = int(terrain.get_meta(Meta.RESOLUTION))
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var spacing := size / float(resolution - 1)
	var builder := TerrainBuilder.new()
	builder.rebuild_all(terrain)
	var spot := Vector2(10, -10)
	for k in 12:
		Brush.apply_vegetation(terrain, ToolMode.Mode.VEGETATION, spot + Vector2.RIGHT.rotated(k * 0.52) * float(k % 3) * 6.0, 8.0, 1.0)
		Brush.apply_vegetation(terrain, ToolMode.Mode.VEGETATION, spot + Vector2.RIGHT.rotated(k * 0.52) * float(k % 3) * 6.0, 8.0, 1.0, "Acacias")
	var s: Dictionary = DetailScatter.settings(terrain)
	print("cell %.2f m" % spacing)
	for rule in DetailScatter._compile(DetailScatter.biome_of(terrain), float(s["density"]), float(s["scale"]) * spacing, int(s["seed"]), spacing):
		if rule.block > 0:
			print("  %-22s block %2d cells, min gap %.2f m" % [rule.node_name, rule.block, rule.min_gap if "min_gap" in rule else 0.0])
	var times: Array[float] = []
	for i in 5:
		var t0 := Time.get_ticks_usec()
		builder.rebuild_all_details(terrain)
		times.append((Time.get_ticks_usec() - t0) / 1000.0)
	times.sort()
	print("painted forest details rebuild: %s ms (median %.0f)" % [times, times[2]])
	root.free()
	quit()
