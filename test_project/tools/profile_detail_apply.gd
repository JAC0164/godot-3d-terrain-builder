extends SceneTree
## What the first chunk's details cost once: times DetailScatter.apply's
## work layer by layer on a fresh savanna map, first chunk then a second one.
##   godot --path . --position -3000,-3000 --script res://tools/profile_detail_apply.gd [-- --warm]
## (--warm: DetailScatter.warmups first, as the runtime does)

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

func _initialize() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var camera := Camera3D.new()
	root.add_child(camera)
	camera.look_at_from_position(Vector3(0, 30, 30), Vector3.ZERO)
	var terrain := Node3D.new()
	root.add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(RECIPE), 7)
	var builder := TerrainBuilder.new()
	builder.rebuild_river_carve(terrain)
	builder._ensure_chunk_container(terrain)
	for c in [Vector2i(1, 1), Vector2i(2, 1)]:
		builder.rebuild_chunk(terrain, c.x, c.y, false)
	if OS.get_cmdline_user_args().has("--warm"):
		# What TerrainRuntime runs before the first details, step by step.
		for warm in DetailScatter.warmups(terrain):
			var m0 := Time.get_ticks_usec()
			warm.call()
			print("  warm %s %s: %.1f ms" % [warm.get_method(), warm.get_bound_arguments(), (Time.get_ticks_usec() - m0) / 1000.0])
	await process_frame
	await process_frame
	var container := terrain.get_node(Meta.GENERATED_CHUNKS_NAME)
	for c in [Vector2i(1, 1), Vector2i(2, 1)]:
		var chunk := container.get_node(TerrainMesher.chunk_name(c.x, c.y)) as Node3D
		var s0 := Time.get_ticks_usec()
		var shading := builder.chunk_shading(terrain, c.x, c.y)
		var s1 := Time.get_ticks_usec()
		var entries := DetailScatter.build(terrain, builder.get_river_carve(terrain), c.x, c.y, shading)
		var s2 := Time.get_ticks_usec()
		print("chunk %s: shading %.1f ms, scatter %.1f ms" % [c, (s1 - s0) / 1000.0, (s2 - s1) / 1000.0])
		var total := 0.0
		for entry in entries:
			if entry[1] == 0:
				continue
			var a0 := Time.get_ticks_usec()
			DetailScatter.apply(terrain, chunk, [entry], func(parent: Node, child: Node) -> void: parent.add_child(child))
			var ms := (Time.get_ticks_usec() - a0) / 1000.0
			total += ms
			if ms > 0.5:
				print("  %-28s %6d instances  %6.1f ms" % [entry[0], entry[1], ms])
		print("  apply total %.1f ms" % total)
		var f0 := Time.get_ticks_usec()
		await process_frame
		print("  next frame %.1f ms" % ((Time.get_ticks_usec() - f0) / 1000.0))
	quit()
