extends SceneTree
## Blended ground textures (TerrainShading layers, terrain_splat.gdshader), on
## a generated savanna map whose Laterite / clay styles get small textures:
## - the weights, shades and colours of a vertex / face do not depend on the
##   region being built (no seam between chunks), smooth and faceted ground;
## - chunks hold one blended surface (CUSTOM0 / CUSTOM1 weights, splat
##   material) and no hard textured top surface of a blended style; weights
##   sum to at most 1 and reach 1 inside a textured area;
## - textured cliffs keep their baked greys (vertex colours + UVs);
## - worker-thread chunks (thread_snapshot + pack_chunk) equal main-thread ones;
## - without textures: no blended surface.
##   godot --headless --path . --script res://tools/check_texture_blend.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const MapRecipe = preload(ADDON + "generation/map_recipe.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const TerrainShading = preload(ADDON + "mesh/terrain_shading.gd")
const MaterialFactory = preload(ADDON + "materials/material_factory.gd")
const StylePalette = preload(ADDON + "styles/style_palette.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

var _failures := 0

func _fail(message: String) -> void:
	_failures += 1
	if _failures <= 12:
		print("FAIL ", message)

func _texture(color: Color) -> Texture2D:
	var image := Image.create(8, 8, false, Image.FORMAT_RGB8)
	image.fill(color)
	image.set_pixel(3, 3, color.darkened(0.3))
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)

## The two most used styles after the first one (patches over the base ground).
func _textured_styles(terrain: Node3D) -> Array[int]:
	var counts := {}
	for style: int in terrain.get_meta(Meta.CELL_STYLES) as PackedInt32Array:
		if style >= 0:
			counts[style] = counts.get(style, 0) + 1
	var ids: Array = counts.keys()
	ids.sort_custom(func(a: int, b: int) -> bool: return counts[a] > counts[b])
	var result: Array[int] = []
	for i in range(1, mini(ids.size(), 3)):
		result.append(ids[i])
	return result

