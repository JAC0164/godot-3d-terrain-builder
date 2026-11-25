@tool
extends RefCounted
## Baked terrain shading for untextured styles.
##
## Everything is computed on the CPU while a chunk is built and stored as
## vertex colours of the merged untextured surface: no extra draw call, no
## texture fetch, no shader cost (the usual low-poly / mobile approach).
##
## - Style transitions: the per-cell style colours are blurred over a few
##   cells and sampled at each face centre, offset by a smooth noise so the
##   border between two styles is organic instead of following the grid.
## - Slope: steep faces move toward the style's cliff colour (grass -> earth).
## - Ambient occlusion: concave vertices (valleys, cliff feet) are darkened,
##   convex ones (ridges, cliff tops) slightly brightened.
## - Variation: a small per-face brightness / warmth jitter.
## - Macro variation: large lighter (warmer) / darker (cooler) patches from a
##   world-space noise, so bare ground is not one flat colour from afar.
## - Cliffs: darker toward the bottom, with an optional band of top colour
##   (a grass lip) along the top edge.
##
## Faceted ground (Smooth Ground off): faces stay flat-coloured (same colour
## on the 3 vertices). Smooth Ground: one colour per vertex, shared by the
## triangles around it (vertex_colors), so no triangle pattern shows. Results only depend on global grid data, so a cell gets the
## same colour whichever chunk builds it. With every setting at 0 the mesher
## skips this module and its output is unchanged.

const Meta = preload("../core/terrain_meta.gd")
const TerrainData = preload("../core/terrain_data.gd")
const MaterialFactory = preload("../materials/material_factory.gd")
const WaterholeStyle = preload("../styles/waterhole_style.gd")
const TerrainBiome = preload("../biomes/terrain_biome.gd")

## Noise frequency, in cells, of the transition border offset.
const BORDER_NOISE_FREQUENCY := 0.35
## Strongest AO darkening / ridge brightening (fractions of the colour).
const AO_DARKEN := 0.45
const AO_BRIGHTEN := 0.12
## Lip colour is slightly darker than the top so the edge reads as an overhang.
const LIP_SHADE := 0.92
## Size in meters of the macro variation patches (noise period).
const MACRO_SIZE := 20.0

static var _noise: FastNoiseLite
static var _macro_noise: FastNoiseLite

## Everything the mesher needs to colour the faces of one chunk.
class Context:
	var blend := 0
	var noise := 0.0
	var slope := 0.0
	var slope_cos_start := 1.0
	var slope_cos_end := 0.0
	var variation := 0.0
	var macro := 0.0
	var cliff_darken := 0.0
	var lip_height := 0.0
	var smooth := false
	# Smooth Ground: baked colour per vertex of the chunk (vw x vh), empty
	# otherwise. `faces` then holds the mean of each triangle's corners.
	var vertex_colors := PackedColorArray()
	# Colour grids of the region: premultiplied r, g, b with the weight in a.
	var rx0 := 0
	var rz0 := 0
	var rw := 0
	var rh := 0
	var top := PackedColorArray()
	var cliff := PackedColorArray()
	# AO factor per vertex of the chunk.
	var min_x := 0
	var min_z := 0
	var vw := 0
	var ao := PackedFloat32Array()
	# Macro variation per vertex of the chunk (signed shade offset), empty when off.
	var macro_shade := PackedFloat32Array()
	# Border-noise offset (in cells) per vertex of the chunk, empty when off.
	var jitter := PackedVector2Array()
	# Baked top-face colours of the chunk, 2 per cell.
	var cw := 0
	var faces := PackedColorArray()
	# style id -> [top colour, cliff colour], used where the grids are empty.
	var style_colors: Dictionary = {}
	# style id -> true when its side faces are untextured (may get a lip).
	var untextured_cliff: Dictionary = {}
	# style id -> true when its top is textured (styles met in the region).
	var textured_top: Dictionary = {}
	# Blended textures (MaterialFactory.splat_layers; empty = off): style id
	# -> layer 0..6, and the one-hot layer weights of the region cells
	# (layers 0-3 / 4-6), blurred like `top`.
	var layers: Dictionary = {}
	var tex_a := PackedColorArray()
	var tex_b := PackedColorArray()
	# Per vertex (Smooth Ground) or per top face, like vertex_colors / faces:
	# normalised layer weights (weights_b.a = waterhole tint of the textures),
	# the shade of the textures (AO x variation) and 1 where some weight is
	# set (the face goes to the blended surface).
	var weights_a := PackedColorArray()
	var weights_b := PackedColorArray()
	var shades := PackedFloat32Array()
	var textured := PackedByteArray()

## Carved heights of the vertices [x0, x1] x [z0, z1] (a chunk plus a
## 1-vertex border), row-major, `width` per row.
class HeightBlock:
	var x0 := 0
	var z0 := 0
	var x1 := 0
	var z1 := 0
	var width := 0
	var values := PackedFloat32Array()

