@tool
extends RefCounted
## Whole-map generation from a LowpolyMapRecipe and a seed.
##
## Writes terrain data only (grid, heights, cells, styles, tracks, dried
## waterholes, biome, detail seed); call TerrainBuilder.rebuild_all() (or let
## LowpolyTerrainRuntime build it) afterwards. The same recipe + seed always
## gives the same data.
##
## Noise fields come from FastNoiseLite.get_image() (native, one call per
## field) and are thresholded by percentile, so a coverage of 0.2 really
## covers 20 % of the eligible cells whatever the seed.
##
## The per-cell loops run in parallel bands of rows (RowBands), the fields
## in parallel too: ~0.6 s instead of 4.6 s for 1 024 x 1 024 cells, the
## same data to the bit. start() / step() make the map in 6 steps, for a
## progress bar.

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")
const TerrainData = preload("../core/terrain_data.gd")
const GroundBumps = preload("../core/ground_bumps.gd")
const StylePalette = preload("../styles/style_palette.gd")
const FeatureStyle = preload("../styles/feature_style.gd")
const WaterholeStyle = preload("../styles/waterhole_style.gd")
const ImageGenerator = preload("image_generator.gd")
const RowBands = preload("row_bands.gd")
const MapPaths = preload("map_paths.gd")
const TerrainBiome = preload("../biomes/terrain_biome.gd")
const GroundStyle = preload("../biomes/ground_style.gd")
const MapRecipe = preload("map_recipe.gd")
const MapPatch = preload("map_patch.gd")

## Share of the plateau height (lowland depth) from which a slope cell takes
## the plateau (lowland) ground style.
const SLOPE_STYLE_SHARE := 0.3
## Cells per side of a generated map (MapRecipe.size is clamped to this).
## 1024 cells x 1.5 m = a 1.5 km open world.
const MIN_SIZE := 16
const MAX_SIZE := 1024

## Replaces the terrain's data with a map made from `recipe` and `map_seed`.
## Returns stats: {size, plateau_cells, lowland_cells, tracks, waterholes, ms}.
static func generate(terrain: Node3D, recipe_resource: Resource, map_seed: int) -> Dictionary:
	var generation := start(terrain, recipe_resource, map_seed)
	while not step(generation):
		pass
	return generation.stats

## The same generation one step at a time, for a progress bar: call step()
## until it returns true (Generation.STEPS says what each step does). Same
## data as generate(). The terrain's palette changes in the first step, its
## map in the last two.
static func start(terrain: Node3D, recipe_resource: Resource, map_seed: int) -> Generation:
	var generation := Generation.new()
	generation.terrain = terrain
	generation.recipe = recipe_resource
	generation.map_seed = map_seed
	return generation

## Runs the next step of `generation`. True when the map is done (stats in
## generation.stats).
static func step(generation: Generation) -> bool:
	var started := Time.get_ticks_usec()
	match generation.done:
		0:
			_prepare(generation)
		1:
			_shape(generation)
		2:
			_patches(generation)
		3:
			_rivers_and_border(generation)
		4:
			_vertices(generation)
		5:
			_features(generation)
	generation.done += 1
	generation.usec += Time.get_ticks_usec() - started
	if generation.done < Generation.STEPS.size():
		return false
	generation.stats["ms"] = generation.usec / 1000.0
	return true

## A map being made (start / step).
class Generation extends RefCounted:
	## What each step does.
	const STEPS: Array[String] = ["Noise", "Plateaus and lowlands", "Patches", "Rivers and border", "Vertices", "Tracks and waterholes"]
	## Steps done.
	var done := 0
	## Time spent in the steps (microseconds).
	var usec := 0
	## generate()'s stats, once done.
	var stats: Dictionary = {}
	var terrain: Node3D
	var recipe: MapRecipe
	var map_seed := 0
	var n := 0
	var cell_size := 1.0
	var biome: TerrainBiome
	var base_id := 0
	var plateau_id := 0
	var lowland_id := 0
	## Noise fields by name ("coast", "plateau", "lowland", "relief") and by
	## patch index.
	var fields: Dictionary = {}
	var active := PackedByteArray()
	var styles := PackedInt32Array()
	var raised := PackedFloat32Array()
	var lowered := PackedFloat32Array()
	var cell_heights := PackedFloat32Array()
	var plateau_cells := 0
	var lowland_cells := 0
	var vertices: Dictionary = {}
	## River courses (PackedVector2Array, cell coordinates), committed in
	## the last step.
	var river_lines: Array = []
	## Plateaus + border: no waterhole where it is raised.
	var obstacle := PackedFloat32Array()

	## 0..1, for a progress bar.
	func progress() -> float:
		return float(done) / float(STEPS.size())

	## What the next step does ("" once done).
	func next_step() -> String:
		return STEPS[done] if done < STEPS.size() else ""

