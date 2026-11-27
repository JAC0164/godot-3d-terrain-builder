extends SceneTree
## Far vegetation thinning (DetailScatter.apply, THIN_DENSITY / THIN_FROM):
## - every dense layer (grass) node stops at THIN_FROM of its draw distance
##   and has a child FAR_NAME from there to the end, holding every other
##   instance of it (same box, so both switch at the same distance);
## - the sparse layers (gravel, shrubs, trees) have none and keep their range;
## - the instance counts (count_instances) do not include the far halves;
## - a layer made sparse loses its far half on the next build;
## - time spent copying the halves (main thread), and the memory they add.
## Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_far_thinning.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _initialize() -> void:
	_run.call_deferred()

func _detail_nodes(t: Node3D) -> Array[MultiMeshInstance3D]:
	var nodes: Array[MultiMeshInstance3D] = []
	for chunk: Node in t.get_node(Meta.GENERATED_CHUNKS_NAME).get_children():
		for child: Node in chunk.get_children():
			if child is MultiMeshInstance3D and String(child.name).begins_with(DetailScatter.NODE_PREFIX + "_"):
				nodes.append(child as MultiMeshInstance3D)
	return nodes

func _run() -> void:
	var root3d := Node3D.new()
	root3d.name = "Root"
	root.add_child(root3d)
	var t := TestTerrain.savanna(root3d)
	var biome: TerrainBiome = TerrainBiome.of(t).duplicate(true)
	t.set_meta(Meta.BIOME, biome)
	var default_distance: float = DetailScatter.settings(t)["distance"]
	var builder := TerrainBuilder.new()
	builder.rebuild_all(t)

	var dense_nodes := 0
	var sparse_nodes := 0
	var full_total := 0
	var far_total := 0
	var bad: Array[String] = []
	for node in _detail_nodes(t):
		var layer: Resource = biome.detail_layers[DetailScatter.node_layer_index(String(node.name)) - 1]
		var density: float = layer.get("density")
		var draw_distance: float = layer.get("draw_distance")
		var distance := draw_distance if draw_distance >= 0.0 else default_distance
		var count := node.multimesh.instance_count
		var far := node.get_node_or_null(DetailScatter.FAR_NAME) as MultiMeshInstance3D
		var dense := density >= DetailScatter.THIN_DENSITY and distance > 0.0 and count >= 2
		if not dense:
			sparse_nodes += 1
			if far != null or not is_equal_approx(node.visibility_range_end, distance):
				bad.append("%s: sparse but far half %s, range %.1f / %.1f" % [node.name, far != null, node.visibility_range_end, distance])
			continue
		dense_nodes += 1
		full_total += count
		if far == null:
			bad.append("%s: dense, no far half" % node.name)
			continue
		far_total += far.multimesh.instance_count
		var split := distance * DetailScatter.THIN_FROM
		var ranges_ok := is_equal_approx(node.visibility_range_end, split) and node.visibility_range_end_margin == 0.0 \
			and is_equal_approx(far.visibility_range_begin, split) and far.visibility_range_begin_margin == 0.0 \
			and is_equal_approx(far.visibility_range_end, distance)
		var full := node.multimesh.buffer
		var half := far.multimesh.buffer
		var every_other := far.multimesh.instance_count == (count + 1) / 2
		for i in far.multimesh.instance_count if every_other else 0:
			if half.slice(i * 16, i * 16 + 16) != full.slice(2 * i * 16, 2 * i * 16 + 16):
				every_other = false
				break
		var same_look := far.material_override == node.material_override and far.multimesh.mesh == node.multimesh.mesh \
			and far.cast_shadow == node.cast_shadow and far.custom_aabb == node.multimesh.get_aabb()
		if not (ranges_ok and every_other and same_look):
			bad.append("%s: ranges %s, every other %s, same look %s" % [node.name, ranges_ok, every_other, same_look])
	check("dense layers: %d nodes stop at %d %% of their distance, a far half takes over (%d -> %d instances)" % [dense_nodes, roundi(DetailScatter.THIN_FROM * 100.0), full_total, far_total],
		dense_nodes > 0 and bad.is_empty() and far_total * 2 >= full_total and far_total * 2 <= full_total + dense_nodes)
	check("sparse layers: %d nodes unchanged, no far half" % sparse_nodes, sparse_nodes > 0 and bad.is_empty())
	for line in bad.slice(0, 5):
		print("     ", line)

	# Main-thread cost of the halves: the same copy as apply(), all chunks.
	var copy_start := Time.get_ticks_usec()
	for node in _detail_nodes(t):
		var far := node.get_node_or_null(DetailScatter.FAR_NAME) as MultiMeshInstance3D
		if far == null:
			continue
		var full := node.multimesh.buffer
		var half := PackedFloat32Array()
		for i in (node.multimesh.instance_count + 1) / 2:
			half.append_array(full.slice(2 * i * 16, (2 * i + 1) * 16))
	print("     copying the far halves: %.1f ms for the whole map (%.0f us per thinned node); +%d instances in memory (%.1f MB)" % [(Time.get_ticks_usec() - copy_start) / 1000.0, (Time.get_ticks_usec() - copy_start) / maxf(dense_nodes, 1.0), far_total, far_total * 64.0 / 1048576.0])

	var counts := DetailScatter.count_instances(t)
	var counted := 0
	for key: String in counts:
		counted += int(counts[key])
	var all_full := 0
	for node in _detail_nodes(t):
		all_full += node.multimesh.instance_count
	check("count_instances leaves the far halves out (%d)" % counted, counted == all_full)

	# A layer made sparse (all under THIN_DENSITY).
	for layer: Resource in biome.detail_layers:
		if layer != null and float(layer.get("density")) >= DetailScatter.THIN_DENSITY:
			layer.set("density", DetailScatter.THIN_DENSITY - 0.01)
	builder.rebuild_all(t)
	var left := 0
	for node in _detail_nodes(t):
		if node.get_node_or_null(DetailScatter.FAR_NAME) != null:
			left += 1
	check("layers made sparse lose their far half on rebuild (%d left)" % left, left == 0)

	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)
