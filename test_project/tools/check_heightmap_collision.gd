extends SceneTree
## Audit: can a HeightMapShape3D (Jolt height field) replace a chunk's
## trimesh? Same random 33 x 33 heights, trimesh cut along the terrain's
## 00-11 diagonal (TerrainMesher), rays straight down on random points:
## largest height difference between the two shapes, and the same with the
## other diagonal (to see which one the height field uses).
##   Godot --headless --path . --script res://tools/check_heightmap_collision.gd

const N := 33
const SPACING := 1.5

func _initialize() -> void:
	_run.call_deferred()

func _run() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var heights := PackedFloat32Array()
	heights.resize(N * N)
	for i in heights.size():
		heights[i] = rng.randf_range(-2.0, 2.0)
	var half := (N - 1) * SPACING * 0.5
	var world := root.get_world_3d()
	var trimesh_a := _trimesh(heights, half, true)
	var trimesh_b := _trimesh(heights, half, false)
	var bodies: Array[StaticBody3D] = []
	for i in 4:
		var body := StaticBody3D.new()
		body.name = "Body%d" % i
		body.position = Vector3(i * 200.0, 0, 0)
		var node := CollisionShape3D.new()
		node.name = "Shape"
		if i == 0:
			node.shape = trimesh_a
		elif i == 1:
			node.shape = trimesh_b
		elif i == 2:
			var hm := HeightMapShape3D.new()
			hm.map_width = N
			hm.map_depth = N
			hm.map_data = heights
			node.shape = hm
			node.scale = Vector3(SPACING, 1.0, SPACING)
		else:
			# Turned 90 degrees about Y: its 10-01 diagonal becomes the
			# terrain's 00-11. local (i, j) = world cell (j, N - 1 - i).
			var rotated := PackedFloat32Array()
			rotated.resize(N * N)
			for j in N:
				for li in N:
					rotated[j * N + li] = heights[(N - 1 - li) * N + j]
			var hm := HeightMapShape3D.new()
			hm.map_width = N
			hm.map_depth = N
			hm.map_data = rotated
			node.shape = hm
			node.transform = Transform3D(Basis(Vector3.UP, PI / 2.0).scaled(Vector3(SPACING, 1.0, SPACING)), Vector3.ZERO)
		body.add_child(node)
		root.add_child(body)
		bodies.append(body)
	await physics_frame
	await physics_frame
	var space := world.direct_space_state
	var worst := [0.0, 0.0, 0.0]
	for k in 2000:
		var x := rng.randf_range(-half + 0.01, half - 0.01)
		var z := rng.randf_range(-half + 0.01, half - 0.01)
		var h: Array[float] = []
		for i in 4:
			var from := Vector3(x + i * 200.0, 50, z)
			var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 100))
			h.append((hit["position"] as Vector3).y if not hit.is_empty() else NAN)
		worst[0] = maxf(worst[0], absf(h[2] - h[0]))
		worst[1] = maxf(worst[1], absf(h[2] - h[1]))
		worst[2] = maxf(worst[2], absf(h[3] - h[0]))
	print("HEIGHTMAP vs trimesh diagonale 00-11: écart max %.3f m | vs diagonale 10-01: %.3f m | tournée 90 deg vs 00-11: %.4f m" % worst)
	quit(0)

func _trimesh(heights: PackedFloat32Array, half: float, diagonal_00_11: bool) -> ConcavePolygonShape3D:
	var faces := PackedVector3Array()
	for z in N - 1:
		for x in N - 1:
			var p00 := Vector3(x * SPACING - half, heights[z * N + x], z * SPACING - half)
			var p10 := Vector3((x + 1) * SPACING - half, heights[z * N + x + 1], z * SPACING - half)
			var p01 := Vector3(x * SPACING - half, heights[(z + 1) * N + x], (z + 1) * SPACING - half)
			var p11 := Vector3((x + 1) * SPACING - half, heights[(z + 1) * N + x + 1], (z + 1) * SPACING - half)
			if diagonal_00_11:
				faces.append_array([p00, p10, p11, p00, p11, p01])
			else:
				faces.append_array([p00, p10, p01, p10, p11, p01])
	var shape := ConcavePolygonShape3D.new()
	shape.backface_collision = true
	shape.set_faces(faces)
	return shape
