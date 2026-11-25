@tool
class_name MapHorizon
extends Node3D
## Distant landscape around a Lowpoly terrain, so the map does not end in the
## void.
##
## - The ground carries on past the map border (same height at the seam), then
##   flattens out with gentle undulations and falls away far off, where the
##   fog hides it.
## - Low flat-topped hills (laterite mesas) and rounded hills stand on the
##   skyline.
## - A few trees are scattered just outside the map.
## - In game, invisible walls along the border keep the player on the map.
##
## Part of this project, not of the plugin: how a map's edge should look
## depends on the game (FPS: a far landscape like this one; top-down: keep the
## camera inside the map and put a plain ground under it; island: water). Add
## it as a child of the terrain (Add Child Node > MapHorizon). Cheap: one flat-shaded mesh (vertex colours,
## the terrain's own material, about 5k triangles), one MultiMesh per tree
## type. Nothing is saved in the scene: it is rebuilt when the scene loads (a
## few ms), when the runtime has built a generated map, and with "Rebuild"
## (after sculpting the border). Colours come from the terrain's biome (its
## first three ground styles) unless "Use Biome Colors" is off.

const Meta = preload("res://addons/lowpoly_terrain_editor/core/terrain_meta.gd")
const TerrainStorage = preload("res://addons/lowpoly_terrain_editor/core/terrain_storage.gd")
const TerrainSampler = preload("res://addons/lowpoly_terrain_editor/core/terrain_sampler.gd")
const MaterialFactory = preload("res://addons/lowpoly_terrain_editor/materials/material_factory.gd")
const DetailMeshes = preload("res://addons/lowpoly_terrain_editor/mesh/detail_meshes.gd")

## Rings of the far ground: [distance outside the map border, segment divider].
## Negative distance = under the terrain, so no slit shows at the seam. The
## divider thins the rings out with distance (long thin triangles would show
## as streaks). The last ring, added after these, lies at `radius`.
const RINGS: Array = [[-1.5, 1], [0.0, 1], [5.0, 1], [14.0, 1], [32.0, 2], [70.0, 2], [150.0, 4], [300.0, 4], [500.0, 8]]
## Where the ground has fully flattened to the map's average border height.
const FLATTEN_DISTANCE := 40.0
## Trees are placed up to this far outside the border (dense rings there).
const TREE_BAND := 90.0
## Trees are split in TREE_CELLS x TREE_CELLS MultiMeshes (see _add_trees).
const TREE_CELLS := 4

@export_tool_button("Rebuild", "Reload") var rebuild_button := rebuild
@export var horizon_seed := 1:
	set(value):
		horizon_seed = value
		_queue_rebuild()
## Distance from the map centre to the outer edge of the far ground (at
## least 600 units past the border).
@export_range(200.0, 3000.0, 10.0) var radius := 700.0:
	set(value):
		radius = value
		_queue_rebuild()
## Height of the ground undulations (0 = flat plain).
@export_range(0.0, 5.0, 0.05) var undulation := 1.0:
	set(value):
		undulation = value
		_queue_rebuild()
## Number of distant hills / mesas.
@export_range(0, 32) var hills := 10:
	set(value):
		hills = value
		_queue_rebuild()
## Number of trees just outside the map.
@export_range(0, 400) var trees := 80:
	set(value):
		trees = value
		_queue_rebuild()
## Invisible walls along the map border, in game only.
@export var boundary_walls := true
## Ground colour: taken from the terrain's own border (so the seam matches)
## when on; `ground_color` otherwise. Patches use the biome's 2nd and 3rd
## ground styles (or the colours below), shaded like the terrain.
@export var use_terrain_colors := true:
	set(value):
		use_terrain_colors = value
		_queue_rebuild()
@export var ground_color := Color(0.66, 0.55, 0.32):
	set(value):
		ground_color = value
		_queue_rebuild()
@export var patch_color := Color(0.7, 0.36, 0.2):
	set(value):
		patch_color = value
		_queue_rebuild()