## Step 1: palette, the three ground styles and every noise field (in
## parallel, one task per field).
static func _prepare(g: Generation) -> void:
	var terrain := g.terrain
	if Meta.is_terrain(terrain):
		TerrainData.ensure_defaults(terrain)
	else:
		TerrainData.initialize(terrain)
	var recipe := g.recipe
	g.n = clampi(int(recipe.size), MIN_SIZE, MAX_SIZE)
	g.cell_size = maxf(float(recipe.cell_size), 0.05)
	g.biome = recipe.biome
	if g.biome == null:
		# The terrain's own biome, else the built-in default.
		g.biome = TerrainBiome.of(terrain)
	# Fresh palette: only the styles this map uses.
	terrain.set_meta(Meta.STYLE_PALETTE, [StylePalette.make_default_style()])
	g.base_id = _style_id(terrain, g.biome, recipe.base_style)
	g.plateau_id = _style_id(terrain, g.biome, recipe.plateau_style)
	g.lowland_id = _style_id(terrain, g.biome, recipe.lowland_style)

	var specs: Array = []
	if float(recipe.island) > 0.0:
		specs.append(["coast", 11, g.n * 0.22])
	specs.append(["plateau", 23, float(recipe.plateau_scale)])
	specs.append(["lowland", 37, float(recipe.lowland_scale)])
	specs.append(["relief", 41, float(recipe.relief_scale)])
	if int(recipe.border) != 0:
		specs.append(["border", 53, maxf(float(recipe.border_width) * 1.2, 8.0)])
	if int(recipe.river_count) > 0 or bool(recipe.track_network):
		specs.append(["meander", 67, 120.0])
	for k in range(recipe.patches.size()):
		var patch: MapPatch = recipe.patches[k]
		if patch != null and float(patch.coverage) > 0.0:
			specs.append([k, 101 + k * 17, float(patch.scale)])
	var fields := RowBands.each(specs.size(), _field_job.bind(g.map_seed, g.n, specs))
	for i in range(specs.size()):
		var spec: Array = specs[i]
		g.fields[spec[0]] = fields[i]

static func _field_job(index: int, map_seed: int, n: int, specs: Array) -> PackedByteArray:
	var spec: Array = specs[index]
	var salt: int = spec[1]
	var scale: float = spec[2]
	return _field(map_seed, salt, scale, n)

## Step 2: outline, plateaus, then lowlands on what is left, smoothed; the
## ground style of each cell (slopes take the style of the plateau / lowland
## they lead to) and the cell heights (+ a gentle rolling relief everywhere).
static func _shape(g: Generation) -> void:
	var recipe := g.recipe
	var n := g.n
	var coast: PackedByteArray = g.fields.get("coast", PackedByteArray())
	g.active = _outline(recipe, n, coast)
	var plateau: PackedByteArray = g.fields["plateau"]
	var lowland: PackedByteArray = g.fields["lowland"]
	var no_limit := PackedByteArray()
	var plateau_threshold := _threshold(RowBands.run(n, _histogram_rows.bind(n, plateau, g.active, no_limit, 0)), float(recipe.plateau_coverage))
	# Lowlands on the cells left open by the plateaus.
	var lowland_threshold := _threshold(RowBands.run(n, _histogram_rows.bind(n, lowland, g.active, plateau, plateau_threshold)), float(recipe.lowland_coverage))
	var ids := PackedInt32Array([g.base_id, g.plateau_id, g.lowland_id])
	var parts := RowBands.run(n, _classify_rows.bind(n, g.active, plateau, plateau_threshold, lowland, lowland_threshold,
		float(recipe.plateau_height), float(recipe.lowland_depth), ids))
	var styles_parts: Array = []
	var raised_parts: Array = []
	var lowered_parts: Array = []
	g.plateau_cells = 0
	g.lowland_cells = 0
	for part: Array in parts:
		styles_parts.append(part[0])
		raised_parts.append(part[1])
		lowered_parts.append(part[2])
		var plateau_cells: int = part[3]
		var lowland_cells: int = part[4]
		g.plateau_cells += plateau_cells
		g.lowland_cells += lowland_cells
	var styles := RowBands.join_ints(styles_parts)
	g.raised = ImageGenerator.smooth_cell_heights(g.active, RowBands.join_floats(raised_parts), n, float(recipe.plateau_smoothness))
	g.lowered = ImageGenerator.smooth_cell_heights(g.active, RowBands.join_floats(lowered_parts), n, float(recipe.lowland_smoothness))
	parts = RowBands.run(n, _slope_rows.bind(n, g.active, styles, g.raised, g.lowered, g.fields["relief"],
		float(recipe.plateau_height) * SLOPE_STYLE_SHARE, -float(recipe.lowland_depth) * SLOPE_STYLE_SHARE, float(recipe.relief), ids))
	styles_parts.clear()
	var height_parts: Array = []
	for part: Array in parts:
		styles_parts.append(part[0])
		height_parts.append(part[1])
	g.styles = RowBands.join_ints(styles_parts)
	g.cell_heights = RowBands.join_floats(height_parts)

## Step 3: ground patches of the recipe, each over the cells of the style it
## grows on (the base style by default), in order.
static func _patches(g: Generation) -> void:
	var recipe := g.recipe
	for k in range(recipe.patches.size()):
		var patch: MapPatch = recipe.patches[k]
		if patch == null or float(patch.coverage) <= 0.0:
			continue
		var on_id := g.base_id if String(patch.on_style).is_empty() else _style_id(g.terrain, g.biome, patch.on_style)
		var patch_id := _style_id(g.terrain, g.biome, patch.style)
		var field: PackedByteArray = g.fields[k]
		var threshold := _threshold(RowBands.run(g.n, _style_histogram_rows.bind(g.n, field, g.styles, on_id)), float(patch.coverage))
		g.styles = RowBands.join_ints(RowBands.run(g.n, _patch_rows.bind(g.n, field, g.styles, on_id, patch_id, threshold)))

