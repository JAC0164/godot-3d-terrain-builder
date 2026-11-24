@tool
extends EditorPlugin
## Screenshots of the plugin's editor UI for the documentation site
## (docs/editor/). Runs inside the real Godot editor of a scratch project
## (tools/editor_shots/run_editor_shots.sh): makes a savanna map with Generate
## Map, then saves the whole editor window and crops of the toolbar, the
## Inspector sections, the brush ring and the biome. The editor window is kept
## off screen; images come from the editor's own viewport, never the desktop.

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Framer = preload(ADDON + "ui/editor_camera_framer.gd")
const BrushOverlay = preload(ADDON + "ui/brush_overlay.gd")
const OUT := "res://shots/"
const SIZE := Vector2i(1920, 1080)

var _plugin: Object
var _toolbar: Control
## The brush ring, drawn by the plugin's own ui/brush_overlay.gd on a control
## over the 3D view (the plugin hides its ring while the mouse is outside the
## view, and the mouse of an off-screen window always is).
var _ring_overlay: Control
var _ring_at: Variant = null
var _ring_mode := 0

func _enter_tree() -> void:
	call_deferred("_run")

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _find(node: Node, node_name: String) -> Node:
	if node.name == node_name:
		return node
	for child in node.get_children():
		var found := _find(child, node_name)
		if found:
			return found
	return null

func _find_button(node: Node, text: String) -> Button:
	if node is Button and (node as Button).text == text:
		return node
	for child in node.get_children():
		var found := _find_button(child, text)
		if found:
			return found
	return null

# --- Capture ----------------------------------------------------------------------

func _image() -> Image:
	await _frames(12)
	await RenderingServer.frame_post_draw
	var image := get_window().get_texture().get_image()
	image.convert(Image.FORMAT_RGB8)
	return image

## Lossless for crops of the UI (sharp text), lossy for views of the map.
func _save(image: Image, file: String, lossy: bool = false) -> void:
	image.save_webp(OUT + file + ".webp", lossy, 0.88)
	print("SHOT ", file, " ", image.get_size())

func _shot(file: String) -> void:
	_save(await _image(), file, true)

## Crop of a control (window pixels), grown by `margin` on each side.
func _shot_of(file: String, control: Control, margin: Vector4i = Vector4i(6, 6, 6, 6)) -> void:
	var image := await _image()
	var rect := Rect2i(control.get_global_rect())
	rect = rect.grow_individual(margin.x, margin.y, margin.z, margin.w).intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	_save(image.get_region(rect), file)

func _shot_rect(file: String, rect: Rect2i) -> void:
	var image := await _image()
	_save(image.get_region(rect.intersection(Rect2i(Vector2i.ZERO, image.get_size()))), file, true)

# --- Editor state -----------------------------------------------------------------

func _inspector_dock() -> Control:
	# The Inspector with its dock header (node name, history buttons).
	var inspector := EditorInterface.get_inspector()
	var node: Node = inspector
	while node.get_parent() is Control and not (node.get_parent() is TabContainer):
		node = node.get_parent()
		if (node as Control).get_global_rect().size.y > inspector.get_global_rect().size.y + 120:
			break
	return inspector.get_parent() as Control if node == null else node as Control

## Opens one section of the terrain panel ("" = all closed).
func _open_section(title: String) -> void:
	var panel := _find(EditorInterface.get_inspector(), "LowPoly Terrain")
	if panel == null:
		push_warning("no terrain panel")
		return
	for child in panel.get_children():
		if child is Button and (child as Button).toggle_mode and (child as Button).flat:
			var button := child as Button
			button.button_pressed = button.text.substr(2) == title
	await _frames(6)

func _ring(mode: int, at: Vector2 = Vector2(0.5, 0.55)) -> void:
	var sub := EditorInterface.get_editor_viewport_3d(0)
	var camera := sub.get_camera_3d()
	_ring_at = _plugin._mouse_to_local_terrain(camera, Vector2(sub.size) * at)
	_ring_mode = mode
	if _ring_overlay == null:
		_ring_overlay = Control.new()
		_ring_overlay.name = "LteShotsRing"
		_ring_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
		(sub.get_parent().get_parent() as Control).add_child(_ring_overlay)
		_ring_overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		_ring_overlay.draw.connect(_draw_ring)
	_ring_overlay.queue_redraw()

func _no_ring() -> void:
	_ring_at = null
	if _ring_overlay:
		_ring_overlay.queue_redraw()

func _draw_ring() -> void:
	if _ring_at == null or not is_instance_valid(_plugin._active_terrain):
		return
	var strokes: Object = _plugin._strokes
	BrushOverlay.draw(_ring_overlay, EditorInterface.get_editor_viewport_3d(0).get_camera_3d(), _plugin._active_terrain, _ring_mode, _ring_at, {
		"radius": strokes.brush_radius,
		"strength": strokes.brush_strength,
		"stroke_active": false,
		"carve": _plugin._builder.get_river_carve(_plugin._active_terrain),
		"over_feature": false,
		"vegetation_target": strokes.vegetation_target,
	})

## Unticks a checked item of the 3D editor menus ("View Gizmos", "View Origin").
func _untick(text: String) -> void:
	for menu in EditorInterface.get_editor_main_screen().find_children("*", "MenuButton", true, false):
		var popup := (menu as MenuButton).get_popup()
		for i in popup.item_count:
			if popup.get_item_text(i) == text and popup.is_item_checked(i):
				popup.id_pressed.emit(popup.get_item_id(i))
				return

