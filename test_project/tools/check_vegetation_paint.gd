extends SceneTree
## Checks of the Vegetation brush placement (mesh/detail_scatter.gd) on
## a generated savanna map (TestTerrain.savanna(): fixed recipe + seed, the
## same data every run). Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_vegetation_paint.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainStorage = preload(ADDON + "core/terrain_storage.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainMesher = preload(ADDON + "mesh/terrain_mesher.gd")
const DetailScatter = preload(ADDON + "mesh/detail_scatter.gd")
const WaterholeStyle = preload(ADDON + "styles/waterhole_style.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

var _failures := 0
var _t: Node3D
var _b: TerrainBuilder
var _cells := 0
var _spacing := 0.0
var _half := 0.0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

## Layer name -> instance positions (terrain local x, z) for the whole map.
func _scatter(paint: Dictionary) -> Dictionary:
	Meta.set_optional(_t, Meta.CELL_VEGETATION, paint if not paint.is_empty() else null)
	var out := {}
	var n := TerrainMesher.chunk_count(_t)
	for cz in n:
		for cx in n:
			for d in DetailScatter.build(_t, _b.get_river_carve(_t), cx, cz, _b.chunk_shading(_t, cx, cz)):
				var name := String(d[3].name)
				var points: PackedVector2Array = out.get(name, PackedVector2Array())
				var buffer: PackedFloat32Array = d[2]
				for i in range(0, buffer.size(), 16):
					points.append(Vector2(buffer[i + 3], buffer[i + 11]))
				out[name] = points
	return out

func _full(value: int) -> PackedByteArray:
	var a := PackedByteArray()
	a.resize(_cells * _cells)
	a.fill(value)
	return a

func _disc(centers: Array, radius: float, value: int) -> PackedByteArray:
	var a := _full(Meta.VEGETATION_NORMAL)
	for z in _cells:
		for x in _cells:
			var p := Vector2((x + 0.5) * _spacing - _half, (z + 0.5) * _spacing - _half)
			for c: Vector2 in centers:
				if p.distance_to(c) < radius:
					a[z * _cells + x] = value
	return a

func _count_in(points: PackedVector2Array, centers: Array, radius: float) -> int:
	var count := 0
	for p in points:
		for c: Vector2 in centers:
			if p.distance_to(c) < radius:
				count += 1
				break
	return count

func _total(result: Dictionary) -> int:
	var total := 0
	for key in result:
		total += (result[key] as PackedVector2Array).size()
	return total

func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(clampi(int((p.x + _half) / _spacing), 0, _cells - 1), clampi(int((p.y + _half) / _spacing), 0, _cells - 1))

func _initialize() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	_t = TestTerrain.savanna(root)
	_b = TerrainBuilder.new()
	var resolution: int = _t.get_meta(Meta.RESOLUTION)
	var world_size: float = _t.get_meta(Meta.WORLD_SIZE)
	_cells = resolution - 1
	_spacing = world_size / float(_cells)
	_half = world_size * 0.5
	var biome: Resource = DetailScatter.biome_of(_t)
	var layers := {}
	for layer in biome.detail_layers:
		if layer:
			layers[String(layer.name)] = layer

	var t0 := Time.get_ticks_usec()
	var base := _scatter({})
	var base_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var base_total := _total(base)
	check("unpainted map has details (%d)" % base_total, base_total > 1000)
	check("paint at normal = unpainted", _scatter({"Acacias": _full(Meta.VEGETATION_NORMAL)}) == base)

	# Forest: Acacias painted full around 3 existing acacias (where they grow).
	var acacias: PackedVector2Array = base.get("Acacias", PackedVector2Array())
	var centers: Array = []
	for p in acacias:
		if centers.size() < 3 and centers.all(func(c: Vector2) -> bool: return c.distance_to(p) > 25.0) and absf(p.x) < _half - 12.0 and absf(p.y) < _half - 12.0:
			centers.append(p)
	var forest := _scatter({"Acacias": _disc(centers, 10.0, 255)})
	var before := _count_in(acacias, centers, 10.0)
	var after := _count_in(forest["Acacias"], centers, 10.0)
	# Painted trees keep Paint Spacing (0.85 crown) apart: 3 discs of 10 m hold
	# about 25 acacias, so x3 at least (was x5 when crowns could cross).
	check("Acacias painted full: forest (%d -> %d acacias in 3 discs)" % [before, after], after >= maxi(before * 3, 15))
	var painted_new: Array[Vector2] = []
	for p in forest["Acacias"]:
		if _count_in(PackedVector2Array([p]), centers, 10.0) > 0 and not acacias.has(p):
			painted_new.append(p)
	var close := 0
	for i in painted_new.size():
		for j in range(i + 1, painted_new.size()):
			if painted_new[i].distance_to(painted_new[j]) < 3.0:
				close += 1
	check("painted acacias: no two closer than 3 m (%d painted, %d close pairs)" % [painted_new.size(), close], painted_new.size() > 0 and close == 0)
	check("Acacias painted: other layers unchanged", forest["Dry Grass"] == base["Dry Grass"] and forest["Rocks"] == base["Rocks"])

	# Ground filter: Dry Grass painted everywhere, rules relaxed or not.
	var grass_layer: Resource = layers["Dry Grass"]
	grass_layer.paint_relaxes_rules = false
	var strict := _scatter({"Dry Grass": _full(255)})
	grass_layer.paint_relaxes_rules = true
	var relaxed := _scatter({"Dry Grass": _full(255)})
	var strict_cells := {}
	for p in strict["Dry Grass"]:
		strict_cells[_cell_of(p)] = true
	var new_cells := {}
	for p in relaxed["Dry Grass"]:
		var c := _cell_of(p)
		if not strict_cells.has(c):
			new_cells[c] = true
	check("Dry Grass painted, rules kept: denser only (%d -> %d)" % [base["Dry Grass"].size(), strict["Dry Grass"].size()], strict["Dry Grass"].size() > base["Dry Grass"].size())
	check("Dry Grass painted, rules relaxed: grows on %d more cells (other ground, slopes)" % new_cells.size(), new_cells.size() > 50)

	# Rim-only layer: grows away from waterholes only when picked itself.
	var spot := Vector2.ZERO
	var holes := WaterholeStyle.shapes(_t)
	for z in range(10, _cells - 10, 7):
		for x in range(10, _cells - 10, 7):
			var p := Vector2((x + 0.5) * _spacing - _half, (z + 0.5) * _spacing - _half)
			# On ground (a bigger map has empty cells around it).
			var far: bool = (_t.get_meta(Meta.CELL_ACTIVE) as PackedByteArray)[z * _cells + x] != 0
			for hole: WaterholeStyle.Shape in holes:
				if hole.bounds.grow(15.0).has_point(p):
					far = false
			if far and spot == Vector2.ZERO:
				spot = p
	var reeds_all := _scatter({"": _disc([spot], 10.0, 255)})
	var reeds_layer := _scatter({"Waterhole Reeds": _disc([spot], 10.0, 255)})
	check("All plants paint: no reeds away from water (%d)" % _count_in(reeds_all.get("Waterhole Reeds", PackedVector2Array()), [spot], 10.0),
		_count_in(reeds_all.get("Waterhole Reeds", PackedVector2Array()), [spot], 10.0) == 0)
	check("Waterhole Reeds picked: reeds where painted (%d)" % _count_in(reeds_layer.get("Waterhole Reeds", PackedVector2Array()), [spot], 10.0),
		_count_in(reeds_layer.get("Waterhole Reeds", PackedVector2Array()), [spot], 10.0) > 20)

	# Everything painted full: never on roads, in waterhole basins, on cliffs.
	var everything := {"": _full(255)}
	for key in layers:
		everything[key] = _full(255)
	t0 = Time.get_ticks_usec()
	var full := _scatter(everything)
	var full_ms := (Time.get_ticks_usec() - t0) / 1000.0
	var roads := DetailScatter._road_mask(_t, 0, 0, _cells, _cells, _spacing, _half)
	var heights: PackedFloat32Array = _t.get_meta(Meta.HEIGHTS)
	var carve := _b.get_river_carve(_t)
	var on_road := 0
	var in_basin := 0
	var on_cliff := 0
	for key in full:
		var layer: Resource = layers[key]
		for p in full[key]:
			var c := _cell_of(p)
			if layer.avoid_roads and roads[c.y * _cells + c.x] != 0:
				on_road += 1
			var centre := Vector2((c.x + 0.5) * _spacing - _half, (c.y + 0.5) * _spacing - _half)
			if layer.waterhole_zone != 3:
				for hole: WaterholeStyle.Shape in holes:
					if hole.bounds.has_point(centre) and hole.zone_at(hole.distance(centre.x, centre.y)) == WaterholeStyle.ZONE_BASIN:
						in_basin += 1
			if layer.slope_max < 50.0:
				var i00 := c.y * resolution + c.x
				var h00 := heights[i00] - (carve[i00] if carve.size() == heights.size() else 0.0)
				var h10 := heights[i00 + 1] - (carve[i00 + 1] if carve.size() == heights.size() else 0.0)
				var h01 := heights[i00 + resolution] - (carve[i00 + resolution] if carve.size() == heights.size() else 0.0)
				var h11 := heights[i00 + resolution + 1] - (carve[i00 + resolution + 1] if carve.size() == heights.size() else 0.0)
				var gx := (h10 + h11 - h00 - h01) * 0.5 / _spacing
				var gz := (h01 + h11 - h00 - h10) * 0.5 / _spacing
				if rad_to_deg(acos(1.0 / sqrt(1.0 + gx * gx + gz * gz))) > 50.5:
					on_cliff += 1
	check("all painted full: nothing on roads (%d)" % on_road, on_road == 0)
	check("all painted full: nothing in waterhole basins (%d)" % in_basin, in_basin == 0)
	check("all painted full: nothing past 50 degrees (%d)" % on_cliff, on_cliff == 0)
	print("PERF unpainted %d instances %.0f ms | all painted full %d instances %.0f ms" % [base_total, base_ms, _total(full), full_ms])
	for key in full:
		print("  %-18s %6d -> %6d" % [key, base.get(key, PackedVector2Array()).size(), full[key].size()])

	print("RESULT %s (%d failure(s))" % ["OK" if _failures == 0 else "FAILED", _failures])
	quit(1 if _failures > 0 else 0)
