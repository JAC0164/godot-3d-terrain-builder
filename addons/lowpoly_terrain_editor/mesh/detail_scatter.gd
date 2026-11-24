@tool
extends RefCounted
## Scatters the detail layers of the terrain's biome (grass, rocks, shrubs,
## skulls...) on the terrain, chunk by chunk.
##
## Mobile-friendly by design:
## - one MultiMesh per chunk and per layer (one draw call each, only for the
##   chunks within the draw distance: visibility range culling);
## - small opaque low-poly meshes, no textures, no alpha, no shadows by
##   default;
## - colours come from the baked ground colour (TerrainShading), so details
##   match the ground under them.
##
## Placement is a pure function of global cell coordinates, the layer name and
## its seed (integer hash), so rebuilding one chunk never moves the details of
## another. Each layer's rules (slope, height, ground colour or style, roads,
## rivers, clumping) are evaluated per cell; see biomes/detail_layer.gd.

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const TerrainData = preload("../core/terrain_data.gd")
const MaterialFactory = preload("../materials/material_factory.gd")
const TerrainShading = preload("terrain_shading.gd")
const DetailMeshes = preload("detail_meshes.gd")
const TerrainBiome = preload("../biomes/terrain_biome.gd")
const DetailLayer = preload("../biomes/detail_layer.gd")
const WaterholeStyle = preload("../styles/waterhole_style.gd")

const NODE_PREFIX := "_Details"
const MAX_PER_CELL := 8
## Fields of one build() entry (one detail layer of a chunk).
const ENTRY_NODE_NAME := 0
const ENTRY_COUNT := 1
## PackedFloat32Array in the MultiMesh buffer layout.
const ENTRY_BUFFER := 2
const ENTRY_LAYER := 3
const ENTRY_MESH := 4
# DetailLayer.GroundFilter / ColorMode values as plain constants (cheaper in
# the per-cell loop than enum lookups through the preloaded script).
const _FILTER_GREENISH := 1
const _FILTER_COLOR := 2
const _FILTER_STYLES := 3
const _COLOR_GROUND := 0
const _COLOR_SIDE := 1
const _ZONE_ANYWHERE := 0
const _ZONE_OUTSIDE_BASIN := 1
const _ZONE_RIM_ONLY := 2
const _ZONE_BASIN_ONLY := 3
const _ZONE_AWAY := 4
const _INV16 := 1.0 / 65536.0
const _VEG_NORMAL := float(Meta.VEGETATION_NORMAL)
const _INV_VEGETATION := 1.0 / _VEG_NORMAL
const _INV_VEG_ABOVE := 1.0 / (255.0 - _VEG_NORMAL)
## Vegetation brush at full: instances per cell a sparse layer reaches (its
## multiplier is between x4 and x25, see Rule.max_paint).
const PAINTED_DENSITY := 0.15
const PAINT_MIN_MULTIPLIER := 4.0
const PAINT_MAX_MULTIPLIER := 25.0
## Sparse layers (at most this many instances per cell at full paint: trees,
## props) are painted in blocks: one instance per block, on its most painted
## cell, so a click grows one where it lands (see Rule.block).
const PAINT_BLOCK_MAX_DENSITY := 0.5
## Block chance per unit of boost: "All plants" (a drag stamps several times)
## and one layer picked in the list (one click = sure, also half a brush away).
const PAINT_BLOCK_GAIN_ALL := 3.0
const PAINT_BLOCK_GAIN_LAYER := 18.0
## Painted thicker: slope limit raised by up to this (never past 50 degrees).
const PAINT_EXTRA_SLOPE := 12.0
const PAINT_SLOPE_CAP := 50.0

## One layer, flattened into typed fields for the per-cell loop.
class Rule:
	var layer: DetailLayer
	## Index of the layer in the biome (1-based, as in node_name()).
	var index := 0
	var node_name := ""
	var mesh: Mesh
	var salt := 0
	var density := 0.0
	var steep_bonus := 0.0
	var edge_bonus := 0.0
	var fade_in := false
	var cos_in_none := 1.0
	var cos_in_full := 1.0
	var fade_out := false
	var cos_out_none := 0.0
	var cos_out_full := 0.0
	var height_min := 0.0
	var height_max := 0.0
	var filter := 0
	var filter_color := Color.WHITE
	var tolerance := 0.0
	var styles: Dictionary = {}
	var skip_textured := true
	var avoid_roads := true
	var avoid_rivers := true
	## Density follows the Vegetation brush (DetailLayer.vegetation_brush).
	var paintable := false
	## Multiplier at full Vegetation paint (x4 dense layers .. x25 sparse ones).
	var max_paint := PAINT_MIN_MULTIPLIER
	## Sparse layers: side, in cells, of the blocks painted placement uses
	## (about 1 / sqrt(painted density), at least min_gap); 0 = per-cell like
	## unpainted cells.
	var block := 0
	## Painted block instances closer than this (m) to a neighbouring block's
	## of a higher rank are dropped (DetailLayer.paint_spacing); 0 = no check.
	var min_gap := 0.0
	## Painted thicker relaxes ground / slope / height / zone rules.
	var relax := true
	var cos_out_none_painted := 0.0
	var cos_out_full_painted := 0.0
	var waterhole_zone := 1
	var margin := 0.0
	var clump: FastNoiseLite = null
	var clump_low := 0.0
	var clump_high := 0.0
	var scale_min := 1.0
	var scale_range := 0.0
	var small_bias := 1.0
	var height_min_scale := 1.0
	var height_range := 0.0
	var stretch := 0.0
	var tilt := 0.0
	var sink := 0.0
	var color_mode := 0
	# tint x brightness
	var tint_r := 1.0
	var tint_g := 1.0
	var tint_b := 1.0
	var jitter := 0.0
	var desaturate := 0.0
	var lighten := 0.0
	var count := 0
	var buffer := PackedFloat32Array()

static func settings(terrain: Node3D) -> Dictionary:
	return {
		"enabled": Meta.get_bool(terrain, Meta.DETAIL_ENABLED, Meta.DEFAULT_DETAIL_ENABLED),
		"density": maxf(Meta.get_float(terrain, Meta.DETAIL_DENSITY, Meta.DEFAULT_DETAIL_DENSITY), 0.0),
		"scale": maxf(Meta.get_float(terrain, Meta.DETAIL_SCALE, Meta.DEFAULT_DETAIL_SCALE), 0.05),
		"distance": maxf(Meta.get_float(terrain, Meta.DETAIL_DRAW_DISTANCE, Meta.DEFAULT_DETAIL_DRAW_DISTANCE), 0.0),
		"seed": Meta.get_int(terrain, Meta.DETAIL_SEED, 0),
		"everywhere": Meta.get_bool(terrain, Meta.DETAILS_EVERYWHERE, Meta.DEFAULT_DETAILS_EVERYWHERE),
	}

## The terrain's biome, or the built-in Temperate one.
static func biome_of(terrain: Node3D) -> TerrainBiome:
	return TerrainBiome.of(terrain)

