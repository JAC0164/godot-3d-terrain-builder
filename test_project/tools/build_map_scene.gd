extends SceneTree
## Generates a map from a recipe + seed and saves it as a bench scene
## (everything saved, like a level made in the editor with Generate Map).
##   godot --headless --path . --script res://tools/build_map_scene.gd -- [--recipe=res://...tres] [--seed=2026] [--out=res://scenes/savanna_map_192.tscn]

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")

func _initialize() -> void:
	var args := {"recipe": ADDON + "generation/presets/senegal_savanna_map.tres", "seed": "2026", "out": "res://scenes/savanna_map_192.tscn"}
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		args[parts[0]] = parts[1] if parts.size() > 1 else "1"
	var root := Node3D.new()
	root.name = "Level"
	get_root().add_child(root)
	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	root.add_child(terrain)
	terrain.owner = root
	TerrainData.initialize(terrain)
	var feature := MeshInstance3D.new()
	feature.name = Meta.GENERATED_MESH_NAME
	terrain.add_child(feature)
	feature.owner = root
	var stats := MapGenerator.generate(terrain, load(args["recipe"]), int(args["seed"]))
	var builder := TerrainBuilder.new()
	builder.owner_provider = func() -> Node: return root
	var started := Time.get_ticks_usec()
	builder.rebuild_all(terrain)
	var runtime := TerrainRuntime.new()
	runtime.name = Meta.RUNTIME_NODE_NAME
	terrain.add_child(runtime)
	runtime.owner = root
	var packed := PackedScene.new()
	packed.pack(root)
	var err := ResourceSaver.save(packed, args["out"])
	print("map %s generated in %.0f ms, built in %.0f ms, saved %s: %s" % [stats, stats["ms"], (Time.get_ticks_usec() - started) / 1000.0, args["out"], error_string(err)])
	quit(0)
