extends SceneTree
## Before / after board of the steep-slope projection (terrain_splat.gdshader):
## a savanna map with a steep cone (~60 degrees) painted with a photo-textured
## ground style, seen from the side and from above.
##   godot --path . --position -3000,-3000 --resolution 960x540 --script res://tools/render_steep_slopes.gd -- <label> [shader file]
## Writes results/steep_slopes/<label>_<view>.png. With a shader file (an
## older terrain_splat.gdshader), the ground uses it instead. When both
## "before" and "after" exist, also writes board_<view>.png (side by side).

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const MaterialFactory = preload(ADDON + "materials/material_factory.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const DIR := "res://results/steep_slopes/"
const CONE := Vector2(20.0, 20.0)
const CONE_RADIUS := 11.0
const CONE_HEIGHT := 18.0
## Camera position, target (local metres around the cone).
const VIEWS := {
	"side": [Vector3(20, 9, -4), Vector3(20, 7, 20)],
	"above": [Vector3(4, 26, 4), Vector3(20, 4, 20)],
}

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var args := OS.get_cmdline_user_args()
	var label := args[0] if args.size() > 0 else "after"
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
	root.add_child(camera)
	camera.current = true

	var t := TestTerrain.savanna(root)
	var biome: TerrainBiome = TerrainBiome.of(t).duplicate(true)
	biome.detail_layers = []
	var palette: Array = t.get_meta(Meta.STYLE_PALETTE)
	var ground: TerrainBiome.GroundStyle = null
	var style_index := -1
	for i in palette.size():
		var style: Dictionary = palette[i]
		for candidate: TerrainBiome.GroundStyle in biome.ground_styles:
			if ground == null and candidate != null and String(candidate.name) == str(style.get("biome_style", "")):
				ground = candidate
				style_index = i
	var image := Image.load_from_file(ProjectSettings.globalize_path("res://assets/textures/polyhaven/dry_ground_rocks.jpg"))
	image.generate_mipmaps()
	ground.top_texture = ImageTexture.create_from_image(image)
	ground.top_tile_size = 3.0
	t.set_meta(Meta.BIOME, biome)

	# The cone, painted with the textured style.
	var resolution: int = t.get_meta(Meta.RESOLUTION)
	var cell := float(t.get_meta(Meta.WORLD_SIZE)) / float(resolution - 1)
	var half := float(t.get_meta(Meta.WORLD_SIZE)) * 0.5
	var heights: PackedFloat32Array = t.get_meta(Meta.HEIGHTS)
	for z in resolution:
		for x in resolution:
			var d := Vector2(x * cell - half, z * cell - half).distance_to(CONE)
			if d < CONE_RADIUS:
				heights[z * resolution + x] = maxf(heights[z * resolution + x], CONE_HEIGHT * (1.0 - d / CONE_RADIUS))
	t.set_meta(Meta.HEIGHTS, heights)
	var styles: Variant = t.get_meta(Meta.CELL_STYLES)
	var cells := resolution - 1
	for z in cells:
		for x in cells:
			if Vector2((x + 0.5) * cell - half, (z + 0.5) * cell - half).distance_to(CONE) < CONE_RADIUS + 3.0:
				styles[z * cells + x] = style_index
	t.set_meta(Meta.CELL_STYLES, styles)
	TerrainBuilder.new().rebuild_all(t)

	var swapped := 0
	if args.size() > 1:
		var shader := Shader.new()
		shader.code = FileAccess.get_file_as_string(args[1])
		for chunk: Node in t.get_node(Meta.GENERATED_CHUNKS_NAME).get_children():
			var mesh := (chunk as MeshInstance3D).mesh as ArrayMesh if chunk is MeshInstance3D else null
			for s in mesh.get_surface_count() if mesh else 0:
				var material := mesh.surface_get_material(s) as ShaderMaterial
				if material and material.shader == MaterialFactory.TerrainSplatShader:
					material.shader = shader
					swapped += 1
	print("%s: style %d textured, %d surfaces on %s" % [label, style_index, swapped, args[1] if args.size() > 1 else "the current shader"])
	for child: Node in t.get_children():
		if child is Node3D and child.name != Meta.GENERATED_CHUNKS_NAME:
			(child as Node3D).visible = false
	for view: String in VIEWS:
		var spot: Array = VIEWS[view]
		camera.look_at_from_position(spot[0], spot[1])
		for i in 12:
			await process_frame
		var shot := get_root().get_texture().get_image()
		shot.convert(Image.FORMAT_RGB8)
		shot.save_png(DIR + "%s_%s.png" % [label, view])
		var before := Image.load_from_file(ProjectSettings.globalize_path(DIR + "before_%s.png" % view)) if FileAccess.file_exists(DIR + "before_%s.png" % view) else null
		var after := Image.load_from_file(ProjectSettings.globalize_path(DIR + "after_%s.png" % view)) if FileAccess.file_exists(DIR + "after_%s.png" % view) else null
		if before and after and before.get_size() == after.get_size():
			before.convert(Image.FORMAT_RGB8)
			after.convert(Image.FORMAT_RGB8)
			var board := Image.create(before.get_width() * 2 + 8, before.get_height(), false, Image.FORMAT_RGB8)
			board.fill(Color.WHITE)
			board.blit_rect(before, Rect2i(Vector2i.ZERO, before.get_size()), Vector2i.ZERO)
			board.blit_rect(after, Rect2i(Vector2i.ZERO, after.get_size()), Vector2i(before.get_width() + 8, 0))
			board.save_png(DIR + "board_%s.png" % view)
			print("board ", DIR + "board_%s.png" % view)
	quit(0)