static func node_name(index: int, layer_name: String) -> String:
	return "%s_%d_%s" % [NODE_PREFIX, index, layer_name.validate_node_name().replace(" ", "")]

## Layer index (1-based) of a detail node name (node_name()), 0 when it is not
## one.
static func node_layer_index(name: String) -> int:
	if not name.begins_with(NODE_PREFIX + "_"):
		return 0
	return int(name.substr(NODE_PREFIX.length() + 1).get_slice("_", 0))

## Bit of layer `index` (1-based, bit 0 unused) in a layer mask (build_begin,
## apply, clear_layers). A mask of -1 means every layer.
static func layer_bit(index: int) -> int:
	return 1 << index

## Distance up to which each layer is drawn, by layer index (1-based; [0]
## unused): the layer's Draw Distance, else the terrain's Detail Draw
## Distance; INF when it is always drawn (0), -1 for a layer that makes
## nothing (disabled, no density, no mesh). Used to build each layer only
## around the player (TerrainRuntime.stream_details).
static func layer_radii(terrain: Node3D) -> PackedFloat32Array:
	var biome := biome_of(terrain)
	var s := settings(terrain)
	var radii := PackedFloat32Array([-1.0])
	if biome == null:
		return radii
	var density: float = s["density"]
	var default_distance: float = s["distance"]
	var on: bool = s["enabled"] and density > 0.0
	for layer: DetailLayer in biome.detail_layers:
		if not on or layer == null or not layer.enabled or layer.density <= 0.0 or layer.resolved_mesh() == null:
			radii.append(-1.0)
			continue
		var distance: float = layer.draw_distance if layer.draw_distance >= 0.0 else default_distance
		radii.append(INF if distance <= 0.0 else distance)
	return radii

## Instance buffers of one chunk: [[node name, count, PackedFloat32Array,
## layer, mesh], ...] using the MultiMesh buffer layout (3x4 row-major transform +
## RGBA colour). Empty when details are disabled.
static func build(
	terrain: Node3D, carve: PackedFloat32Array, chunk_x: int, chunk_z: int, shading: TerrainShading.Context
) -> Array:
	var job := build_begin(terrain, carve, chunk_x, chunk_z, shading)
	build_step(job)
	return build_result(job)

## build() in slices, so a game can spread a chunk's scatter over several
## frames (TerrainRuntime): job := build_begin(), then build_step(job, budget)
## until it returns true, then build_result(job). Cells are scattered row by
## row and each one only depends on itself (and the paint around it), so the
## result is the same however it is sliced.
static func build_begin(
	terrain: Node3D, carve: PackedFloat32Array, chunk_x: int, chunk_z: int, shading: TerrainShading.Context,
	layer_mask: int = -1
) -> Dictionary:
	var empty := {"done": true, "rules": [] as Array[Rule]}
	var s := settings(terrain)
	var density: float = s["density"]
	if not s["enabled"] or density <= 0.0:
		return empty

	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var cell_count := resolution - 1
	var min_x: int = chunk_x * Meta.TERRAIN_CHUNK_CELLS
	var min_z: int = chunk_z * Meta.TERRAIN_CHUNK_CELLS
	if min_x >= cell_count or min_z >= cell_count:
		return empty
	var max_x: int = mini(min_x + Meta.TERRAIN_CHUNK_CELLS, cell_count)
	var max_z: int = mini(min_z + Meta.TERRAIN_CHUNK_CELLS, cell_count)
	var spacing := world_size / float(maxi(cell_count, 1))
	var detail_scale: float = s["scale"]
	var detail_seed: int = s["seed"]
	var rules := _compile(biome_of(terrain), density, detail_scale * spacing, detail_seed, spacing)
	if layer_mask != -1:
		# Only some layers: each layer's placement depends on itself only (cell,
		# layer name, seed), so the others are left out without changing it.
		var kept: Array[Rule] = []
		for rule: Rule in rules:
			if (layer_mask & layer_bit(rule.index)) != 0:
				kept.append(rule)
		rules = kept
	if rules.is_empty():
		return empty

	var half := world_size * 0.5
	var top_offset: float = Meta.get_float(terrain, Meta.TOP_Y_OFFSET, 0.0)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var carved := carve.size() == heights.size()
	var cell_flags: PackedByteArray = terrain.get_meta(Meta.CELL_ACTIVE, PackedByteArray())
	var fast_active := cell_flags.size() == cell_count * cell_count
	var cell_styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES, PackedInt32Array())
	# Vegetation brush: density multiplier per cell (x0..x4-x25), for the layers
	# that follow it ("all") and per layer (that layer only, any layer).
	var paint := Meta.vegetation_paint(terrain)
	# Details Everywhere off: the biome grows only on the generated-map cells,
	# elsewhere only where the brush painted more than normal.
	var everywhere: bool = s["everywhere"]
	var grow: PackedByteArray = paint.get(Meta.VEGETATION_GROW, PackedByteArray())
	var has_grow := grow.size() == cell_count * cell_count
	if not everywhere and not has_grow and paint.is_empty():
		return empty
	var vegetation: PackedByteArray = paint.get(Meta.VEGETATION_ALL, PackedByteArray())
	var painted := vegetation.size() == cell_count * cell_count
	var layer_paint: Array[PackedByteArray] = []
	var any_layer_paint := false
	for rule: Rule in rules:
		var values: PackedByteArray = paint.get(String(rule.layer.name), PackedByteArray())
		if values.size() != cell_count * cell_count:
			values = PackedByteArray()
		any_layer_paint = any_layer_paint or not values.is_empty()
		layer_paint.append(values)
	var need_edge := false
	var need_roads := false
	for rule: Rule in rules:
		need_edge = need_edge or rule.edge_bonus > 0.0
		need_roads = need_roads or rule.avoid_roads

	var cw := max_x - min_x
	var ch := max_z - min_z
	var on_road := _road_mask(terrain, min_x, min_z, cw, ch, spacing, half) if need_roads else PackedByteArray()

	var cos_steep_none := cos(deg_to_rad(20.0))
	var cos_steep_full := cos(deg_to_rad(45.0))
	var chunk_rect := Rect2(float(min_x) * spacing - half, float(min_z) * spacing - half, float(cw) * spacing, float(ch) * spacing)
	var holes := WaterholeStyle.shapes(terrain, chunk_rect)
	var has_holes := not holes.is_empty()
	return {
		"done": false, "z": min_z, "terrain": terrain, "carve": carve, "carved": carved, "shading": shading,
		"rules": rules, "resolution": resolution, "cell_count": cell_count, "spacing": spacing, "half": half,
		"min_x": min_x, "min_z": min_z, "max_x": max_x, "max_z": max_z, "cw": cw,
		"top_offset": top_offset, "heights": heights, "cell_flags": cell_flags, "fast_active": fast_active,
		"cell_styles": cell_styles, "everywhere": everywhere, "grow": grow, "has_grow": has_grow,
		"vegetation": vegetation, "painted": painted, "layer_paint": layer_paint, "any_layer_paint": any_layer_paint,
		"need_edge": need_edge, "need_roads": need_roads, "on_road": on_road,
		"cos_steep_none": cos_steep_none, "cos_steep_full": cos_steep_full, "holes": holes, "has_holes": has_holes,
		# style id -> [textured top, top colour, side colour]
		"style_cache": {},
		# Painted blocks of sparse layers: Vector3i(block x, block z, rule) -> cell.
		"block_cache": {},
	}

