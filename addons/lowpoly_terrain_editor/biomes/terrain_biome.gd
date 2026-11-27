@tool
class_name LowpolyTerrainBiome
extends Resource
## A reusable terrain look, saved as a .tres and dropped on a terrain:
## - ground styles: one-click brush presets (toolbar list next to the Ground tool);
## - detail layers: what grows / lies on the ground (grass, rocks, shrubs,
##   skulls, trees...), each drawn with one MultiMesh per chunk;
## - baked shading and waterholes (colors and shape), read live by every
##   terrain that uses the biome: editing them here changes those terrains
##   at once;
## - materials and ambience: your own ground / detail / road / water
##   materials and an optional Environment (sky, fog, light) for the game.
## It is the terrain's theme: cells painted with a ground style follow it
## (StylePalette.sync_with_biome), so swapping or editing the biome restyles
## the whole terrain; the ground, roads and collisions do not change.
##
## Terrains without a biome use `default_biome()` ("Temperate"). A biome file
## is shared by every terrain using it; "Copy Biome to This Terrain" (Inspector
## > Look) makes one terrain's look its own.
## Everything here is plain data: duplicate a preset and tweak it per game.

const Meta = preload("../core/terrain_meta.gd")
const DetailLayer = preload("detail_layer.gd")
const GroundStyle = preload("ground_style.gd")
const DetailMeshes = preload("../mesh/detail_meshes.gd")

static var _default: LowpolyTerrainBiome = null

@export var name := "Biome":
	set(value):
		name = value
		emit_changed()
## Brush presets shown in the terrain Inspector.
@export var ground_styles: Array[GroundStyle] = []:
	set(value):
		_watch(ground_styles, false)
		ground_styles = value
		_watch(ground_styles, true)
		emit_changed()
## Scattered details, drawn in this order.
@export var detail_layers: Array[DetailLayer] = []:
	set(value):
		_watch(detail_layers, false)
		detail_layers = value
		_watch(detail_layers, true)
		emit_changed()

@export_group("Baked Shading")
## Painted into the ground colors when the terrain is built (free in the
## game; untextured ground styles only). All 0 = flat style colors.
@export_range(0, 8) var blend := Meta.DEFAULT_SHADE_BLEND:
	set(value):
		blend = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var blend_noise := Meta.DEFAULT_SHADE_BLEND_NOISE:
	set(value):
		blend_noise = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var slope_tint := Meta.DEFAULT_SHADE_SLOPE:
	set(value):
		slope_tint = value
		emit_changed()
@export_range(0.0, 90.0, 0.5) var slope_start := Meta.DEFAULT_SHADE_SLOPE_START:
	set(value):
		slope_start = value
		emit_changed()
@export_range(0.0, 90.0, 0.5) var slope_end := Meta.DEFAULT_SHADE_SLOPE_END:
	set(value):
		slope_end = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var ambient_occlusion := Meta.DEFAULT_SHADE_AO:
	set(value):
		ambient_occlusion = value
		emit_changed()
@export_range(0.0, 0.5, 0.005) var variation := Meta.DEFAULT_SHADE_VARIATION:
	set(value):
		variation = value
		emit_changed()
## Large lighter / darker patches (tens of meters across), lighter ones a bit
## warmer, so bare ground does not read as one flat color.
@export_range(0.0, 0.5, 0.005) var macro_variation := Meta.DEFAULT_SHADE_MACRO:
	set(value):
		macro_variation = value
		emit_changed()
@export_range(0.0, 1.0, 0.01) var cliff_darken := Meta.DEFAULT_SHADE_CLIFF_DARKEN:
	set(value):
		cliff_darken = value
		emit_changed()
@export_range(0.0, 2.0, 0.01) var cliff_lip := Meta.DEFAULT_SHADE_CLIFF_LIP:
	set(value):
		cliff_lip = value
		emit_changed()

@export_group("Waterholes")
## Colors of every dried waterhole of the terrain: the clay of the basin and
## mud plates, and the dark ground seen in the cracks.
@export var waterhole_clay_color := Color(0.6, 0.5, 0.39):
	set(value):
		waterhole_clay_color = value
		emit_changed()
