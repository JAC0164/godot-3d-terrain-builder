@tool
extends RefCounted
## Creation, defaults/migration and basic queries on terrain metadata.

const Meta = preload("terrain_meta.gd")
const GridMath = preload("grid_math.gd")
const StylePalette = preload("../styles/style_palette.gd")
const TerrainBiome = preload("../biomes/terrain_biome.gd")
const FeatureStyle = preload("../styles/feature_style.gd")
const WaterholeStyle = preload("../styles/waterhole_style.gd")

## Every terrain setting with its value on a new terrain. initialize() writes
## them all; ensure_defaults() adds the ones a scene is missing (made before
## the setting existed).
const SETTING_DEFAULTS := {
	Meta.BASE_Y: Meta.DEFAULT_BASE_Y,
	Meta.HEIGHT_MIN: Meta.DEFAULT_HEIGHT_MIN,
	Meta.HEIGHT_MAX: Meta.DEFAULT_HEIGHT_MAX,
	Meta.TOP_Y_OFFSET: 0.0,
	Meta.CLIFF_Y_OFFSET: 0.0,
	Meta.FEATURE_Y_OFFSET: 0.0,
	Meta.DOUBLE_SIDED: false,
	Meta.BRUSH_TOP_COLOR: Meta.DEFAULT_TOP_COLOR,
	Meta.BRUSH_CLIFF_COLOR: Meta.DEFAULT_CLIFF_COLOR,
	Meta.BRUSH_TOP_TEXTURE: null,
	Meta.BRUSH_CLIFF_TEXTURE: null,
	Meta.BRUSH_TOP_TILE_SIZE: Meta.DEFAULT_TILE_SIZE,
	Meta.BRUSH_CLIFF_TILE_SIZE: Meta.DEFAULT_TILE_SIZE,
	Meta.COLLISION_ENABLED: false,
	Meta.COLLISION_LAYER: 1,
	Meta.AUTO_EXPAND: true,
	Meta.EXPAND_CHUNK: Meta.DEFAULT_EXPAND_CHUNK,
	Meta.MAX_RESOLUTION: Meta.DEFAULT_MAX_RESOLUTION,
	Meta.GENERATOR_RAISE_HEIGHT: Meta.DEFAULT_GENERATOR_RAISE_HEIGHT,
	Meta.GENERATOR_LOWER_DEPTH: Meta.DEFAULT_GENERATOR_LOWER_DEPTH,
	Meta.GENERATOR_SMOOTHNESS: 0.0,
	Meta.GENERATOR_CLEAR_FEATURES: true,
	Meta.GENERATOR_USE_SINGLE_STYLE: true,
	Meta.ROAD_WIDTH: Meta.DEFAULT_ROAD_WIDTH,
	Meta.ROAD_Y_OFFSET: Meta.DEFAULT_ROAD_Y_OFFSET,
	Meta.ROAD_COLLISION: true,
	Meta.RIVER_WIDTH: Meta.DEFAULT_RIVER_WIDTH,
	Meta.RIVER_DEPTH: Meta.DEFAULT_RIVER_DEPTH,
	Meta.RIVER_SURFACE_DROP: Meta.DEFAULT_RIVER_SURFACE_DROP,
	Meta.RIVER_COLLISION: false,
}

