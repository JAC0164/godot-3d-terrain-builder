extends SceneTree
## Checks the mobile optimisations of the plugin:
## - untextured styles share ONE vertex-coloured surface per chunk,
## - textured styles keep their own surface,
## - terrain materials are shared between chunks,
## - "Mobile Water" / refraction 0 select the shader without screen refraction.
##
##   godot --headless --path . --script res://tools/check_optimizations.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const TerrainBiomeRef = preload(ADDON + "biomes/terrain_biome.gd")
const MaterialFactoryRef = preload(ADDON + "materials/material_factory.gd")
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const StylePalette = preload(ADDON + "styles/style_palette.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const FeatureMesher = preload(ADDON + "mesh/feature_mesher.gd")
const MaterialFactory = preload(ADDON + "materials/material_factory.gd")

var _failures := 0

func _check(condition: bool, label: String) -> void:
	print("%s %s" % ["PASS" if condition else "FAIL", label])
	if not condition:
		_failures += 1

func _initialize() -> void:
	var terrain := Node3D.new()
	TerrainData.initialize(terrain)
	var feature_node := MeshInstance3D.new()
	feature_node.name = Meta.GENERATED_MESH_NAME
	terrain.add_child(feature_node)

	# Fill the whole 48x48 grid: left half untextured (two colours), right
	# quarter with a textured top.
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var cells := resolution - 1
	var green := StylePalette.capture_style_definition(terrain, Color(0.3, 0.7, 0.3), Color(0.4, 0.3, 0.2), null, null, 2.0, 2.0)
	var sand := StylePalette.capture_style_definition(terrain, Color(0.9, 0.8, 0.5), Color(0.6, 0.5, 0.3), null, null, 2.0, 2.0)
	var texture := GradientTexture2D.new()
	var textured := StylePalette.capture_style_definition(terrain, Color.WHITE, Color(0.5, 0.5, 0.5), texture, null, 2.0, 2.0)
	var mask := PackedFloat32Array()
	mask.resize(resolution * resolution)
	mask.fill(1.0)
	var active := PackedByteArray()
	active.resize(cells * cells)
	active.fill(1)
	var styles := PackedInt32Array()
	styles.resize(cells * cells)
	for z in range(cells):
		for x in range(cells):
			styles[z * cells + x] = green if x < 20 else (sand if x < 36 else textured)
	terrain.set_meta(Meta.MASK, mask)
	terrain.set_meta(Meta.CELL_ACTIVE, active)
	terrain.set_meta(Meta.CELL_STYLES, styles)
	# Surface-merge checks expect flat style colours: baked shading off here
	# (it is covered by compare_chunks.gd / check_shading_seams.gd).
	for shade_key in TerrainData.SHADE_DEFAULTS:
		terrain.set_meta(shade_key, 0)
	var flat_biome: Resource = TerrainBiome.default_biome().duplicate(true)
	for property in ["blend", "blend_noise", "slope_tint", "ambient_occlusion", "variation", "macro_variation", "cliff_darken", "cliff_lip"]:
		flat_biome.set(property, 0)
	terrain.set_meta(Meta.BIOME, flat_biome)

	var builder := TerrainBuilder.new()
	builder.rebuild_all(terrain)
	var chunks := terrain.get_node(Meta.GENERATED_CHUNKS_NAME).get_children()
	_check(chunks.size() == 4, "4 chunks for a 48x48 grid")

	# Chunk 0_0 covers x 0..31: green + sand only -> one surface.
	var mesh_00: ArrayMesh = terrain.get_node("%s/Chunk_0_0" % Meta.GENERATED_CHUNKS_NAME).mesh
	_check(mesh_00.get_surface_count() == 1, "untextured chunk has 1 surface (got %d)" % mesh_00.get_surface_count())
	var arrays := mesh_00.surface_get_arrays(0)
	_check(arrays[Mesh.ARRAY_COLOR] != null and (arrays[Mesh.ARRAY_COLOR] as PackedColorArray).size() == (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(), "vertex colours on every vertex")
	var colors := {}
	for c in arrays[Mesh.ARRAY_COLOR]:
		colors[c.to_html()] = true
	_check(colors.size() == 4, "4 colours = 2 styles x (top, side) (got %d)" % colors.size())
	var vc_material := mesh_00.surface_get_material(0) as StandardMaterial3D
	_check(vc_material.vertex_color_use_as_albedo and vc_material.vertex_color_is_srgb, "vertex-colour material, sRGB")

	# Chunk 1_0 covers x 32..47: sand (untextured) + textured top + its sides.
	# The textured top goes to the blended surface, even with the baked
	# shading off.
	var mesh_10: ArrayMesh = terrain.get_node("%s/Chunk_1_0" % Meta.GENERATED_CHUNKS_NAME).mesh
	_check(mesh_10.get_surface_count() == 2 and mesh_10.surface_get_format(1) & Mesh.ARRAY_FORMAT_CUSTOM0, "mixed chunk: 1 merged + 1 blended texture surface (got %d)" % mesh_10.get_surface_count())
	var textured_material := mesh_10.surface_get_material(1) as ShaderMaterial
	_check(textured_material != null and textured_material.get_shader_parameter("layer_0") == texture, "blended surface keeps its texture")
	_check(mesh_10.surface_get_material(0) == vc_material, "vertex-colour material shared between chunks")

	var mesh_11: ArrayMesh = terrain.get_node("%s/Chunk_1_1" % Meta.GENERATED_CHUNKS_NAME).mesh
	_check(mesh_11.surface_get_material(1) == textured_material, "blended texture material shared between chunks")

	# Same geometry as before: one top quad (2 triangles) per active cell.
	var total_vertices := 0
	for chunk in chunks:
		for i in range(chunk.mesh.get_surface_count()):
			total_vertices += chunk.mesh.surface_get_array_len(i)
	var expected_top := cells * cells * 6
	var expected_sides := cells * 4 * 6
	_check(total_vertices == expected_top + expected_sides, "vertex count unchanged (%d)" % total_vertices)

	# Double-sided must not reuse the culled material.
	terrain.set_meta(Meta.DOUBLE_SIDED, true)
	var double_sided: ArrayMesh = TerrainMesher.build_chunk(terrain, builder.get_river_carve(terrain), 0, 0)
	_check((double_sided.surface_get_material(0) as BaseMaterial3D).cull_mode == BaseMaterial3D.CULL_DISABLED, "double-sided gets its own material")
	terrain.set_meta(Meta.DOUBLE_SIDED, false)

	# Water shaders.
	var river_points: Array[Vector2] = [Vector2(-15, -5), Vector2(0, 0), Vector2(15, 6)]
	FeatureStyle.commit(terrain, FeatureStyle.RIVER, river_points)
	var shader_of := func() -> String:
		var mesh: ArrayMesh = FeatureMesher.build(terrain, builder.get_river_carve(terrain))["mesh"]
		return ((mesh.surface_get_material(mesh.get_surface_count() - 1) as ShaderMaterial).shader as Shader).resource_path.get_file()
	_check(shader_of.call() == "river_water.gdshader", "default: refraction shader")
	terrain.set_meta(Meta.RIVER_MOBILE_WATER, true)
	_check(shader_of.call() == "river_water_mobile.gdshader", "Mobile Water: shader without refraction")
	_check(not (load(ADDON + "materials/river_water_mobile.gdshader") as Shader).code.contains("hint_screen_texture"), "mobile shader does not read the screen")
	terrain.set_meta(Meta.RIVER_MOBILE_WATER, false)
	# Water Material of the biome with Refraction Strength 0.
	var biome: Resource = TerrainBiomeRef.of(terrain).duplicate()
	var water: ShaderMaterial = MaterialFactoryRef.editable_water_material(Color(0.1, 0.4, 0.5, 0.7))
	water.set_shader_parameter("refraction_strength", 0.0)
	biome.set("water_material", water)
	terrain.set_meta(Meta.BIOME, biome)
	_check(shader_of.call() == "river_water_mobile.gdshader", "refraction 0: shader without refraction")
	var rivers: Array = terrain.get_meta(Meta.RIVERS)
	rivers[0]["color"] = Color(0.1, 0.4, 0.5, 0.7)
	rivers[0]["refraction"] = 0.0
	terrain.set_meta(Meta.RIVERS, rivers)
	_check(shader_of.call() == "river_water_mobile.gdshader", "old river with its own look, refraction 0: shader without refraction")

	terrain.free()
	print("RESULT: %s (%d failure(s))" % ["OK" if _failures == 0 else "FAILED", _failures])
	quit(1 if _failures > 0 else 0)