## Shading of a terrain: the values of its biome (the single source of the
## look), plus the terrain's own Smooth Ground switch.
static func settings(terrain: Node3D) -> Dictionary:
	var biome: TerrainBiome = TerrainBiome.of(terrain)
	return {
		"blend": clampi(int(biome.blend), 0, 8),
		"noise": clampf(float(biome.blend_noise), 0.0, 1.0),
		"slope": clampf(float(biome.slope_tint), 0.0, 1.0),
		"slope_start": float(biome.slope_start),
		"slope_end": float(biome.slope_end),
		"ao": clampf(float(biome.ambient_occlusion), 0.0, 1.0),
		"variation": clampf(float(biome.variation), 0.0, 0.5),
		"macro": clampf(float(biome.macro_variation), 0.0, 0.5),
		"cliff_darken": clampf(float(biome.cliff_darken), 0.0, 1.0),
		"cliff_lip": maxf(float(biome.cliff_lip), 0.0),
		"smooth": Meta.get_bool(terrain, Meta.SHADE_SMOOTH, Meta.DEFAULT_SHADE_SMOOTH),
	}

static func is_enabled(s: Dictionary) -> bool:
	var blend: int = s["blend"]
	var noise: float = s["noise"]
	var slope: float = s["slope"]
	var ao: float = s["ao"]
	var variation: float = s["variation"]
	var macro: float = s["macro"]
	var cliff_darken: float = s["cliff_darken"]
	var cliff_lip: float = s["cliff_lip"]
	return (
		blend > 0 or noise > 0.0 or slope > 0.0
		or ao > 0.0 or variation > 0.0 or macro > 0.0
		or cliff_darken > 0.0 or cliff_lip > 0.0
	)

## Cells around an edited area whose colours may change with it (blur radius,
## border noise, bilinear sampling and AO neighbourhood).
static func influence_margin(terrain: Node3D) -> int:
	var s := settings(terrain)
	if not is_enabled(s):
		return 0
	var blend: int = s["blend"]
	return blend + 3