@export var waterhole_crack_color := Color(0.28, 0.21, 0.16):
	set(value):
		waterhole_crack_color = value
		emit_changed()
## Shape of every waterhole of the terrain (WaterholeStyle.SHAPE; one placed
## before the shape moved here keeps its own when it differs). Part of the
## radius that is flat cracked floor; the rest is the bank.
@export_range(0.0, 0.95, 0.01) var waterhole_floor := 0.75:
	set(value):
		waterhole_floor = value
		emit_changed()
## How far the outline wobbles away from a circle.
@export_range(0.0, 0.6, 0.01) var waterhole_irregularity := 0.22:
	set(value):
		waterhole_irregularity = value
		emit_changed()
## Width of the trampled clay ring around the basin, as a part of the radius.
@export_range(0.01, 2.0, 0.01) var waterhole_rim_width := 0.45:
	set(value):
		waterhole_rim_width = value
		emit_changed()
## Height (m) of the small earth bank around the basin.
@export_range(0.0, 1.0, 0.01) var waterhole_rim_lip := 0.1:
	set(value):
		waterhole_rim_lip = value
		emit_changed()
## Average width (m) of the cracks between mud plates.
@export_range(0.0, 1.0, 0.01) var waterhole_crack_width := 0.1:
	set(value):
		waterhole_crack_width = value
		emit_changed()
## How much the plate edges curl up as the mud dries.
@export_range(0.0, 0.5, 0.01) var waterhole_plate_curl := 0.05:
	set(value):
		waterhole_plate_curl = value
		emit_changed()

@export_group("Materials & Ambience")
## Your own material for the whole ground (toon, unshaded, palette...),
## textured styles included. Its shader reads COLOR (style color x baked
## shading); with textured styles it also gets the layer textures and their
## weights, like the built-in one (materials/terrain_splat.gdshader).
## Empty = the built-in matte look.
@export var ground_material: Material:
	set(value):
		ground_material = value
		emit_changed()
## Your own material for every detail layer except custom models / meshes
## that keep their own (COLOR = mesh color x instance color). The built-in
## wind is part of the built-in materials. Empty = built-in.
@export var detail_material: Material:
	set(value):
		detail_material = value
		emit_changed()
## Color of the roads (built-in road material).
@export var road_color := Meta.DEFAULT_ROAD_COLOR:
	set(value):
		road_color = value
		emit_changed()
## Your own road material (texture, shader...). Its UV is in meters, seen
## from above. Empty = Road Color, matte.
@export var road_material: Material:
	set(value):
		road_material = value
		emit_changed()
## Tint and transparency of the water (built-in water).
@export var water_color := Meta.DEFAULT_RIVER_COLOR:
	set(value):
		water_color = value
		emit_changed()
## Your own water material. Inspector > Roads, Rivers & Waterholes >
## Customise Water puts an editable copy of the built-in one here (waves,
## flow, refraction...). Empty = the built-in water with Water Color.
@export var water_material: Material:
	set(value):
		water_material = value
		emit_changed()
## 0 = each ground face lit by its own slope (low-poly look); 1 = all ground
## lit as if flat.
@export_range(0.0, 1.0, 0.05) var flat_top_lighting := 0.0:
	set(value):
		flat_top_lighting = value
		emit_changed()
## Sky, fog, light and glow of the game: the terrain's runtime node adds it
## when the scene has no WorldEnvironment of its own. Empty = none.
@export var environment: Environment:
	set(value):
		environment = value
		emit_changed()

## Waterhole colors, keyed like the old terrain settings (migration).
func waterhole_values() -> Dictionary:
	return {
		"_lte_waterhole_clay_color": waterhole_clay_color,
		"_lte_waterhole_crack_color": waterhole_crack_color,
	}

## Baked shading values, keyed like the old terrain settings (migration).
func shading_values() -> Dictionary:
	return {
		Meta.SHADE_BLEND: blend,
		Meta.SHADE_BLEND_NOISE: blend_noise,
		Meta.SHADE_SLOPE: slope_tint,
		Meta.SHADE_SLOPE_START: slope_start,
		Meta.SHADE_SLOPE_END: slope_end,
		Meta.SHADE_AO: ambient_occlusion,
		Meta.SHADE_VARIATION: variation,
		Meta.SHADE_CLIFF_DARKEN: cliff_darken,
		Meta.SHADE_CLIFF_LIP: cliff_lip,
	}

