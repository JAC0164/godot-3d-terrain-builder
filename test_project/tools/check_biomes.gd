extends SceneTree
## Checks of the biome system (biomes/*.gd + mesh/detail_scatter.gd).
## Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_biomes.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const DetailLayer = preload(ADDON + "biomes/detail_layer.gd")
const DetailMeshes = preload(ADDON + "mesh/detail_meshes.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

var _failures := 0

func _check(ok: bool, label: String) -> void:
	print("%s  %s" % ["OK  " if ok else "FAIL", label])
	if not ok:
		_failures += 1

func _details(terrain: Node3D) -> Dictionary:
	return DetailScatter.count_instances(terrain)

func _buffers(terrain: Node3D) -> PackedFloat32Array:
	var all := PackedFloat32Array()
	for node in terrain.find_children("_Details*", "MultiMeshInstance3D", true, false):
		all.append_array((node as MultiMeshInstance3D).multimesh.buffer)
	return all

func _initialize() -> void:
	# Own terrain (no scene file needed): a generated temperate island, with
	# hills (slope rules) and empty cells around it.
	var root := Node3D.new()
	root.name = "CheckBiomes"
	get_root().add_child(root)
	var terrain := TestTerrain.island(root)
	var builder := TerrainBuilder.new()
	builder.owner_provider = func() -> Node: return root

	# 1. No biome: built-in Temperate (grass + rocks).
	Meta.set_optional(terrain, Meta.BIOME, null)
	builder.rebuild_all(terrain)
	var counts := _details(terrain)
	_check(int(counts.get("Grass", 0)) > 500 and int(counts.get("Rocks", 0)) > 50, "default biome scatters grass + rocks %s" % [counts])
	_check(not terrain.has_meta(Meta.LEGACY_DETAIL_GRASS_DENSITY), "legacy density keys removed")

	# 2. Deterministic.
	var first := _buffers(terrain)
	builder.rebuild_all_details(terrain)
	_check(_buffers(terrain) == first, "re-scatter gives identical buffers")

	# 3. Density multiplier.
	terrain.set_meta(Meta.DETAIL_DENSITY, 0.5)
	builder.rebuild_all_details(terrain)
	var half := _details(terrain)
	var ratio := float(half.get("Grass", 0)) / maxf(float(counts.get("Grass", 1)), 1.0)
	_check(ratio > 0.4 and ratio < 0.6, "density x0.5 -> grass ratio %.2f" % ratio)
	terrain.set_meta(Meta.DETAIL_DENSITY, 1.0)

	# 4. Custom biome replaces the layers; stale nodes are removed.
	var biome := TerrainBiome.make_temperate()
	var props := DetailLayer.new()
	props.name = "Props"
	props.builtin_mesh = 4
	props.density = 0.3
	props.clump_size = 6.0
	props.clump_coverage = 0.3
	props.color_mode = DetailLayer.ColorMode.FIXED
	props.tint = Color(0.8, 0.3, 0.2)
	props.brightness_jitter = 0.0
	var layers: Array[DetailLayer] = [props]
	biome.detail_layers = layers
	terrain.set_meta(Meta.BIOME, biome)
	builder.rebuild_all_details(terrain)
	counts = _details(terrain)
	_check(counts.keys() == ["Props"], "only the biome's layer remains %s" % [counts])
	var cells := 0
	for flag in terrain.get_meta(Meta.CELL_ACTIVE):
		cells += 1 if flag != 0 else 0
	var coverage := float(counts.get("Props", 0)) / (0.3 * float(cells))
	_check(coverage > 0.15 and coverage < 0.5, "clumping (coverage 0.3) keeps %.2f of the instances" % coverage)
	var node := terrain.find_children("_Details*", "MultiMeshInstance3D", true, false)[0] as MultiMeshInstance3D
	# Read the buffer (the headless dummy renderer returns no instance data).
	var buffer := node.multimesh.buffer
	var colour := Color(buffer[12], buffer[13], buffer[14], buffer[15])
	_check(colour.is_equal_approx(Color(0.8, 0.3, 0.2)), "FIXED colour mode uses the tint (%s)" % colour)

	# 5. Rules: slope range + STYLES filter.
	props.clump_size = 0.0
	builder.rebuild_all_details(terrain)
	var everywhere := int(_details(terrain).get("Props", 0))
	props.slope_min = 12.0
	builder.rebuild_all_details(terrain)
	var steep_only := int(_details(terrain).get("Props", 0))
	_check(steep_only > 0 and steep_only < everywhere / 2, "slope_min 12 keeps only sloped cells (%d of %d)" % [steep_only, everywhere])
	props.slope_min = 0.0
	props.ground_filter = DetailLayer.GroundFilter.STYLES
	props.filter_styles = PackedInt32Array([999])
	builder.rebuild_all_details(terrain)
	_check(_details(terrain).is_empty(), "STYLES filter with an unused style places nothing")

	# 6. Layer edits re-emit `changed` on the biome (live editing).
	var emitted := [0]
	biome.changed.connect(func() -> void: emitted[0] += 1)
	props.density = 0.4
	_check(emitted[0] > 0, "layer edit emits biome.changed")

	# 7. Disabled details remove every node.
	terrain.set_meta(Meta.DETAIL_ENABLED, false)
	builder.rebuild_all_details(terrain)
	_check(terrain.find_children("_Details*", "", true, false).is_empty(), "details disabled -> no detail nodes")
	terrain.set_meta(Meta.DETAIL_ENABLED, true)

	# 8. Embedded biome survives a scene save / load.
	props.ground_filter = DetailLayer.GroundFilter.ANY
	builder.rebuild_all(terrain)
	var packed := PackedScene.new()
	packed.pack(root)
	var path := "user://check_biomes.tscn"
	ResourceSaver.save(packed, path)
	var loaded := (ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene).instantiate()
	var loaded_terrain: Node3D = loaded.get_node("LowpolyTerrain")
	var loaded_biome := Meta.get_optional(loaded_terrain, Meta.BIOME) as Resource
	_check(loaded_biome != null and loaded_biome.detail_layers.size() == 1 and loaded_biome.detail_layers[0].name == "Props", "embedded biome saved with the scene")
	_check(int(_details(loaded_terrain).get("Props", 0)) == int(_details(terrain).get("Props", 0)), "saved detail nodes match")
	loaded.free()

	# 9. Shipped presets.
	var preset := load(ADDON + "biomes/presets/temperate.tres") as Resource
	_check(preset != null and preset.get_script() == TerrainBiome and preset.detail_layers.size() == 2, "presets/temperate.tres loads")
	var savanna := load(ADDON + "biomes/presets/senegal_savanna.tres") as Resource
	_check(savanna != null and savanna.detail_layers.size() == 13 and savanna.ground_styles.size() == 6, "presets/senegal_savanna.tres loads (13 layers, 6 grounds)")

	# 10. Built-in meshes: present, small, and (except grass blades, which
	# carry both windings with an upward normal) every stored normal matches
	# its face winding, so the front face is the lit one.
	for index in range(1, 11):
		var mesh := DetailMeshes.builtin(index)
		if mesh == null:
			_check(false, "built-in mesh %d exists" % index)
			continue
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var triangles := vertices.size() / 3
		var consistent := 0
		for t in range(triangles):
			var a := vertices[t * 3]
			var winding := (vertices[t * 3 + 2] - a).cross(vertices[t * 3 + 1] - a)
			if winding.length_squared() < 1e-12 or normals[t * 3].dot(winding) > 0.0:
				consistent += 1
		var blades := index == DetailMeshes.GRASS_TUFT or index == DetailMeshes.DRY_GRASS_TUFT
		_check(triangles > 0 and triangles <= 700 and (blades or consistent == triangles),
			"built-in mesh %d: %d triangles, %d/%d normals match the winding" % [index, triangles, consistent, triangles])

	root.queue_free()
	print("RESULT %s (%d failure(s))" % ["OK" if _failures == 0 else "FAILED", _failures])
	quit(1 if _failures > 0 else 0)