## Writes a fresh, empty terrain dataset onto `terrain`.
static func initialize(terrain: Node3D) -> void:
	var resolution := Meta.DEFAULT_RESOLUTION

	var mask := PackedFloat32Array()
	mask.resize(resolution * resolution)
	mask.fill(0.0)

	var heights := PackedFloat32Array()
	heights.resize(resolution * resolution)
	heights.fill(0.0)

	terrain.set_meta(Meta.MARKER, true)
	terrain.set_meta(Meta.RESOLUTION, resolution)
	terrain.set_meta(Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	terrain.set_meta(Meta.MASK, mask)
	terrain.set_meta(Meta.HEIGHTS, heights)
	terrain.set_meta(Meta.ROADS, [])
	terrain.set_meta(Meta.RIVERS, [])
	for key: String in SETTING_DEFAULTS:
		terrain.set_meta(key, SETTING_DEFAULTS[key])
	StylePalette.copy_current_paint_to_generator_styles(terrain)
	terrain.set_meta(Meta.STYLE_PALETTE, [StylePalette.make_default_style()])
	var cell_styles := PackedInt32Array()
	cell_styles.resize((resolution - 1) * (resolution - 1))
	cell_styles.fill(-1)
	terrain.set_meta(Meta.CELL_STYLES, cell_styles)
	var cell_active := PackedByteArray()
	cell_active.resize((resolution - 1) * (resolution - 1))
	cell_active.fill(0)
	terrain.set_meta(Meta.CELL_ACTIVE, cell_active)
	terrain.set_meta(Meta.WINDING_VERSION, Meta.CURRENT_WINDING_VERSION)
	ensure_defaults(terrain)

## Fills in every missing setting and migrates data written by older versions.
## Safe to call repeatedly (it runs each time a terrain is selected).
static func ensure_defaults(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return

	# Metadata is exposed in the Inspector so each terrain can be tuned independently.
	# These values are also serialized by Godot with the scene.
	for key: String in SETTING_DEFAULTS:
		if not terrain.has_meta(key):
			terrain.set_meta(key, SETTING_DEFAULTS[key])
	StylePalette.ensure_generator_style_defaults(terrain)
	for shade_key: String in SHADE_DEFAULTS:
		if not terrain.has_meta(shade_key): terrain.set_meta(shade_key, SHADE_DEFAULTS[shade_key])
	migrate_look(terrain)
	migrate_feature_look(terrain)
	migrate_waterhole_shape(terrain)
	# Per-kind densities now live in the biome's detail layers.
	for legacy_key: String in [Meta.LEGACY_DETAIL_GRASS_DENSITY, Meta.LEGACY_DETAIL_ROCK_DENSITY, Meta.LEGACY_LEVEL_PATH, Meta.LEGACY_GENERATOR_COLOR_TOLERANCE]:
		if terrain.has_meta(legacy_key): terrain.remove_meta(legacy_key)
	StylePalette.ensure_material_data(terrain)
	StylePalette.sync_with_biome(terrain)

	if not terrain.has_meta(Meta.CELL_ACTIVE):
		var migrate_resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
		var migrate_mask: PackedFloat32Array = terrain.get_meta(Meta.MASK, PackedFloat32Array())
		var migrate_cells := PackedByteArray()
		migrate_cells.resize(maxi(0, (migrate_resolution - 1) * (migrate_resolution - 1)))
		migrate_cells.fill(0)
		if migrate_mask.size() == migrate_resolution * migrate_resolution:
			for z in range(migrate_resolution - 1):
				for x in range(migrate_resolution - 1):
					migrate_cells[GridMath.cell_index(x, z, migrate_resolution)] = 1 if GridMath.cell_active_for_mask(migrate_mask, x, z, migrate_resolution) else 0
		terrain.set_meta(Meta.CELL_ACTIVE, migrate_cells)

	# One-time migration from the earlier workaround. Back-face culling is the
	# correct default now that every generated triangle has deterministic winding.
	var winding_version: int = Meta.get_int(terrain, Meta.WINDING_VERSION, 0)
	if winding_version < Meta.CURRENT_WINDING_VERSION:
		terrain.set_meta(Meta.DOUBLE_SIDED, false)
		terrain.set_meta(Meta.WINDING_VERSION, Meta.CURRENT_WINDING_VERSION)

# -----------------------------------------------------------------------------
# Queries
# -----------------------------------------------------------------------------

static func height_min(terrain: Node3D) -> float:
	return Meta.get_float(terrain, Meta.HEIGHT_MIN, Meta.DEFAULT_HEIGHT_MIN)

static func height_max(terrain: Node3D) -> float:
	return Meta.get_float(terrain, Meta.HEIGHT_MAX, Meta.DEFAULT_HEIGHT_MAX)

## Whether a cell is painted. Uses the explicit cell flags when present and
## falls back to the vertex mask for terrains created before they existed.
static func cell_active(terrain: Node3D, x: int, z: int) -> bool:
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	if x < 0 or z < 0 or x >= resolution - 1 or z >= resolution - 1:
		return false
	if terrain.has_meta(Meta.CELL_ACTIVE):
		var cells: PackedByteArray = terrain.get_meta(Meta.CELL_ACTIVE)
		var index: int = GridMath.cell_index(x, z, resolution)
		if index >= 0 and index < cells.size():
			return cells[index] != 0
	var mask: PackedFloat32Array = terrain.get_meta(Meta.MASK)
	return GridMath.cell_active_for_mask(mask, x, z, resolution)

## Re-clamps every height into the current [min, max] limits.
static func clamp_heights_to_limits(terrain: Node3D) -> void:
	var min_height := height_min(terrain)
	var max_height := height_max(terrain)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS, PackedFloat32Array())
	for i in range(heights.size()):
		heights[i] = clampf(heights[i], min_height, max_height)
	terrain.set_meta(Meta.HEIGHTS, heights)

## String that changes whenever a setting affecting generated geometry changes.
## Used to detect Inspector edits made outside the plugin's own controls.
static func tuning_signature(terrain: Node3D) -> String:
	return "%s|%s|%s|%s|%s|%s|%s|%s|%s" % [
		terrain.get_meta(Meta.BASE_Y, Meta.DEFAULT_BASE_Y),
		terrain.get_meta(Meta.HEIGHT_MIN, Meta.DEFAULT_HEIGHT_MIN),
		terrain.get_meta(Meta.HEIGHT_MAX, Meta.DEFAULT_HEIGHT_MAX),
		terrain.get_meta(Meta.TOP_Y_OFFSET, 0.0),
		terrain.get_meta(Meta.CLIFF_Y_OFFSET, 0.0),
		terrain.get_meta(Meta.FEATURE_Y_OFFSET, 0.0),
		terrain.get_meta(Meta.DOUBLE_SIDED, false),
		terrain.get_meta(Meta.COLLISION_ENABLED, false),
		terrain.get_meta(Meta.COLLISION_LAYER, 1),
	] + "|%s|%s" % [terrain.get_meta(Meta.DETAIL_SEED, 0), terrain.get_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_NOTHING)] + _shade_signature(terrain)

