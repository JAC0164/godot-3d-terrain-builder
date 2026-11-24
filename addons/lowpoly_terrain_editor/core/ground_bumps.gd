@tool
extends RefCounted
## Small bumps in the ground (Inspector > Look > Ground Bumps), so faceted
## ground catches the light instead of looking like a flat sheet.
##
## They are written in the heights (data): collision, details, roads, rivers
## and waterholes follow by themselves, and the Relief tools work on top.
## The bump shape is a fixed noise of the local position, so it never changes:
## changing the amount adds (new - old) x shape, and 0 gives the ground back
## as it was. New cells of a growing terrain get the same bumps.

const Meta = preload("terrain_meta.gd")

## About 8 m between bumps, with smaller ones on top.
const FREQUENCY := 0.12
const OCTAVES := 3
const SEED := 3

static func _noise() -> FastNoiseLite:
	var noise := FastNoiseLite.new()
	noise.seed = SEED
	noise.frequency = FREQUENCY
	noise.fractal_octaves = OCTAVES
	return noise

static func amount(terrain: Node3D) -> float:
	return Meta.get_float(terrain, Meta.GROUND_BUMPS, Meta.DEFAULT_GROUND_BUMPS)

## Adds `amount` x bump shape to every vertex of `heights` (a resolution x
## resolution grid of `world_size`), except those inside `keep` (grid
## coordinates, e.g. the old part of a grown canvas), then clamps.
static func add(heights: PackedFloat32Array, resolution: int, world_size: float, amount: float,
		min_height: float, max_height: float, keep := Rect2i()) -> void:
	if is_zero_approx(amount) or resolution < 2:
		return
	var noise := _noise()
	var spacing := world_size / float(resolution - 1)
	var half := world_size * 0.5
	var skip := keep.has_area()
	for z in resolution:
		for x in resolution:
			if skip and keep.has_point(Vector2i(x, z)):
				continue
			var i := z * resolution + x
			var bump := noise.get_noise_2d(float(x) * spacing - half, float(z) * spacing - half)
			heights[i] = clampf(heights[i] + amount * bump, min_height, max_height)

## Adds `amount` x bump shape to the terrain's heights (all vertices).
static func add_to_terrain(terrain: Node3D, amount: float) -> void:
	if is_zero_approx(amount):
		return
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	add(heights, resolution, world_size, amount,
		Meta.get_float(terrain, Meta.HEIGHT_MIN, Meta.DEFAULT_HEIGHT_MIN), Meta.get_float(terrain, Meta.HEIGHT_MAX, Meta.DEFAULT_HEIGHT_MAX))
	terrain.set_meta(Meta.HEIGHTS, heights)

## New bump amount: the ground keeps its relief, only the bumps change.
static func set_amount(terrain: Node3D, value: float) -> void:
	value = maxf(value, 0.0)
	add_to_terrain(terrain, value - amount(terrain))
	terrain.set_meta(Meta.GROUND_BUMPS, value)
