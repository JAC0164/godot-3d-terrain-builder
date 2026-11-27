@tool
extends RefCounted
## Metadata keys, node names and default values shared by every module.
##
## The editable terrain is a plain Node3D. All of its semantic data lives in
## metadata under the keys below; generated meshes are disposable children.

# -----------------------------------------------------------------------------
# Metadata keys
# -----------------------------------------------------------------------------

const MARKER := "_lowpoly_terrain"
const RESOLUTION := "_lte_resolution"
const WORLD_SIZE := "_lte_world_size"
const MASK := "_lte_mask"
const HEIGHTS := "_lte_heights"
const ROADS := "_lte_roads"
const RIVERS := "_lte_rivers"
## Dried waterholes (styles/waterhole_style.gd); their style settings use
## the "_lte_waterhole_<field>" keys.
const WATERHOLES := "_lte_waterholes"
## Old Level JSON export path (the export was removed); removed by ensure_defaults().
const LEGACY_LEVEL_PATH := "_lte_level_path"
const BASE_Y := "_lte_base_y"
const HEIGHT_MIN := "_lte_height_min"
const HEIGHT_MAX := "_lte_height_max"
const TOP_Y_OFFSET := "_lte_top_y_offset"
const CLIFF_Y_OFFSET := "_lte_cliff_y_offset"
const FEATURE_Y_OFFSET := "_lte_feature_y_offset"
const DOUBLE_SIDED := "_lte_double_sided"
const TOP_NORMAL_UP_BIAS := "_lte_top_normal_up_bias"
const WINDING_VERSION := "_lte_winding_version"
const STYLE_PALETTE := "_lte_style_palette"
const CELL_STYLES := "_lte_cell_styles"
const CELL_ACTIVE := "_lte_cell_active"
## Vegetation brush paint: Dictionary {target: PackedByteArray}, one byte per
## cell = density multiplier value / VEGETATION_NORMAL (0 = none,
## VEGETATION_NORMAL = biome density, 255 = x4 for dense layers .. x25 for
## sparse ones, see DetailScatter.PAINTED_DENSITY). Target VEGETATION_ALL = every
## layer that follows the brush (DetailLayer.vegetation_brush); a layer name =
## that layer only (any layer, rocks too). Both multiply. Absent target (or
## another size) = every cell normal; a target back to all normal is removed.
## Target VEGETATION_GROW (not a brush target) = cells where the biome grows
## by itself when DETAILS_EVERYWHERE is off: 1 = grows, 0 = bare.
const CELL_VEGETATION := "_lte_cell_vegetation"
const VEGETATION_NORMAL := 64
const VEGETATION_ALL := ""
const VEGETATION_GROW := "#grow"

const BRUSH_TOP_COLOR := "_lte_brush_top_color"
const BRUSH_CLIFF_COLOR := "_lte_brush_cliff_color"
const BRUSH_TOP_TEXTURE := "_lte_brush_top_texture"
const BRUSH_CLIFF_TEXTURE := "_lte_brush_cliff_texture"
const BRUSH_TOP_TILE_SIZE := "_lte_brush_top_tile_size"
const BRUSH_CLIFF_TILE_SIZE := "_lte_brush_cliff_tile_size"

const COLLISION_ENABLED := "_lte_collision_enabled"
const COLLISION_LAYER := "_lte_collision_layer"

const AUTO_EXPAND := "_lte_auto_expand"
const EXPAND_CHUNK := "_lte_expand_chunk"
const MAX_RESOLUTION := "_lte_max_resolution"

const GENERATOR_IMAGE := "_lte_generator_image"
const GENERATOR_RAISE_HEIGHT := "_lte_generator_raise_height"
const GENERATOR_LOWER_DEPTH := "_lte_generator_lower_depth"
const GENERATOR_COLOR_TOLERANCE := "_lte_generator_color_tolerance"
const GENERATOR_CLEAR_FEATURES := "_lte_generator_clear_features"
const GENERATOR_USE_SINGLE_STYLE := "_lte_generator_use_single_style"
const GENERATOR_SMOOTHNESS := "_lte_generator_smoothness"

## Per-colour generator style keys follow this pattern; see generator_style_key().
const GENERATOR_STYLE_KEY_FORMAT := "_lte_generator_%s_%s"
const GENERATOR_PREFIXES := ["green", "red", "blue"]