## Step 5: vertex heights from the cells, written on the terrain.
static func _vertices(g: Generation) -> void:
	g.vertices = ImageGenerator.cell_heights_to_vertices(g.active, g.cell_heights, g.n)
	_write_map(g.terrain, g.recipe, g.map_seed, g.n, g.cell_size, g.active, g.styles, g.vertices)

## Step 6: rivers, then tracks and waterholes: one random sequence, always
## in this order (with Track Network: waterholes, then tracks).
static func _features(g: Generation) -> void:
	var rivers := _commit_rivers(g)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(g.map_seed * 7919 + 5)
	var vertex_heights: PackedFloat32Array = g.vertices["heights"]
	var tracks := 0
	var holes := 0
	if bool(g.recipe.track_network):
		# Waterholes first: the network joins them.
		holes = _add_waterholes(g.terrain, g.recipe, rng, g.active, g.obstacle, vertex_heights, g.n, g.cell_size)
		tracks = _add_track_network(g, rng)
	else:
		tracks = _add_tracks(g.terrain, g.recipe, rng, g.active, g.n, g.cell_size)
		holes = _add_waterholes(g.terrain, g.recipe, rng, g.active, g.obstacle, vertex_heights, g.n, g.cell_size)
	g.stats = {
		"rivers": rivers,
		"size": g.n,
		"plateau_cells": g.plateau_cells,
		"lowland_cells": g.lowland_cells,
		"tracks": tracks,
		"waterholes": holes,
	}

## Step 4: river courses (planned on the cell heights, committed with the
## tracks), then the border (hills or cliffs), opened where a river leaves
## the map. Nothing when the recipe has neither.
static func _rivers_and_border(g: Generation) -> void:
	var recipe := g.recipe
	g.obstacle = g.raised
	if int(recipe.river_count) > 0:
		g.river_lines = _plan_rivers(g)
	if int(recipe.border) == 0:
		return
	var border_id := _style_id(g.terrain, g.biome, recipe.border_style)
	var gap := _river_gap(g)
	var parts := RowBands.run(g.n, _border_rows.bind(g.n, g.fields["border"], gap, int(recipe.border), float(recipe.border_width),
		float(recipe.border_height), float(recipe.border_noise), g.cell_heights, g.styles, g.raised, border_id))
	var height_parts: Array = []
	var style_parts: Array = []
	var obstacle_parts: Array = []
	for part: Array in parts:
		height_parts.append(part[0])
		style_parts.append(part[1])
		obstacle_parts.append(part[2])
	g.cell_heights = RowBands.join_floats(height_parts)
	g.styles = RowBands.join_ints(style_parts)
	g.obstacle = RowBands.join_floats(obstacle_parts)

## [heights, styles, obstacle] of rows from..to with the border: it rises
## over `width` cells to the edge (hills: smooth and bumpy; cliffs: two
## steps), its inner edge wobbling with the border field; `gap` (when not
## empty) lowers it where rivers pass. Obstacle = plateaus + border (no
## waterhole there).
static func _border_rows(from: int, to: int, n: int, field: PackedByteArray, gap: PackedFloat32Array, mode: int, width: float,
		height: float, noise: float, heights: PackedFloat32Array, styles: PackedInt32Array, raised: PackedFloat32Array,
		border_id: int) -> Array:
	var offset := from * n
	var out_heights := heights.slice(offset, to * n)
	var out_styles := styles.slice(offset, to * n)
	var obstacle := raised.slice(offset, to * n)
	var has_gap := not gap.is_empty()
	for z in range(from, to):
		var to_z := minf(float(z) + 0.5, float(n - z) - 0.5)
		for x in range(n):
			var edge := minf(to_z, minf(float(x) + 0.5, float(n - x) - 0.5))
			if edge > width * (1.0 + noise * 0.5):
				continue
			var c := z * n + x
			var f := float(field[c]) / 255.0
			var t := clampf(1.0 - (edge + (f - 0.5) * noise * width) / width, 0.0, 1.0)
			if t <= 0.0:
				continue
			var b: float
			if mode == 1:
				b = height * smoothstep(0.0, 1.0, t) * (0.7 + 0.6 * f)
			else:
				b = height * (0.5 if t < 0.5 else 1.0)
			if has_gap:
				b *= gap[c]
			var i := c - offset
			out_heights[i] += b
			obstacle[i] += b
			if b > height * 0.25:
				out_styles[i] = border_id
	return [out_heights, out_styles, obstacle]