## Old terrain setting key -> biome property (migration of old scenes).
const LEGACY_LOOK_KEYS := {
	"_lte_shade_blend": "blend",
	"_lte_shade_blend_noise": "blend_noise",
	"_lte_shade_slope": "slope_tint",
	"_lte_shade_slope_start": "slope_start",
	"_lte_shade_slope_end": "slope_end",
	"_lte_shade_ao": "ambient_occlusion",
	"_lte_shade_variation": "variation",
	"_lte_shade_cliff_darken": "cliff_darken",
	"_lte_shade_cliff_lip": "cliff_lip",
	"_lte_waterhole_clay_color": "waterhole_clay_color",
	"_lte_waterhole_crack_color": "waterhole_crack_color",
	"_lte_ground_material": "ground_material",
	"_lte_detail_material": "detail_material",
	"_lte_top_normal_up_bias": "flat_top_lighting",
	"_lte_road_color": "road_color",
	"_lte_river_color": "water_color",
}

## Everything of the biome that is baked into the terrain meshes (shading +
## waterhole colors): when it changes, the terrain is rebuilt, not only its
## details.
func look_signature() -> String:
	var parts: PackedStringArray = []
	for key: String in LEGACY_LOOK_KEYS:
		var property: String = LEGACY_LOOK_KEYS[key]
		parts.append(str(get(property)))
	for property: String in LOOK_PROPERTIES:
		parts.append(str(get(property)))
	# Waterhole shape: the carve (heights, collision) and the plates change.
	for property: String in WATERHOLE_SHAPE_PROPERTIES:
		parts.append(str(get(property)))
	# Painted cells follow their biome ground style (StylePalette.sync_with_biome).
	for style: GroundStyle in ground_styles:
		if style != null:
			parts.append("%s:%s:%s:%s:%s:%s:%s:%s:%s:%s:%s" % [style.name, style.top_color.to_html(), style.side_color.to_html(),
				style.top_texture, style.side_texture, style.top_tile_size, style.side_tile_size,
				style.top_normal, style.top_roughness, style.side_normal, style.side_roughness])
	return "|".join(parts)

## Baked look properties that never were terrain settings (no migration).
const LOOK_PROPERTIES: Array[String] = ["macro_variation", "road_material", "water_material"]
## The waterhole shape (WaterholeStyle.SHAPE; were terrain settings, see
## TerrainData.migrate_waterhole_shape).
const WATERHOLE_SHAPE_PROPERTIES: Array[String] = ["waterhole_floor", "waterhole_irregularity",
	"waterhole_rim_width", "waterhole_rim_lip", "waterhole_crack_width", "waterhole_plate_curl"]

## The biome a terrain uses (its own, else the built-in Temperate).
static func of(terrain: Node) -> LowpolyTerrainBiome:
	var biome: Variant = Meta.get_optional(terrain, Meta.BIOME)
	# Anything else in the Biome slot (a wrong resource) counts as none.
	if biome is LowpolyTerrainBiome:
		var own_biome: LowpolyTerrainBiome = biome
		return own_biome
	return default_biome()

## A sub-resource edit (e.g. a layer's density) re-emits `changed` on the
## biome, so the editor can rebuild the details live.
func _watch(items: Array, connect_items: bool) -> void:
	for item: Resource in items:
		if item == null:
			continue
		var resource := item
		if connect_items and not resource.changed.is_connected(emit_changed):
			resource.changed.connect(emit_changed)
		elif not connect_items and resource.changed.is_connected(emit_changed):
			resource.changed.disconnect(emit_changed)

# -----------------------------------------------------------------------------
# Built-in default
# -----------------------------------------------------------------------------

## The look terrains get without a biome: green grass tufts on gentle ground,
## pebbles on slopes and along cliff edges. Shared, do not modify.
static func default_biome() -> LowpolyTerrainBiome:
	if _default == null:
		_default = make_temperate()
	return _default

