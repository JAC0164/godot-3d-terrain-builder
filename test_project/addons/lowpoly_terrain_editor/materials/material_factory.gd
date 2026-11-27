@tool
extends RefCounted
## Builds the materials used by generated terrain, road and river surfaces.

const Meta = preload("../core/terrain_meta.gd")
const StylePalette = preload("../styles/style_palette.gd")
const FeatureStyle = preload("../styles/feature_style.gd")
const TerrainBiome = preload("../biomes/terrain_biome.gd")
const RiverWaterShader = preload("river_water.gdshader")
## Same water without the screen-texture refraction: no screen copy pass,
## much cheaper on mobile GPUs and the Compatibility renderer.
const RiverWaterMobileShader = preload("river_water_mobile.gdshader")
const DetailMeshes = preload("../mesh/detail_meshes.gd")

## Shared fallback normal map for rivers without a custom Water Normal Texture.
static var _generated_water_normal: Texture2D = null

## Terrain materials shared by every chunk surface with the same look, keyed by
## a description of their properties. Sharing (instead of one copy per
## surface) keeps generated scenes small and lets the renderer batch state.
static var _terrain_material_cache: Dictionary = {}
## Water Material instance id -> its copy without refraction.
static var _no_refraction_copies: Dictionary = {}

## Wind profiles of the detail material: shader parameters per kind of plant
## (see materials/detail_wind.gdshader; `height` = top of the built-in mesh,
## `strength` / `flutter` = sway at that top, in mesh units). Grass bends a
## lot, shrubs less, trees only sway their crown (high stiffness keeps the
## trunk still), baobabs barely move.
const WIND_PROFILES := {
	"grass": {"height": 0.5, "strength": 0.07, "speed": 1.6, "flutter": 0.012, "stiffness": 1.5},
	"shrub": {"height": 0.8, "strength": 0.04, "speed": 1.3, "flutter": 0.01, "stiffness": 2.0},
	"tree": {"height": 1.0, "strength": 0.025, "speed": 1.0, "flutter": 0.008, "stiffness": 3.0},
	"baobab": {"height": 0.9, "strength": 0.01, "speed": 0.9, "flutter": 0.004, "stiffness": 3.0},
}
const DetailWindShader = preload("detail_wind.gdshader")
## Grass: drawn from both sides, one triangle per blade (see the shader).
const DetailWindTwoSidedShader = preload("detail_wind_two_sided.gdshader")
const TWO_SIDED_PROFILES := ["grass"]
## Global wind (set_wind): direction (world X / Z) and strength multiplier.
static var _wind_direction := Vector2(1.0, 0.35)
static var _wind_scale := 1.0

## Size (px) of the generated river wave normal map.
const WATER_NORMAL_SIZE := 256

## Blended ground textures (terrain_splat.gdshader): textured ground styles
## blended per vertex, up to this many (the next ones keep a surface of their
## own, with hard cell borders). The 8th CUSTOM channel is the waterhole tint.
const MAX_SPLAT_LAYERS := 7
## Blended layers that can have a normal / roughness map (7 albedo + 8 = 15
## texture slots, within the 16 of phones).
const MAX_PBR_LAYERS := 4
const TerrainSplatShader = preload("terrain_splat.gdshader")
## "cull|pbr" -> Shader (the file is cull_back, without USE_PBR).
static var _splat_shaders: Dictionary = {}

static func clear_cache() -> void:
	_terrain_material_cache.clear()
	_no_refraction_copies.clear()

static func _cull_mode(terrain: Node3D) -> BaseMaterial3D.CullMode:
	return BaseMaterial3D.CULL_DISABLED if Meta.get_bool(terrain, Meta.DOUBLE_SIDED, false) else BaseMaterial3D.CULL_BACK

static func _style(terrain: Node3D, style_id: int) -> Dictionary:
	var palette: Array = terrain.get_meta(Meta.STYLE_PALETTE, [StylePalette.make_default_style()])
	if palette.is_empty():
		palette = [StylePalette.make_default_style()]
	style_id = clamp(style_id, 0, palette.size() - 1)
	var style: Dictionary = palette[style_id]
	return StylePalette.migrate_style_texture_fields(style)

