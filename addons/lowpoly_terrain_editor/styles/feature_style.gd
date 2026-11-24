@tool
extends RefCounted
## Road / river feature dictionaries.
##
## A committed feature is a Dictionary holding its own style (width, colour,
## texture...) plus "points": Array of Vector2 in terrain-local X/Z space.

const Meta = preload("../core/terrain_meta.gd")
const StylePalette = preload("style_palette.gd")

const ROAD := "road"
const RIVER := "river"

static func features_key(feature_type: String) -> String:
	return Meta.ROADS if feature_type == ROAD else Meta.RIVERS

## Returns a copy of the feature with every missing style field filled in.
static func migrate(feature_variant: Variant, feature_type: String) -> Dictionary:
	var feature: Dictionary = {}
	if typeof(feature_variant) == TYPE_DICTIONARY:
		var source: Dictionary = feature_variant
		feature = source.duplicate(true)
	if feature_type == ROAD:
		if not feature.has("width"): feature["width"] = Meta.DEFAULT_ROAD_WIDTH
		if not feature.has("y_offset"): feature["y_offset"] = Meta.DEFAULT_ROAD_Y_OFFSET
		if not feature.has("color"): feature["color"] = Meta.DEFAULT_ROAD_COLOR
		if not feature.has("texture"): feature["texture"] = null
		if not feature.has("tile_size"): feature["tile_size"] = Meta.DEFAULT_ROAD_TILE_SIZE
		if not feature.has("collision"): feature["collision"] = true
	else:
		if not feature.has("width"): feature["width"] = Meta.DEFAULT_RIVER_WIDTH
		if not feature.has("depth"): feature["depth"] = Meta.DEFAULT_RIVER_DEPTH
		if not feature.has("surface_drop"): feature["surface_drop"] = Meta.DEFAULT_RIVER_SURFACE_DROP
		if not feature.has("color"): feature["color"] = Meta.DEFAULT_RIVER_COLOR
		if not feature.has("texture"): feature["texture"] = null
		if not feature.has("normal_texture"): feature["normal_texture"] = null
		if not feature.has("tile_size"): feature["tile_size"] = Meta.DEFAULT_RIVER_TILE_SIZE
		if not feature.has("roughness"): feature["roughness"] = Meta.DEFAULT_RIVER_ROUGHNESS
		if not feature.has("normal_strength"): feature["normal_strength"] = Meta.DEFAULT_RIVER_NORMAL_STRENGTH
		if not feature.has("refraction"): feature["refraction"] = Meta.DEFAULT_RIVER_REFRACTION
		if not feature.has("flow_speed"): feature["flow_speed"] = Meta.DEFAULT_RIVER_FLOW_SPEED
		if not feature.has("flow_angle"): feature["flow_angle"] = Meta.DEFAULT_RIVER_FLOW_ANGLE
		if not feature.has("collision"): feature["collision"] = false
	return feature

## Style dictionary (without points) built from the terrain's current
## Roads, Rivers & Waterholes settings.
static func from_terrain_settings(terrain: Node3D, feature_type: String) -> Dictionary:
	if feature_type == ROAD:
		return {
			"width": Meta.get_float(terrain, Meta.ROAD_WIDTH, Meta.DEFAULT_ROAD_WIDTH),
			"y_offset": Meta.get_float(terrain, Meta.ROAD_Y_OFFSET, Meta.DEFAULT_ROAD_Y_OFFSET),
			"color": terrain.get_meta(Meta.ROAD_COLOR, Meta.DEFAULT_ROAD_COLOR),
			"texture": StylePalette.as_texture(Meta.get_optional(terrain, Meta.ROAD_TEXTURE)),
			"tile_size": Meta.get_float(terrain, Meta.ROAD_TILE_SIZE, Meta.DEFAULT_ROAD_TILE_SIZE),
			"collision": Meta.get_bool(terrain, Meta.ROAD_COLLISION, true),
		}
	return {
		"width": Meta.get_float(terrain, Meta.RIVER_WIDTH, Meta.DEFAULT_RIVER_WIDTH),
		"depth": Meta.get_float(terrain, Meta.RIVER_DEPTH, Meta.DEFAULT_RIVER_DEPTH),
		"surface_drop": Meta.get_float(terrain, Meta.RIVER_SURFACE_DROP, Meta.DEFAULT_RIVER_SURFACE_DROP),
		"color": terrain.get_meta(Meta.RIVER_COLOR, Meta.DEFAULT_RIVER_COLOR),
		"texture": StylePalette.as_texture(Meta.get_optional(terrain, Meta.RIVER_TEXTURE)),
		"normal_texture": StylePalette.as_texture(Meta.get_optional(terrain, Meta.RIVER_NORMAL_TEXTURE)),
		"tile_size": Meta.get_float(terrain, Meta.RIVER_TILE_SIZE, Meta.DEFAULT_RIVER_TILE_SIZE),
		"roughness": Meta.get_float(terrain, Meta.RIVER_ROUGHNESS, Meta.DEFAULT_RIVER_ROUGHNESS),
		"normal_strength": Meta.get_float(terrain, Meta.RIVER_NORMAL_STRENGTH, Meta.DEFAULT_RIVER_NORMAL_STRENGTH),
		"refraction": Meta.get_float(terrain, Meta.RIVER_REFRACTION, Meta.DEFAULT_RIVER_REFRACTION),
		"flow_speed": Meta.get_float(terrain, Meta.RIVER_FLOW_SPEED, Meta.DEFAULT_RIVER_FLOW_SPEED),
		"flow_angle": Meta.get_float(terrain, Meta.RIVER_FLOW_ANGLE, Meta.DEFAULT_RIVER_FLOW_ANGLE),
		"collision": Meta.get_bool(terrain, Meta.RIVER_COLLISION, false),
	}

## Appends a new feature with the current settings. Ignores strokes with fewer
## than two points. Returns true when a feature was added.
static func commit(terrain: Node3D, feature_type: String, points: Array[Vector2]) -> bool:
	if points.size() < 2:
		return false
	var key := features_key(feature_type)
	var stored: Array = terrain.get_meta(key, [])
	var features: Array = stored.duplicate(true)
	var feature := from_terrain_settings(terrain, feature_type)
	feature["points"] = points.duplicate()
	features.append(feature)
	terrain.set_meta(key, features)
	return true

## Uncommitted feature used for the live stroke preview, or {} if too short.
static func make_preview(terrain: Node3D, feature_type: String, points: Array[Vector2]) -> Dictionary:
	if points.size() < 2:
		return {}
	var feature := from_terrain_settings(terrain, feature_type)
	feature["type"] = feature_type
	feature["preview"] = true
	feature["points"] = points.duplicate()
	return feature