@export var green_color := Color(0.55, 0.6, 0.28):
	set(value):
		green_color = value
		_queue_rebuild()

var _queued := false
var _noise := FastNoiseLite.new()
var _patches := FastNoiseLite.new()
var _greens := FastNoiseLite.new()
var _base_height := 0.0
var _half := 0.0
## Border samples per side (multiple of 8, see RINGS dividers).
var _per_side := 8
var _border: PackedFloat32Array = PackedFloat32Array()
var _border_colors: PackedColorArray = PackedColorArray()
var _ground := ground_color
var _patch := patch_color
var _green := green_color

func _ready() -> void:
	# A generated map changes the heights in game: rebuild once it exists.
	var parent := get_parent()
	if parent != null:
		for sibling in parent.get_children():
			if sibling != self and sibling.has_signal("terrain_ready") and not sibling.is_connected("terrain_ready", rebuild):
				sibling.connect("terrain_ready", rebuild)
	_queue_rebuild()

func _queue_rebuild() -> void:
	if _queued or not is_inside_tree():
		return
	_queued = true
	rebuild.call_deferred()

## Rebuilds everything from the parent terrain's current heights.
func rebuild() -> void:
	_queued = false
	_clear()
	var terrain := get_parent() as Node3D
	if terrain == null or not Meta.is_terrain(terrain):
		return
	TerrainStorage.unpack(terrain)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS, PackedFloat32Array())
	var resolution := int(terrain.get_meta(Meta.RESOLUTION, 0))
	var world_size := float(terrain.get_meta(Meta.WORLD_SIZE, 0.0))
	if resolution < 2 or world_size <= 0.0 or heights.size() < resolution * resolution:
		return
	_half = world_size * 0.5
	for n in [_noise, _patches, _greens]:
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	_noise.seed = horizon_seed
	_noise.frequency = 0.012
	_patches.seed = horizon_seed + 17
	_patches.frequency = 0.01
	_greens.seed = horizon_seed + 31
	_greens.frequency = 0.014

	# Border heights, sampled all around the square (perimeter parameter).
	_per_side = clampi(((resolution - 1) / 2) / 8 * 8, 8, 64)
	var count := _per_side * 4
	_border.resize(count)
	var sorted: Array[float] = []
	for i in count:
		var h := TerrainSampler.uncarved_height_in(heights, resolution, world_size, _square_point(i, _half, _per_side))
		_border[i] = h
		sorted.append(h)
	sorted.sort()
	_base_height = sorted[sorted.size() / 2]
	_pick_colors(terrain, world_size / float(resolution - 1))

	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = _build_ground_mesh(heights, resolution, world_size)
	ground.material_override = MaterialFactory.terrain_vertex_color_material(terrain)
	# Nearly flat and lower than the map: its shadow is never seen, but its
	# bounds span every shadow cascade, so casting would redraw it 4 more times.
	ground.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(ground)
	_add_trees()
	if boundary_walls and not Engine.is_editor_hint():
		_add_walls()

func _clear() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()

# -----------------------------------------------------------------------------
# Colours
# -----------------------------------------------------------------------------