## Texture of the top (`top == true`) or side faces of a palette style, or null.
static func terrain_style_texture(terrain: Node3D, style_id: int, top: bool) -> Texture2D:
	var texture: Object = _style(terrain, style_id).get("top_texture" if top else "cliff_texture", null)
	return texture as Texture2D

## Normal map (`roughness` false) or roughness map of the top / side faces
## of a palette style: from the biome ground style it was painted with
## (palette "biome_style"), so they follow the biome; null for a Custom style.
static func terrain_style_surface(terrain: Node3D, style_id: int, top: bool, roughness: bool) -> Texture2D:
	var linked: String = _style(terrain, style_id).get("biome_style", "")
	if linked.is_empty():
		return null
	for ground: TerrainBiome.GroundStyle in TerrainBiome.of(terrain).ground_styles:
		if ground != null and String(ground.name) == linked:
			if top:
				return ground.top_roughness if roughness else ground.top_normal
			return ground.side_roughness if roughness else ground.side_normal
	return null

## Flat colour of the top or side faces of a palette style. A textured face
## gives its texture's mean colour (StylePalette.fill_texture_means): far
## ground, grass tint and borders match the texture without tuning.
static func terrain_style_color(terrain: Node3D, style_id: int, top: bool) -> Color:
	var style := _style(terrain, style_id)
	var side := "top" if top else "cliff"
	if style.get(side + "_texture", null) != null and style.has(side + "_mean"):
		return style[side + "_mean"]
	return style.get(side + "_color", Color.WHITE)

## Compiles `material`'s shader now (a StandardMaterial3D compiles on first
## use, ~25 ms on a laptop; a game loading over several frames does it in a
## step of its own, see TerrainRuntime). Godot shares the shader of materials
## with the same features, so the next ones are free.
static func compile(material: Material) -> void:
	if material != null:
		material.get_rid()

## Shared material for untextured terrain faces: the style colour comes from
## the vertex colours, so every untextured style fits in one surface.
## The biome's Ground Material when one is set, else the built-in one.
static func terrain_vertex_color_material(terrain: Node3D) -> Material:
	var custom := TerrainBiome.of(terrain).ground_material
	if custom:
		return custom
	var cull := _cull_mode(terrain)
	var key := "vertex_color|%d" % cull
	var material: StandardMaterial3D = _terrain_material_cache.get(key, null)
	if material:
		return material

	material = StandardMaterial3D.new()
	material.resource_name = "Terrain Vertex Color"
	material.vertex_color_use_as_albedo = true
	# Style colours are picked in sRGB, like albedo_color.
	material.vertex_color_is_srgb = true
	material.roughness = 1.0
	_matte(material)
	material.cull_mode = cull
	_terrain_material_cache[key] = material
	return material

## Wind profile of a built-in detail mesh ("" = rigid: rocks, mounds, bones).
static func wind_profile(builtin_mesh: int) -> String:
	match builtin_mesh:
		DetailMeshes.GRASS_TUFT, DetailMeshes.DRY_GRASS_TUFT:
			return "grass"
		DetailMeshes.SHRUB:
			return "shrub"
		DetailMeshes.ACACIA, DetailMeshes.DEAD_TREE:
			return "tree"
		DetailMeshes.BAOBAB:
			return "baobab"
	return ""

## Changes the wind of every detail material, in the editor or in game:
## `direction` = where it blows to (world X / Z), `scale` multiplies every
## profile's sway (0 = calm, 2 = strong wind).
static func set_wind(direction: Vector2, scale: float = 1.0) -> void:
	_wind_direction = direction if direction.length_squared() > 0.0 else Vector2(1.0, 0.0)
	_wind_scale = maxf(scale, 0.0)
	for profile: String in WIND_PROFILES:
		var material: ShaderMaterial = _terrain_material_cache.get("detail|" + profile, null)
		if material:
			material.set_shader_parameter("wind_direction", _wind_direction)
			material.set_shader_parameter("wind_scale", _wind_scale)

## True for the built-in two-sided detail material (grass): built-in meshes
## drawn with it need their thin parts only once (DetailMeshes.builtin(i, true)).
static func is_two_sided_detail(material: Material) -> bool:
	var shader_material := material as ShaderMaterial
	return shader_material != null and shader_material.shader == DetailWindTwoSidedShader

