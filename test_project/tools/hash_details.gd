extends SceneTree
## Prints a hash of every chunk's detail buffers (DetailScatter.build) on the
## audit's savanna map (+ one river, waterholes, one painted forest), on the
## generated island and on scenes/savanna_128.tscn. Run before and after a
## scatter change: same hashes = identical placement.
##   godot --headless --path . --script res://tools/hash_details.gd [-- --sliced]
## --sliced scatters in tiny slices (DetailScatter.build_begin / build_step /
## build_result, as TerrainRuntime loads it): the hashes must not change.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

var _sliced := false

func _initialize() -> void:
	_sliced = OS.get_cmdline_user_args().has("--sliced")
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
	_print("audit savanna", terrain)
	# A painted acacia forest (sparse layer blocks, spacing rule).
	var cells: int = int(terrain.get_meta(Meta.RESOLUTION)) - 1
	var paint := Meta.vegetation_paint(terrain).duplicate()
	var forest := PackedByteArray()
	forest.resize(cells * cells)
	forest.fill(Meta.VEGETATION_NORMAL)
	for z in range(cells / 2 - 12, cells / 2 + 12):
		for x in range(cells / 2 - 12, cells / 2 + 12):
			forest[z * cells + x] = 255
	paint["Acacias"] = forest
	terrain.set_meta(Meta.CELL_VEGETATION, paint)
	_print("painted forest", terrain)
	_print("island", TestTerrain.island(holder))
	var scene := TestTerrain.load_scene(TestTerrain.SAVED_SCENE)
	_print("savanna_128.tscn", scene.get_node("LowpolyTerrain"))
	scene.free()
	holder.free()
	quit()

func _print(label: String, terrain: Node3D) -> void:
	var builder := TerrainBuilder.new()
	builder.rebuild_river_carve(terrain)
	var carve := builder.get_river_carve(terrain)
	var cells: int = int(terrain.get_meta(Meta.RESOLUTION)) - 1
	var chunks := ceili(float(cells) / float(Meta.TERRAIN_CHUNK_CELLS))
	var combined := PackedInt64Array()
	var instances := 0
	var slices := 0
	var t0 := Time.get_ticks_usec()
	for cz in chunks:
		for cx in chunks:
			var shading := builder.chunk_shading(terrain, cx, cz)
			var entries: Array
			if _sliced:
				# Called by name: the tool also runs on the code before slicing.
				var scatter: Script = DetailScatter
				var job: Dictionary = scatter.call("build_begin", terrain, carve, cx, cz, shading)
				while not scatter.call("build_step", job, 1):
					slices += 1
				slices += 1
				entries = scatter.call("build_result", job)
			else:
				entries = DetailScatter.build(terrain, carve, cx, cz, shading)
			for entry in entries:
				instances += int(entry[1])
				combined.append(hash([entry[0], entry[1], entry[2]]))
	print("%s: %d instances, hash %x (%.0f ms%s)" % [label, instances, hash(combined), (Time.get_ticks_usec() - t0) / 1000.0, ", %d slices" % slices if _sliced else ""])
