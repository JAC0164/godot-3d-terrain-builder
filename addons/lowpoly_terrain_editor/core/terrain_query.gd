@tool
class_name LowpolyTerrainQuery
extends RefCounted
## Questions about the ground of a Lowpoly terrain: height, facet normal,
## ground style, ray hit, without physics. Answers match the drawn triangles
## exactly (each cell split along its (0,0)-(1,1) diagonal, river beds
## carved). Positions are global.
##
## Made from a copy of the terrain data (LowpolyTerrainRuntime.get_query()):
## once made it never touches the scene, so it can be used from a worker
## thread. It does not follow later edits: ask the runtime for a new one.
## The copy is a plain memory copy of the arrays (a few ms on a 1 024 map),
## the river carve is applied when asked.
## Outside the map or over an empty cell, heights are NAN (is_nan()).
##
## The terrain may be moved, turned around Y and scaled; not tilted.

const Meta = preload("terrain_meta.gd")

var _resolution := 0
var _world_size := 0.0
var _spacing := 1.0
var _half := 0.0
## Sculpted level of each grid vertex (drawn height = level - carve + top offset).
var _heights := PackedFloat32Array()
## River / waterhole carve per vertex, empty = none (_carved false).
var _carve := PackedFloat32Array()
var _carved := false
var _top_offset := 0.0
## Cell flags (1 = ground), empty = every cell.
var _active := PackedByteArray()
var _styles := PackedInt32Array()
## Palette style id -> its biome ground style name ("" = a custom style).
var _style_names: Array[StringName] = []
var _transform := Transform3D.IDENTITY
var _inverse := Transform3D.IDENTITY
var _normal_basis := Basis.IDENTITY
var _local_range := Vector2.ZERO
## _local_range is found on the first get_height_range() (a pass over every
## vertex: not paid by games that never ask).
var _range_ready := false

## A query over `terrain`'s current data. `carve`: the river / waterhole
## carve (TerrainBuilder.get_river_carve), empty = none.
static func from_terrain(terrain: Node3D, carve: PackedFloat32Array = PackedFloat32Array()) -> LowpolyTerrainQuery:
	var query := LowpolyTerrainQuery.new()
	query._resolution = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	query._world_size = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	query._spacing = query._world_size / float(maxi(query._resolution - 1, 1))
	query._half = query._world_size * 0.5
	# duplicate(): packed arrays are shared by reference and the edits write
	# into the terrain's ones. The carve is not copied: TerrainBuilder only
	# ever replaces its cached carve with a new array, never writes into it.
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS, PackedFloat32Array())
	query._heights = heights.duplicate()
	query._top_offset = Meta.get_float(terrain, Meta.TOP_Y_OFFSET, 0.0)
	query._carved = carve.size() == query._heights.size() and not carve.is_empty()
	query._carve = carve if query._carved else PackedFloat32Array()
	var active: PackedByteArray = terrain.get_meta(Meta.CELL_ACTIVE, PackedByteArray())
	query._active = active.duplicate()
	var styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES, PackedInt32Array())
	query._styles = styles.duplicate()
	var palette: Array = terrain.get_meta(Meta.STYLE_PALETTE, [])
	for style: Variant in palette:
		var name := ""
		if style is Dictionary:
			var entry: Dictionary = style
			name = str(entry.get("biome_style", ""))
		query._style_names.append(StringName(name))
	query.set_transform(terrain.global_transform if terrain.is_inside_tree() else terrain.transform)
	return query

## The terrain's global transform (it moved): no data copied again.
func set_transform(global_transform: Transform3D) -> void:
	_transform = global_transform
	_inverse = global_transform.affine_inverse()
	_normal_basis = global_transform.basis.inverse().transposed()

func get_transform() -> Transform3D:
	return _transform

## Global Y of the ground under `global_position` (its X / Z), NAN outside
## the map or over an empty cell.
func get_height(global_position: Vector3) -> float:
	var local := _inverse * global_position
	var h := _local_height(local.x, local.z)
	if is_nan(h):
		return NAN
	return (_transform * Vector3(local.x, h, local.z)).y

## True when there is ground under `global_position`.
func is_on_terrain(global_position: Vector3) -> bool:
	var local := _inverse * global_position
	return _cell(local.x, local.z) >= 0

## Normal (global, pointing up) of the ground facet under `global_position`,
## Vector3(NAN, NAN, NAN) where there is no ground.
func get_normal(global_position: Vector3) -> Vector3:
	var local := _inverse * global_position
	var cell := _cell(local.x, local.z)
	if cell < 0:
		return Vector3(NAN, NAN, NAN)
	var x0 := cell % (_resolution - 1)
	var z0 := cell / (_resolution - 1)
	var gx := (local.x + _half) / _spacing - float(x0)
	var gz := (local.z + _half) / _spacing - float(z0)
	var a := _vertex(x0, z0)
	var b := _vertex(x0 + 1, z0 + 1)
	var c := _vertex(x0 + 1, z0) if gx >= gz else _vertex(x0, z0 + 1)
	var normal := (b - a).cross(c - a)
	if normal.y < 0.0:
		normal = -normal
	normal = (_normal_basis * normal).normalized()
	return normal if normal.y >= 0.0 else -normal