## Shared material for scattered details (DetailScatter): colour = mesh
## vertex colour x MultiMesh instance colour. Back faces are culled (grass:
## two-sided, see is_two_sided_detail): thin built-in meshes carry both
## windings otherwise (see DetailMeshes).
## `wind_profile` (see WIND_PROFILES / wind_profile()) gives the same look
## with the vertices swaying in the wind (materials/detail_wind.gdshader).
static func detail_material(profile: String = "") -> Material:
	if WIND_PROFILES.has(profile):
		var wind_key := "detail|" + profile
		var wind: ShaderMaterial = _terrain_material_cache.get(wind_key, null)
		if wind:
			return wind
		wind = ShaderMaterial.new()
		wind.resource_name = "Terrain Detail Wind (%s)" % profile
		wind.shader = DetailWindTwoSidedShader if TWO_SIDED_PROFILES.has(profile) else DetailWindShader
		var values: Dictionary = WIND_PROFILES[profile]
		for parameter: String in values:
			wind.set_shader_parameter(parameter, values[parameter])
		wind.set_shader_parameter("wind_direction", _wind_direction)
		wind.set_shader_parameter("wind_scale", _wind_scale)
		_terrain_material_cache[wind_key] = wind
		return wind
	var key := "detail"
	var material: StandardMaterial3D = _terrain_material_cache.get(key, null)
	if material:
		return material

	material = StandardMaterial3D.new()
	material.resource_name = "Terrain Detail"
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 1.0
	_matte(material)
	material.cull_mode = BaseMaterial3D.CULL_BACK
	_terrain_material_cache[key] = material
	return material

## Material for the top (`top == true`) or side faces of a palette style.
## Shared between surfaces with the same texture/colour.
static func terrain_style_material(terrain: Node3D, style_id: int, top: bool) -> Material:
	var texture := terrain_style_texture(terrain, style_id, top)
	# A texture is treated as the complete albedo by default, so it is not
	# accidentally multiplied by the grass/brown fallback colour.
	var albedo: Color = Color.WHITE if texture else terrain_style_color(terrain, style_id, top)
	var cull := _cull_mode(terrain)
	var normal_map := terrain_style_surface(terrain, style_id, top, false) if texture else null
	var roughness_map := terrain_style_surface(terrain, style_id, top, true) if texture else null
	var key := "style|%s|%s|%s|%d|%s|%s" % [top, albedo.to_html(true), StylePalette.resource_identity(texture), cull,
		StylePalette.resource_identity(normal_map), StylePalette.resource_identity(roughness_map)]
	var material: StandardMaterial3D = _terrain_material_cache.get(key, null)
	if material:
		return material

	material = StandardMaterial3D.new()
	material.resource_name = "Terrain Top" if top else "Terrain Side"
	material.albedo_color = albedo
	material.albedo_texture = texture
	material.texture_repeat = true
	if not top:
		# Baked cliff shading (TerrainShading.cliff_colors: greys for textured
		# walls) multiplies the texture; walls without colours stay as is.
		material.vertex_color_use_as_albedo = true
		material.vertex_color_is_srgb = true
	material.roughness = 1.0
	_matte(material)
	if normal_map:
		# Needs the planar tangents (MeshUtils.planar_tangents).
		material.normal_enabled = true
		material.normal_texture = normal_map
	if roughness_map:
		material.roughness_texture = roughness_map
		material.roughness_texture_channel = BaseMaterial3D.TEXTURE_CHANNEL_RED
	if normal_map or roughness_map:
		material.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	material.cull_mode = cull
	_terrain_material_cache[key] = material
	return material

## True when the material of a textured style reads a normal map (its
## surface then needs real tangents).
static func needs_tangents(material: Material) -> bool:
	var standard := material as StandardMaterial3D
	return standard != null and standard.normal_enabled

## Style ids of the blended texture layers (layer i = entry i): the styles
## with a top texture, in palette order, MAX_SPLAT_LAYERS at most. Only reads
## the palette (safe on a thread snapshot).
static func splat_layers(terrain: Node3D) -> Array[int]:
	var layers: Array[int] = []
	var palette: Array = terrain.get_meta(Meta.STYLE_PALETTE, [])
	for style_id in palette.size():
		if layers.size() >= MAX_SPLAT_LAYERS:
			break
		if terrain_style_texture(terrain, style_id, true) != null:
			layers.append(style_id)
	return layers