## Colours and AO needed to shade the cells [min_x, max_x) x [min_z, max_z).
## Returns null when shading is disabled.
static func prepare(terrain: Node3D, carve: PackedFloat32Array, min_x: int, min_z: int, max_x: int, max_z: int) -> Context:
	var s := settings(terrain)
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var spacing := world_size / float(maxi(resolution - 1, 1))
	var half := world_size * 0.5
	# Dried waterholes colour their basin and rim (even with shading off).
	var hole_rect := Rect2(float(min_x) * spacing - half, float(min_z) * spacing - half, float(max_x - min_x) * spacing, float(max_z - min_z) * spacing)
	var holes := WaterholeStyle.shapes(terrain, hole_rect)
	var has_holes := not holes.is_empty()
	# Blended textures need the context (weights) even with shading off.
	if not is_enabled(s) and not has_holes and MaterialFactory.splat_layers(terrain).is_empty():
		return null

	var ctx := Context.new()
	ctx.blend = s["blend"]
	ctx.noise = s["noise"]
	ctx.slope = s["slope"]
	var s_slope_start: float = s["slope_start"]
	var s_slope_end: float = s["slope_end"]
	var slope_start := clampf(minf(s_slope_start, s_slope_end), 0.0, 90.0)
	var slope_end := clampf(maxf(s_slope_start, s_slope_end), 0.0, 90.0)
	ctx.slope_cos_start = cos(deg_to_rad(slope_start))
	ctx.slope_cos_end = cos(deg_to_rad(maxf(slope_end, slope_start + 0.01)))
	ctx.variation = s["variation"]
	ctx.macro = s["macro"]
	ctx.cliff_darken = s["cliff_darken"]
	ctx.lip_height = s["cliff_lip"]
	ctx.smooth = s["smooth"]

	var cell_count := resolution - 1
	var margin := ctx.blend + 3
	ctx.rx0 = maxi(min_x - margin, 0)
	ctx.rz0 = maxi(min_z - margin, 0)
	ctx.rw = mini(max_x + margin, cell_count) - ctx.rx0
	ctx.rh = mini(max_z + margin, cell_count) - ctx.rz0

	# Per-style colours and whether the faces are untextured (vertex coloured):
	# style id -> [top untextured, side untextured, top colour, side colour].
	var style_infos: Dictionary = {}
	var cell_styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES, PackedInt32Array())
	var cell_flags: PackedByteArray = terrain.get_meta(Meta.CELL_ACTIVE, PackedByteArray())
	var fast_active := cell_flags.size() == cell_count * cell_count
	var layer_ids := MaterialFactory.splat_layers(terrain)
	for layer in layer_ids.size():
		ctx.layers[layer_ids[layer]] = layer

	_blend_style_colors(ctx, terrain, cell_count, cell_styles, cell_flags, fast_active, style_infos)

	ctx.min_x = min_x
	ctx.min_z = min_z
	ctx.vw = max_x - min_x + 1
	var vw := ctx.vw

	var hb := _height_block(terrain, carve, resolution, min_x, min_z, max_x, max_z)
	var block := hb.values
	var bx0 := hb.x0
	var bz0 := hb.z0
	var bw := hb.width

	var ao_amount: float = s["ao"]
	var factors := _ao_factors(hb, ao_amount, spacing, min_x, min_z, max_x, max_z)
	ctx.ao = factors

	var jitter := _border_jitter(ctx.noise, min_x, min_z, max_x, max_z)
	ctx.jitter = jitter
	var macro := _macro_offsets(ctx.macro, spacing, half, min_x, min_z, max_x, max_z)
	ctx.macro_shade = macro
	var has_macro := not macro.is_empty()

	# Colour of every top face of the chunk, in one tight loop (locals only:
	# much cheaper in GDScript than a function call per face).
	var cw := max_x - min_x
	var faces := PackedColorArray()
	faces.resize(cw * (max_z - min_z) * 2)
	var top := ctx.top
	var cliff := ctx.cliff
	var rx0 := ctx.rx0
	var rz0 := ctx.rz0
	var rw := ctx.rw
	var rh := ctx.rh
	var max_gx := float(rw - 1)
	var max_gz := float(rh - 1)
	var bilinear := ctx.blend > 0
	var slope := ctx.slope
	var cos_start := ctx.slope_cos_start
	var cos_end := ctx.slope_cos_end
	var variation := ctx.variation
	var inv_spacing := 1.0 / spacing
	var splat := not ctx.layers.is_empty()
	if ctx.smooth:
		_prepare_vertex_colors(ctx, terrain, cell_flags, fast_active, cell_styles, style_infos, cell_count,
			hb, factors, jitter, holes, spacing, half)
		var vcolors := ctx.vertex_colors
		for z in range(min_z, max_z):
			for x in range(min_x, max_x):
				var i00 := (z - min_z) * vw + (x - min_x)
				var v00 := vcolors[i00]
				var v11 := vcolors[i00 + vw + 1]
				var f := ((z - min_z) * cw + (x - min_x)) * 2
				faces[f] = (v00 + vcolors[i00 + 1] + v11) * 0.3333333
				faces[f + 1] = (v00 + v11 + vcolors[i00 + vw]) * 0.3333333
		ctx.cw = cw
		ctx.faces = faces
		return ctx
	var tex_a := ctx.tex_a
	var tex_b := ctx.tex_b
	if splat:
		_size_splat(ctx, faces.size())
	for z in range(min_z, max_z):
		for x in range(min_x, max_x):
			var cell := z * cell_count + x
			var active: bool = cell_flags[cell] != 0 if fast_active else TerrainData.cell_active(terrain, x, z)
			if not active:
				continue
			var style_id: int = maxi(cell_styles[cell], 0) if cell < cell_styles.size() else 0
			var style_info: Array = style_infos[style_id]
			if not style_info[0] and not (splat and ctx.layers.has(style_id)):
				continue
			var i00 := (z - min_z) * vw + (x - min_x)
			var b00 := (z - bz0) * bw + (x - bx0)
			var h00 := block[b00]
			var h10 := block[b00 + 1]
			var h01 := block[b00 + bw]
			var h11 := block[b00 + bw + 1]
			for tri in range(2):
				var i_mid := i00 + 1 if tri == 0 else i00 + vw
				var offset := (jitter[i00] + jitter[i00 + vw + 1] + jitter[i_mid]) * 0.3333333
				# Face centroid in region cell units.
				var gx := float(x - rx0) + (0.6666667 if tri == 0 else 0.3333333) + offset.x
				var gz := float(z - rz0) + (0.3333333 if tri == 0 else 0.6666667) + offset.y
				var c: Color
				var steep := 0.0
				var cell_index := 0
				var dx := 0
				var dz := 0
				var tx := 0.0
				var tz := 0.0
				if bilinear:
					gx = clampf(gx - 0.5, 0.0, max_gx)
					gz = clampf(gz - 0.5, 0.0, max_gz)
					var x0 := int(gx)
					var z0 := int(gz)
					cell_index = z0 * rw + x0
					dx = 1 if x0 + 1 < rw else 0
					dz = rw if z0 + 1 < rh else 0
					tx = gx - float(x0)
					tz = gz - float(z0)
					c = top[cell_index].lerp(top[cell_index + dx], tx).lerp(top[cell_index + dz].lerp(top[cell_index + dz + dx], tx), tz)
				else:
					cell_index = clampi(int(gz), 0, rh - 1) * rw + clampi(int(gx), 0, rw - 1)
					c = top[cell_index]
				var wa := Color(0, 0, 0, 0)
				var wb := Color(0, 0, 0, 0)
				var tint := 0.0
				if splat:
					if bilinear:
						wa = tex_a[cell_index].lerp(tex_a[cell_index + dx], tx).lerp(tex_a[cell_index + dz].lerp(tex_a[cell_index + dz + dx], tx), tz)
						wb = tex_b[cell_index].lerp(tex_b[cell_index + dx], tx).lerp(tex_b[cell_index + dz].lerp(tex_b[cell_index + dz + dx], tx), tz)
					else:
						wa = tex_a[cell_index]
						wb = tex_b[cell_index]
					var total := c.a + _weight_sum(wa, wb)
					if total > 0.0001:
						wa = wa / total
						wb = wb / total
				if c.a > 0.0001:
					c = Color(c.r / c.a, c.g / c.a, c.b / c.a)
				else:
					c = style_info[2]

				if slope > 0.0:
					# Slope from the height differences along the two face edges.
					var ddx := (h10 - h00) if tri == 0 else (h11 - h01)
					var ddz := (h11 - h10) if tri == 0 else (h01 - h00)
					var normal_y := 1.0 / sqrt(1.0 + (ddx * ddx + ddz * ddz) * inv_spacing * inv_spacing)
					if normal_y < cos_start:
						steep = (1.0 - smoothstep(cos_end, cos_start, normal_y)) * slope
						var e: Color
						if bilinear:
							e = cliff[cell_index].lerp(cliff[cell_index + dx], tx).lerp(cliff[cell_index + dz].lerp(cliff[cell_index + dz + dx], tx), tz)
						else:
							e = cliff[cell_index]
						if e.a > 0.0001:
							e = Color(e.r / e.a, e.g / e.a, e.b / e.a)
						else:
							e = style_info[3]
						c = c.lerp(e, steep)

				if has_holes:
					# Clay over the basin, dark crack colour on the floor (seen
					# between the mud plates), fading out over the rim.
					var wx := (float(x) + (0.6666667 if tri == 0 else 0.3333333) + offset.x) * spacing - half
					var wz := (float(z) + (0.3333333 if tri == 0 else 0.6666667) + offset.y) * spacing - half
					for hole: WaterholeStyle.Shape in holes:
						if not hole.bounds.has_point(Vector2(wx, wz)):
							continue
						var d := hole.distance(wx, wz)
						var reach := 1.0 + hole.rim
						if d >= reach:
							continue
						var crack_weight := 1.0 - smoothstep(hole.floor_ratio - 0.12, hole.floor_ratio + 0.04, d)
						var hole_color := hole.clay.lerp(hole.crack, crack_weight)
						var k := 1.0 - smoothstep(0.92, reach, d)
						c = c.lerp(hole_color, k)
						if splat:
							tint = 1.0 - (1.0 - tint) * (1.0 - k)

				var shade := (factors[i00] + factors[i00 + vw + 1] + factors[i_mid]) * 0.3333333
				var warm := 0.0
				if has_macro:
					var m := (macro[i00] + macro[i00 + vw + 1] + macro[i_mid]) * 0.3333333
					shade *= 1.0 + m
					warm = m * 0.3
				var tex_shade := shade
				if variation > 0.0:
					var face_hash := x * 374761393 + z * 668265263 + tri * 1442695041
					face_hash = (face_hash ^ (face_hash >> 13)) * 1274126177
					face_hash = face_hash ^ (face_hash >> 16)
					var value := shade * (1.0 + (float(face_hash & 0xFFFF) / 32767.5 - 1.0) * variation)
					tex_shade = value
					var warmth := (float((face_hash >> 16) & 0xFFFF) / 32767.5 - 1.0) * variation * 0.35 + warm
					c = Color(c.r * value * (1.0 + warmth), c.g * value, c.b * value * (1.0 - warmth))
				else:
					c = Color(c.r * shade * (1.0 + warm), c.g * shade, c.b * shade * (1.0 - warm))
				var face_index := ((z - min_z) * cw + (x - min_x)) * 2 + tri
				faces[face_index] = c.clamp()
				if splat:
					_store_splat(ctx, face_index, wa, wb, tex_shade, tint)
	ctx.cw = cw
	ctx.faces = faces
	return ctx

