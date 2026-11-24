extends SceneTree
## Times the road and river mesh of the audit's savanna map, group by group
## (FeatureMesher.build makes one surface per connected road / river group),
## and the parts of a road group (rasterize, corner field, rest).
##   godot --headless --path . --script res://tools/profile_feature_groups.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const RoadMesher = preload(ADDON + "mesh/road_mesher.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const FeatureMesher = preload(ADDON + "mesh/feature_mesher.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

func _initialize() -> void:
	var terrain := Node3D.new()
	get_root().add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(RECIPE), 7)
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var points: Array[Vector2] = []
	for i in 9:
		var t := float(i) / 8.0
		points.append(Vector2(lerpf(-0.42, 0.42, t) * size, sin(t * 5.0) * 0.12 * size + 0.18 * size))
	FeatureStyle.commit(terrain, FeatureStyle.RIVER, points)
	var builder := TerrainBuilder.new()
	var t0 := Time.get_ticks_usec()
	builder.rebuild_river_carve(terrain)
	print("river carve %.1f ms" % ((Time.get_ticks_usec() - t0) / 1000.0))
	var carve := builder.get_river_carve(terrain)
	for run in 2:
		t0 = Time.get_ticks_usec()
		FeatureMesher.build(terrain, carve)
		print("FeatureMesher.build (run %d) %.1f ms" % [run, (Time.get_ticks_usec() - t0) / 1000.0])
	var roads: Array = terrain.get_meta(Meta.ROADS, [])
	t0 = Time.get_ticks_usec()
	var groups := RoadMesher.group_connected(roads)
	print("roads %d in %d groups, grouping %.1f ms, union cell %.2f m" % [roads.size(), groups.size(), (Time.get_ticks_usec() - t0) / 1000.0, RoadMesher.union_cell_size(terrain)])
	for g in groups:
		var t1 := Time.get_ticks_usec()
		RoadMesher.corner_field(g, RoadMesher.union_cell_size(terrain))
		var t2 := Time.get_ticks_usec()
		var geometry := RoadMesher.build_surface_union(terrain, carve, g)
		var t3 := Time.get_ticks_usec()
		print("  road group of %d: corner field %.1f, whole union %.1f ms, %d vertices" % [g.size(), (t2 - t1) / 1000.0, (t3 - t2) / 1000.0, (geometry["vertices"] as Array).size()])
	var rivers: Array = terrain.get_meta(Meta.RIVERS, [])
	for g in RiverMesher.group_connected(terrain, rivers):
		t0 = Time.get_ticks_usec()
		var geometry := RiverMesher.build_water_union(terrain, carve, g)
		print("  river group of %d: %.1f ms, %d vertices" % [g.size(), (Time.get_ticks_usec() - t0) / 1000.0, (geometry["vertices"] as Array).size()])
	quit()