## Indices (in splat_layers()) of the blended layers with a normal or
## roughness map, MAX_PBR_LAYERS at most: the blended surface uses the PBR
## variant of its shader when there is one. Same mesh either way.
static func splat_pbr_layers(terrain: Node3D) -> Array[int]:
	var result: Array[int] = []
	var layers := splat_layers(terrain)
	for i in layers.size():
		if result.size() >= MAX_PBR_LAYERS:
			break
		if terrain_style_surface(terrain, layers[i], true, false) != null or terrain_style_surface(terrain, layers[i], true, true) != null:
			result.append(i)
	return result

static func splat_pbr(terrain: Node3D) -> bool:
	return not splat_pbr_layers(terrain).is_empty()

## Material of the blended-texture surface of the chunks (TerrainShading
## weights): the top textures of splat_layers() and their tile sizes.
## Shared by every chunk with the same textures.
## A Ground Material (biome) whose shader declares `layer_0` is written for
## textures too: it also draws the blended surface, with the same uniforms
## and CUSTOM0 / CUSTOM1 weights (a copy, refreshed from it at each build).
static func terrain_splat_material(terrain: Node3D) -> Material:
	var layers := splat_layers(terrain)
	var pbr_layers := splat_pbr_layers(terrain)
	var pbr := not pbr_layers.is_empty()
	var cull := _cull_mode(terrain)
	var custom := _custom_splat_material(terrain)
	var key := "splat|%d|%s|%d" % [cull, pbr, custom.get_instance_id() if custom else 0]
	for style_id in layers:
		key += "|%s:%s" % [StylePalette.resource_identity(terrain_style_texture(terrain, style_id, true)),
			terrain_style_tile_size(terrain, style_id, true)]
		key += ":%s:%s" % [StylePalette.resource_identity(terrain_style_surface(terrain, style_id, true, false)),
			StylePalette.resource_identity(terrain_style_surface(terrain, style_id, true, true))]
	var material: ShaderMaterial = _terrain_material_cache.get(key, null)
	if material == null:
		material = ShaderMaterial.new()
		material.resource_name = "Terrain Blended Textures"
		_terrain_material_cache[key] = material
	if custom:
		_copy_material_values(custom, material)
	else:
		material.shader = _splat_shader(cull, pbr)
	var inv_tiles: Array[float] = []
	for i in MAX_SPLAT_LAYERS + 1:
		var tile := 4.0
		if i < layers.size():
			material.set_shader_parameter("layer_%d" % i, terrain_style_texture(terrain, layers[i], true))
			tile = terrain_style_tile_size(terrain, layers[i], true)
		inv_tiles.append(1.0 / maxf(tile, 0.001))
	material.set_shader_parameter("inv_tile_a", Vector4(inv_tiles[0], inv_tiles[1], inv_tiles[2], inv_tiles[3]))
	material.set_shader_parameter("inv_tile_b", Vector4(inv_tiles[4], inv_tiles[5], inv_tiles[6], inv_tiles[7]))
	if custom == null or _declares_uniform(custom.shader, "mean_color"):
		material.set_shader_parameter("mean_color", splat_means(terrain, layers))
	if pbr:
		var slots := Vector4i(-1, -1, -1, -1)
		for slot in pbr_layers.size():
			var style_id := layers[pbr_layers[slot]]
			slots[slot] = pbr_layers[slot]
			material.set_shader_parameter("normal_%d" % slot, terrain_style_surface(terrain, style_id, true, false))
			material.set_shader_parameter("rough_%d" % slot, terrain_style_surface(terrain, style_id, true, true))
		material.set_shader_parameter("pbr_layer", slots)
	return material

## Mean colour of each blended layer: linear rgb from the palette's
## "top_mean" (StylePalette.fill_texture_means), a = 1; a = 0 when unknown
## (the shader then reads it from the texture's last mip).
static func splat_means(terrain: Node3D, layers: Array[int]) -> PackedVector4Array:
	var means := PackedVector4Array()
	for i in MAX_SPLAT_LAYERS:
		var mean := Vector4.ZERO
		if i < layers.size():
			var srgb: Variant = _style(terrain, layers[i]).get("top_mean", null)
			if srgb is Color:
				var color: Color = srgb
				var linear := color.srgb_to_linear()
				mean = Vector4(linear.r, linear.g, linear.b, 1.0)
		means.append(mean)
	return means