## Ground and side colour of every cell around the chunk (ctx.rx0.. region),
## blended `ctx.blend` times with the neighbours: ctx.top, ctx.cliff.
## Fills `style_infos` (see prepare()) for the styles it meets.
static func _blend_style_colors(ctx: Context, terrain: Node3D, cell_count: int, cell_styles: PackedInt32Array,
		cell_flags: PackedByteArray, fast_active: bool, style_infos: Dictionary) -> void:
	# Premultiplied colour grids. Textured and empty cells have weight 0, so
	# they never bleed into neighbours.
	var top := PackedColorArray()
	var cliff := PackedColorArray()
	top.resize(ctx.rw * ctx.rh)
	cliff.resize(ctx.rw * ctx.rh)
	top.fill(Color(0, 0, 0, 0))
	cliff.fill(Color(0, 0, 0, 0))
	# Blended textures: one-hot layer weights of the textured cells.
	var splat := not ctx.layers.is_empty()
	var tex_a := PackedColorArray()
	var tex_b := PackedColorArray()
	if splat:
		tex_a.resize(ctx.rw * ctx.rh)
		tex_b.resize(ctx.rw * ctx.rh)
		tex_a.fill(Color(0, 0, 0, 0))
		tex_b.fill(Color(0, 0, 0, 0))
	for z in range(ctx.rz0, ctx.rz0 + ctx.rh):
		for x in range(ctx.rx0, ctx.rx0 + ctx.rw):
			var cell := z * cell_count + x
			var active: bool = cell_flags[cell] != 0 if fast_active else TerrainData.cell_active(terrain, x, z)
			if not active:
				continue
			var style_id: int = maxi(cell_styles[cell], 0) if cell < cell_styles.size() else 0
			var style_info: Variant = style_infos.get(style_id)
			if style_info == null:
				var top_color := MaterialFactory.terrain_style_color(terrain, style_id, true)
				var cliff_color := MaterialFactory.terrain_style_color(terrain, style_id, false)
				ctx.style_colors[style_id] = [top_color, cliff_color]
				style_info = [
					MaterialFactory.terrain_style_texture(terrain, style_id, true) == null,
					MaterialFactory.terrain_style_texture(terrain, style_id, false) == null,
					top_color, cliff_color,
				]
				style_infos[style_id] = style_info
				ctx.untextured_cliff[style_id] = style_info[1]
				if not style_info[0]:
					ctx.textured_top[style_id] = true
			var i := (z - ctx.rz0) * ctx.rw + (x - ctx.rx0)
			if style_info[0]:
				var c: Color = style_info[2]
				top[i] = Color(c.r, c.g, c.b, 1.0)
			if style_info[1]:
				var c: Color = style_info[3]
				cliff[i] = Color(c.r, c.g, c.b, 1.0)
			if splat:
				var layer: int = ctx.layers.get(style_id, -1)
				if layer >= 0:
					var one_hot := Color(0, 0, 0, 0)
					one_hot[layer & 3] = 1.0
					if layer < 4:
						tex_a[i] = one_hot
					else:
						tex_b[i] = one_hot

	for _pass in range(ctx.blend):
		top = _blur(top, ctx.rw, ctx.rh)
		cliff = _blur(cliff, ctx.rw, ctx.rh)
		if splat:
			tex_a = _blur(tex_a, ctx.rw, ctx.rh)
			tex_b = _blur(tex_b, ctx.rw, ctx.rh)
	ctx.top = top
	ctx.cliff = cliff
	ctx.tex_a = tex_a
	ctx.tex_b = tex_b

