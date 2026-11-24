@tool
extends RefCounted
## Hit-testing and erasing of committed roads / rivers / waterholes.

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const WaterholeStyle = preload("../styles/waterhole_style.gd")

## True when a brush at `point` touches any road or river, or the point is
## inside a waterhole basin.
static func has_feature_at(terrain: Node3D, point: Vector2, brush_radius: float) -> bool:
	if WaterholeStyle.find_at(terrain, point) >= 0:
		return true
	for road: Dictionary in terrain.get_meta(Meta.ROADS, []):
		var points: Array = road.get("points", [])
		var width: float = road.get("width", Meta.DEFAULT_ROAD_WIDTH)
		var half_width: float = width * 0.5
		if GridMath.distance_to_polyline(point, points) <= brush_radius + half_width:
			return true

	for river: Dictionary in terrain.get_meta(Meta.RIVERS, []):
		var points: Array = river.get("points", [])
		var width: float = river.get("width", Meta.DEFAULT_RIVER_WIDTH)
		var half_width: float = width * 0.5
		if GridMath.distance_to_polyline(point, points) <= brush_radius + half_width:
			return true

	return false

## What erasing at `point` would change: {"rect": Rect2 (terrain-local X/Z),
## "rivers": bool}, or null when the brush touches no road / river. The rect
## covers the removed points and the segments around them, or the whole
## feature when it is dropped (see erase_segments), padded by its width.
static func erase_area(terrain: Node3D, point: Vector2, brush_radius: float) -> Variant:
	var area := Rect2()
	var found := false
	var rivers := false
	for entry: Array in [[Meta.ROADS, Meta.DEFAULT_ROAD_WIDTH, false], [Meta.RIVERS, Meta.DEFAULT_RIVER_WIDTH, true]]:
		var key: String = entry[0]
		var default_width: float = entry[1]
		var is_river: bool = entry[2]
		for feature_variant: Variant in terrain.get_meta(key, []):
			var feature: Dictionary = feature_variant
			var points: Array = feature.get("points", [])
			if points.size() < 2:
				continue
			var width: float = feature.get("width", default_width)
			var erase_distance := brush_radius + width * 0.5
			if GridMath.distance_to_polyline(point, points) > erase_distance:
				continue
			var rect := Rect2()
			var hit := false
			for i in points.size():
				var p: Vector2 = points[i]
				if p.distance_to(point) > erase_distance:
					continue
				for j in range(maxi(i - 1, 0), mini(i + 2, points.size())):
					var neighbour: Vector2 = points[j]
					rect = rect.expand(neighbour) if hit else Rect2(neighbour, Vector2.ZERO)
					hit = true
			if not hit:
				# Only a segment crosses the brush: the whole feature goes.
				rect = feature_bounds(feature, default_width)
			rect = rect.grow(maxf(width * 0.75, 0.5))
			area = area.merge(rect) if found else rect
			found = true
			rivers = rivers or is_river
	if not found:
		return null
	return {"rect": area, "rivers": rivers}

## Cuts the brush area out of every road and river. Returns true on change.
static func erase_at(terrain: Node3D, point: Vector2, brush_radius: float) -> bool:
	var changed := false

	# A waterhole is erased whole when the brush centre is inside its basin;
	# roads / rivers crossing it are left alone by that sample.
	var hole_index := WaterholeStyle.find_at(terrain, point)
	if hole_index >= 0:
		var holes: Array = WaterholeStyle.list(terrain).duplicate(true)
		holes.remove_at(hole_index)
		terrain.set_meta(Meta.WATERHOLES, holes)
		return true

	var roads: Array = terrain.get_meta(Meta.ROADS, [])
	var road_result := erase_segments(roads, point, brush_radius, Meta.DEFAULT_ROAD_WIDTH)
	var roads_changed: bool = road_result["changed"]
	if roads_changed:
		terrain.set_meta(Meta.ROADS, road_result["features"])
		changed = true

	var rivers: Array = terrain.get_meta(Meta.RIVERS, [])
	var river_result := erase_segments(rivers, point, brush_radius, Meta.DEFAULT_RIVER_WIDTH)
	var rivers_changed: bool = river_result["changed"]
	if rivers_changed:
		terrain.set_meta(Meta.RIVERS, river_result["features"])
		changed = true

	return changed