## Scatters the next cells of build_begin()'s job, row by row; `budget_usec`
## > 0 stops after about that long (checked every 8 cells; 0 = all). True
## when every row is done.
static func build_step(job: Dictionary, budget_usec: int = 0) -> bool:
	if job["done"]:
		return true
	var start := Time.get_ticks_usec()
	# Hot loop: everything in locals.
	var terrain: Node3D = job["terrain"]
	var carve: PackedFloat32Array = job["carve"]
	var carved: bool = job["carved"]
	var shading: TerrainShading.Context = job["shading"]
	var rules: Array[Rule] = job["rules"]
	var resolution: int = job["resolution"]
	var cell_count: int = job["cell_count"]
	var spacing: float = job["spacing"]
	var half: float = job["half"]
	var min_x: int = job["min_x"]
	var min_z: int = job["min_z"]
	var max_x: int = job["max_x"]
	var max_z: int = job["max_z"]
	var cw: int = job["cw"]
	var top_offset: float = job["top_offset"]
	var heights: PackedFloat32Array = job["heights"]
	var cell_flags: PackedByteArray = job["cell_flags"]
	var fast_active: bool = job["fast_active"]
	var cell_styles: PackedInt32Array = job["cell_styles"]
	var everywhere: bool = job["everywhere"]
	var grow: PackedByteArray = job["grow"]
	var has_grow: bool = job["has_grow"]
	var vegetation: PackedByteArray = job["vegetation"]
	var painted: bool = job["painted"]
	var layer_paint: Array[PackedByteArray] = job["layer_paint"]
	var any_layer_paint: bool = job["any_layer_paint"]
	var need_edge: bool = job["need_edge"]
	var need_roads: bool = job["need_roads"]
	var on_road: PackedByteArray = job["on_road"]
	var cos_steep_none: float = job["cos_steep_none"]
	var cos_steep_full: float = job["cos_steep_full"]
	var holes: Array = job["holes"]
	var has_holes: bool = job["has_holes"]
	var style_cache: Dictionary = job["style_cache"]
	var block_cache: Dictionary = job["block_cache"]

	var z: int = job["z"]
	var resume_x: int = job.get("x", min_x)
	var stopped := false
	while z < max_z:
		for x in range(resume_x, max_x):
			# Every 8 cells too: a dense row (grass) is several ms on a phone.
			if budget_usec > 0 and x != resume_x and (x - min_x) % 8 == 0 and Time.get_ticks_usec() - start >= budget_usec:
				job["x"] = x
				stopped = true
				break
			var cell := z * cell_count + x
			var active: bool = cell_flags[cell] != 0 if fast_active else TerrainData.cell_active(terrain, x, z)
			if not active:
				continue
			# Bare cell (Details Everywhere off, not a generated-map cell):
			# only what the brush painted more than normal grows there.
			var bare := not everywhere and not (has_grow and grow[cell] != 0)
			if bare:
				var painted_more := painted and vegetation[cell] > Meta.VEGETATION_NORMAL
				if not painted_more and any_layer_paint:
					for values in layer_paint:
						if not values.is_empty() and values[cell] > Meta.VEGETATION_NORMAL:
							painted_more = true
							break
				if not painted_more:
					continue
			var road := need_roads and on_road[(z - min_z) * cw + (x - min_x)] != 0
			var style_id: int = maxi(cell_styles[cell], 0) if cell < cell_styles.size() else 0
			var style: Variant = style_cache.get(style_id)
			if style == null:
				style = [
					MaterialFactory.terrain_style_texture(terrain, style_id, true) != null,
					MaterialFactory.terrain_style_color(terrain, style_id, true),
					MaterialFactory.terrain_style_color(terrain, style_id, false),
				]
				style_cache[style_id] = style
			var textured: bool = style[0]

			var i00 := z * resolution + x
			var i10 := i00 + 1
			var i01 := i00 + resolution
			var i11 := i01 + 1
			var river := carved and (carve[i00] > 0.001 or carve[i10] > 0.001 or carve[i01] > 0.001 or carve[i11] > 0.001)
			var zone := WaterholeStyle.ZONE_NONE
			if has_holes:
				var cx := (float(x) + 0.5) * spacing - half
				var cz := (float(z) + 0.5) * spacing - half
				for hole: WaterholeStyle.Shape in holes:
					if not hole.bounds.has_point(Vector2(cx, cz)):
						continue
					var hole_zone := hole.zone_at(hole.distance(cx, cz))
					if hole_zone == WaterholeStyle.ZONE_BASIN:
						zone = hole_zone
						break
					if hole_zone == WaterholeStyle.ZONE_RIM:
						zone = hole_zone
				# The basin is carved too: it is not a river bed.
				if zone == WaterholeStyle.ZONE_BASIN:
					river = false
			var h00 := heights[i00] - (carve[i00] if carved else 0.0)
			var h10 := heights[i10] - (carve[i10] if carved else 0.0)
			var h01 := heights[i01] - (carve[i01] if carved else 0.0)
			var h11 := heights[i11] - (carve[i11] if carved else 0.0)
			var mean_height := (h00 + h10 + h01 + h11) * 0.25

			# Average cell slope (cos of the angle).
			var gx := (h10 + h11 - h00 - h01) * 0.5 / spacing
			var gz := (h01 + h11 - h00 - h10) * 0.5 / spacing
			var normal_y := 1.0 / sqrt(1.0 + gx * gx + gz * gz)
			var steep := 1.0 - smoothstep(cos_steep_full, cos_steep_none, normal_y)

			var ground0: Color = style[1]
			var ground1: Color = style[1]
			if shading != null:
				var face := ((z - shading.min_z) * shading.cw + (x - shading.min_x)) * 2
				ground0 = shading.faces[face]
				ground1 = shading.faces[face + 1]
			var ground := ground0.lerp(ground1, 0.5)

			var edge := false
			if need_edge:
				if fast_active and x > 0 and z > 0 and x < cell_count - 1 and z < cell_count - 1:
					edge = cell_flags[cell - 1] == 0 or cell_flags[cell + 1] == 0 or cell_flags[cell - cell_count] == 0 or cell_flags[cell + cell_count] == 0
				else:
					edge = (
						not _active(terrain, cell_flags, fast_active, cell_count, x - 1, z)
						or not _active(terrain, cell_flags, fast_active, cell_count, x + 1, z)
						or not _active(terrain, cell_flags, fast_active, cell_count, x, z - 1)
						or not _active(terrain, cell_flags, fast_active, cell_count, x, z + 1)
					)

			var x0 := float(x) * spacing - half
			var z0 := float(z) * spacing - half
			var veg_all := float(vegetation[cell]) if painted else _VEG_NORMAL

			var rule_index := -1
			for rule: Rule in rules:
				rule_index += 1
				if (road and rule.avoid_roads) or (river and rule.avoid_rivers) or (textured and rule.skip_textured):
					continue
				# Instances expected if every rule fully passes (the rules below
				# can only lower it). The random draw comes first: on sparse
				# layers (trees, props) most cells lose it and skip the rules.
				var expected := rule.density * (1.0 + rule.steep_bonus * steep + (rule.edge_bonus if edge else 0.0))
				# Painted thicker than normal also fills the gaps between patches.
				# Vegetation brush: below normal = fewer (linear), above = a
				# boost 0..1 towards the layer's max_paint, which also fills
				# the gaps between patches and relaxes the rules below.
				var fill := 0.0
				var boost := 0.0
				var layer_boosted := false
				var extra := 0.0
				var v_all := veg_all if rule.paintable else _VEG_NORMAL
				var v_layer := float(layer_paint[rule_index][cell]) if any_layer_paint and not layer_paint[rule_index].is_empty() else _VEG_NORMAL
				if bare or v_all != _VEG_NORMAL or v_layer != _VEG_NORMAL:
					if v_all <= 0.0 or v_layer <= 0.0:
						continue
					var b_layer := maxf(v_layer - _VEG_NORMAL, 0.0) * _INV_VEG_ABOVE
					boost = minf(maxf(v_all - _VEG_NORMAL, 0.0) * _INV_VEG_ABOVE + b_layer, 1.0)
					# A bare cell starts from nothing: the boost alone (up to
					# the same max_paint) makes this layer grow there.
					if bare and boost <= 0.0:
						continue
					layer_boosted = b_layer > 0.0 and rule.relax
					var lowered := minf(v_all, _VEG_NORMAL) * _INV_VEGETATION * minf(v_layer, _VEG_NORMAL) * _INV_VEGETATION
					if rule.block > 0 and boost > 0.0:
						# Sparse layer painted more: the biome's own instances
						# stay (none on bare ground), plus one per block on its
						# most painted cell, so a click grows one where it lands.
						expected = 0.0 if bare else expected * lowered
						var candidate: Array = _block_candidate(block_cache, rule_index, rule, x, z, cell_count, cell_flags, fast_active, vegetation, painted, layer_paint[rule_index], heights, carve, carved, resolution, spacing)
						if candidate[0] == cell:
							var bx := floori(float(x) / float(rule.block))
							var bz := floori(float(z) / float(rule.block))
							if _block_grows(candidate, bx, bz, rule):
								extra = 1.0
								# Not too close to a neighbouring painted one
								# (crowns of a painted forest do not cross).
								if rule.min_gap > 0.0 and _crowded(block_cache, rule_index, rule, bx, bz, cell, cell_count, cell_flags, fast_active, vegetation, painted, layer_paint[rule_index], heights, carve, carved, resolution, spacing):
									extra = 0.0
						if expected <= 0.0 and extra <= 0.0:
							continue
					else:
						expected *= lowered * (boost * rule.max_paint if bare else 1.0 + boost * (rule.max_paint - 1.0))
					fill = minf(boost * 3.0, 1.0)
					if not rule.relax:
						boost = 0.0
					# Spaced sparse layer: the biome's own instances stay as on
					# unpainted ground (rules not relaxed, no patch fill), so
					# only the spaced block instances are added.
					if extra <= 0.0 and rule.block > 0 and rule.min_gap > 0.0:
						boost = 0.0
						fill = 0.0
						layer_boosted = false
				var hc: int = x * 374761393 + z * 668265263 + rule.salt * 1442695041
				hc = (hc ^ (hc >> 15)) * 2246822519
				hc = (hc ^ (hc >> 13)) * 3266489917
				var chance := float((hc ^ (hc >> 16)) & 0xFFFF) * _INV16
				if expected < 1.0 and chance >= expected and extra <= 0.0:
					continue
				if (mean_height < rule.height_min or mean_height > rule.height_max) and boost <= 0.0:
					continue
				var zone_rule := rule.waterhole_zone
				# Rim / basin-only layers picked in the brush list grow where painted.
				if layer_boosted and (zone_rule == _ZONE_RIM_ONLY or zone_rule == _ZONE_BASIN_ONLY):
					zone_rule = _ZONE_ANYWHERE if zone_rule == _ZONE_BASIN_ONLY else _ZONE_OUTSIDE_BASIN
				if zone_rule != _ZONE_ANYWHERE:
					if zone_rule == _ZONE_OUTSIDE_BASIN:
						if zone == WaterholeStyle.ZONE_BASIN:
							continue
					elif zone_rule == _ZONE_RIM_ONLY:
						if zone != WaterholeStyle.ZONE_RIM:
							continue
					elif zone_rule == _ZONE_BASIN_ONLY:
						if zone != WaterholeStyle.ZONE_BASIN:
							continue
					elif zone != WaterholeStyle.ZONE_NONE:
						continue
				var weight := 1.0
				if rule.fade_out:
					# A painted block cell was picked with the full painted slope
					# limit (_block_candidate): judge it the same way.
					var slope_boost := 1.0 if extra > 0.0 and rule.relax else boost
					if slope_boost > 0.0:
						weight = smoothstep(lerpf(rule.cos_out_none, rule.cos_out_none_painted, slope_boost), lerpf(rule.cos_out_full, rule.cos_out_full_painted, slope_boost), normal_y)
					else:
						weight = smoothstep(rule.cos_out_none, rule.cos_out_full, normal_y)
				if rule.fade_in:
					weight *= 1.0 - smoothstep(rule.cos_in_full, rule.cos_in_none, normal_y)
				if weight <= 0.0:
					continue
				var filter := rule.filter
				if filter == _FILTER_GREENISH:
					var greenish := smoothstep(0.02, 0.1, ground.g - maxf(ground.r, ground.b))
					weight *= greenish if boost <= 0.0 else lerpf(greenish, 1.0, boost)
				elif filter == _FILTER_COLOR:
					var dr := ground.r - rule.filter_color.r
					var dg := ground.g - rule.filter_color.g
					var db := ground.b - rule.filter_color.b
					var near := 1.0 - smoothstep(rule.tolerance * 0.6, rule.tolerance, sqrt(dr * dr + dg * dg + db * db))
					weight *= near if boost <= 0.0 else lerpf(near, 1.0, boost)
				elif filter == _FILTER_STYLES and not rule.styles.has(style_id):
					if boost <= 0.0:
						continue
					weight *= boost
				if weight <= 0.0:
					continue
				expected *= weight
				if rule.clump != null:
					var patch := smoothstep(rule.clump_low, rule.clump_high, rule.clump.get_noise_2d(float(x) + 0.5, float(z) + 0.5))
					expected *= patch + (1.0 - patch) * fill
				# The painted block instance ignores the patches (painted = filled)
				# and the slope / ground fade: a cell the rules allow at all
				# (weight > 0 here) gets it, so a click is never lost.
				expected += extra
				# floor(expected) + 1 with probability frac(expected).
				var count := int(expected)
				if chance < expected - float(count):
					count += 1
				if count == 0:
					continue
				count = mini(count, MAX_PER_CELL)
				rule.count += count
				# Per-instance work is all inline (GDScript calls are costly):
				# one 64-bit hash, remixed for more random bits, 16 bits each.
				var base_color: Color = style[2] if rule.color_mode == _COLOR_SIDE else Color.WHITE
				var margin := rule.margin
				var span := 1.0 - 2.0 * margin
				for k in range(count):
					var r1: int = x * 374761393 + z * 668265263 + (rule.salt + 7919 * (k + 1)) * 1442695041
					r1 = (r1 ^ (r1 >> 15)) * 2246822519
					r1 = (r1 ^ (r1 >> 13)) * 3266489917
					r1 ^= r1 >> 16
					var r2: int = (r1 ^ (r1 >> 29)) * 3935559000370003845
					r2 ^= r2 >> 32
					var u := margin + span * float(r1 & 0xFFFF) * _INV16
					var v := margin + span * float((r1 >> 16) & 0xFFFF) * _INV16
					var size_random := float((r1 >> 32) & 0xFFFF) * _INV16
					if rule.small_bias != 1.0:
						size_random = size_random * size_random if rule.small_bias == 2.0 else pow(size_random, rule.small_bias)
					var size := rule.scale_min + rule.scale_range * size_random
					var size_y := size * (rule.height_min_scale + rule.height_range * float(r2 & 0xFFFF) * _INV16)
					# Yaw rotation columns, then optional tilt, then local scale.
					var yaw := float((r1 >> 48) & 0xFFFF) * _INV16 * TAU
					var cos_yaw := cos(yaw)
					var sin_yaw := sin(yaw)
					var axis_x := Vector3(cos_yaw, 0.0, -sin_yaw)
					var axis_y := Vector3.UP
					var axis_z := Vector3(sin_yaw, 0.0, cos_yaw)
					if rule.tilt > 0.0:
						var r3: int = (r2 ^ (r2 >> 31)) * 2685821657736338717
						var axis_angle := float(r3 & 0xFFFF) * _INV16 * TAU
						var tilt := Basis(Vector3(cos(axis_angle), 0.0, sin(axis_angle)), rule.tilt * float((r3 >> 16) & 0xFFFF) * _INV16)
						axis_x = tilt * axis_x
						axis_y = tilt * axis_y
						axis_z = tilt * axis_z
					axis_x *= size * (1.0 + rule.stretch * float((r2 >> 16) & 0xFFFF) * _INV16)
					axis_y *= size_y
					axis_z *= size
					# Height on the cell's two top triangles (split along p00-p11).
					var y := (h00 + u * (h10 - h00) + v * (h11 - h10)) if u >= v else (h00 + v * (h01 - h00) + u * (h11 - h01))
					y += top_offset - rule.sink * size_y

					var c := base_color
					if rule.color_mode == _COLOR_GROUND:
						c = ground0 if u >= v else ground1
					if rule.desaturate > 0.0:
						var grey := c.get_luminance()
						c = c.lerp(Color(grey, grey, grey), rule.desaturate)
					if rule.lighten > 0.0:
						c = c.lerp(Color.WHITE, rule.lighten)
					var light := 1.0 + rule.jitter * (2.0 * float((r2 >> 32) & 0xFFFF) * _INV16 - 1.0)
					rule.buffer.append_array([
						axis_x.x, axis_y.x, axis_z.x, x0 + u * spacing,
						axis_x.y, axis_y.y, axis_z.y, y,
						axis_x.z, axis_y.z, axis_z.z, z0 + v * spacing,
						minf(c.r * rule.tint_r * light, 1.0), minf(c.g * rule.tint_g * light, 1.0), minf(c.b * rule.tint_b * light, 1.0), 1.0,
					])
		if stopped:
			break
		resume_x = min_x
		z += 1
		if budget_usec > 0 and Time.get_ticks_usec() - start >= budget_usec:
			break
	if not stopped:
		job["x"] = min_x
	job["z"] = z
	job["done"] = z >= max_z
	return job["done"]