## Terrain-level look settings (the baked shading itself is in the biome)
## and detail scatter (mesh/detail_scatter.gd) settings with their defaults.
const SHADE_DEFAULTS := {
	Meta.SHADE_SMOOTH: Meta.DEFAULT_SHADE_SMOOTH,
	Meta.DETAIL_ENABLED: Meta.DEFAULT_DETAIL_ENABLED,
	Meta.DETAILS_EVERYWHERE: Meta.DEFAULT_DETAILS_EVERYWHERE,
	Meta.DETAIL_DENSITY: Meta.DEFAULT_DETAIL_DENSITY,
	Meta.DETAIL_SCALE: Meta.DEFAULT_DETAIL_SCALE,
	Meta.DETAIL_DRAW_DISTANCE: Meta.DEFAULT_DETAIL_DRAW_DISTANCE,
}

static func _shade_signature(terrain: Node3D) -> String:
	var parts: PackedStringArray = []
	for shade_key: String in SHADE_DEFAULTS:
		parts.append(str(terrain.get_meta(shade_key, SHADE_DEFAULTS[shade_key])))
	# Assigning another biome rebuilds; edits inside a biome are watched by
	# the plugin (Resource.changed) instead.
	var biome: Variant = Meta.get_optional(terrain, Meta.BIOME)
	if biome is Object:
		var biome_object: Object = biome
		parts.append(str(biome_object.get_instance_id()))
	else:
		parts.append("-")
	return "|" + "|".join(parts)