## 0..1 per cell: 0 in a river's bed near the map border, rising to 1 over
## the slope a valley needs to cross the border; empty without rivers.
static func _river_gap(g: Generation) -> PackedFloat32Array:
	var gap := PackedFloat32Array()
	if g.river_lines.is_empty():
		return gap
	var n := g.n
	var recipe := g.recipe
	gap.resize(n * n)
	gap.fill(1.0)
	var inner := float(recipe.river_width) * 0.5 + 1.0
	var outer := inner + float(recipe.border_height) / g.cell_size * 1.5 + 4.0
	var zone := float(recipe.border_width) * 1.5 + outer
	for line: PackedVector2Array in g.river_lines:
		for p in line:
			if minf(minf(p.x, float(n) - p.x), minf(p.y, float(n) - p.y)) > zone:
				continue
			for z in range(maxi(int(p.y - outer), 0), mini(int(p.y + outer) + 1, n)):
				for x in range(maxi(int(p.x - outer), 0), mini(int(p.x + outer) + 1, n)):
					var d := Vector2(float(x) + 0.5, float(z) + 0.5).distance_to(p)
					if d >= outer:
						continue
					var v := smoothstep(inner, outer, d)
					var c := z * n + x
					if v < gap[c]:
						gap[c] = v
	return gap

## River courses in cell coordinates along the low ground (AStarGrid2D on a
## coarse grid: high ground costs more, plus a noise for the meanders). The
## first crosses the map from edge to edge; the others are tributaries,
## from another side of the map to a point of the first. Each river makes
## its valley dearer for the next, so they do not run side by side.
static func _plan_rivers(g: Generation) -> Array:
	var recipe := g.recipe
	var n := g.n
	var step := MapPaths.step_for(n)
	var side := MapPaths.side_for(n, step)
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(g.map_seed * 7919 + 11)
	var meander: PackedByteArray = g.fields["meander"]
	var count := side * side
	var heights := PackedFloat32Array()
	heights.resize(count)
	var solid := PackedByteArray()
	solid.resize(count)
	solid.fill(0)
	var low := INF
	var high := -INF
	for z in range(side):
		for x in range(side):
			var cell := MapPaths.node_cell(Vector2i(x, z), n, step)
			var c := cell.y * n + cell.x
			var i := z * side + x
			if g.active[c] == 0:
				solid[i] = 1
				continue
			heights[i] = g.cell_heights[c]
			low = minf(low, heights[i])
			high = maxf(high, heights[i])
	var span := maxf(high - low, 0.001)
	var weights := PackedFloat32Array()
	weights.resize(count)
	for z in range(side):
		for x in range(side):
			var i := z * side + x
			var cell := MapPaths.node_cell(Vector2i(x, z), n, step)
			var f := float(meander[cell.y * n + cell.x]) / 255.0
			weights[i] = 1.0 + 12.0 * (heights[i] - low) / span + 10.0 * float(recipe.river_meander) * f + MapPaths.jitter(x, z)
	var grid := MapPaths.make_grid(side, weights, solid)
	var lines: Array = []
	var main_angle := rng.randf() * TAU
	for k in range(int(recipe.river_count)):
		var from := Vector2i(-1, -1)
		var to := Vector2i(-1, -1)
		if lines.is_empty():
			from = MapPaths.edge_node(grid, side, main_angle)
			to = MapPaths.edge_node(grid, side, main_angle + PI + rng.randf_range(-0.6, 0.6))
		else:
			# A tributary: from a side across the main river, to it.
			var main: PackedVector2Array = lines[0]
			var side_angle := main_angle + (PI * 0.5 if k % 2 == 1 else -PI * 0.5) + rng.randf_range(-0.5, 0.5)
			from = MapPaths.edge_node(grid, side, side_angle)
			to = MapPaths.node_of(main[int(float(main.size() - 1) * rng.randf_range(0.3, 0.7))], side, step)
		var points := MapPaths.find(grid, from, to, n, step)
		if points.size() < 4:
			continue
		points = MapPaths.resample(MapPaths.smooth(MapPaths.reach_border(points, n, float(step) * 1.5), 3), 2.0)
		points = MapPaths.resample(MapPaths.wobble(points, rng, float(recipe.river_meander) * 12.0, 110.0), 2.0)
		lines.append(points)
		# ~20 cells each side: a tributary meets it instead of following it.
		var reach := maxi(20 / step, 2)
		for p in points:
			var node := MapPaths.node_of(p, side, step)
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					var near := node + Vector2i(dx, dz)
					if near.x >= 0 and near.y >= 0 and near.x < side and near.y < side and not grid.is_point_solid(near):
						grid.set_point_weight_scale(near, weights[near.y * side + near.x] + 25.0)
	return lines

## Commits the planned rivers (recipe width and depth). Returns how many.
static func _commit_rivers(g: Generation) -> int:
	if g.river_lines.is_empty():
		return 0
	g.terrain.set_meta(Meta.RIVER_WIDTH, float(g.recipe.river_width) * g.cell_size)
	g.terrain.set_meta(Meta.RIVER_DEPTH, float(g.recipe.river_depth))
	var committed := 0
	for line: PackedVector2Array in g.river_lines:
		if FeatureStyle.commit(g.terrain, FeatureStyle.RIVER, MapPaths.to_local(line, g.n, g.cell_size)):
			committed += 1
	return committed

