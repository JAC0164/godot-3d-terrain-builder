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

## Look fields a road / river held before the biome carried its look
## (Road Color, Water...). A feature that still has them (an older scene with
## another look than its biome) keeps its own look; one without them follows
## the biome (follows_biome).
const ROAD_LOOK_FIELDS: Array[String] = ["color", "texture", "tile_size"]
const RIVER_LOOK_FIELDS: Array[String] = ["color", "texture", "normal_texture", "tile_size", "roughness",
	"normal_strength", "refraction", "flow_speed", "flow_angle"]

static func look_fields(feature_type: String) -> Array[String]:
	return ROAD_LOOK_FIELDS if feature_type == ROAD else RIVER_LOOK_FIELDS

## True when the feature takes its look from the terrain's biome.
static func follows_biome(feature: Dictionary) -> bool:
	return not feature.has("color")

## Returns a copy of the feature with every missing field filled in. The look
## fields are filled only for a feature that keeps its own look; one that
## follows the biome gets a UV in meters (tile_size 1).
static func migrate(feature_variant: Variant, feature_type: String) -> Dictionary:
	var feature: Dictionary = {}
	if typeof(feature_variant) == TYPE_DICTIONARY:
		var source: Dictionary = feature_variant
		feature = source.duplicate(true)
	var own_look := not follows_biome(feature)
	if feature_type == ROAD:
		if not feature.has("width"): feature["width"] = Meta.DEFAULT_ROAD_WIDTH
		if not feature.has("y_offset"): feature["y_offset"] = Meta.DEFAULT_ROAD_Y_OFFSET
		if not feature.has("collision"): feature["collision"] = true
		if not feature.has("tile_size"): feature["tile_size"] = Meta.DEFAULT_ROAD_TILE_SIZE if own_look else 1.0
		if own_look:
			if not feature.has("texture"): feature["texture"] = null
	else:
		if not feature.has("width"): feature["width"] = Meta.DEFAULT_RIVER_WIDTH
		if not feature.has("depth"): feature["depth"] = Meta.DEFAULT_RIVER_DEPTH
		if not feature.has("surface_drop"): feature["surface_drop"] = Meta.DEFAULT_RIVER_SURFACE_DROP
		if not feature.has("collision"): feature["collision"] = false
		if not feature.has("tile_size"): feature["tile_size"] = Meta.DEFAULT_RIVER_TILE_SIZE if own_look else 1.0
		if own_look:
			if not feature.has("texture"): feature["texture"] = null
			if not feature.has("normal_texture"): feature["normal_texture"] = null
			if not feature.has("roughness"): feature["roughness"] = Meta.DEFAULT_RIVER_ROUGHNESS
			if not feature.has("normal_strength"): feature["normal_strength"] = Meta.DEFAULT_RIVER_NORMAL_STRENGTH
			if not feature.has("refraction"): feature["refraction"] = Meta.DEFAULT_RIVER_REFRACTION
			if not feature.has("flow_speed"): feature["flow_speed"] = Meta.DEFAULT_RIVER_FLOW_SPEED
			if not feature.has("flow_angle"): feature["flow_angle"] = Meta.DEFAULT_RIVER_FLOW_ANGLE
	return feature

## Style dictionary (without points) of a new road / river: its shape from
## the terrain's Roads, Rivers & Waterholes settings; its look follows the
## biome.
static func from_terrain_settings(terrain: Node3D, feature_type: String) -> Dictionary:
	if feature_type == ROAD:
		return {
			"width": Meta.get_float(terrain, Meta.ROAD_WIDTH, Meta.DEFAULT_ROAD_WIDTH),
			"y_offset": Meta.get_float(terrain, Meta.ROAD_Y_OFFSET, Meta.DEFAULT_ROAD_Y_OFFSET),
			"collision": Meta.get_bool(terrain, Meta.ROAD_COLLISION, true),
		}
	return {
		"width": Meta.get_float(terrain, Meta.RIVER_WIDTH, Meta.DEFAULT_RIVER_WIDTH),
		"depth": Meta.get_float(terrain, Meta.RIVER_DEPTH, Meta.DEFAULT_RIVER_DEPTH),
		"surface_drop": Meta.get_float(terrain, Meta.RIVER_SURFACE_DROP, Meta.DEFAULT_RIVER_SURFACE_DROP),
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
