extends SceneTree
## Blended ground textures (terrain_splat.gdshader) look the same after a
## shader optimisation: renders a generated savanna map whose three most used
## styles get real photo textures (Poly Haven), from close (textures sharp)
## and from high up (textures faded into their mean colour), with and without
## normal / roughness maps (USE_PBR), and compares each image with the
## reference saved before the change. Details and water are hidden (they move
## with the wind / time).
## Needs a window (renders), off screen:
##   godot --path . --position -3000,-3000 --resolution 960x540 --script res://tools/check_splat_reads.gd [-- --save-ref]
## --save-ref writes results/splat_reads/ref_<view>.png; otherwise each view
## must stay within 1/255 mean difference of it (3/255 for the phone variant,
## trilinear filtering). Exit code 1 if not.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const MaterialFactory = preload(ADDON + "materials/material_factory.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const DIR := "res://results/splat_reads/"
const TEXTURES := ["dry_ground_rocks", "cracked_red_ground", "gravelly_sand"]
## Camera position, target.
const VIEWS := {
	"near": [Vector3(-8, 6, -8), Vector3(30, 0, 30)],
	"far": [Vector3(-40, 120, -40), Vector3(40, 0, 40)],
}

var _failures := 0

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		print("SKIP check_splat_reads: needs a window (renders)")
		quit(0)
		return
	var save_ref := OS.get_cmdline_user_args().has("--save-ref")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var root := Node3D.new()
	root.name = "Root"
	get_root().add_child(root)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = Vector3(-40, 50, 0)
	root.add_child(sun)
	var world := WorldEnvironment.new()
	world.name = "World"
	var environment := Environment.new()
	environment.background_mode = Environment.BG_COLOR
	environment.background_color = Color(0.5, 0.6, 0.75)
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.ambient_light_color = Color(0.6, 0.6, 0.65)
	world.environment = environment
	root.add_child(world)
	var camera := Camera3D.new()
	camera.name = "Camera"
	camera.far = 600.0
	root.add_child(camera)
	camera.current = true

	var t := TestTerrain.savanna(root)
	var biome: TerrainBiome = TerrainBiome.of(t).duplicate(true)
	biome.detail_layers = []
	var used := {}
	for style: Dictionary in t.get_meta(Meta.STYLE_PALETTE):
		if style.has("biome_style"):
			used[style["biome_style"]] = true
	var textured: Array[TerrainBiome.GroundStyle] = []
	for ground: TerrainBiome.GroundStyle in biome.ground_styles:
		if ground != null and used.has(String(ground.name)) and textured.size() < TEXTURES.size():
			textured.append(ground)
	for i in textured.size():
		# With mipmaps (the imported JPGs have none until a 3D material uses
		# them in the editor): the old shader read its mean from the last mip.
		var image := Image.load_from_file(ProjectSettings.globalize_path("res://assets/textures/polyhaven/%s.jpg" % TEXTURES[i]))
		image.generate_mipmaps()
		textured[i].top_texture = ImageTexture.create_from_image(image)
		textured[i].top_tile_size = 3.0
	t.set_meta(Meta.BIOME, biome)
	var builder := TerrainBuilder.new()
	builder.rebuild_all(t)
	await _views(root, camera, t, "albedo", save_ref)

	# PBR variant: a normal map (from the texture's relief) and a roughness map.
	var photo: Image = (textured[0].top_texture as Texture2D).get_image().duplicate()
	if photo.is_compressed():
		photo.decompress()
	photo.clear_mipmaps()
	photo.resize(256, 256)
	var rough_image: Image = photo.duplicate()
	photo.bump_map_to_normal_map(6.0)
	photo.generate_mipmaps()
	rough_image.convert(Image.FORMAT_L8)
	rough_image.generate_mipmaps()
	textured[0].top_normal = ImageTexture.create_from_image(photo)
	textured[0].top_roughness = ImageTexture.create_from_image(rough_image)
	builder.rebuild_all(t)
	await _views(root, camera, t, "pbr", save_ref)

	# Phone variant: trilinear filtering, same picture but slightly blurrier
	# far away (compared with the albedo references, looser).
	textured[0].top_normal = null
	textured[0].top_roughness = null
	builder.rebuild_all(t)
	var mobile := MaterialFactory._splat_shader(BaseMaterial3D.CULL_BACK, false, true)
	var swapped := 0
	for chunk: Node in t.get_node(Meta.GENERATED_CHUNKS_NAME).get_children():
		var mesh := (chunk as MeshInstance3D).mesh as ArrayMesh if chunk is MeshInstance3D else null
		for s in mesh.get_surface_count() if mesh else 0:
			var material := mesh.surface_get_material(s) as ShaderMaterial
			if material and material.shader == MaterialFactory.TerrainSplatShader:
				material.shader = mobile
				swapped += 1
	var ok := swapped > 0 and not mobile.code.contains("anisotropic")
	if not ok:
		_failures += 1
	print("%s  phone variant: trilinear filtering, %d surfaces" % ["OK  " if ok else "FAIL", swapped])
	if not save_ref:
		await _views(root, camera, t, "albedo", false, 3.0)
	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)

## Hides everything that moves (water, details) and renders each view.
func _views(root: Node3D, camera: Camera3D, t: Node3D, label: String, save_ref: bool, limit: float = 1.0) -> void:
	for child: Node in t.get_children():
		if child is Node3D and child.name != Meta.GENERATED_CHUNKS_NAME:
			(child as Node3D).visible = false
	for chunk: Node in t.get_node(Meta.GENERATED_CHUNKS_NAME).get_children():
		for detail: Node in chunk.get_children():
			if detail is Node3D:
				(detail as Node3D).visible = false
	for view: String in VIEWS:
		var spot: Array = VIEWS[view]
		camera.look_at_from_position(spot[0], spot[1])
		for i in 12:
			await process_frame
		var image := get_root().get_texture().get_image()
		image.convert(Image.FORMAT_RGB8)
		var name := "%s_%s" % [label, view]
		var reference_path := DIR + "ref_%s.png" % name
		image.save_png(DIR + "now_%s.png" % name)
		if save_ref:
			image.save_png(reference_path)
			print("saved ", reference_path)
			continue
		var reference := Image.load_from_file(ProjectSettings.globalize_path(reference_path))
		if reference == null or reference.get_size() != image.get_size():
			_failures += 1
			print("FAIL %s: no reference of the same size (run with -- --save-ref first)" % name)
			continue
		reference.convert(Image.FORMAT_RGB8)
		var a := image.get_data()
		var b := reference.get_data()
		var total := 0
		var big := 0
		var worst := 0
		for i in a.size():
			var d := absi(a[i] - b[i])
			total += d
			worst = maxi(worst, d)
			if d > 8:
				big += 1
		var mean := float(total) / a.size()
		var ok := mean < limit
		if not ok:
			_failures += 1
		print("%s  %s: mean diff %.3f / 255, max %d, %.2f %% of values > 8" % ["OK  " if ok else "FAIL", name, mean, worst, 100.0 * big / a.size()])