## Carved heights of the chunk vertices plus a 1-vertex border.
static func _height_block(terrain: Node3D, carve: PackedFloat32Array, resolution: int,
		min_x: int, min_z: int, max_x: int, max_z: int) -> HeightBlock:
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var carved := carve.size() == heights.size()
	var bx0 := maxi(min_x - 1, 0)
	var bz0 := maxi(min_z - 1, 0)
	var bx1 := mini(max_x + 1, resolution - 1)
	var bz1 := mini(max_z + 1, resolution - 1)
	var bw := bx1 - bx0 + 1
	var block := PackedFloat32Array()
	block.resize(bw * (bz1 - bz0 + 1))
	for vz in range(bz0, bz1 + 1):
		for vx in range(bx0, bx1 + 1):
			var index := vz * resolution + vx
			block[(vz - bz0) * bw + (vx - bx0)] = heights[index] - carve[index] if carved else heights[index]
	var hb := HeightBlock.new()
	hb.x0 = bx0
	hb.z0 = bz0
	hb.x1 = bx1
	hb.z1 = bz1
	hb.width = bw
	hb.values = block
	return hb

## Ambient occlusion factor of every chunk vertex: hollows darker, bumps
## lighter (1 = unchanged), from the height block.
static func _ao_factors(hb: HeightBlock, ao: float, spacing: float, min_x: int, min_z: int, max_x: int, max_z: int) -> PackedFloat32Array:
	var block := hb.values
	var bx0 := hb.x0
	var bz0 := hb.z0
	var bx1 := hb.x1
	var bz1 := hb.z1
	var bw := hb.width
	var vw := max_x - min_x + 1
	var vh := max_z - min_z + 1
	var factors := PackedFloat32Array()
	factors.resize(vw * vh)
	factors.fill(1.0)
	if ao > 0.0:
		var scale := 2.0 / spacing
		for vz in range(min_z, max_z + 1):
			for vx in range(min_x, max_x + 1):
				var row := (vz - bz0) * bw
				var col := vx - bx0
				var h := block[row + col]
				var around := (
					block[row + maxi(vx - 1, bx0) - bx0] + block[row + mini(vx + 1, bx1) - bx0]
					+ block[(maxi(vz - 1, bz0) - bz0) * bw + col] + block[(mini(vz + 1, bz1) - bz0) * bw + col]
				) * 0.25
				var concavity := clampf((around - h) * scale, -1.0, 1.0)
				factors[(vz - min_z) * vw + (vx - min_x)] = 1.0 - ao * (
					AO_DARKEN * maxf(concavity, 0.0) - AO_BRIGHTEN * maxf(-concavity, 0.0)
				)
	return factors

## The border noise, made once (TerrainMesher.prepare_threads makes it on the
## main thread before worker threads read it).
static func prepare_noise() -> void:
	if _noise == null:
		_noise = FastNoiseLite.new()
		_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_noise.seed = 1337
		_noise.frequency = BORDER_NOISE_FREQUENCY
	if _macro_noise == null:
		_macro_noise = FastNoiseLite.new()
		_macro_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		_macro_noise.seed = 7331
		_macro_noise.frequency = 1.0 / MACRO_SIZE
		_macro_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
		_macro_noise.fractal_octaves = 3

## Offset (in cells) of every chunk vertex for the noisy style borders.
static func _border_jitter(noise: float, min_x: int, min_z: int, max_x: int, max_z: int) -> PackedVector2Array:
	var vw := max_x - min_x + 1
	var vh := max_z - min_z + 1
	var jitter := PackedVector2Array()
	jitter.resize(vw * vh)
	if noise > 0.0:
		prepare_noise()
		var k := 0
		for vz in range(min_z, max_z + 1):
			for vx in range(min_x, max_x + 1):
				jitter[k] = Vector2(_noise.get_noise_2d(vx, vz), _noise.get_noise_2d(vx + 71.3, vz - 37.9)) * noise
				k += 1
	return jitter

