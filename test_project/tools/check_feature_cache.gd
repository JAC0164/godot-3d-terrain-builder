extends SceneTree
## Editor road / river cache (TerrainBuilder.feature_cache_enabled, phase 3):
## after ground edits on roads, a road change and a river, the mesh made from
## the cache is the same, bit for bit, as a full build; and the time it took.
##   Godot --headless --path . --script res://tools/check_feature_cache.gd

const Meta = preload("res://addons/lowpoly_terrain_editor/core/terrain_meta.gd")
const TerrainData = preload("res://addons/lowpoly_terrain_editor/core/terrain_data.gd")
const MapGenerator = preload("res://addons/lowpoly_terrain_editor/generation/map_generator.gd")
const TerrainBuilder = preload("res://addons/lowpoly_terrain_editor/mesh/terrain_builder.gd")
const FeatureMesher = preload("res://addons/lowpoly_terrain_editor/mesh/feature_mesher.gd")
const FeatureStyle = preload("res://addons/lowpoly_terrain_editor/styles/feature_style.gd")

var _failures := 0

func _ms(start: int) -> float:
	return (Time.get_ticks_usec() - start) / 1000.0

func _mesh_hash(mesh: ArrayMesh) -> int:
	var parts: Array = []
	for surface in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(surface)
		parts.append([arrays[Mesh.ARRAY_VERTEX], arrays[Mesh.ARRAY_NORMAL], arrays[Mesh.ARRAY_TEX_UV], _material_key(mesh.surface_get_material(surface))])
	return hash(var_to_bytes(parts))

## A material by its saved values (river materials are made anew on each
## build, full or cached alike).
func _material_key(material: Material) -> Array:
	var key: Array = [material.get_class()]
	for property in material.get_property_list():
		if property["usage"] & PROPERTY_USAGE_STORAGE:
			var value: Variant = material.get(property["name"])
			key.append(value.get_instance_id() if value is Object and not value is Resource else value)
	return key

func _same(label: String, terrain: Node3D, builder: TerrainBuilder, cached_ms: float) -> void:
	var node: MeshInstance3D = terrain.get_node(Meta.GENERATED_MESH_NAME)
	var t := Time.get_ticks_usec()
	var full: Dictionary = FeatureMesher.build(terrain, builder.get_river_carve(terrain))
	var full_ms := _ms(t)
	var ok: bool = _mesh_hash(node.mesh) == _mesh_hash(full["mesh"]) and builder.get_feature_collision_faces(terrain) == full["collision_faces"]
	if not ok:
		_failures += 1
		var a: ArrayMesh = node.mesh
		var b: ArrayMesh = full["mesh"]
		for surface in a.get_surface_count():
			var x := a.surface_get_arrays(surface)
			var y := b.surface_get_arrays(surface)
			var first := -1
			var vx: PackedVector3Array = x[Mesh.ARRAY_VERTEX]
			var vy: PackedVector3Array = y[Mesh.ARRAY_VERTEX]
			for i in mini(vx.size(), vy.size()):
				if vx[i] != vy[i]:
					first = i
					break
			print("  surface %d: vertices %d/%d same %s first diff %d %s / %s, normals %s, uvs %s, material %s, collision %s" % [surface, vx.size(), vy.size(), vx == vy, first,
				vx[first] if first >= 0 else "", vy[first] if first >= 0 else "",
				x[Mesh.ARRAY_NORMAL] == y[Mesh.ARRAY_NORMAL], x[Mesh.ARRAY_TEX_UV] == y[Mesh.ARRAY_TEX_UV], _material_key(a.surface_get_material(surface)) == _material_key(b.surface_get_material(surface)),
				builder.get_feature_collision_faces(terrain) == full["collision_faces"]])
	print("%s %s: cached %.0f ms, full %.0f ms (%d surfaces)" % ["ok  " if ok else "FAIL", label, cached_ms, full_ms, node.mesh.get_surface_count()])

func _initialize() -> void:
	var terrain := Node3D.new()
	root.add_child(terrain)
	TerrainData.initialize(terrain)
	var recipe: Resource = load("res://addons/lowpoly_terrain_editor/generation/presets/senegal_savanna_map.tres").duplicate()
	recipe.size = 512
	recipe.cell_size = 1.5
	MapGenerator.generate(terrain, recipe, 7)
	var mesh_node := MeshInstance3D.new()
	mesh_node.name = Meta.GENERATED_MESH_NAME
	terrain.add_child(mesh_node)
	# A river across the map too: rivers are cached whole.
	var half: float = float(terrain.get_meta(Meta.WORLD_SIZE)) * 0.5
	FeatureStyle.commit(terrain, FeatureStyle.RIVER, [Vector2(-half * 0.8, half * 0.3), Vector2(0, half * 0.1), Vector2(half * 0.8, half * 0.4)] as Array[Vector2])
	var builder := TerrainBuilder.new()
	builder.feature_cache_enabled = true
	builder.rebuild_river_carve(terrain)
	var t := Time.get_ticks_usec()
	builder.rebuild_feature_mesh(terrain)
	_same("first build (fills the cache)", terrain, builder, _ms(t))

	# Strokes on the first road: heights raised in a 12 m box, three places.
	var road: Dictionary = (terrain.get_meta(Meta.ROADS) as Array)[0]
	var points: Array = road["points"]
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var spacing: float = float(terrain.get_meta(Meta.WORLD_SIZE)) / float(resolution - 1)
	for i in 3:
		var p: Vector2 = points[(points.size() * (i + 1)) / 4]
		var rect := Rect2(p - Vector2(6, 6), Vector2(12, 12))
		var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
		for z in range(int((rect.position.y + half) / spacing), int((rect.end.y + half) / spacing) + 1):
			for x in range(int((rect.position.x + half) / spacing), int((rect.end.x + half) / spacing) + 1):
				heights[z * resolution + x] += 0.8
		terrain.set_meta(Meta.HEIGHTS, heights)
		builder.rebuild_river_carve(terrain)
		t = Time.get_ticks_usec()
		builder.rebuild_feature_mesh(terrain, rect)
		_same("stroke %d on the road" % (i + 1), terrain, builder, _ms(t))

	# A new road far from the others (its own group): only it is made.
	FeatureStyle.commit(terrain, FeatureStyle.ROAD, [Vector2(-half * 0.6, -half * 0.7), Vector2(-half * 0.2, -half * 0.75)] as Array[Vector2])
	t = Time.get_ticks_usec()
	builder.rebuild_feature_mesh(terrain, false)
	_same("new road", terrain, builder, _ms(t))
	print("feature cache: %d failures" % _failures)
	quit(1 if _failures > 0 else 0)