## Track network: tracks join the map exits (`track_count`, drawn from
## `rng`) and the most spread out waterholes (`track_network_stops`) as a
## minimum spanning tree, each link along the easy ground: slopes, plateaus,
## the border, rivers and other waterholes cost more. A link made makes its
## ground cheaper, so the next ones join it. Returns the tracks committed.
static func _add_track_network(g: Generation, rng: RandomNumberGenerator) -> int:
	var recipe := g.recipe
	var terrain := g.terrain
	var n := g.n
	terrain.set_meta(Meta.ROAD_WIDTH, float(recipe.track_width) * g.cell_size)
	var step := MapPaths.step_for(n)
	var side := MapPaths.side_for(n, step)
	var count := side * side
	var meander: PackedByteArray = g.fields["meander"]

	# Waterholes, in cell coordinates.
	var hole_centres: Array[Vector2] = []
	var hole_radii: Array[float] = []
	var half := Vector2(n, n) * 0.5
	var holes: Array = terrain.get_meta(Meta.WATERHOLES, [])
	for hole: Dictionary in holes:
		var centre: Vector2 = hole["center"]
		var radius: float = hole["radius"]
		hole_centres.append(centre / g.cell_size + half)
		hole_radii.append(radius / g.cell_size)

	var heights := PackedFloat32Array()
	heights.resize(count)
	var solid := PackedByteArray()
	solid.resize(count)
	solid.fill(0)
	var extra := PackedFloat32Array()
	extra.resize(count)
	extra.fill(0.0)
	for z in range(side):
		for x in range(side):
			var cell := MapPaths.node_cell(Vector2i(x, z), n, step)
			var c := cell.y * n + cell.x
			var i := z * side + x
			heights[i] = g.cell_heights[c]
			if g.active[c] == 0:
				solid[i] = 1
			elif g.obstacle[c] > 0.05:
				extra[i] += 4.0
	_mark_nodes(extra, side, step, g.river_lines, float(recipe.river_width) * 0.5 + 1.0, 25.0)
	for h in range(hole_centres.size()):
		var line := PackedVector2Array([hole_centres[h]])
		_mark_nodes(extra, side, step, [line], hole_radii[h] * 1.3, 40.0)
	var weights := PackedFloat32Array()
	weights.resize(count)
	var cell_world := float(step) * g.cell_size * 2.0
	for z in range(side):
		for x in range(side):
			var i := z * side + x
			var dx := heights[z * side + mini(x + 1, side - 1)] - heights[z * side + maxi(x - 1, 0)]
			var dz := heights[mini(z + 1, side - 1) * side + x] - heights[maxi(z - 1, 0) * side + x]
			var slope := maxf(absf(dx), absf(dz)) / cell_world
			var cell := MapPaths.node_cell(Vector2i(x, z), n, step)
			var f := float(meander[cell.y * n + cell.x]) / 255.0
			weights[i] = 1.0 + 400.0 * slope * slope + extra[i] + 6.0 * float(recipe.track_meander) * f + MapPaths.jitter(x, z)
	var grid := MapPaths.make_grid(side, weights, solid)

	# Stops: the exits, then the waterholes farthest from the ones taken.
	var stops: Array[Vector2] = []
	var stop_radius: Array[float] = []
	for k in range(int(recipe.track_count)):
		var node := MapPaths.edge_node(grid, side, rng.randf() * TAU)
		if node.x >= 0:
			stops.append(Vector2(node) * float(step) + Vector2.ONE * float(step) * 0.5)
			stop_radius.append(-1.0)
	var taken: Array[int] = []
	var wanted := mini(int(recipe.track_network_stops), hole_centres.size())
	while taken.size() < wanted:
		var best := -1
		var best_distance := -1.0
		for h in range(hole_centres.size()):
			if taken.has(h):
				continue
			var distance := INF
			if taken.is_empty():
				# First: the waterhole nearest the map centre.
				distance = -hole_centres[h].distance_to(half)
			for t in taken:
				distance = minf(distance, hole_centres[h].distance_to(hole_centres[t]))
			if distance > best_distance or best < 0:
				best = h
				best_distance = distance
		taken.append(best)
		stops.append(hole_centres[best])
		stop_radius.append(hole_radii[best])
	if stops.size() < 2:
		return 0

	# Minimum spanning tree (Prim), links in the order they join.
	var joined: Array[int] = [0]
	var links: Array[Vector2i] = []
	while joined.size() < stops.size():
		var link := Vector2i(-1, -1)
		var shortest := INF
		for a in joined:
			for b in range(stops.size()):
				if joined.has(b):
					continue
				var length := stops[a].distance_to(stops[b])
				if length < shortest:
					shortest = length
					link = Vector2i(a, b)
		joined.append(link.y)
		links.append(link)

	var committed := 0
	for link in links:
		var points := MapPaths.find(grid, MapPaths.node_of(stops[link.x], side, step), MapPaths.node_of(stops[link.y], side, step), n, step)
		if points.size() < 2:
			continue
		for p in points:
			var node := MapPaths.node_of(p, side, step)
			grid.set_point_weight_scale(node, maxf(grid.get_point_weight_scale(node) * 0.6, 1.0))
		points = MapPaths.reach_border(points, n, float(step) * 1.5)
		points = _trim_at_hole(points, stops[link.x], stop_radius[link.x])
		points.reverse()
		points = _trim_at_hole(points, stops[link.y], stop_radius[link.y])
		points = MapPaths.resample(MapPaths.smooth(points, 3), 2.0)
		points = MapPaths.resample(MapPaths.wobble(points, rng, float(recipe.track_meander) * 6.0, 70.0), 2.0)
		if points.size() >= 4 and FeatureStyle.commit(terrain, FeatureStyle.ROAD, MapPaths.to_local(points, n, g.cell_size)):
			committed += 1
	return committed

