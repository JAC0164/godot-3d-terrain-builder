@tool
extends RefCounted
## Built-in low-poly detail meshes (LowpolyDetailLayer.builtin_mesh).
##
## The shapes are modelled in Blender (tools/blender/lte_props.py, from photo
## references of the Senegal savanna) and stored as plain data in
## detail_mesh_data.gd; this file turns them into flat-shaded ArrayMeshes.
##
## Sizes are in cell units (1 = one terrain cell): the scatter scales them by
## the cell spacing x the layer size. Small ground details (tufts, stones) are
## modelled at their real size in cells; props (shrub, trees, termite mound,
## skull) are about 1 unit tall, so the layer's Scale is their height in cells.
##
## Opaque, untextured, flat normals, vertex colours darkened towards the
## ground. Tufts and stones are grey and take the instance colour; props carry
## their own colours (bark, leaves, bone) and are meant for ColorMode.FIXED
## with a white tint (the termite mound is grey: tint it with the soil colour).
## Thin parts (grass blades) have an upward normal and are emitted with both
## windings (any back-face-culled material shows them from both sides), or
## once with `one_sided_thin` for the two-sided grass wind material
## (materials/detail_wind_two_sided.gdshader keeps the upward normal on back
## faces): half the triangles. Every mesh is generated once and cached.

const MeshData = preload("detail_mesh_data.gd")

const NONE := 0
const GRASS_TUFT := 1
const ROCK := 2
const DRY_GRASS_TUFT := 3
const PEBBLES := 4
const SHRUB := 5
const ACACIA := 6
const BAOBAB := 7
const TERMITE_MOUND := 8
const ZEBU_SKULL := 9
const DEAD_TREE := 10

const _DATA_KEYS := {
	GRASS_TUFT: "grass_tuft",
	ROCK: "rock",
	DRY_GRASS_TUFT: "dry_grass_tuft",
	PEBBLES: "pebbles",
	SHRUB: "shrub",
	ACACIA: "acacia",
	BAOBAB: "baobab",
	TERMITE_MOUND: "termite_mound",
	ZEBU_SKULL: "zebu_skull",
	DEAD_TREE: "dead_tree",
}

static var _cache: Dictionary = {}

## Shared mesh for a built-in index, or null for NONE / unknown.
## `one_sided_thin`: thin parts once (for a two-sided material only).
static func builtin(index: int, one_sided_thin: bool = false) -> Mesh:
	var key := Vector2i(index, int(one_sided_thin))
	if _cache.has(key):
		return _cache[key]
	var mesh: Mesh = null
	if _DATA_KEYS.has(index) and MeshData.PROPS.has(_DATA_KEYS[index]):
		var data: Dictionary = MeshData.PROPS[_DATA_KEYS[index]]
		mesh = build(data, one_sided_thin)
	if mesh != null:
		_cache[key] = mesh
	return mesh

## True if the built-in mesh has thin parts (grass blades).
static func has_thin_parts(index: int) -> bool:
	if not (_DATA_KEYS.has(index) and MeshData.PROPS.has(_DATA_KEYS[index])):
		return false
	var thin: Array = MeshData.PROPS[_DATA_KEYS[index]]["thin"]
	return not thin.is_empty()

## Flat-shaded mesh from one DetailMeshData entry.
static func build(data: Dictionary, one_sided_thin: bool = false) -> ArrayMesh:
	var palette: Array = data["pal"]
	var points: Array = data["v"]
	var triangles: Array = data["t"]
	var thin := {}
	for i: int in data["thin"]:
		thin[i] = true
	var ao: Array = data["ao"]
	var ao_min: float = ao[0]
	var ao_top: float = ao[1]
	var ao_height := maxf(ao_top, 0.001)
	var jitter: float = data["jit"]

	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var colors := PackedColorArray()
	var count := triangles.size() / 4
	for t in range(count):
		var k := t * 4
		var ia: int = triangles[k]
		var a := _point(points, ia)
		var ib: int = triangles[k + 1]
		var b := _point(points, ib)
		var ic: int = triangles[k + 2]
		var c := _point(points, ic)
		var palette_index: int = triangles[k + 3]
		var p := palette_index * 3
		# Small per-face shade variation, the faceted low-poly look.
		var noise := absf(fmod(sin(float(t) * 78.233 + 1.7) * 43758.5453, 1.0))
		var pr: float = palette[p]
		var pg: float = palette[p + 1]
		var pb: float = palette[p + 2]
		var base := Color(pr, pg, pb) * (1.0 + jitter * (noise * 2.0 - 1.0))
		var ca := _shade(base, a.y, ao_min, ao_height)
		var cb := _shade(base, b.y, ao_min, ao_height)
		var cc := _shade(base, c.y, ao_min, ao_height)
		if thin.has(t) and one_sided_thin:
			vertices.append_array([a, b, c])
			normals.append_array([Vector3.UP, Vector3.UP, Vector3.UP])
			colors.append_array([ca, cb, cc])
		elif thin.has(t):
			vertices.append_array([a, b, c, a, c, b])
			for i in range(6):
				normals.append(Vector3.UP)
			colors.append_array([ca, cb, cc, ca, cc, cb])
		else:
			# Godot front faces are clockwise seen from outside.
			var n := (c - a).cross(b - a).normalized()
			vertices.append_array([a, b, c])
			normals.append_array([n, n, n])
			colors.append_array([ca, cb, cc])
	return _mesh(vertices, normals, colors)

static func _point(points: Array, index: int) -> Vector3:
	var x: float = points[index * 3]
	var y: float = points[index * 3 + 1]
	var z: float = points[index * 3 + 2]
	return Vector3(x, y, z)

## Darker near the ground (cheap baked occlusion), full colour above ao_height.
static func _shade(base: Color, y: float, ao_min: float, ao_height: float) -> Color:
	var f := lerpf(ao_min, 1.0, clampf(y / ao_height, 0.0, 1.0))
	return Color(minf(base.r * f, 1.0), minf(base.g * f, 1.0), minf(base.b * f, 1.0), 1.0)

static func _mesh(vertices: PackedVector3Array, normals: PackedVector3Array, colors: PackedColorArray) -> ArrayMesh:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_COLOR] = colors
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