## Macro variation of every chunk vertex: a signed shade offset (-amount
## to +amount / 2) from a world-space noise, so chunks join seamlessly. Empty when off.
static func _macro_offsets(amount: float, spacing: float, half: float, min_x: int, min_z: int, max_x: int, max_z: int) -> PackedFloat32Array:
	var offsets := PackedFloat32Array()
	if amount <= 0.0:
		return offsets
	prepare_noise()
	offsets.resize((max_x - min_x + 1) * (max_z - min_z + 1))
	var k := 0
	for vz in range(min_z, max_z + 1):
		var wz := float(vz) * spacing - half
		for vx in range(min_x, max_x + 1):
			# FBM output rarely leaves +-0.5: stretched so `amount` is the swing.
			# Lighter patches get half of it, so bright colours do not wash out.
			var n := clampf(_macro_noise.get_noise_2d(float(vx) * spacing - half, wz) * 2.0, -1.0, 1.0)
			offsets[k] = (n if n < 0.0 else n * 0.5) * amount
			k += 1
	return offsets

## Smooth Ground: the colour of every chunk vertex used by an untextured top,
## computed like a face colour but at the vertex (style blend, slope from the
## height gradient, waterholes, AO of the vertex, variation per vertex).
static func _prepare_vertex_colors(ctx: Context, terrain: Node3D, cell_flags: PackedByteArray, fast_active: bool,
		cell_styles: PackedInt32Array, style_infos: Dictionary, cell_count: int, hb: HeightBlock,
		factors: PackedFloat32Array, jitter: PackedVector2Array, holes: Array, spacing: float, half: float) -> void:
	var block := hb.values
	var bx0 := hb.x0
	var bz0 := hb.z0
	var bx1 := hb.x1
	var bz1 := hb.z1
	var bw := hb.width
	var vw := ctx.vw
	var min_x := ctx.min_x
	var min_z := ctx.min_z
	var vh := factors.size() / vw
	var colors := PackedColorArray()
	colors.resize(vw * vh)
	var top := ctx.top
	var cliff := ctx.cliff
	var rx0 := ctx.rx0
	var rz0 := ctx.rz0
	var rw := ctx.rw
	var rh := ctx.rh
	var max_gx := float(rw - 1)
	var max_gz := float(rh - 1)
	var bilinear := ctx.blend > 0
	var slope := ctx.slope
	var cos_start := ctx.slope_cos_start
	var cos_end := ctx.slope_cos_end
	var variation := ctx.variation
	var macro := ctx.macro_shade
	var has_macro := not macro.is_empty()
	var has_holes := not holes.is_empty()
	var inv_spacing := 1.0 / spacing
	var splat := not ctx.layers.is_empty()
	var tex_a := ctx.tex_a
	var tex_b := ctx.tex_b
	if splat:
		_size_splat(ctx, vw * vh)
	for vz in range(min_z, min_z + vh):
		for vx in range(min_x, min_x + vw):
			# Style of a neighbouring active cell with an untextured top
			# (fallback colour where the blend grid has no weight).
			var style_info: Variant = null
			var textured_info: Variant = null
			for k in 4:
				var cx := vx - 1 + (k & 1)
				var cz := vz - 1 + (k >> 1)
				if cx < 0 or cz < 0 or cx >= cell_count or cz >= cell_count:
					continue
				var cell := cz * cell_count + cx
				var active: bool = cell_flags[cell] != 0 if fast_active else TerrainData.cell_active(terrain, cx, cz)
				if not active:
					continue
				var candidate_id: int = maxi(cell_styles[cell], 0) if cell < cell_styles.size() else 0
				var candidate: Variant = style_infos.get(candidate_id)
				if candidate != null and candidate[0]:
					style_info = candidate
					break
				if splat and textured_info == null and candidate != null and ctx.layers.has(candidate_id):
					textured_info = candidate
			if style_info == null:
				style_info = textured_info
			if style_info == null:
				continue
			var vi := (vz - min_z) * vw + (vx - min_x)
			var offset := jitter[vi]
			var gx := float(vx - rx0) + offset.x
			var gz := float(vz - rz0) + offset.y
			var c: Color
			var cell_index := 0
			var dx := 0
			var dz := 0
			var tx := 0.0
			var tz := 0.0
			if bilinear:
				gx = clampf(gx - 0.5, 0.0, max_gx)
				gz = clampf(gz - 0.5, 0.0, max_gz)
				var x0 := int(gx)
				var z0 := int(gz)
				cell_index = z0 * rw + x0
				dx = 1 if x0 + 1 < rw else 0
				dz = rw if z0 + 1 < rh else 0
				tx = gx - float(x0)
				tz = gz - float(z0)
				c = top[cell_index].lerp(top[cell_index + dx], tx).lerp(top[cell_index + dz].lerp(top[cell_index + dz + dx], tx), tz)
			else:
				cell_index = clampi(int(gz), 0, rh - 1) * rw + clampi(int(gx), 0, rw - 1)
				c = top[cell_index]
			var wa := Color(0, 0, 0, 0)
			var wb := Color(0, 0, 0, 0)
			var tint := 0.0
			if splat:
				if bilinear:
					wa = tex_a[cell_index].lerp(tex_a[cell_index + dx], tx).lerp(tex_a[cell_index + dz].lerp(tex_a[cell_index + dz + dx], tx), tz)
					wb = tex_b[cell_index].lerp(tex_b[cell_index + dx], tx).lerp(tex_b[cell_index + dz].lerp(tex_b[cell_index + dz + dx], tx), tz)
				else:
					wa = tex_a[cell_index]
					wb = tex_b[cell_index]
				var total := c.a + _weight_sum(wa, wb)
				if total > 0.0001:
					wa = wa / total
					wb = wb / total
			if c.a > 0.0001:
				c = Color(c.r / c.a, c.g / c.a, c.b / c.a)
			else:
				c = style_info[2]

			if slope > 0.0:
				# Height gradient at the vertex (central differences).
				var row := (vz - bz0) * bw
				var col := vx - bx0
				var xl := maxi(vx - 1, bx0)
				var xr := mini(vx + 1, bx1)
				var zu := maxi(vz - 1, bz0)
				var zd := mini(vz + 1, bz1)
				var ddx := (block[row + xr - bx0] - block[row + xl - bx0]) / float(maxi(xr - xl, 1))
				var ddz := (block[(zd - bz0) * bw + col] - block[(zu - bz0) * bw + col]) / float(maxi(zd - zu, 1))
				var normal_y := 1.0 / sqrt(1.0 + (ddx * ddx + ddz * ddz) * inv_spacing * inv_spacing)
				if normal_y < cos_start:
					var steep := (1.0 - smoothstep(cos_end, cos_start, normal_y)) * slope
					var e: Color
					if bilinear:
						e = cliff[cell_index].lerp(cliff[cell_index + dx], tx).lerp(cliff[cell_index + dz].lerp(cliff[cell_index + dz + dx], tx), tz)
					else:
						e = cliff[cell_index]
					if e.a > 0.0001:
						e = Color(e.r / e.a, e.g / e.a, e.b / e.a)
					else:
						e = style_info[3]
					c = c.lerp(e, steep)

			if has_holes:
				var wx := (float(vx) + offset.x) * spacing - half
				var wz := (float(vz) + offset.y) * spacing - half
				for hole: WaterholeStyle.Shape in holes:
					if not hole.bounds.has_point(Vector2(wx, wz)):
						continue
					var d := hole.distance(wx, wz)
					var reach := 1.0 + hole.rim
					if d >= reach:
						continue
					var crack_weight := 1.0 - smoothstep(hole.floor_ratio - 0.12, hole.floor_ratio + 0.04, d)
					var hole_color := hole.clay.lerp(hole.crack, crack_weight)
					var k := 1.0 - smoothstep(0.92, reach, d)
					c = c.lerp(hole_color, k)
					if splat:
						tint = 1.0 - (1.0 - tint) * (1.0 - k)

			var shade := factors[vi]
			var warm := 0.0
			if has_macro:
				shade *= 1.0 + macro[vi]
				warm = macro[vi] * 0.3
			var tex_shade := shade
			if variation > 0.0:
				var vertex_hash := vx * 374761393 + vz * 668265263 + 7 * 1442695041
				vertex_hash = (vertex_hash ^ (vertex_hash >> 13)) * 1274126177
				vertex_hash = vertex_hash ^ (vertex_hash >> 16)
				var value := shade * (1.0 + (float(vertex_hash & 0xFFFF) / 32767.5 - 1.0) * variation)
				tex_shade = value
				var warmth := (float((vertex_hash >> 16) & 0xFFFF) / 32767.5 - 1.0) * variation * 0.35 + warm
				c = Color(c.r * value * (1.0 + warmth), c.g * value, c.b * value * (1.0 - warmth))
			else:
				c = Color(c.r * shade * (1.0 + warm), c.g * shade, c.b * shade * (1.0 - warm))
			colors[vi] = c.clamp()
			if splat:
				_store_splat(ctx, vi, wa, wb, tex_shade, tint)
	ctx.vertex_colors = colors

