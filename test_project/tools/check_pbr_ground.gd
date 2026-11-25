extends SceneTree
## Normal / roughness maps of the biome ground styles (GroundStyle "Surface"):
## the blended surface switches to the PBR variant of its shader (same 7
## layers, normal / roughness maps on 4 of them, same mesh),
## textured cliffs get a normal map and real tangents, a textured face gives
## its mean colour, the blended textures stay with shading off, and without
## surface maps nothing changes. Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_pbr_ground.gd
## With a window (no --headless) it also draws the ground and saves
## results/pbr_ground_<renderer>.png: the shader must compile (no SHADER
## ERROR in the output), e.g. with --rendering-method gl_compatibility.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const StylePalette = preload(ADDON + "styles/style_palette.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const MaterialFactory = preload(ADDON + "materials/material_factory.gd")
const MeshUtils = preload(ADDON + "mesh/mesh_utils.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _texture(color: Color, spot: Color) -> Texture2D:
	var image := Image.create(16, 16, false, Image.FORMAT_RGB8)
	image.fill(color)
	for i in 16:
		image.set_pixel(i, i, spot)
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

## Bumps: a normal map leaning along +X on half of the texels.
func _normal_map() -> Texture2D:
	var image := Image.create(16, 16, false, Image.FORMAT_RGB8)
	for y in 16:
		for x in 16:
			image.set_pixel(x, y, Color(0.75, 0.5, 0.95) if (x / 4) % 2 == 0 else Color(0.25, 0.5, 0.95))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

func _surfaces(t: Node3D) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	# Each chunk is a MeshInstance3D (its details are children).
	for chunk: Node in t.get_node(Meta.GENERATED_CHUNKS_NAME).get_children():
		var instance := chunk as MeshInstance3D
		if instance == null or not (instance.mesh is ArrayMesh):
			continue
		var mesh := instance.mesh as ArrayMesh
		for s in mesh.get_surface_count():
			result.append({"material": mesh.surface_get_material(s), "format": mesh.surface_get_format(s)})
	return result

func _splat_materials(t: Node3D) -> Array[ShaderMaterial]:
	var result: Array[ShaderMaterial] = []
	for surface: Dictionary in _surfaces(t):
		if int(surface["format"]) & Mesh.ARRAY_FORMAT_CUSTOM0 and surface["material"] is ShaderMaterial:
			result.append(surface["material"])
	return result

func _initialize() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var t := TestTerrain.savanna(root)
	var builder := TerrainBuilder.new()

	# Two biome styles get textures (the cells painted with them follow).
	var biome: TerrainBiome = TerrainBiome.of(t).duplicate(true)
	var used := {}
	for style: Dictionary in t.get_meta(Meta.STYLE_PALETTE):
		if style.has("biome_style"):
			used[style["biome_style"]] = true
	var textured: Array = []
	for ground: TerrainBiome.GroundStyle in biome.ground_styles:
		if ground != null and used.has(String(ground.name)) and textured.size() < 2:
			textured.append(ground)
	check("two biome styles used by the map (%d)" % textured.size(), textured.size() == 2)
	var red := Color(0.8, 0.3, 0.2)
	textured[0].top_texture = _texture(red, Color(0.4, 0.15, 0.1))
	textured[0].side_texture = _texture(Color(0.5, 0.4, 0.35), Color(0.3, 0.25, 0.2))
	textured[1].top_texture = _texture(Color(0.6, 0.55, 0.3), Color(0.5, 0.45, 0.25))
	t.set_meta(Meta.BIOME, biome)
	builder.rebuild_all(t)
	var plain_splat := _splat_materials(t)
	check("albedo only: blended surface with the shader file (%d)" % plain_splat.size(), not plain_splat.is_empty() and plain_splat[0].shader.resource_path.ends_with("terrain_splat.gdshader"))
	check("albedo only: 7 layers at most", MaterialFactory.splat_layers(t).size() <= MaterialFactory.MAX_SPLAT_LAYERS and not MaterialFactory.splat_pbr(t))
	var linked_id := -1
	var palette: Array = t.get_meta(Meta.STYLE_PALETTE)
	for i in palette.size():
		if String((palette[i] as Dictionary).get("biome_style", "")) == String(textured[0].name):
			linked_id = i
	var mean := MaterialFactory.terrain_style_color(t, linked_id, true)
	var expected := red.lerp(Color(0.4, 0.15, 0.1), 1.0 / 16.0)
	if DisplayServer.get_name() != "headless":
		await _render(root, "albedo")
	check("textured face: its texture's mean colour (%s)" % mean, linked_id >= 0 and absf(mean.r - expected.r) < 0.02 and absf(mean.g - expected.g) < 0.02)

	# Surface maps: PBR variant, same layers, cliffs with normal map + tangents.
	var layers_before := MaterialFactory.splat_layers(t)
	textured[0].top_normal = _normal_map()
	textured[0].top_roughness = _texture(Color(0.3, 0.3, 0.3), Color(0.9, 0.9, 0.9))
	textured[0].side_normal = _normal_map()
	builder.rebuild_all(t)
	check("surface map: PBR variant, same blended layers", MaterialFactory.splat_pbr(t) and MaterialFactory.splat_layers(t) == layers_before)
	var pbr_splat := _splat_materials(t)
	var pbr_ok := not pbr_splat.is_empty()
	for material in pbr_splat:
		pbr_ok = pbr_ok and material.shader.code.contains("#define USE_PBR") and material.get_shader_parameter("normal_0") != null and (material.get_shader_parameter("pbr_layer") as Vector4i).x >= 0
	check("blended surface: PBR shader with the normal map (%d)" % pbr_splat.size(), pbr_ok)
	var samplers := 0
	for uniform: Dictionary in pbr_splat[0].shader.get_shader_uniform_list() if pbr_ok else []:
		if int(uniform["type"]) == TYPE_OBJECT:
			samplers += 1
	check("PBR variant: %d texture slots (<= 16)" % samplers, samplers > 0 and samplers <= 16)
	var cliffs := 0
	var cliffs_ok := true
	for surface: Dictionary in _surfaces(t):
		var standard := surface["material"] as StandardMaterial3D
		if standard != null and standard.normal_enabled:
			cliffs += 1
			cliffs_ok = cliffs_ok and int(surface["format"]) & Mesh.ARRAY_FORMAT_TANGENT != 0 and standard.specular_mode != BaseMaterial3D.SPECULAR_DISABLED
	check("textured cliffs: normal map, tangents, specular (%d surfaces)" % cliffs, cliffs > 0 and cliffs_ok)
	var tangents := MeshUtils.planar_tangents(PackedVector3Array([Vector3.UP]), true)
	check("top tangent along +X, binormal towards -Z", Vector3(tangents[0], tangents[1], tangents[2]).is_equal_approx(Vector3.RIGHT) and tangents[3] == 1.0)

	# Shading off: the textures stay blended.
	var shading_off: TerrainBiome = biome.duplicate()
	for property: String in ["blend", "blend_noise", "slope_tint", "ambient_occlusion", "variation", "cliff_darken", "cliff_lip", "macro_variation"]:
		shading_off.set(property, 0)
	t.set_meta(Meta.BIOME, shading_off)
	builder.rebuild_all(t)
	check("shading off: textures still blended (%d)" % _splat_materials(t).size(), not _splat_materials(t).is_empty())
	t.set_meta(Meta.BIOME, biome)
	builder.rebuild_all(t)

	# A Ground Material written for textures (declares layer_0) draws the
	# blended surface too; one for colours only leaves it alone.
	var toon_shader := Shader.new()
	toon_shader.code = "shader_type spatial;
uniform sampler2D layer_0;
uniform vec4 inv_tile_a;
void fragment() { ALBEDO = texture(layer_0, UV).rgb; }
"
	var toon := ShaderMaterial.new()
	toon.shader = toon_shader
	var colour_shader := Shader.new()
	colour_shader.code = "shader_type spatial;
void fragment() { ALBEDO = COLOR.rgb; }
"
	var colour_only := ShaderMaterial.new()
	colour_only.shader = colour_shader
	var custom_biome: TerrainBiome = biome.duplicate()
	custom_biome.ground_material = toon
	t.set_meta(Meta.BIOME, custom_biome)
	builder.rebuild_all(t)
	var custom_splat := _splat_materials(t)
	check("textured Ground Material: blended surface with its shader and the layers", not custom_splat.is_empty() and custom_splat[0].shader == toon_shader and custom_splat[0].get_shader_parameter("layer_0") != null and toon.get_shader_parameter("layer_0") == null)
	custom_biome.ground_material = colour_only
	builder.rebuild_all(t)
	custom_splat = _splat_materials(t)
	check("colour-only Ground Material: blended surface keeps the built-in shader", not custom_splat.is_empty() and custom_splat[0].shader != colour_shader)
	t.set_meta(Meta.BIOME, biome)
	builder.rebuild_all(t)

	if DisplayServer.get_name() != "headless":
		await _render(root, "pbr")
	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)

func _render(root: Node3D, label: String) -> void:
	if root.get_node_or_null("CheckCamera") == null:
		var sun := DirectionalLight3D.new()
		sun.name = "CheckSun"
		sun.rotation_degrees = Vector3(-35, 60, 0)
		root.add_child(sun)
		var camera := Camera3D.new()
		camera.name = "CheckCamera"
		root.add_child(camera)
		camera.look_at_from_position(Vector3(20, 18, 20), Vector3(0, 2, 0))
		camera.current = true
	for i in 20:
		await process_frame
	var image := get_root().get_texture().get_image()
	var path := "res://results/pbr_ground_%s_%s.png" % [RenderingServer.get_current_rendering_method(), label]
	image.save_png(path)
	print("rendered: ", ProjectSettings.globalize_path(path))
