extends SceneTree
## Why the first chunk's details cost more at load: times the parts of
## TerrainBuilder.rebuild_chunk_details on a fresh savanna map (built-in
## meshes, rules, scatter, nodes), first chunk then a second one.
##   godot --path . --position -3000,-3000 --script res://tools/profile_first_details.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const DetailMeshes = preload(ADDON + "mesh/detail_meshes.gd")
const MaterialFactory = preload(ADDON + "materials/material_factory.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

func _initialize() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var terrain := Node3D.new()
	root.add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(RECIPE), 7)
	var builder := TerrainBuilder.new()
	builder.rebuild_river_carve(terrain)
	builder._ensure_chunk_container(terrain)
	for c in [Vector2i(1, 1), Vector2i(2, 1)]:
		builder.rebuild_chunk(terrain, c.x, c.y, false)
	await process_frame
	var t0 := Time.get_ticks_usec()
	for layer in DetailScatter.biome_of(terrain).detail_layers:
		if layer != null:
			layer.resolved_mesh()
	var t1 := Time.get_ticks_usec()
	print("built-in meshes + models of the biome: %.1f ms" % ((t1 - t0) / 1000.0))
	if OS.get_cmdline_user_args().has("--warm"):
		# What the first chunk sets up once: materials (shaders) and the
		# one-sided grass meshes.
		for profile in ["", "grass", "shrub", "tree", "baobab"]:
			var m0 := Time.get_ticks_usec()
			MaterialFactory.detail_material(profile)
			print("  detail material '%s': %.1f ms" % [profile, (Time.get_ticks_usec() - m0) / 1000.0])
		var g0 := Time.get_ticks_usec()
		for i in [DetailMeshes.GRASS_TUFT, DetailMeshes.DRY_GRASS_TUFT]:
			DetailMeshes.builtin(i, true)
		print("  one-sided grass meshes: %.1f ms" % ((Time.get_ticks_usec() - g0) / 1000.0))
	for c in [Vector2i(1, 1), Vector2i(2, 1)]:
		var s0 := Time.get_ticks_usec()
		var entries := DetailScatter.build(terrain, builder.get_river_carve(terrain), c.x, c.y, builder.chunk_shading(terrain, c.x, c.y))
		var s1 := Time.get_ticks_usec()
		builder.rebuild_chunk_details(terrain, c.x, c.y)
		var s2 := Time.get_ticks_usec()
		print("chunk %s: scatter %.1f ms, whole rebuild_chunk_details %.1f ms (%d layers)" % [c, (s1 - s0) / 1000.0, (s2 - s1) / 1000.0, entries.size()])
		await process_frame
		var s3 := Time.get_ticks_usec()
		await process_frame
		print("  next frames: %.1f ms" % ((Time.get_ticks_usec() - s3) / 1000.0))
	quit()