static func make_temperate() -> LowpolyTerrainBiome:
	var biome := LowpolyTerrainBiome.new()
	biome.name = "Temperate"
	biome.ground_styles = [
		make_ground("Grass", Meta.DEFAULT_TOP_COLOR, Meta.DEFAULT_CLIFF_COLOR),
		make_ground("Rock", Color(0.48, 0.47, 0.45), Color(0.36, 0.35, 0.34)),
		make_ground("Sand", Color(0.83, 0.74, 0.52), Color(0.62, 0.52, 0.36)),
		make_ground("Snow", Color(0.93, 0.95, 0.98), Color(0.55, 0.57, 0.62)),
	]

	var grass := DetailLayer.new()
	grass.name = "Grass"
	grass.builtin_mesh = 1
	grass.density = 0.5
	grass.ground_filter = DetailLayer.GroundFilter.GREENISH
	grass.slope_max = 34.0
	grass.slope_fade = 16.0
	grass.scale_min = 0.75
	grass.scale_max = 1.25
	grass.height_scale_min = 0.8
	grass.height_scale_max = 1.2
	grass.sink = 0.05
	grass.color_mode = DetailLayer.ColorMode.GROUND
	grass.tint = Color(0.92, 1.06, 0.7)
	grass.brightness_jitter = 0.08

	var rocks := DetailLayer.new()
	rocks.name = "Rocks"
	rocks.builtin_mesh = 2
	rocks.density = 0.021
	rocks.steep_bonus = 7.0
	rocks.edge_bonus = 5.7
	rocks.cell_margin = 0.1
	rocks.scale_min = 0.55
	rocks.scale_max = 1.45
	rocks.small_bias = 2.0
	rocks.height_scale_min = 0.55
	rocks.height_scale_max = 1.0
	rocks.stretch_max = 1.25
	rocks.max_tilt = 14.0
	rocks.sink = 0.25
	rocks.color_mode = DetailLayer.ColorMode.SIDE
	rocks.desaturate = 0.5
	rocks.lighten = 0.12
	rocks.brightness = 0.975
	rocks.brightness_jitter = 0.13

	biome.detail_layers = [grass, rocks]
	return biome

static func make_ground(ground_name: String, top: Color, side: Color) -> GroundStyle:
	var style := GroundStyle.new()
	style.name = ground_name
	style.top_color = top
	style.side_color = side
	return style

## New detail layer with `properties` ({property name: value}) applied.
static func make_layer(layer_name: String, builtin_mesh: int, density: float, properties: Dictionary = {}) -> DetailLayer:
	var layer := DetailLayer.new()
	layer.name = layer_name
	layer.builtin_mesh = builtin_mesh
	layer.density = density
	for property: String in properties:
		layer.set(property, properties[property])
	return layer

# -----------------------------------------------------------------------------
# Senegal savanna (dry season)
# -----------------------------------------------------------------------------

