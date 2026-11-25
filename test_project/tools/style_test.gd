extends SceneTree
## Look test: the same map (scenes/savanna_128.tscn, its own sky and sun)
## rendered in several low-poly styles. Toon / unshaded use the terrain's
## Custom Materials (examples in world/looks/, outline = world/looks/outline.tscn
## under the camera); the re-cut triangles are done HERE, after the build
## (preview only, the plugin always cuts the same diagonal).
## Real window, kept off screen:
##   godot --path . --rendering-method mobile --position -3000,-3000 --resolution 960x540 --script res://tools/style_test.gd
## Writes res://results/styles/<style>_<view>.png.
## Re-cut / moved vertices are a preview only: roads, waterholes and details
## stay on the original surface (may float or sink by a few centimetres).

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainStorage = preload(ADDON + "core/terrain_storage.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")

const SCENE := "res://scenes/savanna_128.tscn"
const OUT := "res://results/styles"
const STYLES := [
	"actuel", "facettes", "aplats", "toon", "toon_contours",
	"sans_eclairage", "coupe_alternee", "coupe_relief", "sommets_decales",
]
const FACETED := {Meta.SHADE_SMOOTH: false}
const NO_BAKED_SHADING := {
	Meta.SHADE_SMOOTH: false, Meta.SHADE_BLEND: 0, Meta.SHADE_BLEND_NOISE: 0.0,
	Meta.SHADE_SLOPE: 0.0, Meta.SHADE_AO: 0.0, Meta.SHADE_VARIATION: 0.0,
	Meta.SHADE_CLIFF_DARKEN: 0.0, Meta.SHADE_CLIFF_LIP: 0.0,
}


var _root: Node
var _terrain: Node3D
var _camera: Camera3D
var _heights: PackedFloat32Array
var _resolution := 0
var _world_size := 0.0
var _spacing := 1.0

func _ground(p: Vector2) -> float:
	return WaterholeMesher.surface_height(_heights, PackedFloat32Array(), _resolution, _world_size, p)

func _at(p: Vector2, lift: float) -> Vector3:
	return Vector3(p.x, _ground(p) + lift, p.y)

func _load() -> void:
	if _root:
		_root.free()
	_root = (load(SCENE) as PackedScene).instantiate()
	var player := _root.get_node_or_null("FpsPlayer")
	if player:
		_root.remove_child(player)
		player.free()
	_terrain = _root.get_node("LowpolyTerrain")
	var runtime := _terrain.get_node_or_null("_LowpolyTerrainRuntime")
	if runtime:
		_terrain.remove_child(runtime)
		runtime.free()
	TerrainStorage.unpack(_terrain)
	get_root().add_child(_root)
	_heights = _terrain.get_meta(Meta.HEIGHTS)
	_resolution = _terrain.get_meta(Meta.RESOLUTION)
	_world_size = _terrain.get_meta(Meta.WORLD_SIZE)
	_spacing = _world_size / float(_resolution - 1)
	_camera = Camera3D.new()
	_camera.fov = 55.0
	_camera.far = 800.0
	_root.add_child(_camera)
	_camera.current = true

## Terrain settings, except the baked shading keys (Meta.SHADE_*), which go
## to the terrain's own copy of its biome (the biome is the look's source).
func _rebuild(metas: Dictionary) -> void:
	var biome: Resource = TerrainBiome.of(_terrain)
	for key in metas:
		if TerrainBiome.LEGACY_LOOK_KEYS.has(key):
			if biome.resource_path != "" or biome == TerrainBiome.default_biome():
				biome = biome.duplicate(true)
				_terrain.set_meta(Meta.BIOME, biome)
			biome.set(TerrainBiome.LEGACY_LOOK_KEYS[key], metas[key])
		else:
			_terrain.set_meta(key, metas[key])
	TerrainBuilder.new().rebuild_all(_terrain)

# --- Custom Materials (the plugin's slots) -------------------------------------

func _use_materials(ground: String, detail: String) -> void:
	var biome: TerrainBiome = TerrainBiome.of(_terrain).duplicate()
	biome.ground_material = load("res://world/looks/%s.tres" % ground)
	biome.detail_material = load("res://world/looks/%s.tres" % detail)
	_terrain.set_meta(Meta.BIOME, biome)
	TerrainBuilder.refresh_materials(_terrain)

func _add_outline() -> void:
	_camera.add_child((load("res://world/looks/outline.tscn") as PackedScene).instantiate())

# --- Re-cutting the ground ------------------------------------------------------

