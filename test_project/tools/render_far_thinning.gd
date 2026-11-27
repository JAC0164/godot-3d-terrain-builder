extends SceneTree
## Before / after board of the far vegetation thinning (DetailScatter
## THIN_FROM): the savanna map from a low camera, every layer drawn to its
## full distance ("before": the far halves removed, the full sets drawn to the
## end) then as built ("after").
##   godot --path . --position -3000,-3000 --resolution 960x540 --script res://tools/render_far_thinning.gd
## Writes results/far_thinning/{before,after,board}.png.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const DIR := "res://results/far_thinning/"

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
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
	TerrainBuilder.new().rebuild_all(t)
	camera.look_at_from_position(Vector3(-50, 3.5, -50), Vector3(40, 0, 40))

	var shots: Array[Image] = []
	for label: String in ["after", "before"]:
		if label == "before":
			for chunk: Node in t.get_node(Meta.GENERATED_CHUNKS_NAME).get_children():
				for child: Node in chunk.get_children():
					var far := child.get_node_or_null(DetailScatter.FAR_NAME) as MultiMeshInstance3D
					if far != null:
						(child as MultiMeshInstance3D).visibility_range_end = far.visibility_range_end
						far.visible = false
		for i in 20:
			await process_frame
		var shot := get_root().get_texture().get_image()
		shot.convert(Image.FORMAT_RGB8)
		shot.save_png(DIR + "%s.png" % label)
		shots.append(shot)
	var before := shots[1]
	var after := shots[0]
	var board := Image.create(before.get_width() * 2 + 8, before.get_height(), false, Image.FORMAT_RGB8)
	board.fill(Color.WHITE)
	board.blit_rect(before, Rect2i(Vector2i.ZERO, before.get_size()), Vector2i.ZERO)
	board.blit_rect(after, Rect2i(Vector2i.ZERO, after.get_size()), Vector2i(before.get_width() + 8, 0))
	board.save_png(DIR + "board.png")
	print("board ", DIR + "board.png")
	quit(0)