## Palette style id of the ground under `global_position` (painted style,
## see the Inspector's Ground Styles), -1 where there is no ground.
func get_ground_style(global_position: Vector3) -> int:
	var local := _inverse * global_position
	var cell := _cell(local.x, local.z)
	if cell < 0 or cell >= _styles.size():
		return -1
	return _styles[cell]

## Name of the biome ground style under `global_position` (e.g. &"Grass"),
## &"" where there is no ground or for a custom style.
func get_ground_style_name(global_position: Vector3) -> StringName:
	var style := get_ground_style(global_position)
	if style < 0 or style >= _style_names.size():
		return &""
	return _style_names[style]

## Lowest and highest global Y of the ground grid (x, y).
func get_height_range() -> Vector2:
	if not _range_ready:
		_find_range()
	if is_nan(_local_range.x):
		return _local_range
	var low := (_transform * Vector3(0.0, _local_range.x, 0.0)).y
	var high := (_transform * Vector3(0.0, _local_range.y, 0.0)).y
	return Vector2(minf(low, high), maxf(low, high))

func _find_range() -> void:
	_range_ready = true
	if _heights.is_empty():
		_local_range = Vector2(NAN, NAN)
		return
	var low := INF
	var high := -INF
	for i in _heights.size():
		var h := _heights[i] - (_carve[i] if _carved else 0.0)
		low = minf(low, h)
		high = maxf(high, h)
	_local_range = Vector2(low + _top_offset, high + _top_offset)

## First point where the ray from `from` along `direction` goes down through
## the ground, within `max_distance` m; Vector3(NAN, NAN, NAN) when it does
## not. Marches in half cells, then refines (cm).
func get_intersection(from: Vector3, direction: Vector3, max_distance: float = 1000.0) -> Vector3:
	var none := Vector3(NAN, NAN, NAN)
	if direction.length_squared() == 0.0:
		return none
	var dir := direction.normalized()
	var scale := _transform.basis.get_scale()
	var step := maxf(_spacing * minf(absf(scale.x), absf(scale.z)) * 0.5, 0.05)
	var previous_t := 0.0
	var previous_gap := NAN
	var t := 0.0
	while t <= max_distance:
		var p := from + dir * t
		var h := get_height(p)
		var gap := p.y - h if not is_nan(h) else NAN
		if not is_nan(gap) and gap <= 0.0:
			if t == 0.0:
				return Vector3(p.x, h, p.z)
			if not is_nan(previous_gap):
				return _refine(from, dir, previous_t, t)
			# Came over the edge of the map / a hole below the ground: the
			# side of the terrain, not its top.
		previous_t = t
		previous_gap = gap
		t += step
	return none

## Bisection between a point above the ground (t0) and one below (t1).
func _refine(from: Vector3, dir: Vector3, t0: float, t1: float) -> Vector3:
	for i in 20:
		var mid := (t0 + t1) * 0.5
		var p := from + dir * mid
		var h := get_height(p)
		if is_nan(h) or p.y - h > 0.0:
			t0 = mid
		else:
			t1 = mid
	var hit := from + dir * t1
	var ground := get_height(hit)
	return Vector3(hit.x, ground if not is_nan(ground) else hit.y, hit.z)

## Cell index under terrain-local (x, z), -1 outside or empty.
func _cell(x: float, z: float) -> int:
	if _resolution < 2:
		return -1
	var gx := (x + _half) / _spacing
	var gz := (z + _half) / _spacing
	var last := float(_resolution - 1)
	if gx < 0.0 or gz < 0.0 or gx > last or gz > last:
		return -1
	var cx := mini(int(gx), _resolution - 2)
	var cz := mini(int(gz), _resolution - 2)
	var index := cz * (_resolution - 1) + cx
	if not _active.is_empty() and (index >= _active.size() or _active[index] == 0):
		return -1
	return index

## Drawn height at terrain-local (x, z), NAN without ground.
func _local_height(x: float, z: float) -> float:
	var cell := _cell(x, z)
	if cell < 0:
		return NAN
	var x0 := cell % (_resolution - 1)
	var z0 := cell / (_resolution - 1)
	var tx := clampf((x + _half) / _spacing - float(x0), 0.0, 1.0)
	var tz := clampf((z + _half) / _spacing - float(z0), 0.0, 1.0)
	var row := z0 * _resolution + x0
	var i11 := row + _resolution + 1
	var i_mid := row + 1 if tx >= tz else row + _resolution
	var h00 := _heights[row]
	var h11 := _heights[i11]
	var h_mid := _heights[i_mid]
	if _carved:
		h00 -= _carve[row]
		h11 -= _carve[i11]
		h_mid -= _carve[i_mid]
	if tx >= tz:
		return h00 + tx * (h_mid - h00) + tz * (h11 - h_mid) + _top_offset
	return h00 + tz * (h_mid - h00) + tx * (h11 - h_mid) + _top_offset

func _vertex(x: int, z: int) -> Vector3:
	var i := z * _resolution + x
	var h := _heights[i] - (_carve[i] if _carved else 0.0) + _top_offset
	return Vector3(float(x) * _spacing - _half, h, float(z) * _spacing - _half)
