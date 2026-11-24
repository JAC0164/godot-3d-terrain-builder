@tool
extends RefCounted
## Dried waterholes: data and shape.
##
## A waterhole is a Dictionary in the `_lte_waterholes` metadata: "center"
## (Vector2, terrain-local X/Z), "radius" and its own style fields (see
## DEFAULTS). Nothing is written into the heights or the cell styles. Its
## effects are all derived from it, so moving, resizing or erasing a
## waterhole leaves the terrain intact:
## - the depression and the small raised lip: carve depths
##   (WaterholeMesher.add_carve), like river beds;
## - the clay colour of the basin, the dark crack colour of the floor and the
##   tint fading over the rim: baked by TerrainShading, colors read from the
##   terrain's biome (shared by all its waterholes);
## - the cracked mud plates on the floor: WaterholeMesher.build;
## - the BASIN / RIM zones that detail layers can target (DetailScatter).
##
## Shape: normalised distance d = |p - center| / r(angle), with r(angle) the
## radius wobbled by three seeded harmonics (irregular outline):
##   d < floor      flat floor covered with mud plates
##   floor .. 1     bank rising to the original ground
##   1 .. 1 + rim   rim: trampled clay fading into the ground (+ lip)

const Meta = preload("../core/terrain_meta.gd")
const TerrainBiome = preload("../biomes/terrain_biome.gd")

## Default style of new waterholes. Each field is also a terrain setting
## (`_lte_waterhole_<field>`, see setting_key()) used for the next ones.
const DEFAULTS := {
	"depth": 0.7,
	"floor": 0.75,
	"irregularity": 0.22,
	"rim": 0.45,
	"lip": 0.1,
	"plate_size": 0.9,
	"crack_width": 0.1,
	"curl": 0.05,
}

const MIN_RADIUS := 0.75

const ZONE_NONE := 0
const ZONE_BASIN := 1
const ZONE_RIM := 2

## One waterhole flattened into typed fields, for loops over many points.
class Shape:
	var cx := 0.0
	var cz := 0.0
	var radius := 1.0
	var floor_ratio := 0.6
	var rim := 0.4
	var depth := 0.0
	var lip := 0.0
	var irregularity := 0.0
	var phase1 := 0.0
	var phase2 := 0.0
	var phase3 := 0.0
	var seed := 0
	var clay := Color.WHITE
	var crack := Color.BLACK
	## Bounding box of everything the waterhole affects (rim included).
	var bounds := Rect2()

	## Normalised distance of (x, z) to the centre (1 = edge of the basin).
	func distance(x: float, z: float) -> float:
		var dx := x - cx
		var dz := z - cz
		var dist := sqrt(dx * dx + dz * dz)
		if dist < 0.00001:
			return 0.0
		var a := atan2(dz, dx)
		var wobble := 1.0 + irregularity * (0.5 * sin(2.0 * a + phase1) + 0.3 * sin(3.0 * a + phase2) + 0.2 * sin(5.0 * a + phase3))
		return dist / (radius * wobble)

	## Carve depth at normalised distance d: positive digs, negative raises
	## (the lip of earth around the basin).
	func carve_at(d: float) -> float:
		if d < 1.0:
			return depth * (1.0 - smoothstep(floor_ratio, 1.0, d))
		if lip > 0.0 and d < 1.0 + rim:
			var t := (d - 1.0) / rim
			return -lip * sin(t * PI) * (1.0 - t)
		return 0.0

	func zone_at(d: float) -> int:
		if d < 1.0:
			return ZONE_BASIN
		if d < 1.0 + rim:
			return ZONE_RIM
		return ZONE_NONE

static func setting_key(field: String) -> String:
	return "_lte_waterhole_%s" % field

## Copy of a stored waterhole with every missing field filled in.
static func migrate(variant: Variant) -> Dictionary:
	var hole: Dictionary = {}
	if typeof(variant) == TYPE_DICTIONARY:
		var source: Dictionary = variant
		hole = source.duplicate(true)
	if not hole.has("center"): hole["center"] = Vector2.ZERO
	if not hole.has("radius"): hole["radius"] = 4.0
	if not hole.has("seed"):
		var center: Vector2 = hole["center"]
		hole["seed"] = make_seed(center)
	for field: String in DEFAULTS:
		if not hole.has(field):
			hole[field] = DEFAULTS[field]
	return hole

## Style (no centre / radius) from the terrain's waterhole settings.
static func from_terrain_settings(terrain: Node3D) -> Dictionary:
	var style := {}
	for field: String in DEFAULTS:
		style[field] = terrain.get_meta(setting_key(field), DEFAULTS[field])
	return style