## build()'s entries from a finished build_step() job.
static func build_result(job: Dictionary) -> Array:
	var result := []
	for rule: Rule in job["rules"]:
		# In ENTRY_* order.
		result.append([rule.node_name, rule.count, rule.buffer, rule.layer, rule.mesh])
	return result

## Writes `entries` (from build()) into the detail nodes under `chunk`,
## creating / updating / removing them as needed. `add_child` adds a node with
## the right owner. `layer_mask` (layer_bit()) = the layers `entries` were
## built for: the nodes of the other layers are left alone.
static func apply(terrain: Node3D, chunk: Node3D, entries: Array, add_child: Callable, layer_mask: int = -1) -> void:
	var default_distance: float = settings(terrain)["distance"]
	var keep: Dictionary = {}
	for entry: Array in entries:
		var count: int = entry[ENTRY_COUNT]
		if count == 0:
			continue
		var name: String = entry[ENTRY_NODE_NAME]
		var layer: DetailLayer = entry[ENTRY_LAYER]
		keep[name] = true
		var node := chunk.get_node_or_null(name) as MultiMeshInstance3D
		if node == null:
			node = MultiMeshInstance3D.new()
			node.name = name
			add_child.call(chunk, node)
		var distance: float = layer.draw_distance if layer.draw_distance >= 0.0 else default_distance
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if layer.cast_shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		node.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		node.visibility_range_end = distance
		node.visibility_range_end_margin = distance * 0.05 if distance > 0.0 else 0.0
		var material := layer_material(layer, terrain)
		var multimesh := MultiMesh.new()
		multimesh.transform_format = MultiMesh.TRANSFORM_3D
		multimesh.use_colors = true
		var entry_mesh: Mesh = entry[ENTRY_MESH]
		multimesh.mesh = _mesh_for(layer, material, entry_mesh)
		multimesh.instance_count = count
		multimesh.buffer = entry[ENTRY_BUFFER]
		node.multimesh = multimesh
		node.material_override = material
	for child in chunk.get_children():
		var child_name := String(child.name)
		if not child_name.begins_with(NODE_PREFIX) or keep.has(child_name):
			continue
		if layer_mask != -1 and (layer_mask & layer_bit(node_layer_index(child_name))) == 0:
			continue
		chunk.remove_child(child)
		child.queue_free()