func _frame_around(terrain: Node3D, half: float) -> void:
	var c := terrain.global_position
	await Framer.frame(EditorInterface.get_edited_scene_root(), AABB(c - Vector3(half, 0, half), Vector3(half * 2.0, 8, half * 2.0)))
	await _frames(200)  # the zoom indicator fades out

func _viewport_rect() -> Rect2i:
	var sub := EditorInterface.get_editor_viewport_3d(0)
	var container := sub.get_parent() as Control
	return Rect2i(container.get_global_rect())

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(OUT))
	OS.low_processor_usage_mode = false
	get_window().mode = Window.MODE_WINDOWED
	get_window().size = SIZE
	get_window().position = Vector2i(-3000, -3000)
	# No move / rotate handles over the shots.
	EditorInterface.get_editor_settings().set_setting("editors/3d/manipulator_gizmo_opacity", 0.0)
	await _frames(10)

	# A level with the test project's savanna light.
	var root := Node3D.new()
	root.name = "Level"
	var sky := (load("res://world/savanna_sky.tscn") as PackedScene).instantiate()
	root.add_child(sky)
	sky.owner = root
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, "res://level.tscn")
	root.free()
	EditorInterface.open_scene_from_path("res://level.tscn")
	await _frames(10)
	EditorInterface.set_main_screen_editor("3D")
	await _frames(10)
	# No sun icon or world axes over the map.
	_untick("View Gizmos")
	_untick("View Origin")
	_untick("View Transform Gizmo")
	_toolbar = _find(EditorInterface.get_base_control(), "LowpolyTerrainToolbar")
	if _toolbar == null:
		push_error("SHOTS: no toolbar")
		_quit()
		return
	_plugin = _toolbar.new_terrain_pressed.get_connections()[0]["callable"].get_object()

	# 1. No terrain yet: the toolbar shows New Terrain.
	var scene_root := EditorInterface.get_edited_scene_root()
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(scene_root)
	await _frames(6)
	await _shot_of("toolbar_new", _toolbar)

	# 2. New terrain: empty, Ground active, the 3D view says what to do.
	_toolbar.new_terrain_pressed.emit()
	await _frames(10)
	var terrain: Node3D = _plugin._active_terrain
	_ring(1, Vector2(0.5, 0.62))
	await _shot("editor_new_terrain")
	_no_ring()

	# 3. Generate Map (the Senegal Savanna preset, seed 7).
	terrain.set_meta("_lte_map_recipe", load(ADDON + "generation/presets/senegal_savanna_map.tres"))
	terrain.set_meta("_lte_map_seed", 7)
	EditorInterface.inspect_object(terrain)
	await _frames(6)
	await _open_section("Map")
	await _shot_of("inspector_map", _inspector_dock())
	var generate := _find_button(EditorInterface.get_inspector(), "Generate Map")
	generate.pressed.emit()
	await _frames(3)
	for i in 900:
		if _plugin._generating == null:
			break
		await get_tree().process_frame
	await _frames(240)

	# 4. The whole editor: the map, Ground tool and its ring, the Map section.
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(terrain)
	await _frames(6)
	EditorInterface.inspect_object(terrain)
	_plugin._set_tool(1)
	await _frames(6)
	await _open_section("Map")
	await _frame_around(terrain, 62.0)
	_toolbar._brush_radius_spin.value = 8.0
	_ring(1, Vector2(0.4, 0.62))
	await _shot("editor")
	await _shot_of("toolbar_ground", _toolbar)

	# 5. Inspector sections.
	await _open_section("")
	await _shot_of("inspector_sections", _inspector_dock())
	for section: String in ["Look", "Roads, Rivers & Waterholes", "Game", "Advanced"]:
		await _open_section(section)
		await _shot_of("inspector_" + section.get_slice(",", 0).to_lower(), _inspector_dock())
	await _open_section("Map")

	# 6. Closer view (on a track): the tools and their rings.
	var roads: Array = terrain.get_meta("_lte_roads", [])
	var focus := terrain.global_position
	if not roads.is_empty():
		var points: Array = (roads[0] as Dictionary)["points"]
		var mid: Variant = points[points.size() / 2]
		var local := Vector3(mid.x, 0, mid.z) if mid is Vector3 else Vector3(mid.x, 0, mid.y)
		focus = terrain.to_global(local)
	await Framer.frame(scene_root, AABB(focus - Vector3(22, 0, 22), Vector3(44, 6, 44)))
	await _frames(200)
	_toolbar._brush_radius_spin.value = 4.0
	for tool: Array in [[3, "relief"], [10, "vegetation"], [8, "river"]]:
		_plugin._set_tool(tool[0])
		await _frames(4)
		_ring(tool[0], Vector2(0.42, 0.6))
		await _shot_rect("viewport_" + tool[1], _viewport_rect())
		await _shot_of("toolbar_" + tool[1], _toolbar)

	# 7. The biome in the Inspector (Look > Edit Biome).
	_no_ring()
	_plugin._set_tool(0)
	var biome: Resource = terrain.get_meta("_lte_biome")
	EditorInterface.inspect_object(biome)
	await _frames(10)
	await _shot_of("inspector_biome", _inspector_dock())
	_quit()

func _quit() -> void:
	print("SHOTS DONE")
	await _frames(5)
	get_tree().quit()
