extends SceneTree
## Top view of a generated map, one pixel per cell: ground styles with a
## hill shade, rivers (blue), tracks (red-brown), waterholes (dark). For
## looking at what a recipe makes without building it.
##   Godot --headless --path . --script res://tools/render_map_overview.gd -- [recipe.tres] [seed] [out.png]
## Defaults: the open-world preset, seed 7, results/big_world/open_world_7.png.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var recipe_path := args[0] if args.size() > 0 else ADDON + "generation/presets/senegal_savanna_open_world_map.tres"
	var map_seed := int(args[1]) if args.size() > 1 else 7
	var out := args[2] if args.size() > 2 else "res://results/big_world/open_world_%d.png" % map_seed
	var terrain := Node3D.new()
	root.add_child(terrain)
	TerrainData.initialize(terrain)
	var stats := MapGenerator.generate(terrain, load(recipe_path), map_seed)
	print("generated: ", stats)
	var n: int = stats["size"]
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world: float = terrain.get_meta(Meta.WORLD_SIZE)
	var cell := world / float(n)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES)
	var active: PackedByteArray = terrain.get_meta(Meta.CELL_ACTIVE)
	var palette: Array = terrain.get_meta(Meta.STYLE_PALETTE)
	var image := Image.create(n, n, false, Image.FORMAT_RGB8)
	var light := Vector3(-1.0, 1.4, -0.8).normalized()
	for z in range(n):
		for x in range(n):
			var c := z * n + x
			if active[c] == 0:
				image.set_pixel(x, z, Color(0.12, 0.14, 0.2))
				continue
			var h00 := heights[z * resolution + x]
			var h10 := heights[z * resolution + x + 1]
			var h01 := heights[(z + 1) * resolution + x]
			var h11 := heights[(z + 1) * resolution + x + 1]
			var normal := Vector3(((h00 + h01) - (h10 + h11)) * 0.5, cell, ((h00 + h10) - (h01 + h11)) * 0.5).normalized()
			var shade := 0.55 + 0.6 * maxf(normal.dot(light), 0.0)
			var style: Dictionary = palette[clampi(styles[c], 0, palette.size() - 1)]
			var colour: Color = style["top_color"]
			image.set_pixel(x, z, Color(colour.r * shade, colour.g * shade, colour.b * shade))
	var half := float(n) * 0.5
	for river: Dictionary in terrain.get_meta(Meta.RIVERS, []):
		_draw_line(image, river["points"], float(river["width"]) / cell, half, cell, Color(0.2, 0.45, 0.8))
	for road: Dictionary in terrain.get_meta(Meta.ROADS, []):
		_draw_line(image, road["points"], maxf(float(road["width"]) / cell, 1.5), half, cell, Color(0.55, 0.25, 0.15))
	for hole: Dictionary in terrain.get_meta(Meta.WATERHOLES, []):
		var centre: Vector2 = hole["center"]
		_disc(image, centre / cell + Vector2(half, half), float(hole["radius"]) / cell, Color(0.3, 0.22, 0.15))
	image.save_png(out)
	print("saved ", ProjectSettings.globalize_path(out))
	quit()

func _draw_line(image: Image, points: Array, width: float, half: float, cell: float, colour: Color) -> void:
	for i in range(points.size() - 1):
		var a: Vector2 = points[i] / cell + Vector2(half, half)
		var b: Vector2 = points[i + 1] / cell + Vector2(half, half)
		var steps := maxi(int(a.distance_to(b)), 1)
		for s in range(steps + 1):
			_disc(image, a.lerp(b, float(s) / float(steps)), width * 0.5, colour)

func _disc(image: Image, centre: Vector2, radius: float, colour: Color) -> void:
	var r := ceili(radius)
	for z in range(int(centre.y) - r, int(centre.y) + r + 1):
		for x in range(int(centre.x) - r, int(centre.x) + r + 1):
			if x >= 0 and z >= 0 and x < image.get_width() and z < image.get_height() and Vector2(x + 0.5, z + 0.5).distance_to(centre) <= radius + 0.5:
				image.set_pixel(x, z, colour)
