extends SceneTree
## Does the ground poke through the roads? Builds the road mesh of the audit's
## savanna map, of the generated island and of a steep test hill, and compares
## points of every road triangle (corners, edge middles, inside points) with
## the drawn ground under them (TerrainSampler.surface_height_in + the top
## offset). Prints the smallest and largest gap road - ground; a negative gap
## is ground showing through the road.
##   godot --headless --path . --script res://tools/check_road_fit.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainSampler = preload(ADDON + "core/terrain_sampler.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const FeatureMesher = preload(ADDON + "mesh/feature_mesher.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"
## Barycentric points tested in each triangle.
const SAMPLES: Array[Vector3] = [
	Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(0, 0, 1),
	Vector3(0.5, 0.5, 0), Vector3(0, 0.5, 0.5), Vector3(0.5, 0, 0.5),
	Vector3(0.334, 0.333, 0.333), Vector3(0.7, 0.15, 0.15), Vector3(0.15, 0.7, 0.15), Vector3(0.15, 0.15, 0.7),
]

var _failed := false

func _initialize() -> void:
	var holder := Node3D.new()
	get_root().add_child(holder)
	var terrain := Node3D.new()
	holder.add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(RECIPE), 7)
	_check("audit savanna", terrain)
	_check("island", TestTerrain.island(holder))
	_check("steep hill", _steep_hill(holder))
	print("CHECK %s: no ground through the roads" % ("FAIL" if _failed else "PASS"))
	holder.free()
	quit(1 if _failed else 0)

## A 64 m flat map with a 9 m cone hill and a road straight over its top,
## another along its side.
func _steep_hill(holder: Node3D) -> Node3D:
	var terrain := Node3D.new()
	holder.add_child(terrain)
	TerrainData.initialize(terrain)
	var resolution: int = int(terrain.get_meta(Meta.RESOLUTION))
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	for z in resolution:
		for x in resolution:
			var p := Vector2(float(x), float(z)) / float(resolution - 1) * size - Vector2.ONE * size * 0.5
			# Bumpy cone: steep sides and a few folds across the road.
			heights[z * resolution + x] = maxf(0.0, 9.0 - p.length() * 0.6) + sin(p.x * 1.3) * 0.4 + cos(p.y * 0.9) * 0.3
	terrain.set_meta(Meta.HEIGHTS, heights)
	var over: Array[Vector2] = [Vector2(-size * 0.4, -size * 0.05), Vector2(0.0, 0.3), Vector2(size * 0.4, size * 0.07)]
	var side: Array[Vector2] = [Vector2(-size * 0.3, size * 0.25), Vector2(0.0, size * 0.12), Vector2(size * 0.3, size * 0.27)]
	FeatureStyle.commit(terrain, FeatureStyle.ROAD, over)
	FeatureStyle.commit(terrain, FeatureStyle.ROAD, side)
	return terrain

func _check(label: String, terrain: Node3D) -> void:
	var carve := RiverMesher.compute_carve(terrain)
	var result := FeatureMesher.build(terrain, carve)
	var mesh: ArrayMesh = result["mesh"]
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var resolution: int = int(terrain.get_meta(Meta.RESOLUTION))
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var top: float = float(terrain.get_meta(Meta.TOP_Y_OFFSET, 0.0))
	var lowest := INF
	var highest := -INF
	var below := 0
	var tested := 0
	var triangles := 0
	for s in mesh.get_surface_count():
		if not mesh.surface_get_material(s).resource_name.contains("Road"):
			continue
		var v: PackedVector3Array = mesh.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
		triangles += v.size() / 3
		for i in range(0, v.size(), 3):
			for w in SAMPLES:
				var p: Vector3 = v[i] * w.x + v[i + 1] * w.y + v[i + 2] * w.z
				var gap := p.y - (TerrainSampler.surface_height_in(heights, carve, resolution, size, Vector2(p.x, p.z)) + top)
				lowest = minf(lowest, gap)
				highest = maxf(highest, gap)
				tested += 1
				if gap < 0.0:
					below += 1
	if triangles == 0:
		print("%s: no road" % label)
		return
	print("%s: %d road triangles, gap road - ground %.3f .. %.3f m, %d of %d points under the ground" % [label, triangles, lowest, highest, below, tested])
	if below > 0:
		_failed = true