## 0 = checkerboard diagonals, 1 = diagonal joining the closer heights.
## `jitter` moves every vertex sideways by up to jitter x cell size (same
## position -> same offset, so chunks and cliffs stay joined).
func _recut(mode: int, jitter: float) -> void:
	var chunks := _terrain.get_node(Meta.GENERATED_CHUNKS_NAME)
	for chunk in chunks.get_children():
		var mi := chunk as MeshInstance3D
		if mi == null or not (mi.mesh is ArrayMesh):
			continue
		var src := mi.mesh as ArrayMesh
		var dst := ArrayMesh.new()
		for s in src.get_surface_count():
			var arrays := src.surface_get_arrays(s)
			_recut_surface(arrays, mode, jitter)
			dst.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			dst.surface_set_material(s, src.surface_get_material(s))
		mi.mesh = dst

func _same(a: Vector3, b: Vector3) -> bool:
	return a.distance_squared_to(b) < 0.000001

func _recut_surface(arrays: Array, mode: int, jitter: float) -> void:
	var v: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var c = arrays[Mesh.ARRAY_COLOR]
	var uv = arrays[Mesh.ARRAY_TEX_UV]
	var has_c: bool = c != null and (c as PackedColorArray).size() == v.size()
	var has_uv: bool = uv != null and (uv as PackedVector2Array).size() == v.size()
	# Output as slot lists (index of the source vertex) + per-slot colour.
	var slots: Array[int] = []
	var colors: Array[Color] = []
	var i := 0
	while i < v.size():
		var quad := i + 5 < v.size() and n[i].y > 0.3 and n[i + 3].y > 0.3
		var shared: Array[int] = []
		var only_a := -1
		var only_b := -1
		if quad:
			for a in range(i, i + 3):
				var found := false
				for b in range(i + 3, i + 6):
					if _same(v[a], v[b]):
						found = true
				if found:
					shared.append(a)
				else:
					only_a = a
			for b in range(i + 3, i + 6):
				var found := false
				for a in range(i, i + 3):
					if _same(v[a], v[b]):
						found = true
				if not found:
					only_b = b
			quad = shared.size() == 2 and only_a >= 0 and only_b >= 0
			if quad:
				var diag := Vector2(v[shared[0]].x - v[shared[1]].x, v[shared[0]].z - v[shared[1]].z).length()
				quad = diag > _spacing * 1.2
		if not quad:
			for k in 3:
				slots.append(i + k)
				colors.append(c[i + k] if has_c else Color.WHITE)
			i += 3
			continue
		var flip := false
		if mode == 0:
			var lo := Vector2(minf(v[only_a].x, v[only_b].x), minf(v[only_a].z, v[only_b].z))
			var cell := Vector2i(floori(lo.x / _spacing + 0.001), floori(lo.y / _spacing + 0.001))
			flip = posmod(cell.x + cell.y, 2) == 1
		else:
			flip = absf(v[only_a].y - v[only_b].y) < absf(v[shared[0]].y - v[shared[1]].y) - 0.001
		var color_a: Color = c[i] if has_c else Color.WHITE
		var color_b: Color = c[i + 3] if has_c else Color.WHITE
		if not flip:
			for k in 6:
				slots.append(i + k)
				colors.append(c[i + k] if has_c else Color.WHITE)
		else:
			for tri in [[only_a, only_b, shared[0]], [only_b, only_a, shared[1]]]:
				var color := color_a if tri[2] == shared[0] else color_b
				for k in tri:
					slots.append(k)
					colors.append(color)
		i += 6

	var out_v := PackedVector3Array()
	var out_n := PackedVector3Array()
	var out_c := PackedColorArray()
	var out_uv := PackedVector2Array()
	out_v.resize(slots.size())
	out_n.resize(slots.size())
	if has_c:
		out_c.resize(slots.size())
	if has_uv:
		out_uv.resize(slots.size())
	for k in slots.size():
		var p := v[slots[k]]
		if jitter > 0.0:
			var h := hash(Vector2i(roundi(p.x * 100.0), roundi(p.z * 100.0)))
			var ox := float(h & 0xFFFF) / 65535.0 * 2.0 - 1.0
			var oz := float((h >> 16) & 0xFFFF) / 65535.0 * 2.0 - 1.0
			p += Vector3(ox, 0.0, oz) * jitter * _spacing
		out_v[k] = p
		if has_c:
			out_c[k] = colors[k]
		if has_uv:
			out_uv[k] = (uv as PackedVector2Array)[slots[k]]
	# Flat normals; winding as the plugin writes it (cross . normal < 0).
	for t in range(0, slots.size(), 3):
		var a := out_v[t]
		var b := out_v[t + 1]
		var d := out_v[t + 2]
		var cross := (b - a).cross(d - a)
		var old_normal := n[slots[t]]
		var normal := cross.normalized()
		if normal.dot(old_normal) < 0.0:
			normal = -normal
		if cross.dot(normal) > 0.0:
			out_v[t + 1] = d
			out_v[t + 2] = b
			if has_c:
				var tc := out_c[t + 1]
				out_c[t + 1] = out_c[t + 2]
				out_c[t + 2] = tc
			if has_uv:
				var tu := out_uv[t + 1]
				out_uv[t + 1] = out_uv[t + 2]
				out_uv[t + 2] = tu
		out_n[t] = normal
		out_n[t + 1] = normal
		out_n[t + 2] = normal
	arrays[Mesh.ARRAY_VERTEX] = out_v
	arrays[Mesh.ARRAY_NORMAL] = out_n
	arrays[Mesh.ARRAY_COLOR] = out_c if has_c else null
	arrays[Mesh.ARRAY_TEX_UV] = out_uv if has_uv else null