## Baked colour of top triangle `tri` (0: p00-p10-p11, 1: p00-p11-p01) of
## cell (x, z) of the prepared chunk.
## A copy of `ctx` holding only its top-face colours (what the detail
## scatter reads), to keep it for later at a fraction of the memory.
static func top_faces(ctx: Context) -> Context:
	var slim := Context.new()
	slim.min_x = ctx.min_x
	slim.min_z = ctx.min_z
	slim.vw = ctx.vw
	slim.cw = ctx.cw
	slim.faces = ctx.faces
	return slim

## Colour of top triangle `tri` (0 or 1) of cell (x, z).
static func top_face_color(ctx: Context, x: int, z: int, tri: int) -> Color:
	return ctx.faces[((z - ctx.min_z) * ctx.cw + (x - ctx.min_x)) * 2 + tri]
## Colours of one cliff wall: [lip, wall top, wall bottom (darker)]. (fx, fz) is the middle of
## the cell edge carrying the wall, in cell units; `side` 0..3.
static func cliff_colors(ctx: Context, x: int, z: int, side: int, style_id: int, fx: float, fz: float) -> Array:
	if ctx.noise > 0.0:
		# Average border offset of the two edge end vertices.
		var i00 := (z - ctx.min_z) * ctx.vw + (x - ctx.min_x)
		var a: int = [i00, i00 + 1, i00, i00 + ctx.vw][side]
		var b: int = [i00 + ctx.vw, i00 + ctx.vw + 1, i00 + 1, i00 + ctx.vw + 1][side]
		var offset := (ctx.jitter[a] + ctx.jitter[b]) * 0.5
		fx += offset.x
		fz += offset.y
	var lip := _sample(ctx, ctx.top, fx, fz, style_id, 0)
	lip = Color(lip.r * LIP_SHADE, lip.g * LIP_SHADE, lip.b * LIP_SHADE)
	# Textured walls: the shading only (white base), multiplied with the
	# texture by their material.
	var wall := _sample(ctx, ctx.cliff, fx, fz, style_id, 1) if ctx.untextured_cliff.get(style_id, true) else Color.WHITE
	if ctx.variation > 0.0:
		var h := _hash(x, z, 2 + side)
		var value := 1.0 + (float(h & 0xFFFF) / 32767.5 - 1.0) * ctx.variation
		var warmth := (float((h >> 16) & 0xFFFF) / 32767.5 - 1.0) * ctx.variation * 0.35
		wall = Color(wall.r * value * (1.0 + warmth), wall.g * value, wall.b * value * (1.0 - warmth)).clamp()
	var dark := 1.0 - ctx.cliff_darken
	return [lip, wall, Color(wall.r * dark, wall.g * dark, wall.b * dark)]