## Old scenes kept a copy of the biome's shading and waterhole colors on the
## terrain (and colors in each waterhole). The biome is now the only source:
## those copies are removed. When they differ from the biome (hand-tuned
## terrain), the terrain first gets its own copy of the biome holding them,
## so it looks exactly the same. Returns true when the terrain changed.
static func migrate_look(terrain: Node3D) -> bool:
	var legacy := {}
	for key: String in TerrainBiome.LEGACY_LOOK_KEYS:
		if terrain.has_meta(key):
			legacy[key] = terrain.get_meta(key)
	var holes: Array = terrain.get_meta(Meta.WATERHOLES, [])
	var hole_colors := {}
	for hole: Variant in holes:
		if typeof(hole) != TYPE_DICTIONARY:
			continue
		var hole_dict: Dictionary = hole
		if hole_dict.has("clay_color"):
			hole_colors = {"_lte_waterhole_clay_color": hole_dict["clay_color"], "_lte_waterhole_crack_color": hole_dict.get("crack_color", hole_dict["clay_color"])}
			break
	if legacy.is_empty() and hole_colors.is_empty():
		return false
	# Existing waterholes show what the player sees: their colors win over
	# the setting for the next ones.
	legacy.merge(hole_colors, true)
	var biome: TerrainBiome = TerrainBiome.of(terrain)
	var differs := false
	for key: String in legacy:
		var look_property: String = TerrainBiome.LEGACY_LOOK_KEYS[key]
		var current: Variant = biome.get(look_property)
		if not _same_value(legacy[key], current):
			differs = true
			break
	if differs:
		var own: TerrainBiome = biome.duplicate(true)
		own.name = "%s (%s)" % [biome.name, terrain.name]
		for key: String in legacy:
			var property: String = TerrainBiome.LEGACY_LOOK_KEYS[key]
			var value: Variant = legacy[key]
			if property == "blend":
				var blend: int = value
				own.set(property, blend)
			else:
				own.set(property, value)
		terrain.set_meta(Meta.BIOME, own)
	for key: String in TerrainBiome.LEGACY_LOOK_KEYS:
		if terrain.has_meta(key):
			terrain.remove_meta(key)
	if not hole_colors.is_empty():
		var cleaned: Array = []
		for hole: Variant in holes:
			var copy: Variant = hole
			if typeof(hole) == TYPE_DICTIONARY:
				var hole_dict: Dictionary = hole
				copy = hole_dict.duplicate(true)
			if typeof(copy) == TYPE_DICTIONARY:
				var copy_dict: Dictionary = copy
				for field: String in ["clay_color", "crack_color"]:
					copy_dict.erase(field)
			cleaned.append(copy)
		terrain.set_meta(Meta.WATERHOLES, cleaned)
	return true

## Terrain settings that held the look of the next road / river (moved to
## the biome: Road Color, Road Material, Water Color, Water Material).
const LEGACY_FEATURE_LOOK_KEYS: Array[String] = [
	"_lte_road_color", "_lte_road_texture", "_lte_road_tile_size",
	"_lte_river_color", "_lte_river_texture", "_lte_river_normal_texture", "_lte_river_tile_size",
	"_lte_river_roughness", "_lte_river_normal_strength", "_lte_river_refraction",
	"_lte_river_flow_speed", "_lte_river_flow_angle",
]