## Adds `cost` to the nodes within `radius` cells of the points of `lines`.
static func _mark_nodes(extra: PackedFloat32Array, side: int, step: int, lines: Array, radius: float, cost: float) -> void:
	var reach := ceili(radius / float(step))
	for line: PackedVector2Array in lines:
		for p in line:
			var node := MapPaths.node_of(p, side, step)
			for dz in range(-reach, reach + 1):
				for dx in range(-reach, reach + 1):
					var near := node + Vector2i(dx, dz)
					if near.x < 0 or near.y < 0 or near.x >= side or near.y >= side:
						continue
					var centre := Vector2(near) * float(step) + Vector2.ONE * float(step) * 0.5
					var i := near.y * side + near.x
					if centre.distance_to(p) <= radius and extra[i] < cost:
						extra[i] += cost

## `points` from where they leave a waterhole (radius < 0: none): a track
## stops at its rim.
static func _trim_at_hole(points: PackedVector2Array, centre: Vector2, radius: float) -> PackedVector2Array:
	if radius < 0.0:
		return points
	var first := 0
	while first < points.size() - 1 and points[first].distance_to(centre) < radius * 1.2:
		first += 1
	return points.slice(first)

## Cells inside the map (1) or outside (0): every cell, or an island whose
## coast follows a noise field.
static func _outline(recipe: MapRecipe, n: int, coast: PackedByteArray) -> PackedByteArray:
	if float(recipe.island) <= 0.0:
		var active := PackedByteArray()
		active.resize(n * n)
		active.fill(1)
		return active
	var limit := 1.0 - float(recipe.island) * 0.4
	var wobble := float(recipe.coast_noise) * 0.6
	return RowBands.join_bytes(RowBands.run(n, _outline_rows.bind(n, coast, limit, wobble)))

static func _outline_rows(from: int, to: int, n: int, coast: PackedByteArray, limit: float, wobble: float) -> PackedByteArray:
	var active := PackedByteArray()
	active.resize((to - from) * n)
	active.fill(1)
	var half := float(n) * 0.5
	for z in range(from, to):
		for x in range(n):
			var i := z * n + x
			var r := Vector2(float(x) + 0.5 - half, float(z) + 0.5 - half).length() / half
			if r + (float(coast[i]) / 255.0 - 0.5) * wobble >= limit:
				active[i - from * n] = 0
	return active

## Histogram of `field` (256 counts, then the number of cells) over the
## active cells of rows from..to; with `limit_field`, only those where it is
## <= `limit`.
static func _histogram_rows(from: int, to: int, n: int, field: PackedByteArray, active: PackedByteArray,
		limit_field: PackedByteArray, limit: int) -> PackedInt32Array:
	var histogram := PackedInt32Array()
	histogram.resize(257)
	histogram.fill(0)
	var limited := not limit_field.is_empty()
	for i in range(from * n, to * n):
		if active[i] == 0 or (limited and limit_field[i] > limit):
			continue
		histogram[field[i]] += 1
	var total := 0
	for v in range(256):
		total += histogram[v]
	histogram[256] = total
	return histogram

## Histogram of `field` over the cells of style `style_id` (rows from..to).
static func _style_histogram_rows(from: int, to: int, n: int, field: PackedByteArray, styles: PackedInt32Array, style_id: int) -> PackedInt32Array:
	var histogram := PackedInt32Array()
	histogram.resize(257)
	histogram.fill(0)
	for i in range(from * n, to * n):
		if styles[i] == style_id:
			histogram[field[i]] += 1
	var total := 0
	for v in range(256):
		total += histogram[v]
	histogram[256] = total
	return histogram

## Value v such that `coverage` of the counted cells have field > v, from
## the bands' histograms.
static func _threshold(histograms: Array, coverage: float) -> int:
	if coverage <= 0.0:
		return 255
	var histogram := PackedInt32Array()
	histogram.resize(257)
	histogram.fill(0)
	for part: PackedInt32Array in histograms:
		for v in range(257):
			histogram[v] += part[v]
	var target := coverage * float(histogram[256])
	var above := 0
	for v in range(255, -1, -1):
		if float(above + histogram[v]) > target:
			return v
		above += histogram[v]
	return -1

## [styles, raised, lowered, plateau cells, lowland cells] of rows from..to:
## plateaus above their threshold, lowlands on the open cells left.
## ids: base, plateau, lowland style.
static func _classify_rows(from: int, to: int, n: int, active: PackedByteArray, plateau: PackedByteArray, plateau_threshold: int,
		lowland: PackedByteArray, lowland_threshold: int, plateau_height: float, lowland_depth: float, ids: PackedInt32Array) -> Array:
	var size := (to - from) * n
	var offset := from * n
	var styles := PackedInt32Array()
	styles.resize(size)
	styles.fill(-1)
	var raised := PackedFloat32Array()
	raised.resize(size)
	raised.fill(0.0)
	var lowered := PackedFloat32Array()
	lowered.resize(size)
	lowered.fill(0.0)
	var plateau_cells := 0
	var lowland_cells := 0
	for i in range(size):
		var c := offset + i
		if active[c] == 0:
			continue
		if plateau[c] > plateau_threshold:
			raised[i] = plateau_height
			styles[i] = ids[1]
			plateau_cells += 1
		elif lowland[c] > lowland_threshold:
			lowered[i] = -lowland_depth
			styles[i] = ids[2]
			lowland_cells += 1
		else:
			styles[i] = ids[0]
	return [styles, raised, lowered, plateau_cells, lowland_cells]

