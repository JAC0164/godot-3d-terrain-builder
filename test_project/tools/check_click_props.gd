extends SceneTree
## How many Vegetation clicks a big prop needs on bare ground (ground painted
## by hand, Details Everywhere off): for each layer, 30 random spots of the
## savanna island, single clicks (one brush stamp, size 3 m, strength 1) on
## the same spot until one instance of the layer stands inside the brush.
## OK = the first click always grows one. `-- --why` explains slower spots.
##   godot --headless --path . --script res://tools/check_click_props.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const Brush = preload(ADDON + "editing/brush.gd")
const ToolMode = preload(ADDON + "editing/tool_mode.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const RiverMesher = preload(ADDON + "mesh/river_mesher.gd")
const WaterholeMesher = preload(ADDON + "mesh/waterhole_mesher.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

const RADIUS := 3.0
const MAX_CLICKS := 12
const SPOTS := 30

var _t: Node3D
var _carve: PackedFloat32Array
var _shading := {}

func _initialize() -> void:
	var root := Node3D.new()
	_t = TestTerrain.island(root)
	_t.set_meta(Meta.BIOME, load(ADDON + "biomes/presets/senegal_savanna.tres"))
	_t.set_meta(Meta.DETAILS_EVERYWHERE, false)
	_t.set_meta(Meta.CELL_VEGETATION, {})
	_carve = RiverMesher.compute_carve(_t)
	WaterholeMesher.add_carve(_t, _carve)
	var count := TerrainMesher.chunk_count(_t)
	for cz in count:
		for cx in count:
			_shading[Vector2i(cx, cz)] = TerrainMesher.build_chunk_parts(_t, _carve, cx, cz).get("shading")

	# Spots: random ground cells (same every run).
	var cells: int = int(_t.get_meta(Meta.RESOLUTION)) - 1
	var spacing: float = float(_t.get_meta(Meta.WORLD_SIZE)) / float(cells)
	var active: PackedByteArray = _t.get_meta(Meta.CELL_ACTIVE)
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var spots: Array[Vector2] = []
	while spots.size() < SPOTS:
		var cell := rng.randi_range(0, active.size() - 1)
		if active[cell] != 0:
			spots.append((Vector2(cell % cells, cell / cells) + Vector2(0.5, 0.5)) * spacing - Vector2.ONE * float(_t.get_meta(Meta.WORLD_SIZE)) * 0.5)

	var worst := 0
	for layer_name in ["Baobabs", "Acacias", "Termite Mounds", "Zebu Skulls", "Rocks"]:
		var needed: Array[int] = []
		for spot in spots:
			_t.set_meta(Meta.CELL_VEGETATION, {})
			var clicks := 0
			while clicks < MAX_CLICKS:
				clicks += 1
				Brush.apply_vegetation(_t, ToolMode.Mode.VEGETATION, spot, RADIUS, 1.0, layer_name)
				if _count_near(layer_name, spot) > 0:
					break
			needed.append(clicks if _count_near(layer_name, spot) > 0 else MAX_CLICKS + 1)
			if needed[-1] > 1 and OS.get_cmdline_user_args().has("--why"):
				print("  %d clicks: %s at %s, %s, nearest after: %.2f m, road %s" % [needed[-1], layer_name, spot, _describe(spot), _nearest(layer_name, spot), _on_road(spot)])
			if needed[-1] > MAX_CLICKS:
				print("  never: %s at %s, %s" % [layer_name, spot, _describe(spot)])
		var first := needed.filter(func(n): return n == 1).size()
		var never := needed.filter(func(n): return n > MAX_CLICKS).size()
		var sorted := needed.duplicate()
		sorted.sort()
		print("%-15s 1 click: %2d/%d   never in %d clicks: %2d/%d   median %d" % [layer_name, first, SPOTS, MAX_CLICKS, never, SPOTS, sorted[SPOTS / 2]])
		worst = maxi(worst, never + (SPOTS - first))
	print("RESULT: %s" % ("OK" if worst == 0 else "FAIL (a click grew nothing)"))
	root.free()
	quit(0)

## Instances of the layer whose position is inside the brush.
func _count_near(layer_name: String, spot: Vector2) -> int:
	var total := 0
	var count := TerrainMesher.chunk_count(_t)
	for cz in count:
		for cx in count:
			for entry in DetailScatter.build(_t, _carve, cx, cz, _shading[Vector2i(cx, cz)]):
				var layer: Resource = entry[3]
				if String(layer.name) != layer_name:
					continue
				var buffer: PackedFloat32Array = entry[2]
				for i in int(entry[1]):
					var p := Vector2(buffer[i * 16 + 3], buffer[i * 16 + 11])
					if p.distance_to(spot) <= RADIUS:
						total += 1
	return total

## Why a spot may stay empty: steepest slope under the brush centre cell.
func _describe(spot: Vector2) -> String:
	var res: int = int(_t.get_meta(Meta.RESOLUTION))
	var cells := res - 1
	var size: float = float(_t.get_meta(Meta.WORLD_SIZE))
	var spacing := size / float(cells)
	var cx := int((spot.x + size * 0.5) / spacing)
	var cz := int((spot.y + size * 0.5) / spacing)
	var heights: PackedFloat32Array = _t.get_meta(Meta.HEIGHTS)
	var h := [heights[cz * res + cx], heights[cz * res + cx + 1], heights[(cz + 1) * res + cx], heights[(cz + 1) * res + cx + 1]]
	var drop: float = h.max() - h.min()
	var carve := _carve[cz * res + cx]
	return "cell (%d, %d): height drop %.2f m over %.2f m (%.0f deg), carve %.2f" % [cx, cz, drop, spacing, rad_to_deg(atan(drop / spacing)), carve]

func _nearest(layer_name: String, spot: Vector2) -> float:
	var best := INF
	var count := TerrainMesher.chunk_count(_t)
	for cz in count:
		for cx in count:
			for entry in DetailScatter.build(_t, _carve, cx, cz, _shading[Vector2i(cx, cz)]):
				if String((entry[3] as Resource).name) != layer_name:
					continue
				var buffer: PackedFloat32Array = entry[2]
				for i in int(entry[1]):
					best = minf(best, Vector2(buffer[i * 16 + 3], buffer[i * 16 + 11]).distance_to(spot))
	return best

func _on_road(spot: Vector2) -> bool:
	var cells: int = int(_t.get_meta(Meta.RESOLUTION)) - 1
	var spacing: float = float(_t.get_meta(Meta.WORLD_SIZE)) / float(cells)
	var half: float = float(_t.get_meta(Meta.WORLD_SIZE)) * 0.5
	var mask := DetailScatter._road_mask(_t, 0, 0, cells, cells, spacing, half)
	var cx := int((spot.x + half) / spacing)
	var cz := int((spot.y + half) / spacing)
	return mask[cz * cells + cx] != 0