## Roads / rivers used to keep a copy of their look (color, texture, water
## settings) and the terrain the look of the next ones. The biome holds it
## now: a road / river with the biome's look drops its copy (it follows the
## biome from then on); one with another look keeps it, so it looks the same.
## The terrain settings are removed (new roads / rivers take the biome's
## look). Returns true when the terrain changed.
static func migrate_feature_look(terrain: Node3D) -> bool:
	var changed := false
	for key: String in LEGACY_FEATURE_LOOK_KEYS:
		if terrain.has_meta(key):
			terrain.remove_meta(key)
			changed = true
	var biome: TerrainBiome = TerrainBiome.of(terrain)
	for feature_type: String in [FeatureStyle.ROAD, FeatureStyle.RIVER]:
		var key := FeatureStyle.features_key(feature_type)
		var features: Array = terrain.get_meta(key, [])
		var cleaned: Array = []
		var list_changed := false
		for feature_variant: Variant in features:
			if typeof(feature_variant) == TYPE_DICTIONARY:
				var feature: Dictionary = feature_variant
				if not FeatureStyle.follows_biome(feature) and _feature_has_biome_look(feature, feature_type, biome):
					var copy: Dictionary = feature.duplicate(true)
					for field: String in FeatureStyle.look_fields(feature_type):
						copy.erase(field)
					cleaned.append(copy)
					list_changed = true
					continue
			cleaned.append(feature_variant)
		if list_changed:
			terrain.set_meta(key, cleaned)
			changed = true
	return changed

## The waterhole shape (Flat Floor, Irregularity, Rim Width, Rim Lip, Crack
## Width, Plate Curl) moved from the terrain settings to the biome
## (WaterholeStyle.SHAPE). The settings are removed (new waterholes take the
## biome's shape). A stored waterhole drops each shape field equal to the
## biome's (it follows the biome from then on) and keeps the others, so it
## looks the same. Returns true when the terrain changed.
static func migrate_waterhole_shape(terrain: Node3D) -> bool:
	var changed := false
	for field: String in WaterholeStyle.SHAPE:
		var key := WaterholeStyle.setting_key(field)
		if terrain.has_meta(key):
			terrain.remove_meta(key)
			changed = true
	var holes: Array = terrain.get_meta(Meta.WATERHOLES, [])
	var biome: TerrainBiome = TerrainBiome.of(terrain)
	var cleaned: Array = []
	var list_changed := false
	for hole: Variant in holes:
		if typeof(hole) != TYPE_DICTIONARY:
			cleaned.append(hole)
			continue
		var hole_dict: Dictionary = hole
		var copy: Dictionary = hole_dict.duplicate(true)
		for field: String in WaterholeStyle.SHAPE:
			var property: String = WaterholeStyle.SHAPE[field]
			if copy.has(field) and _same_value(copy[field], biome.get(property)):
				copy.erase(field)
				list_changed = true
		cleaned.append(copy)
	if list_changed:
		terrain.set_meta(Meta.WATERHOLES, cleaned)
		changed = true
	return changed

static func _feature_has_biome_look(feature: Dictionary, feature_type: String, biome: TerrainBiome) -> bool:
	var color: Color = feature.get("color", Color.BLACK)
	if feature.get("texture", null) != null:
		return false
	if feature_type == FeatureStyle.ROAD:
		return biome.road_material == null and color.is_equal_approx(biome.road_color)
	if biome.water_material != null or not color.is_equal_approx(biome.water_color) or feature.get("normal_texture", null) != null:
		return false
	var defaults := {
		"tile_size": Meta.DEFAULT_RIVER_TILE_SIZE,
		"roughness": Meta.DEFAULT_RIVER_ROUGHNESS,
		"normal_strength": Meta.DEFAULT_RIVER_NORMAL_STRENGTH,
		"refraction": Meta.DEFAULT_RIVER_REFRACTION,
		"flow_speed": Meta.DEFAULT_RIVER_FLOW_SPEED,
		"flow_angle": Meta.DEFAULT_RIVER_FLOW_ANGLE,
	}
	for field: String in defaults:
		if not _same_value(feature.get(field, defaults[field]), defaults[field]):
			return false
	return true

static func _same_value(a: Variant, b: Variant) -> bool:
	if a is Color and b is Color:
		var color_a: Color = a
		var color_b: Color = b
		return color_a.is_equal_approx(color_b)
	if typeof(a) in [TYPE_INT, TYPE_FLOAT] and typeof(b) in [TYPE_INT, TYPE_FLOAT]:
		var float_a: float = a
		var float_b: float = b
		return is_equal_approx(float_a, float_b)
	return a == b