## Ground colour along the border, read from the terrain's own chunk meshes
## (vertex colours, baked shading included), and the patch colours, shaded
## by the same amount as the ground.
func _pick_colors(terrain: Node3D, spacing: float) -> void:
	var count := _per_side * 4
	_border_colors = PackedColorArray()
	_border_colors.resize(count)
	_ground = ground_color
	_patch = patch_color
	_green = green_color
	var reference := ground_color
	var biome := Meta.get_optional(terrain, Meta.BIOME) as Resource
	if biome != null:
		var styles: Array = biome.get("ground_styles")
		if styles.size() > 0:
			reference = styles[0].top_color
		if styles.size() > 1:
			_patch = styles[1].top_color
		if styles.size() > 2:
			_green = styles[2].top_color
	var sampled := use_terrain_colors and _sample_border_colors(terrain, spacing * 1.5)
	if sampled:
		var mean := Color(0, 0, 0)
		for c in _border_colors:
			mean += c
		mean = Color(mean.r / count, mean.g / count, mean.b / count)
		# The far ground keeps the main style's hue (the border average mixes
		# in laterite slopes, cliffs...) at the terrain's real brightness (it
		# darkens its style colours with AO and variation); same for patches.
		var shade := clampf(mean.get_luminance() / maxf(reference.get_luminance(), 0.01), 0.5, 1.2)
		_ground = Color(reference.r * shade, reference.g * shade, reference.b * shade)
		_patch = Color(_patch.r * shade, _patch.g * shade, _patch.b * shade)
		_green = Color(_green.r * shade, _green.g * shade, _green.b * shade)
	else:
		_ground = reference.darkened(0.12)
		_patch = _patch.darkened(0.12)
		_green = _green.darkened(0.12)
		_border_colors.fill(_ground)

## Averages the vertex colours of the terrain chunks near each border sample.
func _sample_border_colors(terrain: Node3D, band: float) -> bool:
	var container := terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME) as Node3D
	if container == null:
		return false
	var count := _per_side * 4
	var sums: Array[Color] = []
	sums.resize(count)
	sums.fill(Color(0, 0, 0, 0))
	var hits := PackedInt32Array()
	hits.resize(count)
	for chunk in container.get_children():
		var instance := chunk as MeshInstance3D
		if instance == null or instance.mesh == null:
			continue
		var to_terrain := container.transform * instance.transform
		var box := to_terrain * instance.mesh.get_aabb()
		if box.position.x > -_half + band and box.end.x < _half - band and box.position.z > -_half + band and box.end.z < _half - band:
			continue  # an inner chunk
		for s in instance.mesh.get_surface_count():
			# Untextured ground = the surface with vertex colours (whatever its
			# material: built-in or the terrain's Ground Material).
			if not (instance.mesh.surface_get_format(s) & Mesh.ARRAY_FORMAT_COLOR):
				continue
			var arrays := instance.mesh.surface_get_arrays(s)
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			var colors = arrays[Mesh.ARRAY_COLOR]
			if colors == null or (colors as PackedColorArray).size() != vertices.size():
				continue
			for v in vertices.size():
				var p := to_terrain * vertices[v]
				if _half - maxf(absf(p.x), absf(p.z)) > band:
					continue
				var index := _border_index(Vector2(p.x, p.z))
				sums[index] += colors[v]
				hits[index] += 1
	var found := 0
	for i in count:
		if hits[i] > 0:
			_border_colors[i] = sums[i] / float(hits[i])
			found += 1
	if found == 0:
		return false
	# Fill the gaps (unpainted border cells) with the previous sampled colour,
	# going round twice so the start of the loop gets one too.
	var last := Color(-1, 0, 0)
	for pass_index in 2:
		for i in count:
			if hits[i] > 0:
				last = _border_colors[i]
			elif last.r >= 0.0:
				_border_colors[i] = last
				hits[i] = 1
	return true

func _ground_color_at(p: Vector3, d: float, border_color: Color) -> Color:
	var color := border_color.lerp(_ground, smoothstep(0.0, 60.0, d))
	var far := smoothstep(8.0, 60.0, d)
	var laterite := smoothstep(0.35, 0.65, _patches.get_noise_2d(p.x, p.z))
	color = color.lerp(_patch, laterite * 0.6 * far)
	var green := smoothstep(0.35, 0.65, _greens.get_noise_2d(p.x, p.z))
	return color.lerp(_green, green * 0.5 * far)

# -----------------------------------------------------------------------------
# Ground rings
# -----------------------------------------------------------------------------