## Removes the points near `point` and splits features into the remaining
## runs of two or more points. Returns {"features": Array, "changed": bool}.
static func erase_segments(features: Array, point: Vector2, brush_radius: float, default_width: float) -> Dictionary:
	var output: Array = []
	var any_changed := false

	for source_feature: Variant in features:
		var feature: Dictionary = source_feature
		var points: Array = feature.get("points", [])
		if points.size() < 2:
			output.append(feature.duplicate(true))
			continue

		var feature_width: float = feature.get("width", default_width)
		var erase_distance: float = brush_radius + feature_width * 0.5
		var feature_changed := false
		var fragments: Array = []
		var run: Array[Vector2] = []

		for raw_point: Variant in points:
			var path_point: Vector2 = raw_point
			if path_point.distance_to(point) <= erase_distance:
				feature_changed = true
				if run.size() >= 2:
					var fragment: Dictionary = feature.duplicate(true)
					fragment["points"] = run.duplicate()
					fragments.append(fragment)
				run.clear()
			else:
				run.append(path_point)

		if run.size() >= 2:
			var fragment: Dictionary = feature.duplicate(true)
			fragment["points"] = run.duplicate()
			fragments.append(fragment)

		# Feature points are sampled densely, but also test the actual segments.
		# If a segment crosses the erase brush between samples, treat the feature
		# as hit; removing the stroke beats leaving a thin bridge across the gap.
		if not feature_changed and GridMath.distance_to_polyline(point, points) <= erase_distance:
			feature_changed = true
			fragments.clear()

		if feature_changed:
			any_changed = true
			output.append_array(fragments)
		else:
			output.append(feature.duplicate(true))

	return {
		"features": output,
		"changed": any_changed,
	}

## Bounding rectangle of a feature, padded by its width.
static func feature_bounds(feature: Dictionary, default_width: float) -> Rect2:
	var points: Array = feature.get("points", [])
	if points.is_empty():
		return Rect2()

	var first: Vector2 = points[0]
	var min_x := first.x
	var max_x := first.x
	var min_z := first.y
	var max_z := first.y
	for raw_point: Variant in points:
		var p: Vector2 = raw_point
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)

	var width: float = feature.get("width", default_width)
	var margin := maxf(width * 0.75, 0.5)
	return Rect2(
		Vector2(min_x - margin, min_z - margin),
		Vector2(max_x - min_x + margin * 2.0, max_z - min_z + margin * 2.0)
	)

## True when a road / river passes through `rect` (segment by segment, padded
## by its width: the bounds of a whole winding road would cover most of the
## map and rebuild the road mesh after almost every stroke).
static func any_feature_intersects(terrain: Node3D, rect: Rect2) -> bool:
	for entry: Array in [[Meta.ROADS, Meta.DEFAULT_ROAD_WIDTH], [Meta.RIVERS, Meta.DEFAULT_RIVER_WIDTH]]:
		var key: String = entry[0]
		var default_width: float = entry[1]
		for feature_variant: Variant in terrain.get_meta(key, []):
			var feature: Dictionary = feature_variant
			var points: Array = feature.get("points", [])
			if points.is_empty():
				continue
			var width: float = feature.get("width", default_width)
			var area := rect.grow(maxf(width * 0.75, 0.5))
			if not feature_bounds(feature, default_width).intersects(area):
				continue
			if points.size() == 1:
				var only_point: Vector2 = points[0]
				if area.has_point(only_point):
					return true
				continue
			for i in range(points.size() - 1):
				var a: Vector2 = points[i]
				var b: Vector2 = points[i + 1]
				if Rect2(a, Vector2.ZERO).expand(b).intersects(area, true):
					return true
	return false
