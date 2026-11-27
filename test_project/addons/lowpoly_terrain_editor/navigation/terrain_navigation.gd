@tool
extends RefCounted
## Navigation mesh of a Lowpoly terrain, without settings: the terrain hands
## its own walkable geometry to the NavigationServer3D instead of letting a
## NavigationRegion3D parse its nodes (that would also read the grass, the
## water and the shadow casters):
##   - the top faces of the ground cells, as drawn (carved river beds and
##     waterholes included), not the cliff walls nor the empty cells;
##   - river beds left out (water);
##   - the trunks of the detail layers with collision (collision_radius) as
##     obstacles, read from the built detail MultiMeshes.
## Used by the Inspector's Game > Bake Navigation and by
## LowpolyTerrainRuntime.bake_navigation() in game (rebake around the player).

const Meta = preload("../core/terrain_meta.gd")
const NodeNames = preload("../core/node_names.gd")
const RiverMesher = preload("../mesh/river_mesher.gd")
const DetailCollision = preload("../mesh/detail_collision.gd")

## NavigationRegion3D added under the terrain by Bake Navigation.
const REGION_NAME := "Navigation"
## A cell whose corner is dug deeper than this by a river is water.
const RIVER_DEPTH := 0.2
## Sides of the polygon around a trunk.
const TRUNK_SIDES := 8

## The walkable geometry of `terrain`, in the space of `region_transform`
## (global transform of the NavigationRegion3D it is for). `carve`: the
## river + waterhole carve (TerrainBuilder.get_river_carve). `bounds`
## (terrain-local, X / Z used): only the cells inside, empty = every cell.
static func source_geometry(terrain: Node3D, carve: PackedFloat32Array, region_transform: Transform3D, bounds: AABB = AABB()) -> NavigationMeshSourceGeometryData3D:
	var data := NavigationMeshSourceGeometryData3D.new()
	var to_region := region_transform.affine_inverse() * (terrain.global_transform if terrain.is_inside_tree() else terrain.transform)
	data.add_faces(walkable_faces(terrain, carve, bounds), to_region)
	_add_trunks(terrain, data, to_region, bounds)
	return data

## Top faces (terrain-local) of the ground cells, river beds left out.
static func walkable_faces(terrain: Node3D, carve: PackedFloat32Array, bounds: AABB = AABB()) -> PackedVector3Array:
	var resolution := Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size := Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS, PackedFloat32Array())
	var active: PackedByteArray = terrain.get_meta(Meta.CELL_ACTIVE, PackedByteArray())
	var faces := PackedVector3Array()
	if resolution < 2 or heights.size() != resolution * resolution:
		return faces
	var river := RiverMesher.compute_carve(terrain)
	var has_river := river.size() == heights.size()
	var carved := carve.size() == heights.size()
	var top_offset := Meta.get_float(terrain, Meta.TOP_Y_OFFSET, 0.0)
	var spacing := world_size / float(resolution - 1)
	var half := world_size * 0.5
	var cells := resolution - 1
	var x_from := 0
	var x_to := cells
	var z_from := 0
	var z_to := cells
	if bounds.has_volume() or bounds.size.x > 0.0:
		x_from = clampi(int(floorf((bounds.position.x + half) / spacing)), 0, cells)
		x_to = clampi(int(ceilf((bounds.end.x + half) / spacing)), 0, cells)
		z_from = clampi(int(floorf((bounds.position.z + half) / spacing)), 0, cells)
		z_to = clampi(int(ceilf((bounds.end.z + half) / spacing)), 0, cells)
	for z in range(z_from, z_to):
		for x in range(x_from, x_to):
			var cell := z * cells + x
			if not active.is_empty() and (cell >= active.size() or active[cell] == 0):
				continue
			var i00 := z * resolution + x
			var i10 := i00 + 1
			var i01 := i00 + resolution
			var i11 := i01 + 1
			if has_river and maxf(maxf(river[i00], river[i10]), maxf(river[i01], river[i11])) > RIVER_DEPTH:
				continue
			var x0 := float(x) * spacing - half
			var z0 := float(z) * spacing - half
			var p00 := Vector3(x0, heights[i00] + top_offset - (carve[i00] if carved else 0.0), z0)
			var p10 := Vector3(x0 + spacing, heights[i10] + top_offset - (carve[i10] if carved else 0.0), z0)
			var p01 := Vector3(x0, heights[i01] + top_offset - (carve[i01] if carved else 0.0), z0 + spacing)
			var p11 := Vector3(x0 + spacing, heights[i11] + top_offset - (carve[i11] if carved else 0.0), z0 + spacing)
			# Split along (0,0)-(1,1) like the mesh, in the winding the
			# NavigationServer3D takes as facing up.
			faces.append(p00)
			faces.append(p10)
			faces.append(p11)
			faces.append(p00)
			faces.append(p11)
			faces.append(p01)
	return faces