## [styles, cell heights] of rows from..to: slopes take the style of the
## plateau / lowland they lead to; height = plateau + lowland + relief.
static func _slope_rows(from: int, to: int, n: int, active: PackedByteArray, styles: PackedInt32Array, raised: PackedFloat32Array,
		lowered: PackedFloat32Array, relief: PackedByteArray, plateau_foot: float, lowland_foot: float, amplitude: float,
		ids: PackedInt32Array) -> Array:
	var offset := from * n
	var out := styles.slice(offset, to * n)
	var heights := PackedFloat32Array()
	heights.resize(out.size())
	for i in range(out.size()):
		var c := offset + i
		if active[c] != 0:
			if plateau_foot > 0.0 and raised[c] >= plateau_foot:
				out[i] = ids[1]
			elif lowland_foot < 0.0 and lowered[c] <= lowland_foot and styles[c] == ids[0]:
				out[i] = ids[2]
		heights[i] = raised[c] + lowered[c] + (float(relief[c]) / 255.0 - 0.5) * amplitude
	return [out, heights]

## Styles of rows from..to with the patch on the cells of style `on_id`
## whose field is above the threshold.
static func _patch_rows(from: int, to: int, n: int, field: PackedByteArray, styles: PackedInt32Array, on_id: int,
		patch_id: int, threshold: int) -> PackedInt32Array:
	var offset := from * n
	var out := styles.slice(offset, to * n)
	for i in range(out.size()):
		if out[i] == on_id and field[offset + i] > threshold:
			out[i] = patch_id
	return out

## Writes the new map onto the terrain: grid, heights, cells, styles, fresh
## lists (no roads / rivers / waterholes yet), seed and the recipe's biome.
static func _write_map(terrain: Node3D, recipe: MapRecipe, map_seed: int, n: int, cell_size: float,
		active: PackedByteArray, styles: PackedInt32Array, vertices: Dictionary) -> void:
	var amplitude := float(recipe.relief)
	ImageGenerator.write_grid(terrain, n + 1, float(n) * cell_size, vertices, active, styles)
	# Room for the plateaus, lowlands and relief.
	terrain.set_meta(Meta.HEIGHT_MAX, maxf(TerrainData.height_max(terrain), float(recipe.plateau_height) + amplitude + 1.0))
	terrain.set_meta(Meta.HEIGHT_MIN, minf(TerrainData.height_min(terrain), -float(recipe.lowland_depth) - amplitude - 1.0))
	# The terrain's small bumps (Look > Ground Bumps) on the new map too.
	GroundBumps.add_to_terrain(terrain, GroundBumps.amount(terrain))
	terrain.set_meta(Meta.ROADS, [])
	terrain.set_meta(Meta.RIVERS, [])
	terrain.set_meta(Meta.WATERHOLES, [])
	terrain.set_meta(Meta.DETAIL_SEED, map_seed)
	if bool(recipe.ground_collision):
		terrain.set_meta(Meta.COLLISION_ENABLED, true)

	# Biome: its shading and waterhole colours, like "Apply Biome".
	if recipe.biome != null:
		terrain.set_meta(Meta.BIOME, recipe.biome)
		var recipe_biome: TerrainBiome = recipe.biome
		var values: Dictionary = recipe_biome.shading_values()
		values.merge(recipe_biome.waterhole_values(), true)
		for key: String in values:
			terrain.set_meta(key, values[key])

## Palette id of the biome ground style called `style_name` (first style
## when not found; brush colours when the biome has none).
static func _style_id(terrain: Node3D, biome: TerrainBiome, style_name: String) -> int:
	var styles: Array = biome.ground_styles if biome != null else []
	var found: GroundStyle = null
	for style: GroundStyle in styles:
		if style != null and String(style.name).to_lower() == style_name.to_lower():
			found = style
			break
	if found == null and not styles.is_empty():
		found = styles[0]
	if found == null:
		return StylePalette.capture_current_paint_style(terrain)
	return StylePalette.capture_style_definition(
		terrain, found.top_color, found.side_color, found.top_texture, found.side_texture,
		maxf(found.top_tile_size, 0.001), maxf(found.side_tile_size, 0.001)
	)

## n x n noise values 0..255 (row-major).
static func _field(map_seed: int, salt: int, scale: float, n: int) -> PackedByteArray:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.seed = hash(map_seed * 1009 + salt) & 0x7FFFFFFF
	noise.frequency = 1.0 / maxf(scale, 1.0)
	noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	noise.fractal_octaves = 3
	var image := noise.get_image(n, n, false, false, true)
	if image.get_format() != Image.FORMAT_L8:
		image.convert(Image.FORMAT_L8)
	return image.get_data()