const ROAD_WIDTH := "_lte_road_width"
const ROAD_Y_OFFSET := "_lte_road_y_offset"
const ROAD_COLOR := "_lte_road_color"
const ROAD_TEXTURE := "_lte_road_texture"
const ROAD_TILE_SIZE := "_lte_road_tile_size"
const ROAD_COLLISION := "_lte_road_collision"

const RIVER_WIDTH := "_lte_river_width"
const RIVER_DEPTH := "_lte_river_depth"
const RIVER_SURFACE_DROP := "_lte_river_surface_drop"
const RIVER_COLOR := "_lte_river_color"
const RIVER_TEXTURE := "_lte_river_texture"
const RIVER_NORMAL_TEXTURE := "_lte_river_normal_texture"
const RIVER_TILE_SIZE := "_lte_river_tile_size"
const RIVER_ROUGHNESS := "_lte_river_roughness"
const RIVER_NORMAL_STRENGTH := "_lte_river_normal_strength"
const RIVER_REFRACTION := "_lte_river_refraction"
const RIVER_FLOW_SPEED := "_lte_river_flow_speed"
const RIVER_FLOW_ANGLE := "_lte_river_flow_angle"
const RIVER_COLLISION := "_lte_river_collision"
## Terrain-wide: every river uses the water shader without screen refraction
## (phones always do, MaterialFactory.phone_water).
const RIVER_MOBILE_WATER := "_lte_river_mobile_water"
## Terrain-wide: the ground chunks cast sun shadows (hills shade the plain).
## Off = cheaper on phones (trees, rocks and props keep their shadows).
const GROUND_SHADOWS := "_lte_ground_shadows"

## Baked terrain shading (mesh/terrain_shading.gd). All 0 = flat style colours.
const SHADE_BLEND := "_lte_shade_blend"
const SHADE_BLEND_NOISE := "_lte_shade_blend_noise"
const SHADE_SLOPE := "_lte_shade_slope"
const SHADE_SLOPE_START := "_lte_shade_slope_start"
const SHADE_SLOPE_END := "_lte_shade_slope_end"
const SHADE_AO := "_lte_shade_ao"
const SHADE_VARIATION := "_lte_shade_variation"
const SHADE_CLIFF_DARKEN := "_lte_shade_cliff_darken"
const SHADE_CLIFF_LIP := "_lte_shade_cliff_lip"
## Ground tops shaded smoothly: normals and baked colours per vertex, shared by
## the neighbouring triangles (no visible triangle pattern). Off = one normal
## and one colour per triangle (faceted low-poly look). Cliffs stay faceted.
const SHADE_SMOOTH := "_lte_shade_smooth"
## Height (m) of the small bumps written in the ground (core/ground_bumps.gd,
## Inspector > Look > Ground Bumps). 0 = none (scenes made before it).
const GROUND_BUMPS := "_lte_ground_bumps"

## Scattered details (mesh/detail_scatter.gd).
const DETAIL_ENABLED := "_lte_detail_enabled"
## On: the biome's details grow on every ground cell by themselves (scenes
## made before this setting). Off (new terrains): only on the cells Generate
## Map made (CELL_VEGETATION[VEGETATION_GROW]) and where the Vegetation brush
## painted more; ground painted by hand stays bare.
const DETAILS_EVERYWHERE := "_lte_details_everywhere"
## Multiplier on the density of every biome detail layer.
const DETAIL_DENSITY := "_lte_detail_density"
## Replaced by DETAIL_DENSITY + biome layers; removed by ensure_defaults().
const LEGACY_DETAIL_GRASS_DENSITY := "_lte_detail_grass_density"
const LEGACY_DETAIL_ROCK_DENSITY := "_lte_detail_rock_density"
## LowpolyTerrainBiome resource (biomes/terrain_biome.gd); none = Temperate.
const BIOME := "_lte_biome"
## Custom Materials (none = the built-in ones), for the game's own look
## (toon, unshaded, palette...):
##   GROUND_MATERIAL replaces the vertex-colour material of the untextured
##   ground, cliffs and waterholes (COLOR = style colour x baked shading;
##   flat or smooth normals as built). Textured styles keep their texture.
##   DETAIL_MATERIAL replaces the material of every detail layer except custom
##   meshes with Use Mesh Materials (COLOR = mesh colour x instance colour).
##   The built-in wind is part of the built-in material: a custom one has none
##   unless its shader moves the vertices itself.
const GROUND_MATERIAL := "_lte_ground_material"
const DETAIL_MATERIAL := "_lte_detail_material"
const DETAIL_SCALE := "_lte_detail_scale"
## Added to every layer's placement seed: same map, other vegetation.
const DETAIL_SEED := "_lte_detail_seed"
## What the scene file stores vs what LowpolyTerrainRuntime rebuilds when the
## scene is loaded (RuntimeBuild below).
const RUNTIME_BUILD := "_lte_runtime_build"
## Last map recipe / seed used by the Map Generator (Inspector).
const MAP_RECIPE := "_lte_map_recipe"
const MAP_SEED := "_lte_map_seed"
const DETAIL_DRAW_DISTANCE := "_lte_detail_draw_distance"