static func make_seed(center: Vector2) -> int:
	return (int(roundf(center.x * 16.0)) * 73856093 ^ int(roundf(center.y * 16.0)) * 19349663) & 0x7FFFFFFF

static func list(terrain: Node3D) -> Array:
	return terrain.get_meta(Meta.WATERHOLES, [])

## Adds a waterhole with the current settings. Returns false when the radius
## is too small.
static func commit(terrain: Node3D, center: Vector2, radius: float) -> bool:
	var hole := make(terrain, center, radius)
	if hole.is_empty():
		return false
	var holes: Array = list(terrain).duplicate(true)
	holes.append(hole)
	terrain.set_meta(Meta.WATERHOLES, holes)
	return true

## A new waterhole with the current settings, not yet on the terrain (empty
## when the radius is too small). The generator adds many at once with it.
static func make(terrain: Node3D, center: Vector2, radius: float) -> Dictionary:
	if radius < MIN_RADIUS:
		return {}
	var hole := from_terrain_settings(terrain)
	# Rounded so a scene saved as text reloads to exactly the same shape.
	center = center.snappedf(0.001)
	hole["center"] = center
	hole["radius"] = snappedf(radius, 0.001)
	hole["seed"] = make_seed(center)
	return hole

## Gives every existing waterhole the current settings (keeps centre, radius
## and seed). Returns the number of waterholes changed.
static func apply_settings_to_all(terrain: Node3D) -> int:
	var holes: Array = list(terrain).duplicate(true)
	var style := from_terrain_settings(terrain)
	for i in range(holes.size()):
		var hole := migrate(holes[i])
		hole.merge(style, true)
		holes[i] = hole
	terrain.set_meta(Meta.WATERHOLES, holes)
	return holes.size()

## Shape of one stored waterhole; `biome` gives its colors (null = the
## built-in Temperate's, enough for bounds and carving).
static func make_shape(variant: Variant, biome: TerrainBiome = null) -> Shape:
	var hole := migrate(variant)
	var shape := Shape.new()
	var center: Vector2 = hole["center"]
	shape.cx = center.x
	shape.cz = center.y
	var radius: float = hole["radius"]
	var floor_ratio: float = hole["floor"]
	var rim: float = hole["rim"]
	var depth: float = hole["depth"]
	var lip: float = hole["lip"]
	var irregularity: float = hole["irregularity"]
	var hole_seed: int = hole["seed"]
	shape.radius = maxf(radius, MIN_RADIUS)
	shape.floor_ratio = clampf(floor_ratio, 0.0, 0.95)
	shape.rim = maxf(rim, 0.01)
	shape.depth = maxf(depth, 0.0)
	shape.lip = maxf(lip, 0.0)
	shape.irregularity = clampf(irregularity, 0.0, 0.6)
	shape.seed = hole_seed
	var h := shape.seed
	shape.phase1 = float(h & 0x3FF) / 1024.0 * TAU
	shape.phase2 = float((h >> 10) & 0x3FF) / 1024.0 * TAU
	shape.phase3 = float((h >> 20) & 0x3FF) / 1024.0 * TAU
	var colors: TerrainBiome = biome if biome != null else TerrainBiome.default_biome()
	shape.clay = colors.waterhole_clay_color
	shape.crack = colors.waterhole_crack_color
	var reach := shape.radius * (1.0 + shape.irregularity) * (1.0 + shape.rim)
	shape.bounds = Rect2(center - Vector2(reach, reach), Vector2(reach, reach) * 2.0)
	return shape

## Shapes of every waterhole, or only those whose bounds touch `rect`.
static func shapes(terrain: Node3D, rect: Variant = null) -> Array[Shape]:
	var result: Array[Shape] = []
	var biome: TerrainBiome = TerrainBiome.of(terrain)
	var rect_box := Rect2()
	if rect != null:
		rect_box = rect
	for hole: Variant in list(terrain):
		var shape := make_shape(hole, biome)
		if rect == null or shape.bounds.intersects(rect_box, true):
			result.append(shape)
	return result

## Index of the waterhole whose basin contains `point`, or -1.
static func find_at(terrain: Node3D, point: Vector2, margin: float = 0.0) -> int:
	var holes := list(terrain)
	for i in range(holes.size() - 1, -1, -1):
		var shape := make_shape(holes[i])
		if shape.distance(point.x, point.y) <= 1.0 + margin / shape.radius:
			return i
	return -1

## Bounds of the waterhole at `index` (rim included).
static func bounds_of(terrain: Node3D, index: int) -> Rect2:
	return make_shape(list(terrain)[index]).bounds