## Winding tracks crossing the map (split where they leave the ground).
static func _add_tracks(terrain: Node3D, recipe: MapRecipe, rng: RandomNumberGenerator, active: PackedByteArray, n: int, cell_size: float) -> int:
	terrain.set_meta(Meta.ROAD_WIDTH, float(recipe.track_width) * cell_size)
	var half := float(n) * 0.5
	var committed := 0
	for k in range(int(recipe.track_count)):
		var angle := rng.randf() * TAU
		var start := Vector2(half, half) + Vector2(cos(angle), sin(angle)) * float(n) * 0.6
		var end_angle := angle + PI + rng.randf_range(-0.7, 0.7)
		var finish := Vector2(half, half) + Vector2(cos(end_angle), sin(end_angle)) * float(n) * 0.6
		var direction := finish - start
		var normal := Vector2(-direction.y, direction.x).normalized()
		var amplitude := float(recipe.track_meander) * float(n) * 0.12
		var frequency := rng.randf_range(0.8, 1.8)
		var phase := rng.randf() * TAU
		var steps := maxi(int(direction.length() / 2.0), 8)
		var run: Array[Vector2] = []
		for s in range(steps + 1):
			var t := float(s) / float(steps)
			var p := start + direction * t + normal * (sin(t * TAU * frequency + phase) * amplitude + sin(t * TAU * frequency * 2.7 + phase * 1.3) * amplitude * 0.25)
			var cx := int(floorf(p.x))
			var cz := int(floorf(p.y))
			var inside := cx >= 1 and cz >= 1 and cx < n - 1 and cz < n - 1 and active[cz * n + cx] != 0
			if inside:
				run.append((p - Vector2(half, half)) * cell_size)
			if not inside or s == steps:
				if run.size() >= 4 and FeatureStyle.commit(terrain, FeatureStyle.ROAD, run):
					committed += 1
				run = []
	return committed

## Dried waterholes on flat open ground, away from each other and the tracks.
static func _add_waterholes(
	terrain: Node3D, recipe: MapRecipe, rng: RandomNumberGenerator, active: PackedByteArray, raised: PackedFloat32Array,
	heights: PackedFloat32Array, n: int, cell_size: float
) -> int:
	var wanted := int(roundf(float(recipe.waterholes_per_10k_cells) * float(n * n) / 10000.0))
	if wanted <= 0:
		return 0
	var resolution := n + 1
	var half := float(n) * 0.5
	# Away from roads and rivers.
	var roads: Array = terrain.get_meta(Meta.ROADS, [])
	var rivers: Array = terrain.get_meta(Meta.RIVERS, [])
	roads = roads + rivers
	var road_points: Array = []
	var road_widths: Array[float] = []
	var road_bounds: Array[Rect2] = []
	for road: Dictionary in roads:
		var points: Array = road["points"]
		var first: Vector2 = points[0]
		var bounds := Rect2(first, Vector2.ZERO)
		for p: Vector2 in points:
			bounds = bounds.expand(p)
		road_points.append(points)
		var width: float = road["width"]
		road_widths.append(width)
		road_bounds.append(bounds)
	var placed: Array[Vector2] = []
	# Set on the terrain once at the end (one copy, not one per waterhole).
	var holes: Array = WaterholeStyle.list(terrain).duplicate(true)
	var radius_min := minf(float(recipe.waterhole_radius_min), float(recipe.waterhole_radius_max))
	var radius_max := maxf(float(recipe.waterhole_radius_min), float(recipe.waterhole_radius_max))
	var tries := 0
	while placed.size() < wanted and tries < wanted * 400:
		tries += 1
		var radius_cells := rng.randf_range(radius_min, radius_max)
		var reach := int(ceilf(radius_cells * 1.6))
		var gx := rng.randi_range(reach + 1, n - reach - 2)
		var gz := rng.randi_range(reach + 1, n - reach - 2)
		# A waterhole too big for a small map gives an empty range (the draw is
		# then outside it): skip it, its cells would fall off the grid.
		if gx < reach + 1 or gz < reach + 1 or gx >= n - reach - 1 or gz >= n - reach - 1:
			continue
		var center := (Vector2(gx, gz) - Vector2(half, half)) * cell_size
		var radius := radius_cells * cell_size
		# Every test must pass, so they go cheapest first (the draws above
		# are the same whatever fails): other waterholes, the ground, roads.
		var clear := true
		for other in placed:
			if other.distance_to(center) < radius * 2.0 + 12.0 * cell_size:
				clear = false
				break
		if not clear:
			continue
		var h0 := heights[gz * resolution + gx]
		for dz in range(-reach, reach + 1):
			for dx in range(-reach, reach + 1):
				var cell := (gz + dz) * n + gx + dx
				# Plateaus (and their slopes) are excluded by height, not by
				# style: laterite patches on the plain are fine.
				if active[cell] == 0 or raised[cell] > 0.05 or absf(heights[(gz + dz) * resolution + gx + dx] - h0) > 0.6:
					clear = false
					break
			if not clear:
				break
		if not clear:
			continue
		for r in range(roads.size()):
			# Road bounds first: the exact distance walks every point.
			var near: Rect2 = road_bounds[r]
			if not near.grow(radius * 1.6 + road_widths[r]).has_point(center):
				continue
			var points: Array = road_points[r]
			if GridMath.distance_to_polyline(center, points) < radius * 1.6 + road_widths[r]:
				clear = false
				break
		if not clear:
			continue
		var hole := WaterholeStyle.make(terrain, center, radius)
		if not hole.is_empty():
			holes.append(hole)
			placed.append(center)
	terrain.set_meta(Meta.WATERHOLES, holes)
	return placed.size()