const CURRENT_WINDING_VERSION := 2

# -----------------------------------------------------------------------------
# Generated child node names
# -----------------------------------------------------------------------------

## Holds the road/river mesh (historical name kept for scene compatibility).
const GENERATED_MESH_NAME := "_GeneratedTerrainMesh"
const GENERATED_CHUNKS_NAME := "_GeneratedTerrainChunks"
const GENERATED_PREVIEW_MESH_NAME := "_GeneratedTerrainFeaturePreview"
const GENERATED_WATERHOLES_NAME := "_GeneratedWaterholes"
## Runtime companion node (runtime/terrain_runtime.gd), saved with the scene.
const RUNTIME_NODE_NAME := "_LowpolyTerrainRuntime"
## Trunk / mound collision shapes of the detail layers, built in game only.
const DETAIL_COLLISION_NAME := "_DetailCollision"
## Shadow-only child of each ground chunk (MeshUtils.back_face_caster): the
## chunk itself casts no shadow.
const GROUND_SHADOW_NAME := "_GroundShadow"

## RUNTIME_BUILD values.
const RUNTIME_BUILD_NOTHING := 0   ## everything saved in the scene (default)
const RUNTIME_BUILD_DETAILS := 1   ## details rebuilt when the scene loads
const RUNTIME_BUILD_ALL := 2       ## meshes, collision and details rebuilt
const GENERATED_COLLISION_BODY_NAME := "_GeneratedTerrainCollision"
## The single whole-map shape of older scenes (now one per chunk, see
## TerrainBuilder.rebuild_collision): removed at the next rebuild.
const GENERATED_COLLISION_SHAPE_NAME := "_GeneratedTerrainCollisionShape"

const TERRAIN_CHUNK_CELLS := 32

# -----------------------------------------------------------------------------
# Defaults
# -----------------------------------------------------------------------------

const DEFAULT_RESOLUTION := 48
const DEFAULT_WORLD_SIZE := 48.0
const DEFAULT_BASE_Y := -3.0
const DEFAULT_HEIGHT_MIN := -3.0
const DEFAULT_HEIGHT_MAX := 32.0

const DEFAULT_TOP_COLOR := Color(0.44, 0.69, 0.20)
const DEFAULT_CLIFF_COLOR := Color(0.45, 0.25, 0.13)
const DEFAULT_TILE_SIZE := 4.0

const DEFAULT_EXPAND_CHUNK := 8
const DEFAULT_MAX_RESOLUTION := 256

const DEFAULT_GENERATOR_RAISE_HEIGHT := 2.0
const DEFAULT_GENERATOR_LOWER_DEPTH := 1.0
const DEFAULT_GENERATOR_COLOR_TOLERANCE := 0.08
## New terrains historically start with a looser tolerance than the fallback.
const NEW_TERRAIN_GENERATOR_COLOR_TOLERANCE := 0.2

const DEFAULT_ROAD_WIDTH := 2.6
const DEFAULT_ROAD_Y_OFFSET := 0.035
const DEFAULT_ROAD_COLOR := Color(0.76, 0.56, 0.31)
const DEFAULT_ROAD_TILE_SIZE := 4.0

const DEFAULT_RIVER_WIDTH := 3.3
const DEFAULT_RIVER_DEPTH := 0.65
const DEFAULT_RIVER_SURFACE_DROP := 0.15
const DEFAULT_RIVER_COLOR := Color(0.12, 0.38, 0.55, 0.72)
const DEFAULT_RIVER_TILE_SIZE := 6.0
const DEFAULT_RIVER_ROUGHNESS := 0.18
const DEFAULT_RIVER_NORMAL_STRENGTH := 0.8
const DEFAULT_RIVER_REFRACTION := 0.012
const DEFAULT_RIVER_FLOW_SPEED := 0.03
const DEFAULT_RIVER_FLOW_ANGLE := 32.211

