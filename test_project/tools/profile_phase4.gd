extends SceneTree
## Measures the Phase 4 candidates of results/refactor/AUDIT_CODE.md before
## touching them, on the savanna (seed 7 + a river) and scenes/savanna_128:
##   1. river water levels: time of RiverMesher.water_levels per rebuild;
##   2. ground shadow casters: MeshUtils.back_face_caster, split into the
##      vertex read-back (surface_get_arrays) and the rest;
##   3. whole rebuild_all for scale.
##   godot --headless --path . --script res://tools/profile_phase4.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const MeshUtils = preload(ADDON + "mesh/mesh_utils.gd")
const SurfaceRay = preload(ADDON + "editing/surface_ray.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

var _started := false

# Runs on the first frame, not in _initialize(): the terrain must be inside
# the tree (SurfaceRay reads its global transform; outside the tree every call
# prints an error, which alone costs ~40 ms).
func _process(_delta: float) -> bool:
	if not _started:
		_started = true
		_run()
	return true

func _run() -> void:
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
	_profile("savanna", terrain)
	var scene := TestTerrain.load_scene("res://scenes/savanna_128.tscn")
	holder.add_child(scene)
	_profile("savanna_128", scene.get_node("LowpolyTerrain"))
	holder.queue_free()
	quit()

func _profile(label: String, terrain: Node3D) -> void:
	var builder := TerrainBuilder.new()
	var t := Time.get_ticks_usec()
	builder.rebuild_all(terrain)
	builder.flush_deferred()
	var build_ms := (Time.get_ticks_usec() - t) / 1000.0

	# 1. Water levels: what a second computation per rebuild costs.
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var resolution := int(terrain.get_meta(Meta.RESOLUTION))
	var world_size := float(terrain.get_meta(Meta.WORLD_SIZE))
	var rivers: Array = terrain.get_meta(Meta.RIVERS, [])
	t = Time.get_ticks_usec()
	for river in rivers:
		RiverMesher.water_levels(heights, resolution, world_size, river["points"])
	var levels_ms := (Time.get_ticks_usec() - t) / 1000.0

	# 2. Casters: read-back vs the rest.
	var chunks := terrain.get_node(Meta.GENERATED_CHUNKS_NAME).get_children()
	var readback_us := 0
	var caster_us := 0
	for chunk in chunks:
		var mesh := (chunk as MeshInstance3D).mesh as ArrayMesh
		if mesh == null:
			continue
		t = Time.get_ticks_usec()
		for surface in mesh.get_surface_count():
			mesh.surface_get_arrays(surface)
		readback_us += Time.get_ticks_usec() - t
		t = Time.get_ticks_usec()
		MeshUtils.back_face_caster(mesh)
		caster_us += Time.get_ticks_usec() - t
	# 3. Hover ray, worst case: from high above one corner, almost flat
	# towards the far corner (the ray stays long inside the height band).
	var carve := builder.get_river_carve(terrain)
	var origin := Vector3(-world_size * 0.5, 30.0, -world_size * 0.5)
	var direction := Vector3(1.0, -0.02, 1.0).normalized()
	t = Time.get_ticks_usec()
	for i in 20:
		SurfaceRay.hit(terrain, carve, origin, direction)
	var ray_ms := (Time.get_ticks_usec() - t) / 1000.0 / 20.0
	print("%-12s hover ray (worst case) %.2f ms" % [label, ray_ms])
	# 4. Mesher: the extra copy of a one-style chunk (vertices, normals,
	# colours of a full 32 x 32-cell chunk: 6144 entries each).
	var source: Array = []
	source.resize(6144)
	source.fill(Vector3.ONE)
	t = Time.get_ticks_usec()
	for i in 100:
		var copy: Array = []
		copy.append_array(source)
		copy.append_array(source)
		copy.append_array(source)
	print("%-12s mesher extra copy per chunk %.3f ms" % [label, (Time.get_ticks_usec() - t) / 1000.0 / 100.0])
	print("%-12s rebuild_all %.0f ms | %d river(s): water_levels %.2f ms | %d chunks: casters %.1f ms (read-back alone %.1f ms)" % [
		label, build_ms, rivers.size(), levels_ms, chunks.size(), caster_us / 1000.0, readback_us / 1000.0])