static func _custom_splat_material(terrain: Node3D) -> ShaderMaterial:
	var custom := TerrainBiome.of(terrain).ground_material as ShaderMaterial
	if custom == null or custom.shader == null:
		return null
	return custom if _declares_uniform(custom.shader, "layer_0") else null

static func _declares_uniform(shader: Shader, uniform_name: String) -> bool:
	if shader == null:
		return false
	for uniform: Dictionary in shader.get_shader_uniform_list():
		if uniform["name"] == uniform_name:
			return true
	return false

## `target` takes the shader and every uniform value of `source`.
static func _copy_material_values(source: ShaderMaterial, target: ShaderMaterial) -> void:
	target.shader = source.shader
	target.render_priority = source.render_priority
	target.next_pass = source.next_pass
	for uniform: Dictionary in source.shader.get_shader_uniform_list():
		var uniform_name: String = uniform["name"]
		target.set_shader_parameter(uniform_name, source.get_shader_parameter(uniform_name))

## The blended-texture shader for a cull mode / PBR. On phones
## (`mobile`, default OS.has_feature("mobile")) its textures use trilinear
## filtering instead of anisotropic: cheaper on mobile GPUs, the ground is
## seen at grazing angles less sharply far away.
static func _splat_shader(cull: BaseMaterial3D.CullMode, pbr: bool = false, mobile: bool = OS.has_feature("mobile")) -> Shader:
	if cull == BaseMaterial3D.CULL_BACK and not pbr and not mobile:
		return TerrainSplatShader
	var key := "%d|%s|%s" % [cull, pbr, mobile]
	var shader: Shader = _splat_shaders.get(key, null)
	if shader == null:
		shader = Shader.new()
		var code := TerrainSplatShader.code.replace("cull_back", "cull_disabled") if cull != BaseMaterial3D.CULL_BACK else TerrainSplatShader.code
		if pbr:
			code = code.replace("shader_type spatial;", "shader_type spatial;\n#define USE_PBR")
		if mobile:
			code = code.replace("filter_linear_mipmap_anisotropic", "filter_linear_mipmap")
		shader.code = code
		_splat_shaders[key] = shader
	return shader

## Fully rough ground, roads and details: no specular term (invisible at
## roughness 1) and Lambert diffuse instead of Burley, the cheapest lighting
## per pixel for the same look (the ground covers most of the screen; GPUs
## of phones are bound by that per-pixel work).
static func _matte(material: StandardMaterial3D) -> void:
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	material.diffuse_mode = BaseMaterial3D.DIFFUSE_LAMBERT

static func terrain_style_tile_size(terrain: Node3D, style_id: int, top: bool) -> float:
	var palette: Array = terrain.get_meta(Meta.STYLE_PALETTE, [StylePalette.make_default_style()])
	if palette.is_empty():
		return Meta.DEFAULT_TILE_SIZE
	style_id = clamp(style_id, 0, palette.size() - 1)
	var raw_style: Dictionary = palette[style_id]
	var style: Dictionary = StylePalette.migrate_style_texture_fields(raw_style)
	var tile_size: float = style.get("top_tile_size" if top else "cliff_tile_size", Meta.DEFAULT_TILE_SIZE)
	return maxf(tile_size, 0.001)

## Material of a road. A road that follows the biome (FeatureStyle.
## follows_biome) gets the biome's Road Material, else the built-in one with
## its Road Color; an older road with its own look keeps it.
## Built-in ones are shared per look (colour, texture, cull mode), like the
## ground materials: a StandardMaterial3D's shader is freed with the last
## material using it, so a new material per rebuild would compile it again
## (~25 ms).
static func road_material(terrain: Node3D, feature_variant: Variant) -> Material:
	var feature := FeatureStyle.migrate(feature_variant, FeatureStyle.ROAD)
	if FeatureStyle.follows_biome(feature):
		var biome := TerrainBiome.of(terrain)
		if biome.road_material:
			return biome.road_material
		return built_in_road_material(biome.road_color, null, _cull_mode(terrain))
	var texture_object: Object = feature.get("texture", null)
	var texture := texture_object as Texture2D
	var color: Color = Color.WHITE if texture else feature.get("color", Meta.DEFAULT_ROAD_COLOR)
	return built_in_road_material(color, texture, _cull_mode(terrain))