## Point `i` of the perimeter of the square of half-size `half` (2D x, z),
## `per_side` points per side, going around from the (-half, -half) corner.
func _square_point(i: int, half: float, per_side: int) -> Vector2:
	var side := i / per_side
	var t := float(i % per_side) / float(per_side) * 2.0 - 1.0
	match side:
		0:
			return Vector2(t * half, -half)
		1:
			return Vector2(half, t * half)
		2:
			return Vector2(-t * half, half)
		_:
			return Vector2(-half, -t * half)

## Index of the border sample closest to a point on (or near) the border.
func _border_index(p: Vector2) -> int:
	var t: float
	var side: int
	if absf(p.y) >= absf(p.x):
		side = 0 if p.y < 0.0 else 2
		t = p.x / _half if side == 0 else -p.x / _half
	else:
		side = 1 if p.x > 0.0 else 3
		t = p.y / _half if side == 1 else -p.y / _half
	var count := _per_side * 4
	return posmod(side * _per_side + roundi((t + 1.0) * 0.5 * float(_per_side)), count)

## Point `i` of the ring `d` units outside the border: a square near the map,
## rounder and rounder further away.
func _ring_point(i: int, d: float, per_side: int) -> Vector2:
	var size := _half + d
	var square := _square_point(i, size, per_side)
	var roundness := clampf((d - 10.0) / 140.0, 0.0, 1.0)
	return square.lerp(square.normalized() * size, roundness)

## Ground height `d` units outside the border at `p`, `border_height` being
## the terrain height at the matching border point.
func _surface_height(border_height: float, d: float, p: Vector2) -> float:
	var flat := smoothstep(0.0, FLATTEN_DISTANCE, d)
	var h := lerpf(border_height, _base_height, flat) - 0.12 * (1.0 - flat)
	var amplitude := undulation * (0.5 + 3.5 * smoothstep(20.0, 250.0, d)) * flat
	return h + _noise.get_noise_2dv(p) * amplitude

func _build_ground_mesh(heights: PackedFloat32Array, resolution: int, world_size: float) -> ArrayMesh:
	var rings: Array = RINGS.duplicate()
	rings.append([maxf(radius - _half, 600.0), 8])
	var points: Array[PackedVector3Array] = []
	var tints: Array[PackedColorArray] = []
	for r in rings.size():
		var d: float = rings[r][0]
		var divider: int = rings[r][1]
		var per_side := _per_side / divider
		var count := per_side * 4
		var ring := PackedVector3Array()
		var tint := PackedColorArray()
		ring.resize(count)
		tint.resize(count)
		for i in count:
			var p := _ring_point(i, d, per_side)
			var border := i * divider
			var h: float
			if d < 0.0:
				h = TerrainSampler.uncarved_height_in(heights, resolution, world_size, p) - 0.3
			elif r == rings.size() - 1:
				h = _base_height - 30.0  # falls away under the skyline
			else:
				h = _surface_height(_border[border], d, p)
			ring[i] = Vector3(p.x, h, p.y)
			tint[i] = _ground_color_at(ring[i], d, _border_colors[border])
		points.append(ring)
		tints.append(tint)

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	for r in points.size() - 1:
		var inner := points[r]
		var outer := points[r + 1]
		var inner_tint := tints[r]
		var outer_tint := tints[r + 1]
		var a := inner.size()
		var b := outer.size()
		var m := a / b  # inner segments per outer segment (1 or 2)
		for j in b:
			var o0 := outer[j]
			var o1 := outer[(j + 1) % b]
			for t in m:
				var i0 := j * m + t
				var i1 := (i0 + 1) % a
				_add_tri(vertices, normals, colors, o0, inner[i0], inner[i1], (outer_tint[j] + inner_tint[i0] + inner_tint[i1]) / 3.0)
			var last := (j * m + m) % a
			_add_tri(vertices, normals, colors, o0, inner[last], o1, (outer_tint[j] + inner_tint[last] + outer_tint[(j + 1) % b]) / 3.0)
	for h in hills:
		_add_hill(vertices, normals, colors, h)
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## One flat-shaded triangle facing up (or `outward`), in one colour.
func _add_tri(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray,
		a: Vector3, b: Vector3, c: Vector3, color: Color, outward := Vector3.ZERO) -> void:
	# Godot front faces are clockwise: normal = (c - a) x (b - a).
	var normal := (c - a).cross(b - a)
	if normal.length_squared() < 1e-10:
		return
	var facing := outward if outward != Vector3.ZERO else Vector3.UP
	if normal.dot(facing) < 0.0:
		var swap := b
		b = c
		c = swap
		normal = -normal
	normal = normal.normalized()
	# Small per-face jitter keeps the facets readable.
	var centre := (a + b + c) / 3.0
	var jitter := 1.0 + 0.04 * sin(centre.x * 12.9898 + centre.z * 78.233)
	color = Color(color.r * jitter, color.g * jitter, color.b * jitter)
	for v in [a, b, c]:
		vertices.append(v)
		normals.append(normal)
		colors.append(color)