# --- Views --------------------------------------------------------------------

func _biggest(part: String) -> Vector3:
	var best := -1.0
	var found := Vector3.ZERO
	for node in _terrain.find_children("_Details*", "MultiMeshInstance3D", true, false):
		if not String(node.name).contains(part):
			continue
		var buffer: PackedFloat32Array = (node as MultiMeshInstance3D).multimesh.buffer
		for i in range(0, buffer.size(), 16):
			var s := Vector3(buffer[i], buffer[i + 4], buffer[i + 8]).length()
			var p := Vector3(buffer[i + 3], buffer[i + 7], buffer[i + 11])
			var score := s - p.length() * 0.01
			if score > best:
				best = score
				found = p
	return found

func _plateau_edge() -> Vector2:
	var half := _world_size * 0.5
	var best := INF
	var found := Vector2.ZERO
	for z in range(4, _resolution - 4, 2):
		for x in range(4, _resolution - 7, 2):
			var h := _heights[z * _resolution + x]
			var h2 := _heights[z * _resolution + x + 3]
			if h2 - h > 1.6:
				var p := Vector2(x * _spacing - half, z * _spacing - half)
				if p.length() < best:
					best = p.length()
					found = p + Vector2(_spacing * 1.5, 0)
	return found

func _views() -> Dictionary:
	var acacia := _biggest("Acacias")
	var ac := Vector2(acacia.x, acacia.z)
	var edge := _plateau_edge()
	return {
		"vue_haute": [Vector3(0, 72, 82), Vector3(0, 0, 4)],
		"vue_moyenne": [_at(Vector2(-20, 40), 20.0), _at(Vector2(5, 5), 0.0)],
		"hauteur_yeux": [_at(Vector2(-6, 30), 1.7), _at(Vector2(10, -10), 2.0)],
		"acacia": [_at(ac + Vector2(-8, 9), 2.5), _at(ac, 2.5)],
		"relief": [_at(edge + Vector2(-14, 12), 5.0), _at(edge + Vector2(3, 0), 1.0)],
	}

func _apply(style: String) -> void:
	match style:
		"facettes":
			_rebuild(FACETED)
		"aplats":
			_rebuild(NO_BAKED_SHADING)
		"toon":
			_rebuild(FACETED)
			_use_materials("ground_toon", "detail_toon_wind")
		"toon_contours":
			_rebuild(FACETED)
			_use_materials("ground_toon", "detail_toon_wind")
			_add_outline()
		"sans_eclairage":
			_use_materials("ground_unshaded", "detail_unshaded")
		"coupe_alternee":
			_rebuild(FACETED)
			_recut(0, 0.0)
		"coupe_relief":
			_rebuild(FACETED)
			_recut(1, 0.0)
		"sommets_decales":
			_rebuild(FACETED)
			_recut(1, 0.3)

func _initialize() -> void:
	var only := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	# The root enters the tree after _initialize returns.
	await process_frame
	_load()
	var views := _views()
	for style in STYLES:
		if only != "" and not only.split(",").has(style):
			continue
		var t0 := Time.get_ticks_msec()
		_load()
		_apply(style)
		print("style %s ready in %d ms" % [style, Time.get_ticks_msec() - t0])
		for view_name in views:
			var view: Array = views[view_name]
			_camera.look_at_from_position(_terrain.to_global(view[0]), _terrain.to_global(view[1]))
			for f in range(8):
				await RenderingServer.frame_post_draw
			var path := "%s/%s_%s.png" % [OUT, style, view_name]
			get_root().get_texture().get_image().save_png(path)
		print("wrote %s_*" % style)
	quit(0)
