extends RefCounted
## Five trial biomes made game side, with the plugin's API (not in the plugin):
## desert, snow, volcanic, tropical, autumn. Each entry: title, file, biome,
## the three ground styles (main, raised, lowered) and the relief (raise,
## lower) for a pixel map. Used by tools/build_biomes_from_image.gd and
## tools/render_showcase.gd.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const DetailLayer = preload(ADDON + "biomes/detail_layer.gd")
const GroundStyle = preload(ADDON + "biomes/ground_style.gd")
const DetailMeshes = preload(ADDON + "mesh/detail_meshes.gd")

const GROUND := DetailLayer.ColorMode.GROUND
const SIDE := DetailLayer.ColorMode.SIDE
const FIXED := DetailLayer.ColorMode.FIXED
const BY_COLOR := DetailLayer.GroundFilter.COLOR

static func list() -> Array[Dictionary]:
	var list: Array[Dictionary] = []

	# Desert: sand, sandstone mesas, a green oasis in the hollow.
	var sand := Color(0.87, 0.74, 0.5)
	var oasis := Color(0.42, 0.56, 0.24)
	var desert := make("Desert", [
		TerrainBiome.make_ground("Sand", sand, Color(0.74, 0.57, 0.38)),
		TerrainBiome.make_ground("Sandstone", Color(0.76, 0.48, 0.3), Color(0.66, 0.38, 0.24)),
		TerrainBiome.make_ground("Oasis", oasis, Color(0.52, 0.4, 0.26)),
	], [
		TerrainBiome.make_layer("Oasis Grass", DetailMeshes.GRASS_TUFT, 0.9, {"ground_filter": BY_COLOR, "filter_color": oasis, "filter_tolerance": 0.2, "slope_max": 30.0, "tint": Color(0.92, 1.06, 0.7)}),
		TerrainBiome.make_layer("Oasis Trees", DetailMeshes.ACACIA, 0.03, {"ground_filter": BY_COLOR, "filter_color": oasis, "filter_tolerance": 0.2, "slope_max": 22.0, "scale_min": 3.0, "scale_max": 5.0, "color_mode": FIXED, "tint": Color(0.85, 1.1, 0.8), "cast_shadows": true}),
		TerrainBiome.make_layer("Dry Tufts", DetailMeshes.DRY_GRASS_TUFT, 0.06, {"ground_filter": BY_COLOR, "filter_color": sand, "filter_tolerance": 0.2, "clump_size": 6.0, "clump_coverage": 0.4, "color_mode": FIXED, "tint": Color(0.85, 0.74, 0.5)}),
		TerrainBiome.make_layer("Rocks", DetailMeshes.ROCK, 0.012, {"steep_bonus": 8.0, "edge_bonus": 6.0, "scale_min": 0.6, "scale_max": 1.5, "small_bias": 2.0, "sink": 0.25, "color_mode": SIDE, "desaturate": 0.2}),
		TerrainBiome.make_layer("Skulls", DetailMeshes.ZEBU_SKULL, 0.002, {"slope_max": 15.0, "scale_min": 0.55, "scale_max": 0.75, "color_mode": FIXED}),
		TerrainBiome.make_layer("Dead Trees", DetailMeshes.DEAD_TREE, 0.001, {"slope_max": 20.0, "scale_min": 2.0, "scale_max": 3.2, "color_mode": FIXED}),
	])
	list.append({"title": "Désert (essai)", "file": "desert", "biome": desert,
		"styles": ["Sand", "Sandstone", "Oasis"], "raise": 5.0, "lower": 0.8})

	# Snow: snowfield, bare rock hills, a frozen lake.
	var snow := Color(0.93, 0.95, 0.98)
	var tundra := make("Snow", [
		TerrainBiome.make_ground("Snow", snow, Color(0.6, 0.63, 0.68)),
		TerrainBiome.make_ground("Rock", Color(0.5, 0.5, 0.5), Color(0.36, 0.36, 0.37)),
		TerrainBiome.make_ground("Ice", Color(0.68, 0.84, 0.95), Color(0.5, 0.63, 0.74)),
	], [
		TerrainBiome.make_layer("Frozen Grass", DetailMeshes.DRY_GRASS_TUFT, 0.15, {"ground_filter": BY_COLOR, "filter_color": snow, "filter_tolerance": 0.1, "clump_size": 5.0, "clump_coverage": 0.35, "color_mode": FIXED, "tint": Color(0.75, 0.72, 0.6)}),
		TerrainBiome.make_layer("Rocks", DetailMeshes.ROCK, 0.02, {"steep_bonus": 8.0, "edge_bonus": 6.0, "scale_min": 0.6, "scale_max": 1.6, "small_bias": 2.0, "sink": 0.3, "color_mode": SIDE}),
		TerrainBiome.make_layer("Pebbles", DetailMeshes.PEBBLES, 0.05, {"ground_filter": BY_COLOR, "filter_color": Color(0.5, 0.5, 0.5), "filter_tolerance": 0.15, "color_mode": SIDE}),
		TerrainBiome.make_layer("Dead Trees", DetailMeshes.DEAD_TREE, 0.004, {"ground_filter": BY_COLOR, "filter_color": snow, "filter_tolerance": 0.1, "slope_max": 25.0, "scale_min": 2.0, "scale_max": 3.5, "color_mode": FIXED, "tint": Color(0.7, 0.68, 0.66), "cast_shadows": true}),
	])
	list.append({"title": "Neige (essai)", "file": "neige", "biome": tundra,
		"styles": ["Snow", "Rock", "Ice"], "raise": 4.0, "lower": 0.5})

	# Volcanic: ash plain, black basalt hills, a lava hollow (orange colour only, no glow).
	var ash := Color(0.36, 0.34, 0.33)
	var volcanic := make("Volcanic", [
		TerrainBiome.make_ground("Ash", ash, Color(0.26, 0.24, 0.23)),
		TerrainBiome.make_ground("Basalt", Color(0.17, 0.16, 0.16), Color(0.12, 0.11, 0.11)),
		TerrainBiome.make_ground("Lava", Color(1.0, 0.4, 0.08), Color(0.35, 0.12, 0.05)),
	], [
		TerrainBiome.make_layer("Rocks", DetailMeshes.ROCK, 0.03, {"steep_bonus": 8.0, "edge_bonus": 6.0, "scale_min": 0.6, "scale_max": 1.6, "small_bias": 2.0, "sink": 0.25, "color_mode": FIXED, "tint": Color(0.16, 0.15, 0.15)}),
		TerrainBiome.make_layer("Pebbles", DetailMeshes.PEBBLES, 0.2, {"ground_filter": BY_COLOR, "filter_color": ash, "filter_tolerance": 0.12, "color_mode": FIXED, "tint": Color(0.2, 0.19, 0.19)}),
		TerrainBiome.make_layer("Burnt Trees", DetailMeshes.DEAD_TREE, 0.006, {"ground_filter": BY_COLOR, "filter_color": ash, "filter_tolerance": 0.12, "slope_max": 25.0, "scale_min": 2.0, "scale_max": 3.5, "color_mode": FIXED, "tint": Color(0.12, 0.1, 0.09), "cast_shadows": true}),
	])
	list.append({"title": "Volcanique (essai)", "file": "volcan", "biome": volcanic,
		"styles": ["Ash", "Basalt", "Lava"], "raise": 5.0, "lower": 0.8})

	# Tropical: lush grass, jungle hills, a swamp.
	var lush := Color(0.27, 0.56, 0.2)
	var jungle := Color(0.18, 0.42, 0.15)
	var swamp := Color(0.26, 0.36, 0.24)
	var tropical := make("Tropical", [
		TerrainBiome.make_ground("Lush Grass", lush, Color(0.42, 0.3, 0.18)),
		TerrainBiome.make_ground("Jungle", jungle, Color(0.36, 0.25, 0.15)),
		TerrainBiome.make_ground("Swamp", swamp, Color(0.3, 0.24, 0.16)),
	], [
		TerrainBiome.make_layer("Grass", DetailMeshes.GRASS_TUFT, 1.0, {"ground_filter": DetailLayer.GroundFilter.GREENISH, "slope_max": 34.0, "scale_min": 0.9, "scale_max": 1.5, "tint": Color(0.92, 1.06, 0.7)}),
		TerrainBiome.make_layer("Bushes", DetailMeshes.SHRUB, 0.12, {"ground_filter": DetailLayer.GroundFilter.GREENISH, "clump_size": 6.0, "clump_coverage": 0.6, "slope_max": 35.0, "scale_min": 1.0, "scale_max": 2.0, "color_mode": FIXED, "tint": Color(0.55, 1.0, 0.45)}),
		TerrainBiome.make_layer("Trees", DetailMeshes.ACACIA, 0.05, {"ground_filter": BY_COLOR, "filter_color": jungle, "filter_tolerance": 0.12, "slope_max": 35.0, "scale_min": 3.5, "scale_max": 6.0, "color_mode": FIXED, "tint": Color(0.6, 1.1, 0.55), "cast_shadows": true}),
		TerrainBiome.make_layer("Big Trees", DetailMeshes.BAOBAB, 0.004, {"ground_filter": BY_COLOR, "filter_color": lush, "filter_tolerance": 0.12, "slope_max": 18.0, "scale_min": 5.0, "scale_max": 7.0, "color_mode": FIXED, "tint": Color(0.8, 1.0, 0.75), "cast_shadows": true}),
		TerrainBiome.make_layer("Reeds", DetailMeshes.DRY_GRASS_TUFT, 0.8, {"ground_filter": BY_COLOR, "filter_color": swamp, "filter_tolerance": 0.1, "height_scale_min": 1.6, "height_scale_max": 2.4, "color_mode": FIXED, "tint": Color(0.45, 0.6, 0.3)}),
	])
	list.append({"title": "Tropical (essai)", "file": "tropical", "biome": tropical,
		"styles": ["Lush Grass", "Jungle", "Swamp"], "raise": 4.0, "lower": 0.6})

	# Autumn: golden grass, red-brown hills, a green meadow in the hollow.
	var golden := Color(0.7, 0.52, 0.24)
	var autumn := make("Autumn", [
		TerrainBiome.make_ground("Golden Grass", golden, Color(0.48, 0.34, 0.2)),
		TerrainBiome.make_ground("Red Hills", Color(0.6, 0.3, 0.17), Color(0.45, 0.26, 0.18)),
		TerrainBiome.make_ground("Meadow", Color(0.46, 0.55, 0.26), Color(0.42, 0.32, 0.2)),
	], [
		TerrainBiome.make_layer("Grass", DetailMeshes.DRY_GRASS_TUFT, 0.8, {"slope_max": 32.0, "clump_size": 7.0, "clump_coverage": 0.7, "color_mode": GROUND, "tint": Color(1.05, 0.95, 0.8)}),
		TerrainBiome.make_layer("Orange Shrubs", DetailMeshes.SHRUB, 0.06, {"clump_size": 8.0, "clump_coverage": 0.5, "slope_max": 30.0, "scale_min": 1.0, "scale_max": 1.8, "color_mode": FIXED, "tint": Color(1.25, 0.6, 0.25)}),
		TerrainBiome.make_layer("Red Trees", DetailMeshes.ACACIA, 0.012, {"slope_max": 25.0, "scale_min": 3.5, "scale_max": 5.5, "color_mode": FIXED, "tint": Color(1.4, 0.55, 0.3), "cast_shadows": true}),
		TerrainBiome.make_layer("Rocks", DetailMeshes.ROCK, 0.015, {"steep_bonus": 8.0, "edge_bonus": 6.0, "scale_min": 0.55, "scale_max": 1.4, "small_bias": 2.0, "sink": 0.25, "color_mode": SIDE, "desaturate": 0.4}),
	])
	list.append({"title": "Automne (essai)", "file": "automne", "biome": autumn,
		"styles": ["Golden Grass", "Red Hills", "Meadow"], "raise": 3.5, "lower": 0.8})
	return list

## A trial biome with the savanna's baked shading.
static func make(biome_name: String, grounds: Array, layers: Array) -> Resource:
	var biome: Resource = TerrainBiome.new()
	biome.name = biome_name
	var styles: Array[GroundStyle] = []
	styles.assign(grounds)
	biome.ground_styles = styles
	var detail: Array[DetailLayer] = []
	detail.assign(layers)
	biome.detail_layers = detail
	biome.blend = 2
	biome.blend_noise = 0.75
	biome.slope_tint = 0.5
	biome.ambient_occlusion = 0.45
	biome.variation = 0.08
	biome.cliff_darken = 0.3
	return biome
