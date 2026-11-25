@tool
extends RefCounted
## The Map Recipes shipped in generation/presets/: the Inspector's "Map
## Preset" list, and the recipe Generate Map uses when none is assigned (a
## button must never do nothing).

const MapRecipe = preload("map_recipe.gd")

## Listed first, and the recipe of a terrain whose biome has no preset: the
## generic one (the plugin is not tied to a theme).
const DEFAULT_FILE := "temperate_island_map.tres"

## Map Recipes found in `directory` (*.tres): DEFAULT_FILE first, then the
## others by file name.
static func list(directory: String) -> Array[Resource]:
	var out: Array[Resource] = []
	var files := DirAccess.get_files_at(directory)
	files.sort()
	for file in files:
		# Exported games list "x.tres.remap": keep the resource path.
		file = file.trim_suffix(".remap")
		if not file.ends_with(".tres"):
			continue
		var recipe := load(directory.path_join(file)) as Resource
		if recipe != null and recipe.get_script() == MapRecipe:
			if file == DEFAULT_FILE:
				out.push_front(recipe)
			else:
				out.append(recipe)
	return out

## Preset whose biome is the terrain's biome, else the first preset (the
## generic DEFAULT_FILE); null when there is no preset at all.
static func default_for(terrain: Node3D, presets: Array[Resource], biome_key: String) -> Resource:
	if presets.is_empty():
		return null
	var biome: Resource = null
	if is_instance_valid(terrain) and terrain.has_meta(biome_key):
		var value: Variant = terrain.get_meta(biome_key)
		# Anything but a Resource in the slot counts as no biome.
		if value is Resource:
			biome = value
	if biome != null:
		for recipe in presets:
			var recipe_biome: Resource = recipe.get("biome")
			if recipe_biome != null and recipe_biome.resource_path == biome.resource_path:
				return recipe
	return presets[0]

## True when `recipe` is one of `presets` (same file).
static func is_preset(recipe: Resource, presets: Array[Resource]) -> bool:
	if recipe == null or recipe.resource_path.is_empty():
		return false
	for preset in presets:
		if preset.resource_path == recipe.resource_path:
			return true
	return false
