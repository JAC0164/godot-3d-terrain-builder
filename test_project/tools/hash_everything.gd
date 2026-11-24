extends SceneTree
## Fingerprint of everything the plugin produces, to prove a refactor keeps
## the output byte-identical. For 3 terrains (savanna seed 7 + a river, the
## generated temperate island, scenes/savanna_128.tscn) it prints one hash
## per category:
##   data       every _lte_* metadata value (map generation, carve inputs)
##   ground     chunk meshes + their _GroundShadow casters (all arrays)
##   details    detail MultiMesh buffers
##   features   road / river / waterhole meshes and anything else
##   collision  collision shapes
## Run before and after a change: every line must be the same.
##   godot --headless --path . --script res://tools/hash_everything.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

func _initialize() -> void:
	var holder := Node3D.new()
	get_root().add_child(holder)
	var terrain := Node3D.new()
	holder.add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(RECIPE), 7)
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var points: Array[Vector2] = []
	for i in 9:
		var t := float(i) / 8.0
		points.append(Vector2(lerpf(-0.42, 0.42, t) * size, sin(t * 5.0) * 0.12 * size + 0.18 * size))
	FeatureStyle.commit(terrain, FeatureStyle.RIVER, points)
	_print("savanna", terrain)
	_print("island", TestTerrain.island(holder))
	var scene := TestTerrain.load_scene("res://results/refactor/savanna_128_frozen.tscn")
	holder.add_child(scene)
	_print("savanna_128", scene.get_node("LowpolyTerrain"))
	holder.free()
	quit()

func _print(label: String, terrain: Node3D) -> void:
	var data := _hasher()
	var keys := terrain.get_meta_list()
	# As text: StringNames sort in creation order, which changes with the code.
	keys.sort_custom(func(a: StringName, b: StringName) -> bool: return String(a) < String(b))
	for key in keys:
		data.update(String(key).to_utf8_buffer())
		data.update(var_to_bytes(_stable(terrain.get_meta(key))))
	var start := Time.get_ticks_msec()
	var builder := TerrainBuilder.new()
	builder.rebuild_all(terrain)
	builder.flush_deferred()
	builder.rebuild_collision(terrain, builder.get_feature_collision_faces(terrain))
	var build_ms := Time.get_ticks_msec() - start
	var hashes := {"ground": _hasher(), "details": _hasher(), "features": _hasher(), "collision": _hasher()}
	var nodes := terrain.find_children("*", "", true, false)
	nodes.sort_custom(func(a, b): return String(terrain.get_path_to(a)) < String(terrain.get_path_to(b)))
	for node in nodes:
		var path := String(terrain.get_path_to(node)).to_utf8_buffer()
		if node is MultiMeshInstance3D:
			var multimesh: MultiMesh = node.multimesh
			hashes["details"].update(path)
			if multimesh != null:
				hashes["details"].update(var_to_bytes(multimesh.buffer))
		elif node is MeshInstance3D:
			var category := "ground" if String(node.name).begins_with("Chunk_") or String(node.name) == Meta.GROUND_SHADOW_NAME else "features"
			hashes[category].update(path)
			_hash_mesh(hashes[category], node.mesh)
		elif node is CollisionShape3D:
			hashes["collision"].update(path)
			var shape: Shape3D = node.shape
			if shape is ConcavePolygonShape3D:
				hashes["collision"].update(var_to_bytes((shape as ConcavePolygonShape3D).get_faces()))
			elif shape != null:
				hashes["collision"].update(var_to_bytes(shape.get_debug_mesh().surface_get_arrays(0)[Mesh.ARRAY_VERTEX]))
	print("%-12s data %s ground %s details %s features %s collision %s (%d nodes, %d ms)" % [label,
		data.finish().hex_encode().left(10), hashes["ground"].finish().hex_encode().left(10),
		hashes["details"].finish().hex_encode().left(10), hashes["features"].finish().hex_encode().left(10),
		hashes["collision"].finish().hex_encode().left(10), nodes.size(), build_ms])

## `value` with every Object replaced by its file path (or class): var_to_bytes()
## writes an Object as its instance id, which changes from one run to the
## next as soon as the code creates one object more or less.
func _stable(value: Variant) -> Variant:
	if value is Object:
		var resource := value as Resource
		return "<%s %s>" % [(value as Object).get_class(), resource.resource_path if resource else ""]
	if value is Array:
		var items := []
		for item in value:
			items.append(_stable(item))
		return items
	if value is Dictionary:
		var copy := {}
		for key in value:
			copy[_stable(key)] = _stable(value[key])
		return copy
	return value

func _hasher() -> HashingContext:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	return ctx

func _hash_mesh(ctx: HashingContext, mesh: Mesh) -> void:
	if mesh == null:
		return
	for surface in mesh.get_surface_count():
		for array in mesh.surface_get_arrays(surface):
			if array != null:
				ctx.update(var_to_bytes(array))
