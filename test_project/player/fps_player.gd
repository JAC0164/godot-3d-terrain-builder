class_name FpsPlayer
extends CharacterBody3D
## Simple first-person explorer: a capsule body with a camera at eye height.
##
## Mouse: look (click in the window to capture it, Esc to release it).
## W A S D / Z Q S D / arrows: walk (physical keys, so QWERTY and AZERTY both
## work). Shift: run. Space: jump. V: fly on / off (Space up, C or Ctrl down).
## Phone: player/touch_controls.gd fills the touch_* fields below and calls
## look(); the mouse is then left alone.

@export var walk_speed := 5.0
@export var run_speed := 10.0
@export var jump_velocity := 5.5
@export var gravity := 18.0
@export var fly_speed := 18.0
@export var acceleration := 12.0
@export_range(0.0005, 0.01, 0.0005) var mouse_sensitivity := 0.0025
## On the first physics frame, drop straight onto the ground below (or above)
## the spot where the player was placed, so it can be put anywhere in the editor.
@export var snap_to_ground := true
## Below this height the player falls back to its start spot.
@export var fall_limit := -60.0

@onready var head: Node3D = $Head
@onready var camera: Camera3D = $Head/Camera3D

var flying := false
## Touch input (player/touch_controls.gd): stick (x right, y back, length
## <= 1), held buttons, run toggle. touch_mode = the mouse is not captured.
var touch_mode := false
var touch_move := Vector2.ZERO
var touch_up := false
var touch_down := false
var touch_run := false
var _pitch := 0.0
var _start := Vector3.ZERO
var _snapped := false

func _ready() -> void:
	_start = global_position
	if OS.has_feature("mobile"):
		touch_mode = true
	if not touch_mode:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED

## Turns the view: `relative` in pixels, `sensitivity` in radians per pixel.
func look(relative: Vector2, sensitivity: float) -> void:
	rotate_y(-relative.x * sensitivity)
	_pitch = clampf(_pitch - relative.y * sensitivity, -1.5, 1.5)
	head.rotation.x = _pitch

func toggle_fly() -> void:
	flying = not flying
	velocity = Vector3.ZERO

func _unhandled_input(event: InputEvent) -> void:
	if touch_mode and (event is InputEventMouseMotion or event is InputEventMouseButton):
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		look(event.relative, mouse_sensitivity)
	elif event is InputEventMouseButton and event.pressed and Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		elif event.physical_keycode == KEY_V:
			toggle_fly()

## Puts the player at `point` (feet), standing still.
func teleport(point: Vector3) -> void:
	global_position = point
	velocity = Vector3.ZERO

## Ground under `point` (ray from high above), or `point` itself if none.
func ground_below(point: Vector3) -> Vector3:
	var query := PhysicsRayQueryParameters3D.create(point + Vector3.UP * 500.0, point + Vector3.DOWN * 500.0)
	query.exclude = [get_rid()]
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	return hit["position"] if not hit.is_empty() else point

func _physics_process(delta: float) -> void:
	if snap_to_ground and not _snapped:
		# The physics space is ready from the first physics frame on.
		_snapped = true
		teleport(ground_below(global_position) + Vector3.UP * 0.1)
		_start = global_position
	if global_position.y < fall_limit:
		teleport(ground_below(_start) + Vector3.UP * 0.1)
	var input := Vector2.ZERO
	if _key(KEY_W) or _key(KEY_UP):
		input.y -= 1.0
	if _key(KEY_S) or _key(KEY_DOWN):
		input.y += 1.0
	if _key(KEY_A) or _key(KEY_LEFT):
		input.x -= 1.0
	if _key(KEY_D) or _key(KEY_RIGHT):
		input.x += 1.0
	input = (input + touch_move).limit_length()
	var running := _key(KEY_SHIFT) or touch_run
	var blend := minf(acceleration * delta, 1.0)

	if flying:
		# Fly where the camera looks.
		var direction := camera.global_basis * Vector3(input.x, 0.0, input.y)
		if _key(KEY_SPACE) or touch_up:
			direction += Vector3.UP
		if _key(KEY_C) or _key(KEY_CTRL) or touch_down:
			direction += Vector3.DOWN
		var fly_velocity := direction.limit_length() * fly_speed * (2.5 if running else 1.0)
		velocity = velocity.lerp(fly_velocity, blend)
		move_and_slide()
		return

	# The body only turns around Y: its basis gives the walking direction.
	var walk_velocity := global_basis * Vector3(input.x, 0.0, input.y) * (run_speed if running else walk_speed)
	if not is_on_floor():
		blend *= 0.3
	velocity.x = lerpf(velocity.x, walk_velocity.x, blend)
	velocity.z = lerpf(velocity.z, walk_velocity.z, blend)
	if is_on_floor():
		if _key(KEY_SPACE) or touch_up:
			velocity.y = jump_velocity
	else:
		velocity.y -= gravity * delta
	move_and_slide()

func _key(key: Key) -> bool:
	return Input.is_physical_key_pressed(key)
