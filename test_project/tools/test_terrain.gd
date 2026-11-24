extends RefCounted
## Terrains for the check / profile tools.
##   island(): a generated temperate island (same recipe + seed = same data,
##             hills, empty cells around, no waterholes); no scene file needed.
##   savanna(): a generated Senegal savanna map (savanna biome, tracks,
##             waterholes, plateaus); fixed recipe + seed, so the checks do
##             not depend on scenes/savanna_128.tscn being edited by hand.
##   load_scene(): a saved terrain scene, with its packed data unpacked (the
##             tools read the terrain arrays without entering the tree).

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainStorage = preload(ADDON + "core/terrain_storage.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")

## Saved scene used by the tools that compare with / time a stored terrain.
const SAVED_SCENE := "res://scenes/savanna_128.tscn"
const ISLAND_RECIPE := ADDON + "generation/presets/temperate_island_map.tres"
const ISLAND_SEED := 7
const SAVANNA_RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"
const SAVANNA_SEED := 7

## Adds a generated island "LowpolyTerrain" under `root` (owned by it).
static func island(root: Node) -> Node3D:
	return generated(root, load(ISLAND_RECIPE), ISLAND_SEED)

## Adds a generated savanna map "LowpolyTerrain" under `root` (owned by it).
static func savanna(root: Node) -> Node3D:
	return generated(root, load(SAVANNA_RECIPE), SAVANNA_SEED)

static func generated(root: Node, recipe: Resource, map_seed: int) -> Node3D:
	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	root.add_child(terrain)
	terrain.owner = root
	TerrainData.initialize(terrain)
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = Meta.GENERATED_MESH_NAME
	terrain.add_child(mesh_instance)
	mesh_instance.owner = root
	MapGenerator.generate(terrain, recipe, map_seed)
	TerrainData.ensure_defaults(terrain)
	return terrain

## Instantiates a terrain scene and unpacks its "LowpolyTerrain" data.
static func load_scene(path: String = SAVED_SCENE) -> Node:
	var scene := load(path) as PackedScene
	if scene == null:
		push_error("test_terrain: cannot load %s" % path)
		return null
	var root := scene.instantiate()
	var terrain := root.get_node_or_null("LowpolyTerrain")
	if terrain:
		TerrainStorage.unpack(terrain)
	return root