## Sahelian / Sudanian savanna in the dry season: straw-coloured grass,
## laterite (red iron soil) patches and plateaus, scattered shrubs, umbrella
## acacias, a few baobabs, cathedral termite mounds and the odd bleached zebu
## skull. Sizes assume 1 cell ~ 1 m (Size Multiplier rescales everything).
## Ground colours: paint with the biome's ground styles; the layers find them
## by colour (Dry Grass, Green Savanna, Laterite).
static func make_senegal_savanna() -> LowpolyTerrainBiome:
	const FIXED := DetailLayer.ColorMode.FIXED
	const GROUND := DetailLayer.ColorMode.GROUND
	const BY_COLOR := DetailLayer.GroundFilter.COLOR
	var dry_grass := Color(0.74, 0.62, 0.36)
	var green_savanna := Color(0.55, 0.6, 0.28)
	var laterite := Color(0.7, 0.36, 0.2)

	var biome := LowpolyTerrainBiome.new()
	biome.name = "Senegal Savanna"
	biome.ground_styles = [
		make_ground("Dry Grass", dry_grass, Color(0.58, 0.4, 0.24)),
		make_ground("Laterite", laterite, Color(0.55, 0.27, 0.16)),
		make_ground("Green Savanna", green_savanna, Color(0.5, 0.32, 0.18)),
		make_ground("Sand", Color(0.86, 0.76, 0.55), Color(0.7, 0.56, 0.38)),
		make_ground("Dry Clay", Color(0.62, 0.52, 0.42), Color(0.48, 0.38, 0.3)),
		make_ground("Burnt Ground", Color(0.3, 0.26, 0.22), Color(0.4, 0.28, 0.2)),
	]
	biome.blend = 2
	biome.blend_noise = 0.75
	biome.slope_tint = 0.6
	biome.slope_start = 28.0
	biome.slope_end = 48.0
	biome.ambient_occlusion = 0.45
	biome.variation = 0.09
	biome.cliff_darken = 0.3
	biome.cliff_lip = 0.12
	biome.waterhole_clay_color = Color(0.64, 0.48, 0.34)
	biome.waterhole_crack_color = Color(0.3, 0.19, 0.13)
	biome.road_color = Color(0.66, 0.4, 0.26)
	const RIM := DetailLayer.WaterholeZone.RIM_ONLY

	var layers: Array[DetailLayer] = [
		make_layer("Dry Grass", DetailMeshes.DRY_GRASS_TUFT, 1.2, {
			"clump_size": 7.0, "clump_coverage": 0.7,
			"ground_filter": BY_COLOR, "filter_color": dry_grass, "filter_tolerance": 0.28,
			"slope_max": 32.0, "slope_fade": 10.0,
			"scale_min": 0.9, "scale_max": 1.5, "height_scale_min": 0.8, "height_scale_max": 1.4, "sink": 0.05,
			"color_mode": GROUND, "tint": Color(1.05, 0.98, 0.78), "brightness": 1.05, "brightness_jitter": 0.12,
			"draw_distance": 50.0,
		}),
		make_layer("Green Grass", DetailMeshes.GRASS_TUFT, 0.6, {
			"ground_filter": BY_COLOR, "filter_color": green_savanna, "filter_tolerance": 0.2,
			"slope_max": 30.0, "slope_fade": 12.0, "sink": 0.05,
			"color_mode": GROUND, "tint": Color(0.92, 1.06, 0.7), "draw_distance": 50.0,
		}),
		make_layer("Laterite Gravel", DetailMeshes.PEBBLES, 0.18, {
			"ground_filter": BY_COLOR, "filter_color": laterite, "filter_tolerance": 0.22,
			"scale_min": 0.6, "scale_max": 1.2, "small_bias": 1.5, "max_tilt": 10.0, "sink": 0.15,
			"color_mode": GROUND, "brightness": 0.78, "desaturate": 0.15, "draw_distance": 50.0,
		}),
		make_layer("Rocks", DetailMeshes.ROCK, 0.015, {
			"steep_bonus": 8.0, "edge_bonus": 6.0, "cell_margin": 0.1,
			"scale_min": 0.55, "scale_max": 1.45, "small_bias": 2.0, "height_scale_min": 0.55, "height_scale_max": 1.0,
			"stretch_max": 1.25, "max_tilt": 14.0, "sink": 0.25,
			"color_mode": DetailLayer.ColorMode.SIDE, "desaturate": 0.35, "lighten": 0.08, "brightness_jitter": 0.13,
		}),
		make_layer("Shrubs", DetailMeshes.SHRUB, 0.035, {
			"clump_size": 9.0, "clump_coverage": 0.45, "slope_max": 28.0,
			"scale_min": 0.9, "scale_max": 1.8, "small_bias": 1.5, "height_scale_min": 0.7, "height_scale_max": 1.1,
			"stretch_max": 1.3, "sink": 0.05, "color_mode": FIXED, "tint": Color(0.95, 0.88, 0.7), "brightness_jitter": 0.12,
			"draw_distance": 120.0,
		}),
		make_layer("Acacias", DetailMeshes.ACACIA, 0.006, {
			"clump_size": 16.0, "clump_coverage": 0.5, "slope_max": 22.0, "cell_margin": 0.2,
			"scale_min": 3.5, "scale_max": 6.0, "small_bias": 1.3, "height_scale_min": 0.85, "height_scale_max": 1.15,
			"stretch_max": 1.25, "max_tilt": 4.0, "sink": 0.02, "color_mode": FIXED, "brightness_jitter": 0.1,
			"draw_distance": 300.0, "cast_shadows": true,
			"collision_radius": 0.045, "collision_height": 0.7,
		}),
		make_layer("Baobabs", DetailMeshes.BAOBAB, 0.001, {
			"slope_max": 18.0, "cell_margin": 0.3,
			"scale_min": 5.0, "scale_max": 7.5, "small_bias": 1.2, "height_scale_min": 0.9, "height_scale_max": 1.15,
			"stretch_max": 1.15, "sink": 0.03, "color_mode": FIXED, "brightness_jitter": 0.08, "draw_distance": 400.0,
			"cast_shadows": true, "collision_radius": 0.22, "collision_height": 0.7,
		}),
		make_layer("Termite Mounds", DetailMeshes.TERMITE_MOUND, 0.004, {
			"clump_size": 20.0, "clump_coverage": 0.5, "slope_max": 20.0, "cell_margin": 0.15,
			"scale_min": 1.2, "scale_max": 2.6, "small_bias": 1.6, "height_scale_min": 0.8, "height_scale_max": 1.3,
			"max_tilt": 3.0, "sink": 0.08, "color_mode": FIXED, "tint": Color(0.78, 0.45, 0.28), "brightness_jitter": 0.08,
			"draw_distance": 160.0, "collision_radius": 0.4, "collision_height": 0.85,
		}),
		make_layer("Zebu Skulls", DetailMeshes.ZEBU_SKULL, 0.0015, {
			"slope_max": 15.0, "cell_margin": 0.15,
			"scale_min": 0.55, "scale_max": 0.75, "height_scale_min": 1.0, "height_scale_max": 1.0,
			"max_tilt": 12.0, "sink": 0.15, "color_mode": FIXED, "brightness_jitter": 0.06, "draw_distance": 45.0,
		}),
		# Around dried waterholes (Waterhole tool): where the herds came to
		# drink, now trampled clay with bones, dead trees and dry reeds.
		make_layer("Waterhole Reeds", DetailMeshes.DRY_GRASS_TUFT, 0.9, {
			"waterhole_zone": RIM, "clump_size": 4.0, "clump_coverage": 0.45, "slope_max": 35.0,
			"scale_min": 1.0, "scale_max": 1.5, "height_scale_min": 1.6, "height_scale_max": 2.4, "sink": 0.05,
			"color_mode": FIXED, "tint": Color(0.8, 0.7, 0.48), "brightness_jitter": 0.12, "draw_distance": 60.0,
		}),
		make_layer("Waterhole Skulls", DetailMeshes.ZEBU_SKULL, 0.035, {
			"waterhole_zone": RIM, "slope_max": 30.0, "cell_margin": 0.15,
			"scale_min": 0.5, "scale_max": 0.75, "height_scale_min": 1.0, "height_scale_max": 1.0,
			"max_tilt": 22.0, "sink": 0.15, "color_mode": FIXED, "brightness_jitter": 0.06, "draw_distance": 50.0,
		}),
		make_layer("Dead Trees", DetailMeshes.DEAD_TREE, 0.012, {
			"waterhole_zone": RIM, "slope_max": 30.0, "cell_margin": 0.25,
			"scale_min": 2.2, "scale_max": 4.0, "height_scale_min": 0.85, "height_scale_max": 1.2,
			"stretch_max": 1.2, "max_tilt": 10.0, "sink": 0.03, "color_mode": FIXED, "brightness_jitter": 0.1,
			"draw_distance": 200.0, "collision_radius": 0.065, "collision_height": 0.6,
		}),
		make_layer("Basin Bones", DetailMeshes.ZEBU_SKULL, 0.006, {
			"waterhole_zone": DetailLayer.WaterholeZone.BASIN_ONLY, "cell_margin": 0.2,
			"scale_min": 0.5, "scale_max": 0.65, "height_scale_min": 1.0, "height_scale_max": 1.0,
			"max_tilt": 25.0, "sink": 0.12, "color_mode": FIXED, "brightness_jitter": 0.05, "draw_distance": 50.0,
		}),
	]
	biome.detail_layers = layers
	return biome