## Material of a layer's detail nodes. Built-in plants (grass, shrubs, trees)
## get the wind material of their kind, rigid meshes (rocks, mounds, bones)
## the plain one; a custom mesh gets the plain one, or null to keep its own
## materials (a Model, or a Mesh with `use_mesh_materials`). The terrain's
## Detail Material (Meta.DETAIL_MATERIAL) replaces all of them except those.
## The terrain's custom detail Material (Meta.DETAIL_MATERIAL); null when
## unset or when the slot holds anything else.
static func custom_material(terrain: Node3D) -> Material:
	var value: Variant = Meta.get_optional(terrain, Meta.DETAIL_MATERIAL)
	if value is Material:
		var material: Material = value
		return material
	return null

static func layer_material(layer: DetailLayer, terrain: Node3D = null) -> Material:
	if layer.keeps_own_materials():
		return null
	var custom: Material = null
	if terrain != null:
		custom = custom_material(terrain)
	if custom:
		return custom
	if layer.is_custom():
		return MaterialFactory.detail_material()
	return MaterialFactory.detail_material(MaterialFactory.wind_profile(layer.builtin_mesh))

## The one-time work of the first chunk's details, one Callable per piece:
## making and compiling each detail material (~25 ms each on a laptop: a wind
## ShaderMaterial compiles when made, a StandardMaterial3D on first use), then
## each layer's mesh (built-in shape or merged model). A game loading over
## several frames runs them as steps of their own before the first chunk's
## details (TerrainRuntime), instead of all in that chunk's frame.
static func warmups(terrain: Node3D) -> Array[Callable]:
	var warmups: Array[Callable] = []
	var biome := biome_of(terrain)
	if biome == null:
		return warmups
	var custom := custom_material(terrain)
	if custom != null:
		warmups.append(MaterialFactory.compile.bind(custom))
	var seen := {}
	var layers: Array[DetailLayer] = []
	for layer: DetailLayer in biome.detail_layers:
		if layer == null or not layer.enabled or layer.density <= 0.0:
			continue
		layers.append(layer)
		if custom != null or layer.keeps_own_materials():
			continue
		var profile := "" if layer.is_custom() else MaterialFactory.wind_profile(layer.builtin_mesh)
		if not seen.has(profile):
			seen[profile] = true
			warmups.append(_compile_detail_material.bind(profile))
	for layer: DetailLayer in layers:
		warmups.append(layer.resolved_mesh)
	return warmups

