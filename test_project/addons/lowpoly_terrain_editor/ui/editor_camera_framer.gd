@tool
extends RefCounted
## Frames the 3D editor camera on an area (after Generate Map).
##
## Godot has no script API for the editor camera (4.7). This class drives the
## 3D viewport the way the user would:
##   1. a temporary marker at the centre of the area is selected and
##      View > Focus Selection runs (it moves the orbit point, not the zoom);
##   2. mouse-wheel steps sent to the viewport set the zoom (each step scales
##      the orbit distance by ZOOM_STEP, like the wheel).
## The view angle is kept. The previous selection is restored in the same
## frame. When the editor layout differs (other Godot version) it does nothing.

## Godot's mouse-wheel zoom factor (Node3DEditorViewport, ZOOM_FREELOOK_MULTIPLIER).
const ZOOM_STEP := 1.08
const MAX_ZOOM_STEPS := 120
## Distance factor over the bounding-sphere fit (1.0: the whole sphere is in
## view; the near corners of a flat map are the first to leave the screen).
const FILL := 1.0
## Frames to wait at most for the camera to finish its move (inertia).
const MAX_SETTLE_FRAMES := 240

## World AABB of the terrain chunk meshes (empty AABB when nothing is built).
static func terrain_aabb(terrain: Node3D, chunks_name: String) -> AABB:
	var container := terrain.get_node_or_null(chunks_name)
	var bounds := AABB()
	var has_bounds := false
	if container == null:
		return bounds
	for child in container.get_children():
		var mesh_instance := child as MeshInstance3D
		if mesh_instance == null or mesh_instance.mesh == null:
			continue
		var box := mesh_instance.global_transform * mesh_instance.get_aabb()
		bounds = box if not has_bounds else bounds.merge(box)
		has_bounds = true
	return bounds

## True when the four top corners of `aabb` are on screen in the first 3D
## viewport (nothing to do then).
static func is_in_view(aabb: AABB) -> bool:
	var sub := EditorInterface.get_editor_viewport_3d(0)
	var camera := sub.get_camera_3d() if sub else null
	if camera == null:
		return true
	var rect := Rect2(Vector2.ZERO, Vector2(sub.size))
	var top := aabb.position.y + aabb.size.y
	for corner: Vector3 in [Vector3(aabb.position.x, top, aabb.position.z), Vector3(aabb.end.x, top, aabb.position.z),
			Vector3(aabb.position.x, top, aabb.end.z), Vector3(aabb.end.x, top, aabb.end.z)]:
		if camera.is_position_behind(corner) or not rect.has_point(camera.unproject_position(corner)):
			return false
	return true

## Frames `aabb` in the first 3D viewport. Coroutine (waits for the camera
## move); returns false when the viewport could not be driven.
static func frame(host: Node, aabb: AABB) -> bool:
	var sub := EditorInterface.get_editor_viewport_3d(0)
	if sub == null or sub.get_parent() == null:
		return false
	var viewport_control := sub.get_parent().get_parent() as Control
	var camera := sub.get_camera_3d()
	if viewport_control == null or camera == null or not viewport_control.is_visible_in_tree():
		return false
	var focus := _focus_menu_item(viewport_control)
	var surface := _input_surface(viewport_control)
	if focus.is_empty() or surface == null:
		return false

	var center := aabb.get_center()
	var selection := EditorInterface.get_selection()
	var previous: Array[Node] = selection.get_selected_nodes()
	var marker := Node3D.new()
	marker.name = "_LteFrameMarker"
	host.add_child(marker)
	marker.global_position = center
	selection.clear()
	selection.add_node(marker)
	var focus_popup: PopupMenu = focus[0]
	focus_popup.id_pressed.emit(focus[1])
	selection.clear()
	for node in previous:
		if is_instance_valid(node):
			selection.add_node(node)
	marker.queue_free()

	# The camera glides to the new orbit point; its distance to the point is
	# the orbit distance once it stops.
	if not await _settle(host, camera):
		return false
	var distance := camera.global_position.distance_to(center)
	var half_view := deg_to_rad(clampf(camera.fov, 1.0, 179.0)) * 0.5
	var target := maxf(aabb.size.length() * 0.5, 1.0) / sin(half_view) * FILL
	if distance < 0.001:
		return true
	var steps := clampi(roundi(log(target / distance) / log(ZOOM_STEP)), -MAX_ZOOM_STEPS, MAX_ZOOM_STEPS)
	for i in absi(steps):
		var wheel := InputEventMouseButton.new()
		wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN if steps > 0 else MOUSE_BUTTON_WHEEL_UP
		wheel.pressed = true
		wheel.factor = 1.0
		wheel.position = surface.size * 0.5
		surface.gui_input.emit(wheel)
	return true

static func _settle(host: Node, camera: Camera3D) -> bool:
	var last := camera.global_position
	var still := 0
	for i in MAX_SETTLE_FRAMES:
		await host.get_tree().process_frame
		if not is_instance_valid(camera):
			return false
		var moved := camera.global_position.distance_to(last)
		last = camera.global_position
		still = still + 1 if moved < 0.001 else 0
		if still >= 3 and i >= 3:
			return true
	return true

## [popup, id] of View > Focus Selection (found by its shortcut, so the editor
## language does not matter).
static func _focus_menu_item(viewport_control: Control) -> Array:
	var shortcut := EditorInterface.get_editor_settings().get_shortcut("spatial_editor/focus_selection")
	if shortcut == null:
		return []
	for menu in viewport_control.find_children("*", "MenuButton", true, false):
		var popup: PopupMenu = (menu as MenuButton).get_popup()
		for i in popup.item_count:
			if popup.get_item_shortcut(i) == shortcut:
				return [popup, popup.get_item_id(i)]
	return []

## The control that receives the viewport's mouse input.
static func _input_surface(viewport_control: Control) -> Control:
	for child in viewport_control.get_children():
		if child is Control and not (child is SubViewportContainer) and not (child as Control).gui_input.get_connections().is_empty():
			return child
	return null