## Trunks of the layers with collision: an obstacle each.
static func _add_trunks(terrain: Node3D, data: NavigationMeshSourceGeometryData3D, to_region: Transform3D, bounds: AABB) -> void:
	var container := terrain.get_node_or_null(Meta.GENERATED_CHUNKS_NAME)
	if container == null or not DetailCollision.has_collision_layers(terrain):
		return
	var use_bounds := bounds.has_volume() or bounds.size.x > 0.0
	for chunk_node in container.get_children():
		var chunk := chunk_node as Node3D
		if chunk == null:
			continue
		var job := DetailCollision.begin_chunk(terrain, chunk)
		var sources: Array = job["sources"]
		DetailCollision.cancel_chunk(job)
		var chunk_to_terrain := terrain.global_transform.affine_inverse() * chunk.global_transform if chunk.is_inside_tree() and terrain.is_inside_tree() else chunk.transform
		for source: Array in sources:
			var buffer: PackedFloat32Array = source[0]
			var stride: int = source[1]
			var count: int = source[2]
			var base: Transform3D = source[3]
			var radius_unit: float = source[4]
			var height_unit: float = source[5]
			for i in count:
				var o := i * stride
				var sx := Vector3(buffer[o], buffer[o + 4], buffer[o + 8]).length()
				var sy := Vector3(buffer[o + 1], buffer[o + 5], buffer[o + 9]).length()
				var local := chunk_to_terrain * (base * Vector3(buffer[o + 3], buffer[o + 7], buffer[o + 11]))
				if use_bounds and (local.x < bounds.position.x or local.x > bounds.end.x or local.z < bounds.position.z or local.z > bounds.end.z):
					continue
				var radius := radius_unit * sx
				var outline := PackedVector3Array()
				for side in TRUNK_SIDES:
					var angle := TAU * float(side) / float(TRUNK_SIDES)
					outline.append(to_region * (local + Vector3(cos(angle) * radius, 0.0, sin(angle) * radius)))
				var foot := to_region * local
				data.add_projected_obstruction(outline, foot.y - 0.5, height_unit * sy + 0.5, false)

## The terrain's NavigationRegion3D (REGION_NAME child), made when missing
## with a NavigationMesh at Godot's defaults. `owner`: scene owner of a new
## one (the edited scene in the editor), null in game.
static func ensure_region(terrain: Node3D, owner: Node = null) -> NavigationRegion3D:
	var region := terrain.get_node_or_null(REGION_NAME) as NavigationRegion3D
	if region == null:
		region = NavigationRegion3D.new()
		region.name = REGION_NAME
		NodeNames.add(terrain, region)
		if owner != null:
			region.owner = owner
	if region.navigation_mesh == null:
		region.navigation_mesh = NavigationMesh.new()
	return region

## Bakes `region`'s navigation mesh from the terrain (see source_geometry).
## `threaded`: on a worker thread, `on_done` (no argument) called on the main
## thread when the new mesh is in the region. Returns false when a bake of
## this mesh is still running.
static func bake(terrain: Node3D, region: NavigationRegion3D, carve: PackedFloat32Array, bounds: AABB = AABB(), threaded: bool = true, on_done: Callable = Callable()) -> bool:
	if region.navigation_mesh == null:
		region.navigation_mesh = NavigationMesh.new()
	var navigation_mesh := region.navigation_mesh
	if NavigationServer3D.is_baking_navigation_mesh(navigation_mesh):
		return false
	var data := source_geometry(terrain, carve, region.global_transform if region.is_inside_tree() else region.transform, bounds)
	var finish := func() -> void:
		if is_instance_valid(region):
			# Reassigned: the region sends the new polygons to the map.
			region.navigation_mesh = navigation_mesh
			navigation_mesh.emit_changed()
		if on_done.is_valid():
			on_done.call()
	if threaded:
		NavigationServer3D.bake_from_source_geometry_data_async(navigation_mesh, data, finish)
	else:
		NavigationServer3D.bake_from_source_geometry_data(navigation_mesh, data)
		finish.call()
	return true
