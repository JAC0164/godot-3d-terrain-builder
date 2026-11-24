extends SceneTree
## The ground's shadow comes from back-face casters (MeshUtils.back_face_caster):
##   1. a runtime-built map: every chunk casts nothing and has a shadow-only
##      _GroundShadow child with as many triangles as the chunk;
##   2. Ground Casts Shadows off / on (TerrainBuilder.apply_ground_shadows);
##   3. a scene saved before the casters (scenes/savanna_128.tscn) gets them
##      when it loads.
##   godot --headless --path . --script res://tools/check_ground_shadow.gd
const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")

var _failures := 0

func _initialize() -> void:
	await process_frame
	var terrain := Node3D.new()
	get_root().add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(ADDON + "generation/presets/senegal_savanna_map.tres"), 7)
	terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	var runtime := TerrainRuntime.new()
	runtime.build_on_ready = false
	runtime.progressive = false
	runtime.detail_collision = false
	terrain.add_child(runtime)
	runtime.build()
	_check_casters("runtime map", terrain, GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY, true)
	terrain.set_meta(Meta.GROUND_SHADOWS, false)
	TerrainBuilder.apply_ground_shadows(terrain)
	_check_casters("ground shadows off", terrain, GeometryInstance3D.SHADOW_CASTING_SETTING_OFF, false)
	terrain.set_meta(Meta.GROUND_SHADOWS, true)
	TerrainBuilder.apply_ground_shadows(terrain)
	_check_casters("ground shadows on again", terrain, GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY, false)
	terrain.queue_free()

	var scene := (load("res://scenes/savanna_128.tscn") as PackedScene).instantiate()
	get_root().add_child(scene)
	for i in 5:
		await process_frame
	for node in scene.find_children("*", "Node3D", true, false):
		if Meta.is_terrain(node as Node3D):
			_check_casters("saved scene " + String(node.name), node, GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY, true)
	print("RESULT %s (%d failure(s))" % ["OK" if _failures == 0 else "FAIL", _failures])
	quit()

func _check_casters(label: String, terrain: Node3D, expected: int, count_triangles: bool) -> void:
	var container := terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME)
	var chunks := 0
	var bad := PackedStringArray()
	if container != null:
		for child in container.get_children():
			var chunk := child as MeshInstance3D
			if chunk == null or chunk.mesh == null:
				continue
			chunks += 1
			var caster := chunk.get_node_or_null(Meta.GROUND_SHADOW_NAME) as MeshInstance3D
			if chunk.cast_shadow != GeometryInstance3D.SHADOW_CASTING_SETTING_OFF:
				bad.append("%s casts" % chunk.name)
			if caster == null or caster.mesh == null:
				bad.append("%s has no caster" % chunk.name)
				continue
			if caster.cast_shadow != expected:
				bad.append("%s caster setting %d" % [chunk.name, caster.cast_shadow])
			if count_triangles:
				var triangles := 0
				for s in chunk.mesh.get_surface_count():
					triangles += chunk.mesh.surface_get_array_len(s) / 3
				var caster_triangles: int = caster.mesh.surface_get_array_index_len(0) / 3
				if caster_triangles != triangles:
					bad.append("%s %d triangles, caster %d" % [chunk.name, triangles, caster_triangles])
	if chunks == 0:
		bad.append("no chunk")
	_failures += bad.size()
	print("%s %s: %d chunks%s" % ["OK  " if bad.is_empty() else "FAIL", label, chunks, "" if bad.is_empty() else " — " + ", ".join(bad.slice(0, 5))])
