extends SceneTree
## Cost of MeshUtils.back_face_caster at load: every ground chunk of the
## explore map (seed 7), vertices of the chunks / of their casters, total ms.
##   godot --headless --path . --script res://tools/time_shadow_mesh.gd
const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const MeshUtils = preload(ADDON + "mesh/mesh_utils.gd")

func _initialize() -> void:
	await process_frame
	var terrain := Node3D.new()
	get_root().add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(ADDON + "generation/presets/senegal_savanna_map.tres"), 7)
	terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	var runtime := TerrainRuntime.new()
	# Every detail at load (as the earlier measures; on by default since 2026-11-24).
	runtime.stream_details = false
	runtime.build_on_ready = false
	runtime.progressive = false
	runtime.detail_collision = false
	terrain.add_child(runtime)
	runtime.build()
	var meshes: Array[ArrayMesh] = []
	for node in terrain.find_children("*", "MeshInstance3D", true, false):
		if String(node.name).begins_with("Chunk") and node.mesh is ArrayMesh:
			meshes.append(node.mesh)
	var before := 0
	var after := 0
	for m in meshes:
		for s in m.get_surface_count():
			before += m.surface_get_array_len(s)
			pass
		after += MeshUtils.back_face_caster(m).surface_get_array_len(0)
	var start := Time.get_ticks_usec()
	for m in meshes:
		MeshUtils.back_face_caster(m)
	var ms := (Time.get_ticks_usec() - start) / 1000.0
	print("chunks: %d, vertices %d -> %d (%.1fx fewer), back_face_caster total %.1f ms (%.2f ms per chunk)" % [meshes.size(), before, after, float(before) / max(after, 1), ms, ms / max(meshes.size(), 1)])
	quit()
