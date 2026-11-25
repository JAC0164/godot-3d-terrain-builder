extends SceneTree
## Old scenes keep their look: the look settings that left the terrain for
## the biome (Ground / Detail Material, Flat Top Lighting, road / water color)
## and the look of each road / river (TerrainData.migrate_look and
## migrate_feature_look). Plus the biome's Environment in game
## (TerrainRuntime). Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_look_migration.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const MaterialFactory = preload(ADDON + "materials/material_factory.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _terrain(root: Node) -> Node3D:
	var t := Node3D.new()
	t.name = "OldTerrain"
	root.add_child(t)
	TerrainData.initialize(t)
	return t

func _line(x: float) -> Array[Vector2]:
	var points: Array[Vector2] = [Vector2(x, -10.0), Vector2(x, 10.0)]
	return points

func _initialize() -> void:
	var root := Node3D.new()
	get_root().add_child(root)

	# 1. Old scene with the old defaults: nothing to copy, the keys go away.
	var plain := _terrain(root)
	var biome_before: Variant = Meta.get_optional(plain, Meta.BIOME)
	plain.set_meta("_lte_road_color", Meta.DEFAULT_ROAD_COLOR)
	plain.set_meta("_lte_river_color", Meta.DEFAULT_RIVER_COLOR)
	plain.set_meta("_lte_top_normal_up_bias", 0.0)
	plain.set_meta("_lte_river_roughness", Meta.DEFAULT_RIVER_ROUGHNESS)
	TerrainData.ensure_defaults(plain)
	check("old defaults: no biome copy", Meta.get_optional(plain, Meta.BIOME) == biome_before)
	var left := ["_lte_road_color", "_lte_river_color", "_lte_top_normal_up_bias", "_lte_river_roughness"].filter(func(key: String) -> bool: return plain.has_meta(key))
	check("old defaults: old keys removed %s" % [left], left.is_empty())

	# 2. Old scene with its own look: the terrain gets a biome copy holding it.
	var own := _terrain(root)
	var ground := StandardMaterial3D.new()
	var detail := StandardMaterial3D.new()
	var red_road := Color(0.7, 0.2, 0.1)
	var green_water := Color(0.1, 0.5, 0.3, 0.8)
	own.set_meta("_lte_ground_material", ground)
	own.set_meta("_lte_detail_material", detail)
	own.set_meta("_lte_top_normal_up_bias", 0.4)
	own.set_meta("_lte_road_color", red_road)
	own.set_meta("_lte_river_color", green_water)
	TerrainData.ensure_defaults(own)
	var copy := TerrainBiome.of(own)
	check("own look: a biome copy in the terrain", Meta.get_optional(own, Meta.BIOME) is TerrainBiome and copy != TerrainBiome.default_biome())
	check("own look: Ground / Detail Material moved", copy.ground_material == ground and copy.detail_material == detail)
	check("own look: Flat Top Lighting moved", is_equal_approx(copy.flat_top_lighting, 0.4))
	check("own look: road / water color moved", copy.road_color.is_equal_approx(red_road) and copy.water_color.is_equal_approx(green_water))
	check("own look: built-in biome unchanged", TerrainBiome.default_biome().ground_material == null and TerrainBiome.default_biome().road_color.is_equal_approx(Meta.DEFAULT_ROAD_COLOR))
	check("own look: old keys removed", not own.has_meta("_lte_ground_material") and not own.has_meta("_lte_road_color"))
	check("ground material: the build uses the biome's", MaterialFactory.terrain_vertex_color_material(own) == ground)

	# 3. Roads / rivers: a stored look equal to the biome's follows it; any
	# other stays as it was.
	var feats := _terrain(root)
	var road_key := FeatureStyle.features_key(FeatureStyle.ROAD)
	var river_key := FeatureStyle.features_key(FeatureStyle.RIVER)
	var biome_road := {"points": _line(0.0), "width": 3.0, "y_offset": 0.05, "collision": true, "color": Meta.DEFAULT_ROAD_COLOR, "texture": null, "tile_size": 4.0}
	var own_road := {"points": _line(5.0), "width": 3.0, "y_offset": 0.05, "collision": true, "color": Color(0.3, 0.3, 0.3), "texture": null, "tile_size": 4.0}
	var biome_river := {"points": _line(10.0), "width": 4.0, "depth": 1.0, "color": Meta.DEFAULT_RIVER_COLOR, "roughness": Meta.DEFAULT_RIVER_ROUGHNESS, "flow_speed": Meta.DEFAULT_RIVER_FLOW_SPEED}
	var own_river := {"points": _line(15.0), "width": 4.0, "depth": 1.0, "color": Meta.DEFAULT_RIVER_COLOR, "roughness": 0.6}
	feats.set_meta(road_key, [biome_road, own_road])
	feats.set_meta(river_key, [biome_river, own_river])
	var own_river_before := MaterialFactory.river_material(feats, own_river)
	TerrainData.ensure_defaults(feats)
	var roads: Array = feats.get_meta(road_key)
	var rivers: Array = feats.get_meta(river_key)
	check("road with the biome's look follows the biome", FeatureStyle.follows_biome(roads[0]))
	check("road with its own color keeps it", not FeatureStyle.follows_biome(roads[1]) and (roads[1]["color"] as Color).is_equal_approx(Color(0.3, 0.3, 0.3)))
	check("road shape kept", is_equal_approx(float(roads[0]["width"]), 3.0) and (roads[0]["points"] as Array).size() == 2)
	check("river with the default water follows the biome", FeatureStyle.follows_biome(rivers[0]))
	check("river with its own roughness keeps its look", not FeatureStyle.follows_biome(rivers[1]))
	var own_river_after := MaterialFactory.river_material(feats, rivers[1])
	check("own river: same water values", own_river_after.get_shader_parameter("roughness_value") == own_river_before.get_shader_parameter("roughness_value") and own_river_after.get_shader_parameter("water_color") == own_river_before.get_shader_parameter("water_color"))
	var road_mat := MaterialFactory.road_material(feats, roads[0]) as StandardMaterial3D
	check("biome road: built-in road in the biome color", road_mat != null and road_mat.albedo_color.is_equal_approx(TerrainBiome.of(feats).road_color))

	# 4. Live: a road / water material in the biome reaches the roads / rivers
	# that follow it, not the ones with their own look.
	var themed: TerrainBiome = TerrainBiome.of(feats).duplicate()
	themed.road_material = MaterialFactory.editable_road_material(Color.WHITE)
	themed.water_material = MaterialFactory.editable_water_material(Color(0.2, 0.3, 0.9, 0.7))
	feats.set_meta(Meta.BIOME, themed)
	check("biome Road Material on a biome road", MaterialFactory.road_material(feats, roads[0]) == themed.road_material)
	check("own-look road keeps its material", MaterialFactory.road_material(feats, roads[1]) != themed.road_material)
	check("biome Water Material on a biome river", MaterialFactory.river_material(feats, rivers[0]) == themed.water_material)
	var mobile_a := MaterialFactory.river_material(feats, rivers[0], true) as ShaderMaterial
	var mobile_b := MaterialFactory.river_material(feats, rivers[0], true) as ShaderMaterial
	check("phone water: one copy without refraction, same values", mobile_a == mobile_b and mobile_a.shader != (themed.water_material as ShaderMaterial).shader and mobile_a.get_shader_parameter("water_color") == themed.water_material.get_shader_parameter("water_color"))
	check("new road follows the biome", FeatureStyle.follows_biome(FeatureStyle.from_terrain_settings(feats, FeatureStyle.ROAD)))

	# 5. The biome's Environment in game, unless the scene has one.
	var env_terrain := _terrain(root)
	var env_biome: TerrainBiome = TerrainBiome.make_temperate()
	env_biome.environment = Environment.new()
	env_terrain.set_meta(Meta.BIOME, env_biome)
	var runtime: Node = TerrainRuntime.new()
	runtime.set("build_on_ready", false)
	env_terrain.add_child(runtime)
	# _ready runs on the first frame of a SceneTree script.
	await process_frame
	var added := runtime.find_children("*", "WorldEnvironment", false, false)
	check("biome Environment applied in game (%d node)" % added.size(), added.size() == 1 and (added[0] as WorldEnvironment).environment == env_biome.environment and String(added[0].name) == "BiomeEnvironment")
	var second := _terrain(root)
	second.set_meta(Meta.BIOME, env_biome)
	var runtime_2: Node = TerrainRuntime.new()
	runtime_2.set("build_on_ready", false)
	second.add_child(runtime_2)
	await process_frame
	check("a WorldEnvironment already in the scene wins", runtime_2.find_children("*", "WorldEnvironment", false, false).is_empty())
	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)
