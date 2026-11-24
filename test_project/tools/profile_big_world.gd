extends SceneTree
## Phase 0 of the open-world plan: what a big generated map costs, before
## streaming it. For the savanna recipe at 256 / 512 / 1024 cells of 1.5 m
## (384 m, 768 m, 1.5 km) it prints:
##   - generation time, step by step (MapGenerator.start / step);
##   - the size of the data arrays in memory, and packed (Zstandard) as saved;
##   - a 4 x 4 sample of chunks spread over the map: ground mesh time and
##     triangles, details time and instances, extrapolated to every chunk;
##   - one brush stroke (raise, 4 m) with the rebuild of the chunks it touches;
##   - the road mesh of the whole map (one mesh today).
## Writes the table to results/big_world/phase0.txt too.
##   godot --headless --path . --script res://tools/profile_big_world.gd [-- 256 512 1024]

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainStorage = preload(ADDON + "core/terrain_storage.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const MapRecipe = preload(ADDON + "generation/map_recipe.gd")
const ImageGenerator = preload(ADDON + "generation/image_generator.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const Brush = preload(ADDON + "editing/brush.gd")
const ToolMode = preload(ADDON + "editing/tool_mode.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"
const CELL_SIZE := 1.5
const SAMPLES_PER_SIDE := 4

var _lines: PackedStringArray = []

func _initialize() -> void:
	var sizes: Array[int] = []
	for arg in OS.get_cmdline_user_args():
		if arg.is_valid_int():
			sizes.append(arg.to_int())
	if sizes.is_empty():
		sizes = [256, 512, 1024]
	var holder := Node3D.new()
	get_root().add_child(holder)
	for size in sizes:
		_profile(holder, size)
	holder.free()
	DirAccess.make_dir_recursive_absolute("res://results/big_world")
	var file := FileAccess.open("res://results/big_world/phase0.txt", FileAccess.WRITE)
	file.store_string("\n".join(_lines) + "\n")
	file.close()
	quit()

func _out(text: String) -> void:
	print(text)
	_lines.append(text)

func _profile(holder: Node3D, size: int) -> void:
	var recipe: MapRecipe = (load(RECIPE) as MapRecipe).duplicate()
	recipe.size = size
	recipe.cell_size = CELL_SIZE
	var terrain := Node3D.new()
	holder.add_child(terrain)
	TerrainData.initialize(terrain)
	_out("== %d cells x %.1f m = %.0f m, %d chunks" % [size, CELL_SIZE, size * CELL_SIZE,
		int(pow(ceilf(float(size) / Meta.TERRAIN_CHUNK_CELLS), 2.0))])

	# Generation, step by step (MapGenerator.start / step).
	var seed := 7
	var generation := MapGenerator.start(terrain, recipe, seed)
	var step_line := ""
	var finished := false
	while not finished:
		var label := generation.next_step()
		var step_start := Time.get_ticks_usec()
		finished = MapGenerator.step(generation)
		step_line += " | %s %.0f" % [label, _ms(step_start)]
	_out("generate %.0f ms%s (%d tracks, %d holes)" % [generation.stats["ms"], step_line, generation.stats["tracks"], generation.stats["waterholes"]])

	# Data size: in memory, then packed as saved.
	var raw_bytes := 0
	for key in TerrainStorage.PACKED_KEYS:
		if terrain.has_meta(key):
			raw_bytes += var_to_bytes(terrain.get_meta(key)).size()
	var t := Time.get_ticks_usec()
	var originals := TerrainStorage.pack(terrain)
	var pack_ms := _ms(t)
	var packed: Dictionary = terrain.get_meta(TerrainStorage.PACKED_DATA, {})
	var packed_bytes: int = (packed.get("zstd", PackedByteArray()) as PackedByteArray).size()
	TerrainStorage.restore(terrain, originals)
	_out("data %.1f MB in memory, %.2f MB packed (pack %.0f ms)" % [raw_bytes / 1048576.0, packed_bytes / 1048576.0, pack_ms])

	# A spread sample of chunks: ground, then details.
	var builder := TerrainBuilder.new()
	var chunks := int(ceilf(float(size) / Meta.TERRAIN_CHUNK_CELLS))
	var ground_us := 0
	var detail_us := 0
	var triangles := 0
	var instances := 0
	var sampled := 0
	for sz in SAMPLES_PER_SIDE:
		for sx in SAMPLES_PER_SIDE:
			var cx := int((sx + 0.5) * chunks / SAMPLES_PER_SIDE)
			var cz := int((sz + 0.5) * chunks / SAMPLES_PER_SIDE)
			t = Time.get_ticks_usec()
			var parts := builder.rebuild_chunk(terrain, cx, cz, false)
			ground_us += Time.get_ticks_usec() - t
			if parts.is_empty():
				continue
			sampled += 1
			var mesh: ArrayMesh = parts["mesh"]
			for surface in mesh.get_surface_count():
				triangles += mesh.surface_get_array_len(surface) / 3
			t = Time.get_ticks_usec()
			var job := builder.start_chunk_details(terrain, cx, cz, -1, parts["shading"])
			builder.step_chunk_details(job)
			builder.finish_chunk_details(job)
			detail_us += Time.get_ticks_usec() - t
			var chunk := TerrainMesher.find_chunk(terrain, cx, cz)
			for node in chunk.find_children("*", "MultiMeshInstance3D", true, false):
				var multimesh: MultiMesh = (node as MultiMeshInstance3D).multimesh
				if multimesh != null:
					instances += multimesh.instance_count
	var per := float(maxi(sampled, 1))
	var all := float(chunks * chunks)
	_out("per chunk (%d sampled): ground %.1f ms, %.0f tris | details %.1f ms, %.0f instances" % [
		sampled, ground_us / 1000.0 / per, triangles / per, detail_us / 1000.0 / per, instances / per])
	_out("whole map (extrapolated): ground %.1f s, %.0f k tris | details %.1f s, %.0f k instances" % [
		ground_us / 1e6 / per * all, triangles / per * all / 1000.0, detail_us / 1e6 / per * all, instances / per * all / 1000.0])

	# One brush stroke at the centre: data + the chunks it touches (no details).
	t = Time.get_ticks_usec()
	Brush.apply_vertex_brush(terrain, ToolMode.Mode.RAISE, Vector2.ZERO, 4.0, 1.0)
	var brush_ms := _ms(t)
	t = Time.get_ticks_usec()
	var touched := builder.chunks_for_vertex_bounds(terrain, Brush.vertex_bounds(terrain, Vector2.ZERO, 4.0, 1))
	for key in touched:
		builder.rebuild_chunk(terrain, key.x, key.y, false)
	_out("brush stroke: data %.1f ms, %d chunk(s) rebuilt %.1f ms" % [brush_ms, touched.size(), _ms(t)])

	# Roads: one mesh for the whole map today.
	t = Time.get_ticks_usec()
	builder.rebuild_feature_mesh(terrain)
	_out("road mesh, whole map: %.0f ms (%d roads)" % [_ms(t), (terrain.get_meta(Meta.ROADS, []) as Array).size()])
	terrain.free()

func _ms(start_usec: int) -> float:
	return (Time.get_ticks_usec() - start_usec) / 1000.0
