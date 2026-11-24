@tool
extends RefCounted
## Height queries on the terrain grid.
##
## - "base"/"uncarved" height: the sculpted heights only.
## - "effective" height: sculpted height minus the river carve. `carve` is the
##   per-vertex carve depth array computed by RiverMesher.compute_carve().

const Meta = preload("terrain_meta.gd")
const GridMath = preload("grid_math.gd")

## Nearest-vertex sculpted height.
static func base_height(terrain: Node3D, point: Vector2) -> float:
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var grid := GridMath.local_to_grid(point, resolution, world_size)

	var x := clampi(int(roundf(grid.x)), 0, resolution - 1)
	var z := clampi(int(roundf(grid.y)), 0, resolution - 1)
	return heights[GridMath.grid_index(x, z, resolution)]

## Bilinear sculpted height, ignoring river carving.
static func uncarved_height(terrain: Node3D, point: Vector2) -> float:
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	return uncarved_height_in(heights, resolution, world_size, point)

## uncarved_height() on already-fetched data, for hot loops (same result).
static func uncarved_height_in(heights: PackedFloat32Array, resolution: int, world_size: float, point: Vector2) -> float:
	var grid := GridMath.local_to_grid(point, resolution, world_size)
	var x0: int = clampi(int(floorf(grid.x)), 0, resolution - 1)
	var z0: int = clampi(int(floorf(grid.y)), 0, resolution - 1)
	var x1: int = mini(x0 + 1, resolution - 1)
	var z1: int = mini(z0 + 1, resolution - 1)
	var tx: float = clampf(grid.x - floorf(grid.x), 0.0, 1.0)
	var tz: float = clampf(grid.y - floorf(grid.y), 0.0, 1.0)
	var h00: float = heights[GridMath.grid_index(x0, z0, resolution)]
	var h10: float = heights[GridMath.grid_index(x1, z0, resolution)]
	var h01: float = heights[GridMath.grid_index(x0, z1, resolution)]
	var h11: float = heights[GridMath.grid_index(x1, z1, resolution)]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

## Height of grid vertex (x, z) minus the river carving there.
static func effective_height_at_grid_in(heights: PackedFloat32Array, carve: PackedFloat32Array, resolution: int, x: int, z: int) -> float:
	var index := GridMath.grid_index(x, z, resolution)
	var base: float = heights[index]
	if index >= 0 and index < carve.size():
		return base - carve[index]
	return base

## Height of the drawn ground (with river carving): on the terrain's own
## triangles, each cell split along its (0,0)-(1,1) diagonal as TerrainMesher
## draws it. effective_height_in() is bilinear, which leaves the triangles
## inside a cell (up to a few cm on a slope).
static func surface_height_in(heights: PackedFloat32Array, carve: PackedFloat32Array, resolution: int, world_size: float, point: Vector2) -> float:
	var grid := GridMath.local_to_grid(point, resolution, world_size)
	var x0 := clampi(int(floorf(grid.x)), 0, maxi(resolution - 2, 0))
	var z0 := clampi(int(floorf(grid.y)), 0, maxi(resolution - 2, 0))
	var x1 := mini(x0 + 1, resolution - 1)
	var z1 := mini(z0 + 1, resolution - 1)
	var tx := clampf(grid.x - float(x0), 0.0, 1.0)
	var tz := clampf(grid.y - float(z0), 0.0, 1.0)
	var h00 := effective_height_at_grid_in(heights, carve, resolution, x0, z0)
	var h11 := effective_height_at_grid_in(heights, carve, resolution, x1, z1)
	if tx >= tz:
		var h10 := effective_height_at_grid_in(heights, carve, resolution, x1, z0)
		return h00 + tx * (h10 - h00) + tz * (h11 - h10)
	var h01 := effective_height_at_grid_in(heights, carve, resolution, x0, z1)
	return h00 + tz * (h01 - h00) + tx * (h11 - h01)

## Bilinear height including river carving.
static func effective_height(terrain: Node3D, carve: PackedFloat32Array, point: Vector2) -> float:
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var resolution: int = terrain.get_meta(Meta.RESOLUTION)
	var world_size: float = terrain.get_meta(Meta.WORLD_SIZE)
	return effective_height_in(heights, carve, resolution, world_size, point)

## effective_height() on already-fetched data, for hot loops (same result).
static func effective_height_in(heights: PackedFloat32Array, carve: PackedFloat32Array, resolution: int, world_size: float, point: Vector2) -> float:
	var grid := GridMath.local_to_grid(point, resolution, world_size)

	var x0 := clampi(int(floorf(grid.x)), 0, resolution - 1)
	var z0 := clampi(int(floorf(grid.y)), 0, resolution - 1)
	var x1 := mini(x0 + 1, resolution - 1)
	var z1 := mini(z0 + 1, resolution - 1)

	var tx: float = grid.x - floorf(grid.x)
	var tz: float = grid.y - floorf(grid.y)

	var h00 := effective_height_at_grid_in(heights, carve, resolution, x0, z0)
	var h10 := effective_height_at_grid_in(heights, carve, resolution, x1, z0)
	var h01 := effective_height_at_grid_in(heights, carve, resolution, x0, z1)
	var h11 := effective_height_at_grid_in(heights, carve, resolution, x1, z1)

	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