static func _compile_detail_material(profile: String) -> void:
	MaterialFactory.compile(MaterialFactory.detail_material(profile))

## Gives the detail nodes already in the scene their current layer_material():
## a saved scene keeps the material it was built with (scenes built before the
## wind existed hold the plain one). Run when the scene loads.
static func refresh_materials(terrain: Node3D) -> void:
	var root := terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME)
	if root == null:
		return
	var materials: Dictionary = {}
	var layers: Dictionary = {}
	var index := 0
	for layer: DetailLayer in biome_of(terrain).detail_layers:
		index += 1
		if layer != null:
			materials[node_name(index, layer.name)] = layer_material(layer, terrain)
			layers[node_name(index, layer.name)] = layer
	for chunk in root.get_children():
		for child in chunk.get_children():
			var node := child as MultiMeshInstance3D
			if node and materials.has(String(node.name)):
				var layer: DetailLayer = layers[String(node.name)]
				node.material_override = materials[String(node.name)]
				# Built-in mesh to match: grass one-sided with the two-sided material.
				var built_in := DetailMeshes.builtin(layer.builtin_mesh)
				if node.multimesh != null and node.multimesh.mesh != null and not layer.is_custom() and built_in != null:
					# Built-in meshes are ArrayMeshes (DetailMeshes.build()).
					var wanted: ArrayMesh = _mesh_for(layer, node.material_override, built_in)
					# A saved mesh of another kind (the layer was a custom
					# SphereMesh...) is replaced too.
					var current := node.multimesh.mesh as ArrayMesh
					# Only when the triangle count differs (opening a scene
					# leaves it unchanged otherwise).
					if current == null or current.get_surface_count() == 0 or current.surface_get_array_len(0) != wanted.surface_get_array_len(0):
						node.multimesh.mesh = wanted

## Built-in grass with the two-sided grass material: one triangle per blade
## instead of two (DetailMeshes.builtin(i, true)); otherwise `mesh` itself.
static func _mesh_for(layer: DetailLayer, material: Material, mesh: Mesh) -> Mesh:
	if not layer.is_custom() and MaterialFactory.is_two_sided_detail(material) and DetailMeshes.has_thin_parts(layer.builtin_mesh):
		return DetailMeshes.builtin(layer.builtin_mesh, true)
	return mesh

## Removes every detail node of a chunk.
static func clear(chunk: Node3D) -> void:
	for child in chunk.get_children():
		if String(child.name).begins_with(NODE_PREFIX):
			chunk.remove_child(child)
			child.queue_free()

## Removes the detail nodes of the layers in `layer_mask` (layer_bit()).
static func clear_layers(chunk: Node3D, layer_mask: int) -> void:
	for child in chunk.get_children():
		var child_name := String(child.name)
		if child_name.begins_with(NODE_PREFIX) and (layer_mask & layer_bit(node_layer_index(child_name))) != 0:
			chunk.remove_child(child)
			child.queue_free()

## Instances per layer over the whole terrain, for stats: {node name: count}.
static func count_instances(terrain: Node3D) -> Dictionary:
	var counts: Dictionary = {}
	var root := terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME)
	if root == null:
		return counts
	for chunk in root.get_children():
		for child in chunk.get_children():
			var node := child as MultiMeshInstance3D
			if node and String(node.name).begins_with(NODE_PREFIX) and node.multimesh:
				var key := String(node.name).substr(String(node.name).find("_", NODE_PREFIX.length() + 1) + 1)
				var previous: int = counts.get(key, 0)
				counts[key] = previous + node.multimesh.instance_count
	return counts

# -----------------------------------------------------------------------------