## A distant hill: a flat-topped laterite mesa (most of them) or a rounded
## grassy hill, on the skyline outside the map.
func _add_hill(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray, index: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([horizon_seed, index, "hill"])
	var angle := TAU * (float(index) + rng.randf_range(0.15, 0.85)) / float(maxi(hills, 1))
	var size := rng.randf_range(25.0, 75.0)
	# Between the map and the last flat ring (the ground falls away after it).
	var near := _half * 1.42 + size + 110.0
	var far := maxf(_half + float(RINGS[-1][0]) - size, near + 10.0)
	var distance := rng.randf_range(near, far)
	var centre := Vector2(cos(angle), sin(angle)) * distance
	var mesa := rng.randf() < 0.65
	var height := rng.randf_range(6.0, 18.0) if mesa else rng.randf_range(10.0, 30.0)
	var base := _base_height - 4.0  # below the undulations
	var sides := 9
	# Rings: [radius factor, height factor] from the foot to the top.
	var profile: Array = [[1.35, 0.0], [1.0, 0.3], [0.72, 1.0]] if mesa else [[1.0, 0.0], [0.72, 0.55], [0.38, 0.9]]
	var cliff := Color(_patch.r * 0.78, _patch.g * 0.72, _patch.b * 0.7)
	var rings: Array[PackedVector3Array] = []
	for k in profile.size():
		var ring := PackedVector3Array()
		for s in sides:
			var a := TAU * float(s) / float(sides) + rng.randf_range(-0.12, 0.12)
			var r: float = size * profile[k][0] * rng.randf_range(0.88, 1.1)
			var y: float = base + height * profile[k][1] + (rng.randf_range(-0.6, 0.6) if k > 0 else 0.0)
			ring.append(Vector3(centre.x + cos(a) * r, y, centre.y + sin(a) * r))
		rings.append(ring)
	for k in rings.size() - 1:
		var colour := _ground.lerp(_patch, 0.35) if k == 0 else (cliff if mesa else _ground.lerp(_green, 0.25))
		for s in sides:
			var t := (s + 1) % sides
			var mid := (rings[k][s] + rings[k + 1][t]) * 0.5
			var outward := Vector3(mid.x - centre.x, 0.0, mid.z - centre.y)
			_add_tri(vertices, normals, colors, rings[k][s], rings[k + 1][s], rings[k + 1][t], colour, outward + Vector3.UP * size * 0.2)
			_add_tri(vertices, normals, colors, rings[k][s], rings[k + 1][t], rings[k][t], colour, outward + Vector3.UP * size * 0.2)
	var top := rings[-1]
	var peak := Vector3(centre.x, base + height * (1.02 if mesa else 1.0), centre.y)
	var top_colour := _ground if mesa else _ground.lerp(_green, 0.35)
	for s in sides:
		_add_tri(vertices, normals, colors, top[s], top[(s + 1) % sides], peak, top_colour)

# -----------------------------------------------------------------------------
# Trees and walls
# -----------------------------------------------------------------------------

func _add_trees() -> void:
	if trees <= 0:
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([horizon_seed, "trees"])
	# Trees grouped in TREE_CELLS x TREE_CELLS cells, one MultiMesh per cell and
	# kind: a MultiMesh is culled as a whole, so one big ring of trees would be
	# drawn (and drawn again in every shadow cascade) wherever the camera looks.
	var acacias: Dictionary = {}
	var baobabs: Dictionary = {}
	var reach := _half + TREE_BAND
	var cell_size := 2.0 * reach / float(TREE_CELLS)
	var placed := 0
	var tries := 0
	while placed < trees and tries < trees * 20:
		tries += 1
		var p := Vector2(rng.randf_range(-reach, reach), rng.randf_range(-reach, reach))
		var d := maxf(absf(p.x), absf(p.y)) - _half
		if d < 4.0:
			continue
		# Matching border point: the closest point of the square border.
		var edge := Vector2(clampf(p.x, -_half, _half), clampf(p.y, -_half, _half))
		var h := _surface_height(_border[_border_index(edge)], d, p) - 0.35
		var baobab := rng.randf() < 0.13
		var scale := rng.randf_range(5.0, 7.5) if baobab else rng.randf_range(3.5, 6.0)
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(scale, scale * rng.randf_range(0.85, 1.15), scale))
		var cell := Vector2i(
			clampi(int((p.x + reach) / cell_size), 0, TREE_CELLS - 1),
			clampi(int((p.y + reach) / cell_size), 0, TREE_CELLS - 1))
		var group: Dictionary = baobabs if baobab else acacias
		if not group.has(cell):
			var list: Array[Transform3D] = []
			group[cell] = list
		group[cell].append(Transform3D(basis, Vector3(p.x, h, p.y)))
		placed += 1
	for cell: Vector2i in acacias:
		_add_multimesh("Acacias_%d_%d" % [cell.x, cell.y], DetailMeshes.ACACIA, acacias[cell], rng)
	for cell: Vector2i in baobabs:
		_add_multimesh("Baobabs_%d_%d" % [cell.x, cell.y], DetailMeshes.BAOBAB, baobabs[cell], rng)