# -----------------------------------------------------------------------------
# Blended textures
# -----------------------------------------------------------------------------

static func _size_splat(ctx: Context, count: int) -> void:
	ctx.weights_a.resize(count)
	ctx.weights_b.resize(count)
	ctx.shades.resize(count)
	ctx.textured.resize(count)

## Sum of the layer weights (layers 0-6: wb.a is the waterhole tint).
static func _weight_sum(wa: Color, wb: Color) -> float:
	return wa.r + wa.g + wa.b + wa.a + wb.r + wb.g + wb.b

## Stores the blended-texture data of vertex / face `index`; `textured` is 1
## when some weight survives the 8-bit storage of the mesh. `tint` (how much
## a waterhole colours the textures, keeping their grain) goes in wb.a.
static func _store_splat(ctx: Context, index: int, wa: Color, wb: Color, shade: float, tint: float) -> void:
	ctx.weights_a[index] = wa
	ctx.weights_b[index] = Color(wb.r, wb.g, wb.b, tint)
	ctx.shades[index] = shade
	ctx.textured[index] = 1 if _weight_sum(wa, wb) * 255.0 >= 0.5 else 0

# -----------------------------------------------------------------------------

## One 3x3 box pass (sums, normalised later by the weight in alpha) over a
## premultiplied colour grid. Cells outside the region count as empty;
## callers keep a margin so this never matters for shaded cells.
static func _blur(src: PackedColorArray, w: int, h: int) -> PackedColorArray:
	var tmp := PackedColorArray()
	tmp.resize(src.size())
	for z in range(h):
		var base := z * w
		for i in range(base, base + w):
			var v := src[i]
			if i > base: v += src[i - 1]
			if i < base + w - 1: v += src[i + 1]
			tmp[i] = v
	var dst := PackedColorArray()
	dst.resize(src.size())
	for z in range(h):
		var base := z * w
		for i in range(base, base + w):
			var v := tmp[i]
			if z > 0: v += tmp[i - w]
			if z < h - 1: v += tmp[i + w]
			dst[i] = v
	return dst

## Colour of a grid at a point in cell units: bilinear between cell centres
## when blending, nearest cell otherwise. Falls back to the style's own
## colour (`which` 0 = top, 1 = cliff) where the grid has no weight.
static func _sample(ctx: Context, grid: PackedColorArray, fx: float, fz: float, style_id: int, which: int) -> Color:
	var gx := fx - float(ctx.rx0)
	var gz := fz - float(ctx.rz0)
	var c: Color
	if ctx.blend == 0:
		c = grid[clampi(int(gz), 0, ctx.rh - 1) * ctx.rw + clampi(int(gx), 0, ctx.rw - 1)]
	else:
		gx = clampf(gx - 0.5, 0.0, float(ctx.rw - 1))
		gz = clampf(gz - 0.5, 0.0, float(ctx.rh - 1))
		var x0 := int(gx)
		var z0 := int(gz)
		var i := z0 * ctx.rw + x0
		var dx := 1 if x0 + 1 < ctx.rw else 0
		var dz := ctx.rw if z0 + 1 < ctx.rh else 0
		var tx := gx - float(x0)
		c = grid[i].lerp(grid[i + dx], tx).lerp(grid[i + dz].lerp(grid[i + dz + dx], tx), gz - float(z0))
	if c.a <= 0.0001:
		var own: Variant = ctx.style_colors.get(style_id)
		return own[which] if own != null else Color.WHITE
	return Color(c.r / c.a, c.g / c.a, c.b / c.a)

## Deterministic 32-bit integer hash of a face / wall.
static func _hash(x: int, z: int, salt: int) -> int:
	var h: int = x * 374761393 + z * 668265263 + salt * 1442695041
	h = (h ^ (h >> 13)) * 1274126177
	return h ^ (h >> 16)