## `size_scale` = Detail Scale x cell size (built-in meshes and Mesh are in
## cell units); a Model is in metres, so it only gets the Detail Scale.
static func _compile(biome: TerrainBiome, density_scale: float, size_scale: float, detail_seed: int = 0, cell_size: float = 1.0) -> Array[Rule]:
	var rules: Array[Rule] = []
	var index := 0
	for layer: DetailLayer in biome.detail_layers:
		index += 1
		if layer == null or not layer.enabled or layer.density <= 0.0:
			continue
		var mesh: Mesh = layer.resolved_mesh()
		if mesh == null:
			continue
		var rule := Rule.new()
		rule.layer = layer
		rule.index = index
		rule.node_name = node_name(index, layer.name)
		rule.mesh = mesh
		rule.salt = (String(layer.name).hash() & 0x7FFFFFFF) + (layer.placement_seed + detail_seed) * 104729
		rule.density = layer.density * density_scale
		rule.steep_bonus = layer.steep_bonus
		rule.edge_bonus = layer.edge_bonus
		var slope_min := clampf(layer.slope_min, 0.0, 90.0)
		var slope_max := clampf(layer.slope_max, slope_min, 90.0)
		var fade := clampf(layer.slope_fade, 0.0, maxf(slope_max - slope_min, 0.0))
		rule.fade_in = slope_min > 0.0
		rule.cos_in_none = cos(deg_to_rad(slope_min))
		rule.cos_in_full = cos(deg_to_rad(minf(slope_min + fade, 90.0))) - 0.000001
		rule.fade_out = slope_max < 90.0
		rule.cos_out_none = cos(deg_to_rad(slope_max))
		rule.cos_out_full = cos(deg_to_rad(maxf(slope_max - fade, 0.0))) + 0.000001
		var painted_max := maxf(slope_max, minf(slope_max + PAINT_EXTRA_SLOPE, PAINT_SLOPE_CAP))
		rule.cos_out_none_painted = cos(deg_to_rad(painted_max))
		rule.cos_out_full_painted = cos(deg_to_rad(maxf(painted_max - fade, 0.0))) + 0.000001
		rule.height_min = layer.height_min
		rule.height_max = layer.height_max
		rule.filter = layer.ground_filter
		rule.filter_color = layer.filter_color
		rule.tolerance = maxf(layer.filter_tolerance, 0.001)
		for style_id: int in layer.filter_styles:
			rule.styles[style_id] = true
		rule.skip_textured = layer.skip_textured and layer.ground_filter != DetailLayer.GroundFilter.STYLES
		rule.avoid_roads = layer.avoid_roads
		rule.avoid_rivers = layer.avoid_rivers
		rule.paintable = layer.vegetation_brush == DetailLayer.VegetationBrush.FOLLOW or (
			layer.vegetation_brush == DetailLayer.VegetationBrush.AUTO
			and (layer.is_custom() or MaterialFactory.wind_profile(layer.builtin_mesh) != ""))
		rule.max_paint = clampf(PAINTED_DENSITY / maxf(rule.density, 0.000001), PAINT_MIN_MULTIPLIER, PAINT_MAX_MULTIPLIER)
		var painted_density := rule.density * rule.max_paint
		if painted_density > 0.0 and painted_density < PAINT_BLOCK_MAX_DENSITY:
			rule.block = clampi(roundi(1.0 / sqrt(painted_density)), 2, 8)
			# Painted instances keep paint_spacing x their width apart: blocks
			# at least that wide, so only the 8 neighbouring blocks can be too
			# close (_crowded).
			var layer_scale_gap := size_scale / maxf(cell_size, 0.000001) if layer.model != null else size_scale
			var mean_size := (minf(layer.scale_min, layer.scale_max) + absf(layer.scale_max - layer.scale_min) * 0.5) * layer_scale_gap
			var box := mesh.get_aabb()
			var width := (box.size.x + box.size.z) * 0.5 * mean_size * (1.0 + maxf(layer.stretch_max - 1.0, 0.0) * 0.5)
			rule.min_gap = maxf(layer.paint_spacing, 0.0) * width
			if rule.min_gap > 0.0:
				rule.block = clampi(maxi(rule.block, ceili(rule.min_gap / maxf(cell_size, 0.000001))), 2, 16)
		rule.relax = layer.paint_relaxes_rules
		rule.waterhole_zone = layer.waterhole_zone
		rule.margin = clampf(layer.cell_margin, 0.0, 0.45)
		if layer.clump_size > 0.0:
			# Native noise (C++): evaluating it per cell is cheap, unlike a
			# GDScript noise. Sampled at global cell coordinates (no seams).
			rule.clump = FastNoiseLite.new()
			rule.clump.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
			rule.clump.seed = rule.salt & 0x7FFFFFFF
			rule.clump.frequency = 1.0 / layer.clump_size
			rule.clump.fractal_octaves = 2
			# The noise is centred on 0 with most values within +/-0.5: shift
			# the threshold with the wanted coverage.
			var threshold := (0.5 - clampf(layer.clump_coverage, 0.0, 1.0)) * 0.8
			rule.clump_low = threshold - 0.08
			rule.clump_high = threshold + 0.08
		var layer_scale := size_scale / maxf(cell_size, 0.000001) if layer.model != null else size_scale
		rule.scale_min = minf(layer.scale_min, layer.scale_max) * layer_scale
		rule.scale_range = absf(layer.scale_max - layer.scale_min) * layer_scale
		rule.small_bias = maxf(layer.small_bias, 0.01)
		rule.height_min_scale = minf(layer.height_scale_min, layer.height_scale_max)
		rule.height_range = absf(layer.height_scale_max - layer.height_scale_min)
		rule.stretch = maxf(layer.stretch_max - 1.0, 0.0)
		rule.tilt = deg_to_rad(layer.max_tilt)
		rule.sink = layer.sink
		rule.color_mode = layer.color_mode
		rule.tint_r = layer.tint.r * layer.brightness
		rule.tint_g = layer.tint.g * layer.brightness
		rule.tint_b = layer.tint.b * layer.brightness
		rule.jitter = layer.brightness_jitter
		rule.desaturate = layer.desaturate
		rule.lighten = layer.lighten
		rules.append(rule)
	return rules

## Cells of a chunk covered by a road: each road segment only tests the cells
## inside its own bounding box.
static func _road_mask(terrain: Node3D, min_x: int, min_z: int, cw: int, ch: int, spacing: float, half: float) -> PackedByteArray:
	var on_road := PackedByteArray()
	on_road.resize(cw * ch)
	var max_x := min_x + cw
	var max_z := min_z + ch
	var chunk_rect := Rect2(float(min_x) * spacing - half, float(min_z) * spacing - half, float(cw) * spacing, float(ch) * spacing)
	for road_variant: Variant in terrain.get_meta(Meta.ROADS, []):
		if typeof(road_variant) != TYPE_DICTIONARY:
			continue
		var road: Dictionary = road_variant
		var road_width: float = road.get("width", Meta.DEFAULT_ROAD_WIDTH)
		var radius := road_width * 0.5 + spacing * 0.75
		var points: Array = road.get("points", [])
		for i in range(points.size() - 1):
			var a: Vector2 = points[i]
			var b: Vector2 = points[i + 1]
			var box := Rect2(a, Vector2.ZERO).expand(b).grow(radius)
			if not box.intersects(chunk_rect):
				continue
			var cx0 := maxi(int(floorf((box.position.x + half) / spacing)), min_x)
			var cz0 := maxi(int(floorf((box.position.y + half) / spacing)), min_z)
			var cx1 := mini(int(floorf((box.end.x + half) / spacing)), max_x - 1)
			var cz1 := mini(int(floorf((box.end.y + half) / spacing)), max_z - 1)
			for cz in range(cz0, cz1 + 1):
				for cx in range(cx0, cx1 + 1):
					var center := Vector2((float(cx) + 0.5) * spacing - half, (float(cz) + 0.5) * spacing - half)
					if GridMath.distance_to_segment(center, a, b) <= radius:
						on_road[(cz - min_z) * cw + (cx - min_x)] = 1
	return on_road