func _add_multimesh(node_name: String, mesh_index: int, transforms: Array[Transform3D], rng: RandomNumberGenerator) -> void:
	if transforms.is_empty():
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.use_colors = true
	multimesh.mesh = DetailMeshes.builtin(mesh_index)
	multimesh.instance_count = transforms.size()
	for i in transforms.size():
		multimesh.set_instance_transform(i, transforms[i])
		var shade := rng.randf_range(0.9, 1.05)
		multimesh.set_instance_color(i, Color(shade, shade, shade))
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = multimesh
	# Same look as the terrain's details: its Detail Material when one is set.
	var custom: Material = null
	if get_parent() != null:
		custom = MaterialFactory.TerrainBiome.of(get_parent()).detail_material
	node.material_override = custom if custom else MaterialFactory.detail_material(MaterialFactory.wind_profile(mesh_index))
	add_child(node)

func _add_walls() -> void:
	var body := StaticBody3D.new()
	body.name = "BoundaryWalls"
	var thickness := 1.0
	var height := 400.0
	for side in 4:
		var shape := BoxShape3D.new()
		var along := _half * 2.0 + thickness * 2.0
		shape.size = Vector3(along, height, thickness) if side % 2 == 0 else Vector3(thickness, height, along)
		var collision := CollisionShape3D.new()
		collision.shape = shape
		var offset := _half + thickness * 0.5
		match side:
			0:
				collision.position = Vector3(0.0, _base_height, -offset)
			1:
				collision.position = Vector3(offset, _base_height, 0.0)
			2:
				collision.position = Vector3(0.0, _base_height, offset)
			_:
				collision.position = Vector3(-offset, _base_height, 0.0)
		body.add_child(collision)
	add_child(body)