const DEFAULT_SHADE_BLEND := 1
const DEFAULT_SHADE_BLEND_NOISE := 0.6
const DEFAULT_SHADE_SLOPE := 0.75
const DEFAULT_SHADE_SLOPE_START := 30.0
const DEFAULT_SHADE_SLOPE_END := 50.0
const DEFAULT_SHADE_AO := 0.5
const DEFAULT_SHADE_VARIATION := 0.05
const DEFAULT_SHADE_MACRO := 0.2
const DEFAULT_SHADE_CLIFF_DARKEN := 0.35
const DEFAULT_SHADE_CLIFF_LIP := 0.2
const DEFAULT_SHADE_SMOOTH := true
const DEFAULT_GROUND_BUMPS := 0.0

const DEFAULT_DETAIL_ENABLED := true
const DEFAULT_DETAILS_EVERYWHERE := true
const DEFAULT_DETAIL_DENSITY := 1.0
const DEFAULT_DETAIL_SCALE := 1.0
const DEFAULT_DETAIL_DRAW_DISTANCE := 70.0

# -----------------------------------------------------------------------------
# Feature geometry tuning
# -----------------------------------------------------------------------------

const ROAD_SAMPLE_SPACING := 0.45
## Fixed cell size (m) the road margins are measured in (when roads touch,
## how far the edge sits out). Not the road mesh grid: that is
## RoadMesher.union_cell_size(), which follows the terrain.
const ROAD_NOMINAL_CELL := 0.45
## Largest cell of the road mesh grid (RoadMesher.union_cell_size): the
## terrain's own cells, split in n x n when the terrain spacing is larger.
const ROAD_UNION_MAX_CELL := 1.0
const ROAD_UNION_EDGE_PADDING := 0.32
## Minimum distance between two recorded points of a road/river stroke.
const FEATURE_SAMPLE_DISTANCE := 0.65


# -----------------------------------------------------------------------------
# Accessors
# -----------------------------------------------------------------------------

static func is_terrain(object: Object) -> bool:
	return object is Node3D and object.has_meta(MARKER) and get_bool(object, MARKER)

## Godot treats null metadata as absent metadata. Calling get_meta() for an
## absent optional texture can print an editor error, so always guard it.
static func get_optional(object: Object, key: StringName) -> Variant:
	return object.get_meta(key) if object.has_meta(key) else null

## Typed reads of a metadata value (`default` when absent), in place of
## float(object.get_meta(...)) & co: the typed assignment converts an int /
## float / bool value exactly like those constructors, and the result is
## statically typed.
static func get_float(object: Object, key: StringName, default: float = 0.0) -> float:
	var value: float = object.get_meta(key, default)
	return value

static func get_int(object: Object, key: StringName, default: int = 0) -> int:
	var value: int = object.get_meta(key, default)
	return value

static func get_bool(object: Object, key: StringName, default: bool = false) -> bool:
	var value: bool = object.get_meta(key, default)
	return value

## Vegetation paint of a freshly generated map: the biome grows on every
## ground cell it made, nowhere else (see VEGETATION_GROW).
static func generated_vegetation(cell_active: PackedByteArray) -> Dictionary:
	var grow := PackedByteArray()
	grow.resize(cell_active.size())
	for i in cell_active.size():
		grow[i] = 1 if cell_active[i] != 0 else 0
	return {VEGETATION_GROW: grow}

## The Vegetation brush paint (see CELL_VEGETATION), {} when none.
static func vegetation_paint(terrain: Object) -> Dictionary:
	var value: Variant = terrain.get_meta(CELL_VEGETATION, {})
	return value if value is Dictionary else {}

## Sets a metadata value, or removes the key when the value is null.
static func set_optional(object: Object, key: StringName, value: Variant) -> void:
	if value == null:
		if object.has_meta(key):
			object.remove_meta(key)
	else:
		object.set_meta(key, value)

static func generator_style_key(prefix: String, field: String) -> String:
	return GENERATOR_STYLE_KEY_FORMAT % [prefix, field]