## The built-in matte road material (shared per look). `uv_scale` repeats
## the texture (1 / tile size when the UV is in meters).
static func built_in_road_material(color: Color, texture: Texture2D, cull: BaseMaterial3D.CullMode = BaseMaterial3D.CULL_BACK, uv_scale: float = 1.0) -> StandardMaterial3D:
	var key := "road|%s|%d|%d|%.5f" % [color.to_html(), texture.get_instance_id() if texture else 0, cull, uv_scale]
	var material: StandardMaterial3D = _terrain_material_cache.get(key, null)
	if material:
		return material
	material = StandardMaterial3D.new()
	material.resource_name = "LowPoly Road"
	material.albedo_color = color
	material.albedo_texture = texture
	material.texture_repeat = true
	material.uv1_scale = Vector3(uv_scale, uv_scale, 1.0)
	material.roughness = 1.0
	_matte(material)
	material.cull_mode = cull
	_terrain_material_cache[key] = material
	return material

## A road material to edit (Customise Road): the built-in look, not shared.
static func editable_road_material(color: Color) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.resource_name = "Road"
	material.albedo_color = color
	material.texture_repeat = true
	# Road UVs are in meters: a texture repeats every 4 m (UV1 > Scale).
	material.uv1_scale = Vector3.ONE / Meta.DEFAULT_ROAD_TILE_SIZE
	material.roughness = 1.0
	_matte(material)
	return material

## A copy of the built-in water to edit (Customise Water): its shader and
## values, with an editable ripple texture (NoiseTexture2D).
static func editable_water_material(color: Color) -> ShaderMaterial:
	var material := built_in_water_material({"color": color})
	material.resource_name = "Water"
	material.shader = RiverWaterShader
	material.set_shader_parameter("refraction_strength", Meta.DEFAULT_RIVER_REFRACTION)
	material.set_shader_parameter("normal_texture", make_water_normal_texture())
	return material

## Seamless NoiseTexture2D + FastNoiseLite normal map, the same kind of resource
## a user would create by hand in the Inspector.
static func make_water_normal_texture() -> NoiseTexture2D:
	var texture := NoiseTexture2D.new()
	texture.width = WATER_NORMAL_SIZE
	texture.height = WATER_NORMAL_SIZE
	texture.seamless = true
	texture.as_normal_map = true
	texture.noise = make_water_noise()
	return texture

static func make_water_noise() -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.frequency = 0.035
	noise.fractal_octaves = 4
	return noise

## The wave normal map of rivers that have none: the image of
## make_water_normal_texture() (NoiseTexture2D defaults: seamless, normalized,
## bump strength 8, mipmaps), made at once in this call (~20 ms on a laptop).
## A NoiseTexture2D makes its image on a thread and the next frame waits for
## it; a game loading over several frames makes this one in a step of its own
## (TerrainBuilder.feature_material_warmups).
static func generated_water_normal() -> Texture2D:
	if not is_instance_valid(_generated_water_normal):
		var image := make_water_noise().get_seamless_image(WATER_NORMAL_SIZE, WATER_NORMAL_SIZE, false, false, 0.1, true)
		image.bump_map_to_normal_map(8.0)
		image.generate_mipmaps()
		_generated_water_normal = ImageTexture.create_from_image(image)
	return _generated_water_normal

## Phones always get the water without refraction: the refraction copies the
## whole screen (with mipmaps) every frame a river is seen, ~7-8 ms on a
## Mali-G57 phone (test_project/AUDIT_PERF_MOBILE.md).
static func phone_water() -> bool:
	return OS.has_feature("mobile")

## Water material of a river. A river that follows the biome gets the
## biome's Water Material, else the built-in water with its Water Color; an
## older river with its own look keeps it. `mobile_water` (terrain setting), a
## refraction of 0 or a phone selects the built-in shader without
## screen-texture refraction (also in a Water Material made from it).
static func river_material(terrain: Node3D, feature_variant: Variant, mobile_water: bool = false) -> Material:
	var feature := FeatureStyle.migrate(feature_variant, FeatureStyle.RIVER)
	if FeatureStyle.follows_biome(feature):
		var biome := TerrainBiome.of(terrain)
		if biome.water_material:
			return _without_refraction(biome.water_material) if mobile_water or phone_water() or _refraction_off(biome.water_material) else biome.water_material
		return built_in_water_material({"color": biome.water_color}, mobile_water)
	return built_in_water_material(feature, mobile_water)