## [cell, top "All plants" paint, top layer paint] of the block around (x, z)
## for a painted sparse layer. The cell holds its instance: the most painted
## ground cell not too steep for the layer (paint for "All plants" if the
## layer follows it + its own paint), ties broken by a fixed random draw. The
## top paints (any ground cell of the block) give its chance. Blocks are
## aligned on the whole terrain grid, so chunks agree (no seams).
static func _block_candidate(cache: Dictionary, rule_index: int, rule: Rule, x: int, z: int, cell_count: int,
		cell_flags: PackedByteArray, fast_active: bool, vegetation: PackedByteArray, painted: bool, values: PackedByteArray,
		heights: PackedFloat32Array, carve: PackedFloat32Array, carved: bool, resolution: int, spacing: float) -> Array:
	var b := rule.block
	var bx := floori(float(x) / float(b))
	var bz := floori(float(z) / float(b))
	var key := Vector3i(bx, bz, rule_index)
	var found: Variant = cache.get(key)
	if found != null:
		return found
	var use_all := rule.paintable and painted
	var use_layer := not values.is_empty()
	var best := -1
	var best_score := -1.0
	var top_all := _VEG_NORMAL
	var top_layer := _VEG_NORMAL
	for cz in range(bz * b, mini(bz * b + b, cell_count)):
		for cx in range(bx * b, mini(bx * b + b, cell_count)):
			var c := cz * cell_count + cx
			if fast_active and cell_flags[c] == 0:
				continue
			if use_all:
				top_all = maxf(top_all, float(vegetation[c]))
			if use_layer:
				top_layer = maxf(top_layer, float(values[c]))
			if rule.fade_out:
				# Same slope as the scatter loop: skip cliffs the layer avoids,
				# so a click at a cliff edge still grows one on the flat side.
				var i00 := cz * resolution + cx
				var h00 := heights[i00] - (carve[i00] if carved else 0.0)
				var h10 := heights[i00 + 1] - (carve[i00 + 1] if carved else 0.0)
				var h01 := heights[i00 + resolution] - (carve[i00 + resolution] if carved else 0.0)
				var h11 := heights[i00 + resolution + 1] - (carve[i00 + resolution + 1] if carved else 0.0)
				var gx := (h10 + h11 - h00 - h01) * 0.5 / spacing
				var gz := (h01 + h11 - h00 - h10) * 0.5 / spacing
				if 1.0 / sqrt(1.0 + gx * gx + gz * gz) <= (rule.cos_out_none_painted if rule.relax else rule.cos_out_none):
					continue
			var score := 0.0
			if use_all:
				score += float(vegetation[c])
			if use_layer:
				score += float(values[c])
			var h: int = cx * 374761393 + cz * 668265263 + rule.salt * 2654435761
			h = (h ^ (h >> 15)) * 2246822519
			h = (h ^ (h >> 13)) * 3266489917
			score += float((h ^ (h >> 16)) & 0xFFFF) * _INV16 * 0.5
			if score > best_score:
				best_score = score
				best = c
	var result := [best, top_all, top_layer]
	cache[key] = result
	return result

## True if painted block (bx, bz) grows its instance: a fixed random draw
## against the block's strongest paint (a click on a cliff still counts in
## full for the flat cell next to it). `candidate` = _block_candidate().
static func _block_grows(candidate: Array, bx: int, bz: int, rule: Rule) -> bool:
	var cell: int = candidate[0]
	if cell < 0:
		return false
	var hb: int = bx * 1103515245 + bz * 2654435761 + rule.salt * 40503
	hb = (hb ^ (hb >> 15)) * 2246822519
	hb = (hb ^ (hb >> 13)) * 3266489917
	var block_chance := float((hb ^ (hb >> 16)) & 0xFFFF) * _INV16
	var top_all: float = candidate[1]
	var top_layer: float = candidate[2]
	var b_all := maxf(top_all - _VEG_NORMAL, 0.0) * _INV_VEG_ABOVE
	var b_block := maxf(top_layer - _VEG_NORMAL, 0.0) * _INV_VEG_ABOVE
	return block_chance < minf(b_all * PAINT_BLOCK_GAIN_ALL + b_block * PAINT_BLOCK_GAIN_LAYER, 1.0)

## Fixed random rank of a painted block: of two blocks whose instances would
## be too close, the higher rank keeps its own.
static func _block_rank(bx: int, bz: int, salt: int) -> int:
	var h: int = bx * 2246822519 + bz * 3266489917 + salt * 668265263
	h = (h ^ (h >> 15)) * 374761393
	h = (h ^ (h >> 13)) * 1442695041
	return (h ^ (h >> 16)) & 0x7FFFFFFF

## Position (in cells) of the first instance of `cell`: same draw as the
## scatter loop for k = 0.
static func _instance_spot(cell: int, cell_count: int, rule: Rule) -> Vector2:
	var x := cell % cell_count
	var z := cell / cell_count
	var r1: int = x * 374761393 + z * 668265263 + (rule.salt + 7919) * 1442695041
	r1 = (r1 ^ (r1 >> 15)) * 2246822519
	r1 = (r1 ^ (r1 >> 13)) * 3266489917
	r1 ^= r1 >> 16
	var span := 1.0 - 2.0 * rule.margin
	return Vector2(float(x) + rule.margin + span * float(r1 & 0xFFFF) * _INV16, float(z) + rule.margin + span * float((r1 >> 16) & 0xFFFF) * _INV16)

## True if one of the 8 neighbouring blocks, of a higher rank, grows its
## painted instance closer than rule.min_gap to the one of block (bx, bz) in
## `cell`. Blocks are global (same answer in every chunk); a block may also
## give way to a neighbour that itself gives way to another (a few gaps).
static func _crowded(cache: Dictionary, rule_index: int, rule: Rule, bx: int, bz: int, cell: int, cell_count: int,
		cell_flags: PackedByteArray, fast_active: bool, vegetation: PackedByteArray, painted: bool, values: PackedByteArray,
		heights: PackedFloat32Array, carve: PackedFloat32Array, carved: bool, resolution: int, spacing: float) -> bool:
	var b := rule.block
	var rank := _block_rank(bx, bz, rule.salt)
	var here := _instance_spot(cell, cell_count, rule)
	var gap := rule.min_gap / spacing
	for dz in range(-1, 2):
		for dx in range(-1, 2):
			var nx := bx + dx
			var nz := bz + dz
			if (dx == 0 and dz == 0) or nx < 0 or nz < 0 or nx * b >= cell_count or nz * b >= cell_count:
				continue
			var other := _block_rank(nx, nz, rule.salt)
			if other < rank or (other == rank and (nz > bz or (nz == bz and nx > bx))):
				continue
			var candidate: Array = _block_candidate(cache, rule_index, rule, nx * b, nz * b, cell_count, cell_flags, fast_active, vegetation, painted, values, heights, carve, carved, resolution, spacing)
			if not _block_grows(candidate, nx, nz, rule):
				continue
			var other_cell: int = candidate[0]
			if here.distance_to(_instance_spot(other_cell, cell_count, rule)) < gap:
				return true
	return false

static func _active(terrain: Node3D, flags: PackedByteArray, fast: bool, cell_count: int, x: int, z: int) -> bool:
	if x < 0 or z < 0 or x >= cell_count or z >= cell_count:
		return false
	return flags[z * cell_count + x] != 0 if fast else TerrainData.cell_active(terrain, x, z)
