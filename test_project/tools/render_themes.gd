extends SceneTree
## Same savanna map, three themes made only in its biome: textures alone,
## textures + normal / roughness maps (Surface), toon (Ground / Detail
## Material). Saves results/themes_sheet.png. Needs a window:
##   godot --path . --position -3000,-3000 --resolution 960x540 --script res://tools/render_themes.gd
## The normal / roughness maps are derived from the Poly Haven albedos
## (brightness = height), for the demo only.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const TEX := "res://assets/textures/polyhaven/%s.jpg"
## Biome style -> texture.
const TEXTURES := {
	"Dry Grass": "dry_ground_01",
	"Laterite": "cracked_red_ground",
	"Green Savanna": "grass_path_2",
	"Sand": "gravelly_sand",
	"Dry Clay": "mud_cracked_dry_03",
	"Burnt Ground": "brown_mud_dry",
}

func _maps(texture: Texture2D) -> Array[Texture2D]:
	var image := texture.get_image()
	if image.is_compressed():
		image.decompress()
	image.clear_mipmaps()
	image.convert(Image.FORMAT_RGBA8)
	image.resize(512, 512, Image.INTERPOLATE_LANCZOS)
	var normal := image.duplicate() as Image
	normal.bump_map_to_normal_map(6.0)
	normal.generate_mipmaps()
	var rough := image.duplicate() as Image
	rough.convert(Image.FORMAT_L8)
	# Bright grains a little shinier than the dark gaps.
	for y in rough.get_height():
		for x in rough.get_width():
			var v := rough.get_pixel(x, y).r
			rough.set_pixel(x, y, Color(0.95 - v * 0.35, 0, 0))
	rough.generate_mipmaps()
	return [ImageTexture.create_from_image(normal), ImageTexture.create_from_image(rough)]

func _initialize() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	root.add_child((load("res://world/savanna_sky.tscn") as PackedScene).instantiate())
	var t := TestTerrain.savanna(root)
	var builder := TerrainBuilder.new()
	var base: TerrainBiome = TerrainBiome.of(t)
	var camera := Camera3D.new()
	camera.name = "ThemeCamera"
	camera.fov = 60.0
	root.add_child(camera)
	camera.look_at_from_position(Vector3(-6, 5.5, 18), Vector3(6, 1.5, -4))
	camera.current = true

	var textured: TerrainBiome = base.duplicate(true)
	var surface: TerrainBiome = base.duplicate(true)
	for i in textured.ground_styles.size():
		var style: TerrainBiome.GroundStyle = textured.ground_styles[i]
		var file: String = TEXTURES.get(String(style.name), "")
		if file.is_empty():
			continue
		var albedo: Texture2D = load(TEX % file)
		style.top_texture = albedo
		style.top_tile_size = 3.0
		var pbr: TerrainBiome.GroundStyle = surface.ground_styles[i]
		pbr.top_texture = albedo
		pbr.top_tile_size = 3.0
		var maps := _maps(albedo)
		pbr.top_normal = maps[0]
		pbr.top_roughness = maps[1]
	var toon: TerrainBiome = base.duplicate(true)
	toon.ground_material = load("res://world/looks/ground_toon.tres")
	toon.detail_material = load("res://world/looks/detail_toon.tres")

	var shots: Array[Image] = []
	for biome: TerrainBiome in [textured, surface, toon]:
		t.set_meta(Meta.BIOME, biome)
		builder.rebuild_all(t)
		for i in 30:
			await process_frame
		shots.append(get_root().get_texture().get_image())
	var w := shots[0].get_width()
	var h := shots[0].get_height()
	var sheet := Image.create(w * shots.size(), h, false, shots[0].get_format())
	for i in shots.size():
		sheet.blit_rect(shots[i], Rect2i(0, 0, w, h), Vector2i(i * w, 0))
	sheet.save_png("res://results/themes_sheet.png")
	print("saved ", ProjectSettings.globalize_path("res://results/themes_sheet.png"))
	quit()