## True for the built-in water shader with Refraction Strength 0: the
## shader without refraction looks the same and skips the screen copy.
static func _refraction_off(material: Material) -> bool:
	var shader_material := material as ShaderMaterial
	if shader_material == null or shader_material.shader != RiverWaterShader:
		return false
	var strength: Variant = shader_material.get_shader_parameter("refraction_strength")
	return (strength is float or strength is int) and float(str(strength)) <= 0.0

## A Water Material made from the built-in water shader, switched to the
## shader without refraction (a copy, so it always has the current values;
## the shader itself is shared).
static func _without_refraction(material: Material) -> Material:
	var shader_material := material as ShaderMaterial
	if shader_material == null or shader_material.shader != RiverWaterShader:
		return material
	# One copy per Water Material (one draw state for every river), its
	# values copied again at each build.
	var copy: ShaderMaterial = _no_refraction_copies.get(shader_material.get_instance_id(), null)
	if copy == null:
		copy = ShaderMaterial.new()
		copy.resource_name = shader_material.resource_name
		copy.shader = RiverWaterMobileShader
		_no_refraction_copies[shader_material.get_instance_id()] = copy
	copy.render_priority = shader_material.render_priority
	copy.next_pass = shader_material.next_pass
	for uniform: Dictionary in RiverWaterMobileShader.get_shader_uniform_list():
		var uniform_name: String = uniform["name"]
		copy.set_shader_parameter(uniform_name, shader_material.get_shader_parameter(uniform_name))
	return copy

## The built-in water: `look` holds the river look fields (FeatureStyle.
## RIVER_LOOK_FIELDS); missing ones take their defaults.
static func built_in_water_material(look: Dictionary, mobile_water: bool = false) -> ShaderMaterial:
	var feature := look
	var material := ShaderMaterial.new()
	material.resource_name = "LowPoly River Water"
	var raw_refraction: float = feature.get("refraction", Meta.DEFAULT_RIVER_REFRACTION)
	var refraction: float = maxf(raw_refraction, 0.0)
	material.shader = RiverWaterMobileShader if mobile_water or refraction <= 0.0 or phone_water() else RiverWaterShader
	var color: Color = feature.get("color", Meta.DEFAULT_RIVER_COLOR)
	var texture_object: Object = feature.get("texture", null)
	var texture := texture_object as Texture2D
	var normal_texture_object: Object = feature.get("normal_texture", null)
	var normal_texture := normal_texture_object as Texture2D
	if normal_texture == null:
		normal_texture = generated_water_normal()
	var raw_tile_size: float = feature.get("tile_size", Meta.DEFAULT_RIVER_TILE_SIZE)
	var tile_size: float = maxf(raw_tile_size, 0.001)
	material.set_shader_parameter("water_color", color)
	material.set_shader_parameter("use_albedo_texture", texture != null)
	if texture != null:
		material.set_shader_parameter("albedo_texture", texture)
	material.set_shader_parameter("use_normal_texture", normal_texture != null)
	if normal_texture != null:
		material.set_shader_parameter("normal_texture", normal_texture)
	material.set_shader_parameter("tile_scale", 1.0 / tile_size)
	var flow_speed: float = feature.get("flow_speed", Meta.DEFAULT_RIVER_FLOW_SPEED)
	material.set_shader_parameter("flow_speed", flow_speed)
	var flow_angle: float = feature.get("flow_angle", Meta.DEFAULT_RIVER_FLOW_ANGLE)
	var flow_angle_radians := deg_to_rad(flow_angle)
	material.set_shader_parameter("flow_direction", Vector2(cos(flow_angle_radians), sin(flow_angle_radians)))
	var roughness: float = feature.get("roughness", Meta.DEFAULT_RIVER_ROUGHNESS)
	material.set_shader_parameter("roughness_value", clampf(roughness, 0.0, 1.0))
	var normal_strength: float = feature.get("normal_strength", Meta.DEFAULT_RIVER_NORMAL_STRENGTH)
	material.set_shader_parameter("normal_strength", maxf(normal_strength, 0.0))
	if material.shader == RiverWaterShader:
		material.set_shader_parameter("refraction_strength", refraction)
	return material
