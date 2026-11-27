extends Node
## Game-side example (not in the plugin): keeps the navigation mesh of a big
## map baked around a moving node, on a worker thread. Put it anywhere in the
## scene and set `runtime` and `target`. The first bake starts once the
## ground is built (terrain_ready); the next one when the target is
## `rebake_distance` metres from the last centre, or after the ground was
## edited in game (terrain_changed). The terrain's "Navigation" child is
## made on the first bake when the scene has none.

## The terrain's runtime node (its _LowpolyTerrainRuntime child).
@export var runtime: LowpolyTerrainRuntime
## What the navigation follows (the player).
@export var target: Node3D
## Half the side of the square baked around the target, metres.
@export var radius := 80.0
## How far the target moves before the next bake, metres.
@export var rebake_distance := 40.0

## Emitted when a bake is in place (centre = global position it was made for).
signal baked(centre: Vector3)

var _centre := Vector3.INF
var _dirty := true

func _ready() -> void:
	if runtime != null:
		runtime.terrain_changed.connect(func(_rect: Rect2) -> void: _dirty = true)

func _process(_delta: float) -> void:
	if runtime == null or target == null or not runtime.is_ground_ready:
		return
	var at := target.global_position
	if not _dirty and Vector2(at.x - _centre.x, at.z - _centre.z).length() < rebake_distance:
		return
	var terrain := runtime.terrain if runtime.terrain != null else runtime.get_parent() as Node3D
	var local := terrain.to_local(at)
	var size := radius / maxf(terrain.global_transform.basis.get_scale().x, 0.0001)
	# Terrain-local bounds, only X / Z are used.
	var bounds := AABB(Vector3(local.x - size, 0.0, local.z - size), Vector3(size * 2.0, 0.0, size * 2.0))
	if runtime.bake_navigation(null, bounds, func() -> void: baked.emit(at)):
		_centre = at
		_dirty = false