func _initialize() -> void:
	var recipe: MapRecipe = (load(RECIPE) as MapRecipe).duplicate()
	recipe.size = 128
	var terrain := Node3D.new()
	get_root().add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, recipe, 7)
	StylePalette.ensure_material_data(terrain)
	var styles := _textured_styles(terrain)
	if styles.size() < 2:
		_fail("map has fewer than 3 styles")
	var palette: Array = terrain.get_meta(Meta.STYLE_PALETTE)
	var colors := [Color(0.8, 0.3, 0.2), Color(0.5, 0.45, 0.4)]
	for i in styles.size():
		var style: Dictionary = palette[styles[i]]
		style["top_texture"] = _texture(colors[i])
		style["top_tile_size"] = 3.0
	(palette[styles[0]] as Dictionary)["cliff_texture"] = _texture(Color(0.6, 0.35, 0.25))
	print("textured styles: ", styles, " layers: ", MaterialFactory.splat_layers(terrain))
	var builder := TerrainBuilder.new()
	builder.rebuild_river_carve(terrain)
	var carve := builder.get_river_carve(terrain)

	for smooth: bool in [true, false]:
		terrain.set_meta(Meta.SHADE_SMOOTH, smooth)
		var label := "smooth" if smooth else "faceted"
		_check_seams(terrain, carve, label)
		_check_chunks(terrain, carve, label, styles)
		_check_threads(terrain, carve, label)

	for id in styles:
		(palette[id] as Dictionary)["top_texture"] = null
	(palette[styles[0]] as Dictionary)["cliff_texture"] = null
	for z in TerrainMesher.chunk_count(terrain):
		for x in TerrainMesher.chunk_count(terrain):
			var mesh: ArrayMesh = TerrainMesher.build_chunk_parts(terrain, carve, x, z).get("mesh")
			if mesh and _splat_surface(mesh) >= 0:
				_fail("untextured: chunk %d,%d has a blended surface" % [x, z])
	terrain.free()
	print("RESULT: %s (%d failures)" % ["OK" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures > 0 else 0)

## Same values for the chunk-sized region and a larger region around it.
func _check_seams(terrain: Node3D, carve: PackedFloat32Array, label: String) -> void:
	var small := TerrainShading.prepare(terrain, carve, 32, 32, 64, 64)
	var large := TerrainShading.prepare(terrain, carve, 10, 20, 90, 70)
	if small.layers.is_empty():
		_fail("%s: no blended layers" % label)
		return
	var bad := 0
	var set_count := 0
	if label == "smooth":
		for z in range(32, 65):
			for x in range(32, 65):
				var a := (z - small.min_z) * small.vw + (x - small.min_x)
				var b := (z - large.min_z) * large.vw + (x - large.min_x)
				set_count += small.textured[a]
				if small.textured[a] != large.textured[b] or not small.weights_a[a].is_equal_approx(large.weights_a[b]) \
						or not small.weights_b[a].is_equal_approx(large.weights_b[b]) \
						or not is_equal_approx(small.shades[a], large.shades[b]) \
						or not small.vertex_colors[a].is_equal_approx(large.vertex_colors[b]):
					bad += 1
	else:
		for z in range(32, 64):
			for x in range(32, 64):
				for tri in 2:
					var a := ((z - small.min_z) * small.cw + (x - small.min_x)) * 2 + tri
					var b := ((z - large.min_z) * large.cw + (x - large.min_x)) * 2 + tri
					set_count += small.textured[a]
					if small.textured[a] != large.textured[b] or not small.weights_a[a].is_equal_approx(large.weights_a[b]) \
							or not small.weights_b[a].is_equal_approx(large.weights_b[b]) \
							or not is_equal_approx(small.shades[a], large.shades[b]) \
							or not small.faces[a].is_equal_approx(large.faces[b]):
						bad += 1
	if bad > 0:
		_fail("%s: %d blended values depend on the region built" % [label, bad])
	if set_count == 0:
		_fail("%s: no textured vertex / face in the tested region" % label)
	print("%s seams: %d textured, %d mismatches" % [label, set_count, bad])

func _splat_surface(mesh: ArrayMesh) -> int:
	for s in mesh.get_surface_count():
		if mesh.surface_get_format(s) & Mesh.ARRAY_FORMAT_CUSTOM0:
			return s
	return -1

func _check_chunks(terrain: Node3D, carve: PackedFloat32Array, label: String, styles: Array[int]) -> void:
	var count := TerrainMesher.chunk_count(terrain)
	var full := 0
	var partial := 0
	var walls := 0
	for z in count:
		for x in count:
			var mesh: ArrayMesh = TerrainMesher.build_chunk_parts(terrain, carve, x, z).get("mesh")
			if mesh == null:
				continue
			for s in mesh.get_surface_count():
				var material := mesh.surface_get_material(s)
				var format := mesh.surface_get_format(s)
				if material and material.resource_name == "Terrain Top":
					_fail("%s chunk %d,%d: hard textured top surface left" % [label, x, z])
				if material and material.resource_name == "Terrain Side":
					if format & Mesh.ARRAY_FORMAT_COLOR and format & Mesh.ARRAY_FORMAT_TEX_UV:
						walls += 1
					else:
						_fail("%s chunk %d,%d: textured cliff without baked greys" % [label, x, z])
			var s := _splat_surface(mesh)
			if s < 0:
				continue
			var material := mesh.surface_get_material(s) as ShaderMaterial
			if material == null or material.shader != MaterialFactory.TerrainSplatShader:
				_fail("%s chunk %d,%d: blended surface without the splat material" % [label, x, z])
			var arrays := mesh.surface_get_arrays(s)
			var weights_a: PackedByteArray = arrays[Mesh.ARRAY_CUSTOM0]
			var weights_b: PackedByteArray = arrays[Mesh.ARRAY_CUSTOM1]
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if weights_a.size() != vertices.size() * 4 or weights_b.size() != vertices.size() * 4:
				_fail("%s chunk %d,%d: weight arrays of the wrong size" % [label, x, z])
				continue
			for v in vertices.size():
				var total := 0
				# weights_b alpha = the waterhole tint, not a layer.
				for k in 4:
					total += weights_a[v * 4 + k] + (weights_b[v * 4 + k] if k < 3 else 0)
				if total > 255 + 8:
					_fail("%s chunk %d,%d: weights sum to %d / 255" % [label, x, z, total])
					break
				if total >= 250:
					full += 1
				elif total > 0:
					partial += 1
	if full == 0 or partial == 0:
		_fail("%s: %d fully / %d partly textured vertices (both expected)" % [label, full, partial])
	if walls == 0:
		_fail("%s: no textured cliff surface met" % label)
	print("%s chunks: %d fully, %d partly textured vertices, %d textured walls" % [label, full, partial, walls])

func _surfaces_bytes(mesh: ArrayMesh) -> PackedByteArray:
	var bytes := PackedByteArray()
	for s in mesh.get_surface_count():
		bytes.append_array(var_to_bytes(mesh.surface_get_arrays(s)))
		bytes.append_array(var_to_bytes(mesh.surface_get_format(s)))
		var material := mesh.surface_get_material(s)
		bytes.append_array(var_to_bytes(material.resource_name if material else ""))
	return bytes

func _check_threads(terrain: Node3D, carve: PackedFloat32Array, label: String) -> void:
	var count := TerrainMesher.chunk_count(terrain)
	TerrainMesher.prepare_threads(terrain)
	var looks := TerrainMesher.chunk_looks(terrain)
	var bad := 0
	for z in count:
		for x in count:
			var expected: ArrayMesh = TerrainMesher.build_chunk_parts(terrain, carve, x, z).get("mesh")
			var snapshot := TerrainMesher.thread_snapshot(terrain)
			var result: Array[Dictionary] = [{}]
			var cx := x
			var cz := z
			var task := WorkerThreadPool.add_task(func() -> void:
				result[0] = TerrainMesher.pack_chunk(TerrainMesher.build_chunk_arrays(snapshot, carve, cx, cz), looks))
			WorkerThreadPool.wait_for_task_completion(task)
			snapshot.free()
			var parts := TerrainMesher.assemble_packed(terrain, result[0])
			var mesh: ArrayMesh = parts.get("mesh")
			if (mesh == null) != (expected == null):
				bad += 1
			elif mesh and _surfaces_bytes(mesh) != _surfaces_bytes(expected):
				bad += 1
	if bad > 0:
		_fail("%s: %d worker chunks differ from the main-thread build" % [label, bad])
	print("%s threads: %d chunks differ" % [label, bad])
