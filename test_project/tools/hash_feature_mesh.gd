extends SceneTree
## Prints a hash of every surface of the road / river mesh (vertices, normals,
## UVs, collision faces) built by FeatureMesher.build on the audit's savanna map
## (+ one river), on the generated island and on scenes/savanna_128.tscn.
## Run before and after a mesher change: same hashes = identical output.
##   godot --headless --path . --script res://tools/hash_feature_mesh.gd
## `-- --sliced` builds it in 2 ms slices (FeatureMesher.start / step / finish,
## as TerrainRuntime loads it): the hashes must not change. `-- --threaded`:
## each group on a worker thread (FeatureMesher.start_threaded, as
## TerrainRuntime loads a big map), same hashes. `--open-world` adds the
## open-world preset (seed 7).

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const FeatureMesher = preload(ADDON + "mesh/feature_mesher.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"
const OPEN_WORLD := ADDON + "generation/presets/senegal_savanna_open_world_map.tres"

func _initialize() -> void:
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
	_print("island", TestTerrain.island(holder))
	var scene := TestTerrain.load_scene(TestTerrain.SAVED_SCENE)
	_print("savanna_128.tscn", scene.get_node("LowpolyTerrain"))
	scene.free()
	if OS.get_cmdline_user_args().has("--open-world"):
		var world := Node3D.new()
		holder.add_child(world)
		TerrainData.initialize(world)
		MapGenerator.generate(world, load(OPEN_WORLD), 7)
		_print("open world", world)
	quit()

func _print(label: String, terrain: Node3D) -> void:
	var t0 := Time.get_ticks_usec()
	var result: Dictionary
	var slices := 1
	var slowest := 0.0
	if OS.get_cmdline_user_args().has("--threaded"):
		var threaded := FeatureMesher.start_threaded(terrain, RiverMesher.compute_carve(terrain))
		slices = 0
		while not FeatureMesher.step(threaded, 2000):
			slices += 1
		result = FeatureMesher.finish(threaded)
		label += " [threaded, %d polls]" % slices
	elif OS.get_cmdline_user_args().has("--sliced"):
		# As TerrainRuntime loads it: 2 ms slices.
		var job := FeatureMesher.start(terrain, RiverMesher.compute_carve(terrain))
		slices = 0
		while true:
			var s0 := Time.get_ticks_usec()
			var done := FeatureMesher.step(job, 2000)
			slowest = maxf(slowest, (Time.get_ticks_usec() - s0) / 1000.0)
			slices += 1
			if done:
				break
		result = FeatureMesher.finish(job)
		label += " [%d slices, slowest %.1f ms]" % [slices, slowest]
	else:
		result = FeatureMesher.build(terrain, RiverMesher.compute_carve(terrain))
	var ms := (Time.get_ticks_usec() - t0) / 1000.0
	var mesh: ArrayMesh = result["mesh"]
	var parts: Array[String] = []
	for s in mesh.get_surface_count():
		var arrays := mesh.surface_get_arrays(s)
		parts.append("%d:%d v %x n %x uv %x mat %s" % [s, (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size(),
			hash(arrays[Mesh.ARRAY_VERTEX]), hash(arrays[Mesh.ARRAY_NORMAL]), hash(arrays[Mesh.ARRAY_TEX_UV]),
			mesh.surface_get_material(s).resource_name])
	print("%s (%.0f ms): %s | collision %d %x" % [label, ms, ", ".join(parts), (result["collision_faces"] as PackedVector3Array).size(), hash(result["collision_faces"])])
