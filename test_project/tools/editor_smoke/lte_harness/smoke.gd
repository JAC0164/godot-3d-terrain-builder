@tool
extends EditorPlugin

var _log: Array[String] = []

const DetailScatterRef = preload("res://addons/lowpoly_terrain_editor/mesh/detail_scatter.gd")
const TerrainMesherRef = preload("res://addons/lowpoly_terrain_editor/mesh/terrain_mesher.gd")
const TerrainBiomeScript = preload("res://addons/lowpoly_terrain_editor/biomes/terrain_biome.gd")

func _enter_tree() -> void:
	call_deferred("_run")

func check(label: String, ok: bool) -> void:
	_log.append(("PASS " if ok else "FAIL ") + label)

func _frames(n: int) -> void:
	for i in range(n):
		await get_tree().process_frame

func _peak(heights: PackedFloat32Array) -> float:
	var peak := -INF
	for h in heights:
		peak = maxf(peak, h)
	return peak

func _find(node: Node, node_name: String) -> Node:
	if node.name == node_name:
		return node
	for child in node.get_children():
		var found := _find(child, node_name)
		if found:
			return found
	return null

func _find_button(node: Node, text: String) -> Button:
	if node is Button and node.text == text:
		return node
	for child in node.get_children():
		var found := _find_button(child, text)
		if found:
			return found
	return null

## Hash of every generated chunk mesh, detail MultiMesh and the feature mesh.
func _mesh_hash(terrain: Node3D) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var nodes := terrain.find_children("*", "GeometryInstance3D", true, false)
	nodes.sort_custom(func(a, b): return String(terrain.get_path_to(a)) < String(terrain.get_path_to(b)))
	for node in nodes:
		ctx.update(String(terrain.get_path_to(node)).to_utf8_buffer())
		if node is MeshInstance3D and node.mesh != null:
			for si in node.mesh.get_surface_count():
				var arrays: Array = node.mesh.surface_get_arrays(si)
				ctx.update(var_to_bytes(arrays[Mesh.ARRAY_VERTEX]))
				if arrays[Mesh.ARRAY_COLOR] != null:
					ctx.update(var_to_bytes(arrays[Mesh.ARRAY_COLOR]))
		elif node is MultiMeshInstance3D and node.multimesh != null:
			ctx.update(var_to_bytes(node.multimesh.buffer))
	return ctx.finish().hex_encode()

## Hash of the detail MultiMeshes only.
func _detail_hash(terrain: Node3D) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	var nodes := terrain.find_children("_Details_*", "MultiMeshInstance3D", true, false)
	nodes.sort_custom(func(a, b): return String(terrain.get_path_to(a)) < String(terrain.get_path_to(b)))
	for node in nodes:
		ctx.update(String(terrain.get_path_to(node)).to_utf8_buffer())
		ctx.update(var_to_bytes(node.multimesh.buffer))
	return ctx.finish().hex_encode()

func _run() -> void:
	var root := Node3D.new()
	root.name = "SmokeRoot"
	var packed := PackedScene.new()
	packed.pack(root)
	ResourceSaver.save(packed, "res://smoke.tscn")
	root.free()
	EditorInterface.open_scene_from_path("res://smoke.tscn")
	await _frames(5)

	EditorInterface.set_plugin_enabled("lowpoly_terrain_editor", true)
	await _frames(5)
	check("plugin enabled", EditorInterface.is_plugin_enabled("lowpoly_terrain_editor"))

	var toolbar := _find(EditorInterface.get_base_control(), "LowpolyTerrainToolbar")
	check("toolbar in editor", toolbar != null)
	if toolbar == null:
		_finish()
		return
	var plugin: Object = toolbar.new_terrain_pressed.get_connections()[0]["callable"].get_object()
	check("no terrain: only New Terrain (with its name) shown", not toolbar._terrain_row.visible and _find_button(toolbar, "New Terrain") != null)
	var tool_modes: Array = toolbar._tool_buttons.keys()
	tool_modes.sort()
	check("7 tools: Ground, Relief, Flatten, Road, River, Waterhole, Vegetation (%s)" % [tool_modes], tool_modes == [1, 3, 5, 7, 8, 9, 10])

	toolbar.new_terrain_pressed.emit()
	await _frames(3)
	var terrain: Node3D = plugin._active_terrain
	check("terrain created", terrain != null and terrain.has_meta("_lowpoly_terrain"))
	check("terrain in scene", terrain != null and terrain.owner == EditorInterface.get_edited_scene_root())
	# Undo then Redo of New Terrain: the terrain and its nodes stay in the
	# scene (owner given back), then it is selected again.
	var created_root := EditorInterface.get_edited_scene_root()
	var editor_undo: EditorUndoRedoManager = plugin.get_undo_redo()
	var create_history := editor_undo.get_history_undo_redo(editor_undo.get_object_history_id(terrain))
	var owned_before := terrain.find_children("*", "", true, false).filter(func(n: Node) -> bool: return n.owner == created_root).size()
	create_history.undo()
	var removed := not terrain.is_inside_tree()
	create_history.redo()
	var owned_after := terrain.find_children("*", "", true, false).filter(func(n: Node) -> bool: return n.owner == created_root).size()
	check("new terrain: Undo removes it, Redo keeps it in the scene (%d / %d owned nodes)" % [owned_after, owned_before],
		removed and terrain.is_inside_tree() and terrain.owner == created_root and owned_after == owned_before)
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(terrain)
	await _frames(3)
	plugin._set_tool(1)
	check("paint tool active", plugin._strokes.mode == 1)
	var chunks := terrain.get_node_or_null("_GeneratedTerrainChunks")
	check("new terrain: everything at runtime (chunks not saved)", chunks != null and chunks.owner == null and int(terrain.get_meta("_lte_runtime_build")) == 2)
	# N4: a new terrain starts in the generic Temperate biome (the plugin is
	# not tied to a theme), so its ground list and the proposed Map Preset agree.
	var new_biome: Resource = terrain.get_meta("_lte_biome") if terrain.has_meta("_lte_biome") else null
	check("new terrain: Temperate biome", new_biome != null and new_biome.resource_path.ends_with("biomes/presets/temperate.tres"))
	var new_ground: OptionButton = toolbar.get_ground_select()
	check("new terrain: ground list starts with Grass (%s)" % new_ground.get_item_text(0), new_ground.get_item_text(0) == "Grass" and new_ground.get_item_text(new_ground.selected) == "Grass")
	var new_recipe: Resource = plugin.default_map_recipe(terrain)
	check("new terrain: Map Preset = Temperate Island", new_recipe != null and new_recipe.resource_path.ends_with("temperate_island_map.tres"))
	check("Map Preset list starts with Temperate Island", plugin.get_map_presets()[0].resource_path.ends_with("temperate_island_map.tres"))
	# N5: rare layer settings in a closed "Advanced" group, after the others.
	var layer_props: Array = []
	var in_advanced := false
	for prop in load("res://addons/lowpoly_terrain_editor/biomes/detail_layer.gd").new().get_property_list():
		if prop["usage"] & PROPERTY_USAGE_GROUP:
			in_advanced = prop["name"] == "Advanced"
		elif in_advanced and prop["usage"] & PROPERTY_USAGE_EDITOR:
			layer_props.append(prop["name"])
	check("layer Advanced group %s" % [layer_props], layer_props == ["steep_bonus", "edge_bonus", "vegetation_brush", "paint_relaxes_rules", "paint_spacing", "cell_margin", "small_bias", "sink"])

	EditorInterface.inspect_object(terrain)
	await _frames(5)
	var inspector := EditorInterface.get_inspector()
	check("inspector panel built", _find_button(inspector, "Generate from Image") != null)
	# Simplicity audit step 2: 4 sections + a closed Advanced, no paragraphs.
	var panel := _find(inspector, "LowPoly Terrain")
	var titles: Array = []
	for child in panel.get_children():
		if child is Button and child.toggle_mode and child.flat:
			titles.append((child as Button).text.substr(2))
	check("inspector sections %s" % [titles], titles == ["Map", "Look", "Roads, Rivers & Waterholes", "Game", "Advanced"])
	var paragraphs := panel.find_children("*", "Label", true, false).filter(func(l): return (l as Label).autowrap_mode != TextServer.AUTOWRAP_OFF)
	check("no help paragraphs (%d)" % paragraphs.size(), paragraphs.is_empty())

	var mask_before: PackedFloat32Array = (terrain.get_meta("_lte_mask") as PackedFloat32Array).duplicate()
	plugin._strokes.begin(terrain, Vector3(0, 0, 0))
	plugin._strokes.update(terrain, Vector3(2, 0, 1))
	plugin._strokes.end(terrain)
	var mask_after: PackedFloat32Array = (terrain.get_meta("_lte_mask") as PackedFloat32Array).duplicate()
	check("paint stroke changed mask", mask_before != mask_after)
	plugin._toolbar_undo()
	await _frames(2)
	check("undo restores mask", terrain.get_meta("_lte_mask") == mask_before)
	plugin._toolbar_redo()
	await _frames(2)
	check("redo reapplies mask", terrain.get_meta("_lte_mask") == mask_after)

	# Relief held with the mouse still keeps raising (no motion event).
	var heights_before: PackedFloat32Array = (terrain.get_meta("_lte_heights") as PackedFloat32Array).duplicate()
	plugin._strokes.mode = 3
	plugin._strokes.begin(terrain, Vector3(0, 0, 0))
	var peak_click := _peak(terrain.get_meta("_lte_heights"))
	await get_tree().create_timer(0.5).timeout
	var peak_held := _peak(terrain.get_meta("_lte_heights"))
	plugin._strokes.end(terrain)
	plugin._strokes.mode = plugin._tool
	check("relief held still keeps raising (%.2f -> %.2f m)" % [peak_click, peak_held], peak_held > peak_click + 0.4)
	plugin._toolbar_undo()
	await _frames(2)
	check("undo lowers the held relief", terrain.get_meta("_lte_heights") == heights_before)

	# Viewport input path with a real camera looking down at the terrain.
	var camera := Camera3D.new()
	EditorInterface.get_edited_scene_root().add_child(camera)
	camera.global_position = Vector3(0, 30, 0)
	camera.look_at(Vector3.ZERO, Vector3.FORWARD)
	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	press.position = camera.get_viewport().get_visible_rect().size * 0.5
	var consumed: int = plugin._forward_3d_gui_input(camera, press)
	var release := InputEventMouseButton.new()
	release.button_index = MOUSE_BUTTON_LEFT
	release.pressed = false
	plugin._forward_3d_gui_input(camera, release)
	check("viewport input consumed", consumed == EditorPlugin.AFTER_GUI_INPUT_STOP)

	# Icon toolbar, brush ring, surface ray.
	var icon_count := 0
	for b in toolbar.find_children("*", "Button", true, false):
		if (b as Button).icon != null and (b as Button).text.is_empty():
			icon_count += 1
	check("toolbar uses icons (%d), one row, %d px, status [%s]" % [icon_count, toolbar.get_combined_minimum_size().x, plugin._toolbar.get_status()], icon_count >= 7 and toolbar is HBoxContainer and toolbar.get_combined_minimum_size().x < 1000)
	var motion := InputEventMouseMotion.new()
	motion.position = camera.get_viewport().get_visible_rect().size * 0.5
	plugin._forward_3d_gui_input(camera, motion)
	check("hover sets the brush ring point", plugin._hover_local != null)
	var heights: PackedFloat32Array = terrain.get_meta("_lte_heights")
	var saved_heights := heights.duplicate()
	heights.fill(2.5)
	terrain.set_meta("_lte_heights", heights)
	var ray_hit = plugin._mouse_to_local_terrain(camera, motion.position)
	check("surface ray lands on raised ground (y=%s)" % [ray_hit.y if ray_hit != null else "null"], ray_hit != null and absf(ray_hit.y - 2.5) < 0.05)
	terrain.set_meta("_lte_heights", saved_heights)
	var radius_before: float = plugin._strokes.brush_radius
	var key := InputEventKey.new()
	key.keycode = KEY_BRACKETRIGHT
	key.pressed = true
	plugin._forward_3d_gui_input(camera, key)
	check("] grows the brush", plugin._strokes.brush_radius > radius_before)
	plugin._strokes.brush_radius = radius_before

	# UX audit: modifiers, camera navigation, keys, contextual size field.
	var center: Vector2 = camera.get_viewport().get_visible_rect().size * 0.5
	plugin._set_tool(3)
	var ctrl_press := InputEventMouseButton.new()
	ctrl_press.button_index = MOUSE_BUTTON_LEFT
	ctrl_press.pressed = true
	ctrl_press.ctrl_pressed = true
	ctrl_press.position = center
	plugin._forward_3d_gui_input(camera, ctrl_press)
	check("Ctrl+drag with Raise lowers", plugin._strokes.is_stroke_active() and plugin._strokes.mode == 4)
	var outside := InputEventMouseMotion.new()
	outside.position = center + Vector2(4, 0)
	outside.button_mask = 0
	plugin._forward_3d_gui_input(camera, outside)
	check("release outside the view ends the stroke", not plugin._strokes.is_stroke_active() and plugin._strokes.mode == 3)
	var shift_press := ctrl_press.duplicate()
	shift_press.ctrl_pressed = false
	shift_press.shift_pressed = true
	plugin._forward_3d_gui_input(camera, shift_press)
	check("Shift+drag smooths", plugin._strokes.mode == 6)
	var release_ux := InputEventMouseButton.new()
	release_ux.button_index = MOUSE_BUTTON_LEFT
	release_ux.pressed = false
	plugin._forward_3d_gui_input(camera, release_ux)
	var alt_press := ctrl_press.duplicate()
	alt_press.ctrl_pressed = false
	alt_press.alt_pressed = true
	check("Alt+LMB left to camera navigation", plugin._forward_3d_gui_input(camera, alt_press) == EditorPlugin.AFTER_GUI_INPUT_PASS and not plugin._strokes.is_stroke_active())
	var sky := ctrl_press.duplicate()
	sky.ctrl_pressed = false
	sky.position = Vector2(center.x, -5000)
	camera.global_position = Vector3(0, 5, 0)
	camera.look_at(Vector3(0, 5, -10), Vector3.UP)
	check("click in the sky keeps the terrain selected", plugin._forward_3d_gui_input(camera, sky) == EditorPlugin.AFTER_GUI_INPUT_STOP and not plugin._strokes.is_stroke_active())
	camera.global_position = Vector3(0, 30, 0)
	camera.look_at(Vector3.ZERO, Vector3.FORWARD)
	var strength_before: float = plugin._strokes.brush_strength
	var equal := InputEventKey.new()
	equal.keycode = KEY_EQUAL
	equal.pressed = true
	plugin._forward_3d_gui_input(camera, equal)
	check("= raises the strength", plugin._strokes.brush_strength > strength_before)
	plugin._strokes.brush_strength = strength_before
	plugin._set_tool(7)
	var width_before := float(terrain.get_meta("_lte_road_width", 2.6))
	plugin._forward_3d_gui_input(camera, key)
	check("] widens the road with Road active", float(terrain.get_meta("_lte_road_width", 2.6)) > width_before and is_equal_approx(plugin._strokes.brush_radius, radius_before))
	check("Strength field off for Road", not toolbar._brush_strength_spin.editable)
	terrain.set_meta("_lte_road_width", width_before)
	plugin._set_tool(3)
	check("Size field back to the radius", is_equal_approx(toolbar._brush_radius_spin.value, radius_before) and toolbar._brush_strength_spin.editable)
	var escape := InputEventKey.new()
	escape.keycode = KEY_ESCAPE
	escape.pressed = true
	plugin._forward_3d_gui_input(camera, escape)
	check("Esc leaves the tool", plugin._tool == 0)
	plugin._strokes.brush_radius = 4.5
	plugin._strokes.brush_strength = 0.6
	plugin._brush_settings_changed()
	plugin._save_brush_settings()
	plugin._strokes.brush_radius = 1.0
	plugin._strokes.brush_strength = 2.0
	plugin._load_brush_settings()
	check("brush size / strength kept per project", is_equal_approx(plugin._strokes.brush_radius, 4.5) and is_equal_approx(plugin._strokes.brush_strength, 0.6) and plugin._brush_settings_save_at_ms == -1)
	plugin._strokes.brush_radius = radius_before
	plugin._strokes.brush_strength = strength_before
	plugin._save_brush_settings()

	plugin._set_tool(0)
	plugin._forward_3d_gui_input(camera, motion)
	check("no tool: no ring", plugin._hover_local == null)
	plugin._set_tool(1)
	camera.queue_free()

	# A low Highest Ground clamps the ground; its Undo gives the heights back.
	var limit_before: Variant = terrain.get_meta("_lte_height_max")
	var heights_before_limit: PackedFloat32Array = (terrain.get_meta("_lte_heights") as PackedFloat32Array).duplicate()
	plugin.set_tuning_setting(terrain, "_lte_height_max", 0.05)
	check("height limit clamps the ground", terrain.get_meta("_lte_heights") != heights_before_limit)
	plugin._toolbar_undo()
	check("height limit: Undo gives the heights and the limit back", terrain.get_meta("_lte_heights") == heights_before_limit and terrain.get_meta("_lte_height_max") == limit_before)
	plugin._toolbar_redo()
	check("height limit: Redo clamps again", float(terrain.get_meta("_lte_height_max")) == 0.05 and terrain.get_meta("_lte_heights") != heights_before_limit)
	plugin._toolbar_undo()
	# Grow Terrain is undoable.
	var size_before: int = terrain.get_meta("_lte_resolution")
	plugin.grow_canvas(terrain)
	var grown: int = terrain.get_meta("_lte_resolution")
	plugin._toolbar_undo()
	check("grow terrain: Undo gives the old size back (%d -> %d -> %d)" % [size_before, grown, int(terrain.get_meta("_lte_resolution"))], grown > size_before and int(terrain.get_meta("_lte_resolution")) == size_before and terrain.get_meta("_lte_heights") == heights_before_limit)

	plugin.set_tuning_setting(terrain, "_lte_height_max", 2.0)
	check("tuning applied", float(terrain.get_meta("_lte_height_max")) == 2.0)

	# Bare ground: on a new terrain nothing grows by itself on ground painted
	# by hand; the Vegetation brush adds it.
	var detail_total := func(t: Node3D) -> int:
		var total := 0
		for node in t.find_children("_Details_*", "MultiMeshInstance3D", true, false):
			total += node.multimesh.instance_count
		return total
	check("new terrain: Details Everywhere off", terrain.get_meta("_lte_details_everywhere", true) == false)
	check("new terrain: walkable collision on", terrain.get_meta("_lte_collision_enabled", false) == true)
	# Small bumps on new terrains; Ground Bumps 0 takes
	# only the bumps away (painted relief stays), Undo puts them back, and
	# a grown canvas gets the same bumps on its new ground.
	check("new terrain: smooth ground (texture = the game's material)", terrain.get_meta("_lte_shade_smooth", true) == true)
	check("new terrain: ground bumps 0.3 m", is_equal_approx(float(terrain.get_meta("_lte_ground_bumps", 0.0)), 0.3))
	var bumps_script: GDScript = load("res://addons/lowpoly_terrain_editor/core/ground_bumps.gd")
	var bumped: PackedFloat32Array = (terrain.get_meta("_lte_heights") as PackedFloat32Array).duplicate()
	plugin.set_ground_bumps(terrain, 0.0)
	var unbumped: PackedFloat32Array = (terrain.get_meta("_lte_heights") as PackedFloat32Array).duplicate()
	var bump_change := 0.0
	for i in bumped.size():
		bump_change = maxf(bump_change, absf(bumped[i] - unbumped[i]))
	check("ground bumps 0: bumps gone, relief kept (max change %.2f m)" % bump_change, bump_change > 0.05 and bump_change <= 0.31 and float(terrain.get_meta("_lte_ground_bumps")) == 0.0)
	plugin._toolbar_undo()
	var redone: PackedFloat32Array = terrain.get_meta("_lte_heights")
	var undo_gap := 0.0
	for i in bumped.size():
		undo_gap = maxf(undo_gap, absf(bumped[i] - redone[i]))
	check("ground bumps: Undo puts them back", undo_gap < 0.0001 and is_equal_approx(float(terrain.get_meta("_lte_ground_bumps")), 0.3))
	var grow_a := Node3D.new()
	var grow_b := Node3D.new()
	for g in [grow_a, grow_b]:
		load("res://addons/lowpoly_terrain_editor/core/terrain_data.gd").initialize(g)
		bumps_script.set_amount(g, 0.3)
	var CanvasGrow: GDScript = load("res://addons/lowpoly_terrain_editor/editing/canvas.gd")
	CanvasGrow.expand(grow_a, 4)
	var flat_grown: PackedFloat32Array = grow_a.get_meta("_lte_heights").duplicate()
	flat_grown.fill(0.0)
	grow_b.set_meta("_lte_resolution", int(grow_a.get_meta("_lte_resolution")))
	grow_b.set_meta("_lte_world_size", float(grow_a.get_meta("_lte_world_size")))
	grow_b.set_meta("_lte_heights", flat_grown)
	grow_b.set_meta("_lte_ground_bumps", 0.0)
	bumps_script.set_amount(grow_b, 0.3)
	var grown_a: PackedFloat32Array = grow_a.get_meta("_lte_heights")
	var grown_b: PackedFloat32Array = grow_b.get_meta("_lte_heights")
	var grow_gap := 0.0
	for i in grown_a.size():
		grow_gap = maxf(grow_gap, absf(grown_a[i] - grown_b[i]))
	check("grown terrain: same bumps on the new ground (gap %.5f m)" % grow_gap, grown_a.size() == grown_b.size() and grow_gap < 0.0001)
	grow_a.free()
	grow_b.free()
	# Your own asset: a scene (.glb / .tscn) in a layer's Model slot becomes
	# one mesh standing on its bottom centre, with its own materials.
	var model_root := Node3D.new()
	var model_part := MeshInstance3D.new()
	var model_box := BoxMesh.new()
	model_box.size = Vector3(2, 3, 2)
	model_box.material = StandardMaterial3D.new()
	model_part.mesh = model_box
	model_part.position = Vector3(5, 7, -1)
	model_root.add_child(model_part)
	model_part.owner = model_root
	var model_scene := PackedScene.new()
	model_scene.pack(model_root)
	model_root.free()
	var model_layer := LowpolyDetailLayer.new()
	model_layer.model = model_scene
	var model_mesh: Mesh = model_layer.resolved_mesh()
	var model_box_aabb := model_mesh.get_aabb() if model_mesh else AABB()
	check("custom model: one mesh on its bottom centre, 3 m high", model_mesh != null and absf(model_box_aabb.position.y) < 0.001 and model_box_aabb.get_center().length() < 1.6 and absf(model_box_aabb.size.y - 3.0) < 0.001)
	var scatter_script: GDScript = load("res://addons/lowpoly_terrain_editor/mesh/detail_scatter.gd")
	check("custom model: keeps its own material", model_mesh.surface_get_material(0) != null and scatter_script.layer_material(model_layer) == null)
	# Mobile: built-in grass is one triangle per blade with the two-sided
	# grass material, both windings with any other material.
	var meshes_script: GDScript = load("res://addons/lowpoly_terrain_editor/mesh/detail_meshes.gd")
	var grass_layer := LowpolyDetailLayer.new()
	grass_layer.builtin_mesh = 3
	var grass_material: Material = scatter_script.layer_material(grass_layer)
	var grass_mesh: Mesh = scatter_script._mesh_for(grass_layer, grass_material, meshes_script.builtin(3))
	var grass_custom: Mesh = scatter_script._mesh_for(grass_layer, StandardMaterial3D.new(), meshes_script.builtin(3))
	check("grass: 1 triangle per blade when two-sided (%d / %d vertices)" % [grass_mesh.surface_get_array_len(0), grass_custom.surface_get_array_len(0)],
		grass_mesh.surface_get_array_len(0) * 2 == grass_custom.surface_get_array_len(0) and (grass_material as ShaderMaterial).shader.code.contains("cull_disabled"))
	plugin._builder.rebuild_feature_mesh(terrain)
	var feature_node := terrain.get_node_or_null("_GeneratedTerrainMesh") as GeometryInstance3D
	check("roads / rivers cast no shadow", feature_node != null and feature_node.cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF)
	# Game > Ground Casts Shadows: on by default, off at once (no rebuild), Undo.
	# The chunks never cast: their shadow-only _GroundShadow child (back faces)
	# does, unless the option is off.
	var shadow_chunks := func(setting: int) -> bool:
		var caster_setting := GeometryInstance3D.SHADOW_CASTING_SETTING_SHADOWS_ONLY if setting == GeometryInstance3D.SHADOW_CASTING_SETTING_ON else setting
		var nodes := terrain.get_node("_GeneratedTerrainChunks").get_children().filter(func(n): return n is MeshInstance3D)
		return not nodes.is_empty() and nodes.all(func(n):
			var caster := (n as Node).get_node_or_null("_GroundShadow") as MeshInstance3D
			return (n as MeshInstance3D).cast_shadow == GeometryInstance3D.SHADOW_CASTING_SETTING_OFF and caster != null and caster.cast_shadow == caster_setting)
	check("ground casts shadows by default", shadow_chunks.call(GeometryInstance3D.SHADOW_CASTING_SETTING_ON))
	plugin.set_ground_shadows(terrain, false)
	check("Ground Casts Shadows off: no chunk casts", shadow_chunks.call(GeometryInstance3D.SHADOW_CASTING_SETTING_OFF) and terrain.get_meta("_lte_ground_shadows") == false)
	plugin._builder.rebuild_all(terrain)
	check("rebuilt chunks keep it off", shadow_chunks.call(GeometryInstance3D.SHADOW_CASTING_SETTING_OFF))
	plugin._toolbar_undo()
	check("undo: ground casts shadows again", shadow_chunks.call(GeometryInstance3D.SHADOW_CASTING_SETTING_ON) and terrain.get_meta("_lte_ground_shadows") == true)
	var bare_cells: PackedByteArray = terrain.get_meta("_lte_cell_active")
	bare_cells.fill(1)
	terrain.set_meta("_lte_cell_active", bare_cells)
	plugin._builder.rebuild_all(terrain)
	var bare_count: int = detail_total.call(terrain)
	check("ground painted by hand stays bare (%d details)" % bare_count, bare_count == 0)
	var brush_script: GDScript = load("res://addons/lowpoly_terrain_editor/editing/brush.gd")
	var mode_script: GDScript = load("res://addons/lowpoly_terrain_editor/editing/tool_mode.gd")
	for i in 6:
		brush_script.apply_vegetation(terrain, mode_script.Mode.VEGETATION, Vector2.ZERO, 8.0, 1.0)
	plugin._builder.rebuild_all(terrain)
	var painted_count: int = detail_total.call(terrain)
	check("Vegetation brush grows plants on bare ground (%d)" % painted_count, painted_count > 0)
	# Painted acacia forest: crowns do not cross (DetailLayer.paint_spacing).
	# Trees come from the Savanna example biome (the default Temperate has none).
	terrain.set_meta("_lte_biome", load("res://addons/lowpoly_terrain_editor/biomes/presets/senegal_savanna.tres"))
	var acacia_spots := func() -> Array[Vector2]:
		var spots: Array[Vector2] = []
		# From the scatter buffers (headless MultiMesh transforms read back as zero).
		var builder = plugin._builder
		var n: int = TerrainMesherRef.chunk_count(terrain)
		for cz in n:
			for cx in n:
				for d in DetailScatterRef.build(terrain, builder.get_river_carve(terrain), cx, cz, builder.chunk_shading(terrain, cx, cz)):
					if String(d[3].name) == "Acacias":
						var buffer: PackedFloat32Array = d[2]
						for k in range(0, buffer.size(), 16):
							spots.append(Vector2(buffer[k + 3], buffer[k + 11]))
		return spots
	var close_pairs := func(spots: Array[Vector2], gap: float) -> int:
		var n := 0
		for i in spots.size():
			for j in range(i + 1, spots.size()):
				if spots[i].distance_to(spots[j]) < gap:
					n += 1
		return n
	for i in 6:
		brush_script.apply_vegetation(terrain, mode_script.Mode.VEGETATION, Vector2.ZERO, 12.0, 1.0, "Acacias")
	plugin._builder.rebuild_all(terrain)
	var forest: Array[Vector2] = acacia_spots.call()
	var forest_close: int = close_pairs.call(forest, 3.0)
	check("painted acacia forest: no two trunks closer than 3 m (%d trees, %d close pairs)" % [forest.size(), forest_close], forest.size() >= 4 and forest_close == 0)
	var acacia_layer: Resource = null
	for layer in DetailScatterRef.biome_of(terrain).detail_layers:
		if layer != null and layer.name == "Acacias":
			acacia_layer = layer
	if acacia_layer:
		var saved_spacing: float = acacia_layer.paint_spacing
		acacia_layer.paint_spacing = 0.0
		plugin._builder.rebuild_all(terrain)
		var packed_spots: Array[Vector2] = acacia_spots.call()
		check("Paint Spacing 0: denser, crowns may cross (%d trees, %d close pairs)" % [packed_spots.size(), close_pairs.call(packed_spots, 3.0)], packed_spots.size() > forest.size() and close_pairs.call(packed_spots, 3.0) > 0)
		acacia_layer.paint_spacing = saved_spacing
		plugin._builder.rebuild_all(terrain)
	else:
		check("savanna biome has an Acacias layer", false)
	for i in 10:
		brush_script.apply_vegetation(terrain, mode_script.Mode.VEGETATION_CLEAR, Vector2.ZERO, 8.0, 1.0)
		brush_script.apply_vegetation(terrain, mode_script.Mode.VEGETATION_CLEAR, Vector2.ZERO, 14.0, 1.0, "Acacias")
	plugin._builder.rebuild_all(terrain)
	check("Ctrl brush: bare again (%d)" % detail_total.call(terrain), detail_total.call(terrain) == 0)
	if terrain.has_meta("_lte_cell_vegetation"):
		terrain.remove_meta("_lte_cell_vegetation")

	# Biomes: create an editable biome, live-edit a layer, ground style preset.
	# (Back to no biome first: a new terrain starts in the savanna one; the
	# older checks below expect the biome to grow everywhere.)
	plugin.set_biome(terrain, null)
	terrain.set_meta("_lte_details_everywhere", true)
	await _frames(3)
	inspector = EditorInterface.get_inspector()
	EditorInterface.inspect_object(terrain)
	await _frames(5)
	var create_button := _find_button(EditorInterface.get_inspector(), "Create Editable Biome")
	check("biome section built", create_button != null)
	if create_button:
		create_button.pressed.emit()
	await _frames(3)
	var biome: Resource = terrain.get_meta("_lte_biome") if terrain.has_meta("_lte_biome") else null
	# Activate every cell so there is ground for the details.
	var cells: PackedByteArray = terrain.get_meta("_lte_cell_active")
	cells.fill(1)
	terrain.set_meta("_lte_cell_active", cells)
	plugin._builder.rebuild_all(terrain)
	check("editable biome created", biome != null and biome.detail_layers.size() == 2)
	var grass_nodes := func() -> int:
		var total := 0
		for node in terrain.find_children("_Details_1_*", "MultiMeshInstance3D", true, false):
			total += node.multimesh.instance_count
		return total
	var grass_before: int = grass_nodes.call()
	if biome:
		biome.detail_layers[0].density = 2.0
	await get_tree().create_timer(0.6).timeout
	await _frames(3)
	var grass_after: int = grass_nodes.call()
	check("live layer edit re-scatters (%d -> %d)" % [grass_before, grass_after], grass_after > grass_before)
	EditorInterface.inspect_object(terrain)
	await _frames(5)
	# Ground style list next to the Ground tool (simplicity audit step 3).
	plugin._set_tool(3)
	var ground_select: OptionButton = toolbar.get_ground_select()
	var sand := -1
	for i in ground_select.item_count:
		if ground_select.get_item_text(i) == "Sand":
			sand = i
	check("ground list: biome styles + Custom (%d items)" % ground_select.item_count, ground_select.item_count == biome.ground_styles.size() + 1 and ground_select.get_item_text(ground_select.item_count - 1) == "Custom")
	if sand >= 0:
		ground_select.select(sand)
		ground_select.item_selected.emit(sand)
	check("ground style loads brush", sand >= 0 and (terrain.get_meta("_lte_brush_top_color") as Color).is_equal_approx(biome.ground_styles[2].top_color))
	check("ground style selects the Ground tool", plugin._tool == 1)
	var ctrl_key := InputEventKey.new()
	ctrl_key.keycode = KEY_CTRL
	ctrl_key.ctrl_pressed = true
	var shift_key := InputEventKey.new()
	shift_key.keycode = KEY_SHIFT
	shift_key.shift_pressed = true
	var ctrl_ground: int = plugin._modified_tool(ctrl_key)
	plugin._set_tool(3)
	var ctrl_relief: int = plugin._modified_tool(ctrl_key)
	var shift_relief: int = plugin._modified_tool(shift_key)
	check("Ctrl: Ground erases, Relief digs; Shift smooths (%d %d %d)" % [ctrl_ground, ctrl_relief, shift_relief], ctrl_ground == 2 and ctrl_relief == 4 and shift_relief == 6)
	plugin._set_tool(2)
	check("Erase mode shows the Ground button", toolbar.get_tool_button(1).button_pressed)
	plugin._set_tool(1)
	terrain.set_meta("_lte_brush_top_color", Color(0.1, 0.2, 0.9))
	plugin._refresh_ground_styles()
	check("own brush colors show Custom", ground_select.get_item_text(ground_select.selected) == "Custom")
	plugin.use_ground_style(terrain, biome.ground_styles[2])
	check("list follows the brush (Sand)", ground_select.get_item_text(ground_select.selected) == "Sand")
	var preset: Resource = load("res://addons/lowpoly_terrain_editor/biomes/presets/temperate.tres")
	preset.ambient_occlusion = 0.9
	terrain.set_meta("_lte_brush_top_color", Color(0.1, 0.2, 0.9))
	plugin.set_biome(terrain, preset)
	check("other biome keeps Custom brush colors", (terrain.get_meta("_lte_brush_top_color") as Color).is_equal_approx(Color(0.1, 0.2, 0.9)))
	var shading_script: GDScript = load("res://addons/lowpoly_terrain_editor/mesh/terrain_shading.gd")
	check("shading read from the biome, no copy on the terrain", is_equal_approx(float(shading_script.settings(terrain)["ao"]), 0.9) and not terrain.has_meta("_lte_shade_ao"))
	# Step 4: editing the biome changes the terrain at once (no Re-apply).
	var chunk_colors := func() -> PackedColorArray:
		var chunk := terrain.get_node("_GeneratedTerrainChunks").get_child(0) as MeshInstance3D
		return chunk.mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var colors_before: PackedColorArray = chunk_colors.call()
	preset.ambient_occlusion = 0.0
	await get_tree().create_timer(0.6).timeout
	await _frames(3)
	check("biome shading edit rebuilds the ground", chunk_colors.call() != colors_before)
	check("no Re-apply button", _find_button(EditorInterface.get_inspector(), "Re-apply Biome Shading") == null)
	# A biome file is shared: copy it to this terrain, undo goes back.
	check("biome file is shared", plugin.biome_is_shared(terrain))
	plugin.copy_biome_to_terrain(terrain)
	var own: Resource = terrain.get_meta("_lte_biome")
	check("copy biome to terrain (%s)" % own.name, own != preset and not plugin.biome_is_shared(terrain) and is_equal_approx(own.ambient_occlusion, 0.0) and own.detail_layers.size() == preset.detail_layers.size())
	plugin._toolbar_undo()
	await _frames(2)
	check("undo: shared biome again", terrain.get_meta("_lte_biome") == preset)
	preset.ambient_occlusion = 0.5
	plugin.set_biome(terrain, null)
	check("set_biome(null) clears", not terrain.has_meta("_lte_biome"))
	EditorInterface.inspect_object(terrain)
	await _frames(5)
	# Old scenes: shading / waterhole colors stored on the terrain.
	var data_script: GDScript = load("res://addons/lowpoly_terrain_editor/core/terrain_data.gd")
	var default_biome: Resource = load("res://addons/lowpoly_terrain_editor/biomes/terrain_biome.gd").default_biome()
	var same := Node3D.new()
	same.set_meta("_lte_shade_ao", default_biome.ambient_occlusion)
	same.set_meta("_lte_waterhole_clay_color", default_biome.waterhole_clay_color)
	var migrated_same: bool = data_script.migrate_look(same)
	check("migration: same values -> copies removed, no own biome", migrated_same and not same.has_meta("_lte_shade_ao") and not same.has_meta("_lte_waterhole_clay_color") and not same.has_meta("_lte_biome"))
	var tuned := Node3D.new()
	tuned.name = "OldTerrain"
	tuned.set_meta("_lte_shade_ao", 0.77)
	tuned.set_meta("_lte_shade_blend", 3)
	tuned.set_meta("_lte_waterholes", [{"center": Vector2(1, 2), "radius": 3.0, "clay_color": Color(0.9, 0.1, 0.1), "crack_color": Color(0.1, 0.1, 0.9)}])
	data_script.migrate_look(tuned)
	var tuned_biome: Resource = tuned.get_meta("_lte_biome") if tuned.has_meta("_lte_biome") else null
	check("migration: tuned terrain gets its own biome with its values", tuned_biome != null and is_equal_approx(tuned_biome.ambient_occlusion, 0.77) and tuned_biome.blend == 3
		and tuned_biome.waterhole_clay_color.is_equal_approx(Color(0.9, 0.1, 0.1)) and not tuned.has_meta("_lte_shade_ao")
		and not (tuned.get_meta("_lte_waterholes")[0] as Dictionary).has("clay_color") and not is_equal_approx(default_biome.ambient_occlusion, 0.77))
	check("migration: runs once", not data_script.migrate_look(tuned))
	same.free()
	tuned.free()

	# Dried waterholes: tool button, click, undo / redo, erase.
	var waterhole_button: Button = toolbar.get_tool_button(9)
	check("waterhole tool button", waterhole_button != null)
	if waterhole_button:
		waterhole_button.pressed.emit()
	check("waterhole tool active", plugin._strokes.mode == 9)
	plugin._strokes.brush_radius = 3.0
	plugin._strokes.begin(terrain, Vector3(1, 0, 1))
	plugin._strokes.end(terrain)
	var holes: Array = terrain.get_meta("_lte_waterholes", [])
	var plates := terrain.get_node_or_null("_GeneratedWaterholes/Waterhole_0") as MeshInstance3D
	check("waterhole placed with plates", holes.size() == 1 and plates != null and plates.mesh != null and plates.owner == null)
	check("waterhole inspector section", _find_button(EditorInterface.get_inspector(), "Apply to Existing Waterholes") != null)
	plugin._toolbar_undo()
	await _frames(2)
	check("undo removes the waterhole", terrain.get_meta("_lte_waterholes", []).is_empty() and terrain.get_node_or_null("_GeneratedWaterholes") == null)
	plugin._toolbar_redo()
	await _frames(2)
	check("redo restores it", terrain.get_meta("_lte_waterholes", []).size() == 1)
	plugin._set_tool(2)
	plugin._strokes.begin(terrain, Vector3(1, 0, 1))
	plugin._strokes.end(terrain)
	check("erase removes the waterhole", terrain.get_meta("_lte_waterholes", []).is_empty())
	plugin._set_tool(0)
	inspector = EditorInterface.get_inspector()
	var res_before := int(terrain.get_meta("_lte_resolution"))
	_find_button(inspector, "Grow Terrain").pressed.emit()
	check("grow canvas button", int(terrain.get_meta("_lte_resolution")) == res_before + 16)

	var img := Image.create(10, 8, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 1, 0))
	img.set_pixel(5, 4, Color(1, 0, 0))
	terrain.set_meta("_lte_generator_image", ImageTexture.create_from_image(img))
	plugin.generate_from_image(terrain)
	check("generate from image", int(terrain.get_meta("_lte_resolution")) == 11)
	plugin._toolbar_undo()
	await _frames(2)
	check("undo generation", int(terrain.get_meta("_lte_resolution")) == res_before + 16)

	# Phase 4: map generator + runtime.
	var res_before_map := int(terrain.get_meta("_lte_resolution"))
	terrain.set_meta("_lte_map_recipe", load("res://addons/lowpoly_terrain_editor/generation/presets/senegal_savanna_map.tres"))
	terrain.set_meta("_lte_map_seed", 5)
	terrain.notify_property_list_changed()
	await _frames(3)
	var gen_button := _find_button(EditorInterface.get_inspector(), "Generate Map")
	check("map generator inspector section", gen_button != null)
	if gen_button:
		gen_button.pressed.emit()
	# One generation step a frame (progress bar).
	await _frames(2)
	for i in 60:
		if plugin._generating == null:
			break
		await get_tree().process_frame
	check("generate map", int(terrain.get_meta("_lte_resolution")) == 193 and terrain.get_meta("_lte_waterholes", []).size() > 0)
	var framer = load("res://addons/lowpoly_terrain_editor/ui/editor_camera_framer.gd")
	var map_aabb: AABB = framer.terrain_aabb(terrain, "_GeneratedTerrainChunks")
	await _frames(300)
	var editor_camera := EditorInterface.get_editor_viewport_3d(0).get_camera_3d()
	var selected := EditorInterface.get_selection().get_selected_nodes()
	check("selection kept after framing", selected.size() == 1 and selected[0] == terrain and plugin._active_terrain == terrain)
	check("camera framed on the generated map (%.0f m away)" % editor_camera.global_position.distance_to(map_aabb.get_center()),
		framer.is_in_view(map_aabb) and editor_camera.global_position.distance_to(map_aabb.get_center()) < map_aabb.size.length() * 1.5)
	var runtime_node := terrain.get_node_or_null("_LowpolyTerrainRuntime")
	check("runtime node auto-added (tree collision)", runtime_node != null and runtime_node.owner == EditorInterface.get_edited_scene_root())
	# Compact storage: packed in the file, plain arrays in memory.
	var heights_mem: PackedFloat32Array = terrain.get_meta("_lte_heights")
	var styles_mem: PackedInt32Array = terrain.get_meta("_lte_cell_styles")
	var hash_mem := _mesh_hash(terrain)
	var t_save := Time.get_ticks_msec()
	EditorInterface.save_scene()
	var save_ms := Time.get_ticks_msec() - t_save
	await _frames(2)
	var saved_text := FileAccess.get_file_as_string("res://smoke.tscn")
	var heights_line := ""
	for line in saved_text.split("\n"):
		if line.begins_with("metadata/_lte_heights"):
			heights_line = line
	check("scene stores the packed block (%d KB file, saved in %d ms)" % [saved_text.length() / 1024, save_ms],
		saved_text.length() < 512 * 1024 and saved_text.contains("metadata/_lte_packed_data = {") and saved_text.contains("\"zstd\": PackedByteArray(") and heights_line.length() < 100)
	check("arrays back in memory after save", terrain.get_meta("_lte_heights") == heights_mem and terrain.get_meta("_lte_cell_styles") == styles_mem
		and (terrain.get_meta("_lte_packed_data", {}) as Dictionary).is_empty() and _mesh_hash(terrain) == hash_mem)
	var reloaded: Node = ResourceLoader.load("res://smoke.tscn", "", ResourceLoader.CACHE_MODE_IGNORE).instantiate()
	var holder := Node.new()
	add_child(holder)
	holder.add_child(reloaded)
	var reloaded_terrain: Node3D = reloaded.get_node(EditorInterface.get_edited_scene_root().get_path_to(terrain))
	check("reloaded scene unpacks identical data", reloaded_terrain.get_meta("_lte_heights") == heights_mem and reloaded_terrain.get_meta("_lte_cell_styles") == styles_mem
		and reloaded_terrain.get_meta("_lte_mask") == terrain.get_meta("_lte_mask") and reloaded_terrain.get_meta("_lte_cell_active") == terrain.get_meta("_lte_cell_active"))
	await _frames(3)
	var restored_chunks := reloaded_terrain.get_node_or_null("_GeneratedTerrainChunks")
	var first_mesh: Mesh = null
	if restored_chunks and restored_chunks.get_child_count() > 0:
		first_mesh = (restored_chunks.get_child(0) as MeshInstance3D).mesh
	check("scene open rebuilds the map from its data", first_mesh != null and restored_chunks.owner == null)
	plugin._edit(reloaded_terrain)
	check("selecting it does not rebuild again", first_mesh != null and (restored_chunks.get_child(0) as MeshInstance3D).mesh == first_mesh)
	plugin._edit(terrain)
	holder.queue_free()
	# Lighting is not part of the plugin any more: no biome lighting button.
	terrain.notify_property_list_changed()
	await _frames(3)
	check("no biome lighting button", _find_button(EditorInterface.get_inspector(), "Apply Biome Lighting") == null and _find_button(EditorInterface.get_inspector(), "Add Horizon") == null)
	var scene_root := EditorInterface.get_edited_scene_root()
	var details := terrain.find_children("_Details*", "MultiMeshInstance3D", true, false)
	check("map details not saved by default", not details.is_empty() and details[0].owner == null)
	plugin.set_runtime_build(terrain, 0)
	check("save everything: owned", terrain.get_node("_GeneratedTerrainChunks").owner != null and details[0].owner != null)
	plugin.set_runtime_build(terrain, 1)
	check("details at runtime: not owned", details[0].owner == null and terrain.get_node("_GeneratedTerrainChunks").owner != null)
	plugin.set_runtime_build(terrain, 2)
	check("everything at runtime: chunks not owned", terrain.get_node("_GeneratedTerrainChunks").owner == null)
	plugin.set_runtime_build(terrain, 0)
	check("save everything: owned again", terrain.get_node("_GeneratedTerrainChunks").owner != null and terrain.find_children("_Details*", "MultiMeshInstance3D", true, false)[0].owner != null)
	# Fluid editing: undo of a stroke rebuilds its area only, and must give
	# back exactly the same meshes / details; collision waits for a pause.
	var hash_before := _mesh_hash(terrain)
	var details_at_start := _detail_hash(terrain)
	plugin._set_tool(3)
	plugin._strokes.brush_radius = 4.0
	plugin._strokes.begin(terrain, Vector3(5, 0, 5))
	plugin._strokes.update(terrain, Vector3(14, 0, 7))
	plugin._strokes.end(terrain)
	plugin._set_tool(0)
	var collision_waits: bool = plugin._builder.has_pending_collision()
	plugin._builder.flush_deferred()
	var hash_stroke := _mesh_hash(terrain)
	check("stroke changed meshes", hash_stroke != hash_before)
	check("sculpt stroke leaves the details as they are", _detail_hash(terrain) == details_at_start)
	check("collision not rebuilt during edits", collision_waits or not terrain.get_meta("_lte_collision_enabled", false))
	plugin._apply_changes()
	check("collision rebuilt before save / run", not plugin._builder.has_pending_collision())
	plugin._toolbar_undo()
	plugin._builder.flush_deferred()
	check("area undo = identical meshes + details", _mesh_hash(terrain) == hash_before)
	plugin._toolbar_redo()
	plugin._builder.flush_deferred()
	check("area redo = identical meshes + details", _mesh_hash(terrain) == hash_stroke)
	plugin.replace_details(terrain)
	check("Replace Details puts the details on the raised ground", _detail_hash(terrain) != details_at_start)
	plugin._toolbar_undo()
	plugin._builder.flush_deferred()
	plugin.replace_details(terrain)
	check("Replace Details on the original ground = original details", _detail_hash(terrain) == details_at_start)
	var t_select := Time.get_ticks_msec()
	plugin._edit(terrain)
	check("reselect does not rebuild (%d ms)" % (Time.get_ticks_msec() - t_select), Time.get_ticks_msec() - t_select < 500)

	# Rivers never climb: raising a hill under a river cuts the channel
	# through it (whole river re-carved at the end of the stroke, same
	# meshes as a full rebuild), and Undo gives everything back.
	var rivers_saved: Array = terrain.get_meta("_lte_rivers", []).duplicate(true)
	var feature_style: GDScript = load("res://addons/lowpoly_terrain_editor/styles/feature_style.gd")
	var river_mesher: GDScript = load("res://addons/lowpoly_terrain_editor/mesh/river_mesher.gd")
	feature_style.commit(terrain, feature_style.RIVER, [Vector2(-24, -12), Vector2(24, -12)] as Array[Vector2])
	plugin._builder.rebuild_all(terrain)
	var river_carve_before: PackedFloat32Array = plugin._builder.get_river_carve(terrain).duplicate()
	var river_hash_before := _mesh_hash(terrain)
	plugin._set_tool(3)
	plugin._strokes.brush_radius = 5.0
	plugin._strokes.brush_strength = 1.0
	plugin._strokes.begin(terrain, Vector3(0, 0, -12))
	for i in 12:
		plugin._strokes.update(terrain, Vector3(0.2 * (i % 2), 0, -12))
	plugin._strokes.end(terrain)
	plugin._set_tool(0)
	plugin._builder.flush_deferred()
	var river_res := int(terrain.get_meta("_lte_resolution"))
	var river_size := float(terrain.get_meta("_lte_world_size"))
	var river_line: Dictionary = river_mesher.water_levels(terrain.get_meta("_lte_heights"), river_res, river_size, (terrain.get_meta("_lte_rivers") as Array)[-1]["points"])
	var river_levels: PackedFloat32Array = river_line["levels"]
	var river_ground: PackedFloat32Array = river_line["ground"]
	var river_hill := Array(river_ground).max() as float
	var river_ends := maxf(river_ground[0], river_ground[river_ground.size() - 1])
	check("river over a raised hill: water stays at %.2f m, hill %.2f m" % [Array(river_levels).max(), river_hill], river_hill > river_ends + 0.5 and (Array(river_levels).max() as float) <= river_ends + 0.001)
	plugin.replace_details(terrain)
	var river_hash_stroke := _mesh_hash(terrain)
	plugin._builder.rebuild_all(terrain)
	check("sculpt near a river = same meshes as a full rebuild", _mesh_hash(terrain) == river_hash_stroke)
	plugin._toolbar_undo()
	plugin._builder.flush_deferred()
	plugin.replace_details(terrain)
	check("undo of the sculpt: carve and meshes back", plugin._builder.get_river_carve(terrain) == river_carve_before and _mesh_hash(terrain) == river_hash_before)
	terrain.set_meta("_lte_rivers", rivers_saved)
	plugin._builder.rebuild_all(terrain)

	# Vegetation brush: thicker / none / back to normal, live details, area undo.
	var ToolModeScript = load("res://addons/lowpoly_terrain_editor/editing/tool_mode.gd")
	check("vegetation Ctrl / Shift variants", ToolModeScript.with_modifiers(10, true, false) == 11 and ToolModeScript.with_modifiers(10, false, true) == 12 and ToolModeScript.with_modifiers(11, true, false) == 10)
	var veg_button: Button = toolbar.get_tool_button(10)
	check("vegetation tool button", veg_button != null)
	if veg_button:
		veg_button.pressed.emit()
	check("vegetation tool active", plugin._strokes.mode == 10)
	var veg_counts := func() -> Dictionary:
		var out := {"plants": 0, "others": 0}
		for node in terrain.find_children("_Details*", "MultiMeshInstance3D", true, false):
			var n := String(node.name)
			var c: int = node.multimesh.visible_instance_count if node.multimesh.visible_instance_count >= 0 else node.multimesh.instance_count
			var plant := n.contains("Grass") or n.contains("Shrubs") or n.contains("Acacias") or n.contains("Baobabs") or n.contains("DeadTrees") or n.contains("Reeds")
			out["plants" if plant else "others"] += c
		return out
	var veg_stroke := func(mode: int, at: Vector3, samples: int) -> void:
		plugin._set_tool(mode)
		plugin._strokes.brush_radius = 12.0
		plugin._strokes.brush_strength = 4.0
		plugin._strokes.begin(terrain, at)
		for i in samples:
			plugin._strokes.update(terrain, at)
		plugin._strokes.end(terrain)
		plugin._builder.flush_deferred()
	var counts0: Dictionary = veg_counts.call()
	var hash_veg0 := _mesh_hash(terrain)
	var collision_before: bool = plugin._builder.has_pending_collision()
	veg_stroke.call(10, Vector3(20, 0, 20), 5)
	var counts_forest: Dictionary = veg_counts.call()
	var veg: PackedByteArray = terrain.get_meta("_lte_cell_vegetation", {}).get("", PackedByteArray())
	var veg_cells := int(terrain.get_meta("_lte_resolution")) - 1
	check("vegetation + stored per cell", veg.size() == veg_cells * veg_cells and veg.count(64) < veg.size() and veg.has(255))
	check("vegetation + thickens plants live (%d -> %d), rocks kept (%d -> %d)" % [counts0["plants"], counts_forest["plants"], counts0["others"], counts_forest["others"]],
		counts_forest["plants"] > counts0["plants"] and counts_forest["others"] == counts0["others"])
	check("vegetation stroke leaves collision alone", plugin._builder.has_pending_collision() == collision_before)
	plugin._toolbar_undo()
	plugin._builder.flush_deferred()
	check("vegetation undo = identical details, no paint stored", _mesh_hash(terrain) == hash_veg0 and _brush_paint(terrain).is_empty())
	plugin._toolbar_redo()
	plugin._builder.flush_deferred()
	check("vegetation redo", veg_counts.call()["plants"] == counts_forest["plants"])
	plugin._toolbar_undo()
	plugin._builder.flush_deferred()
	veg_stroke.call(11, Vector3(-30, 0, -30), 5)
	var counts_clear: Dictionary = veg_counts.call()
	check("vegetation - clears plants (%d -> %d), rocks kept" % [counts0["plants"], counts_clear["plants"]],
		counts_clear["plants"] < counts0["plants"] and counts_clear["others"] == counts0["others"])
	check("vegetation - reaches none", (terrain.get_meta("_lte_cell_vegetation")[""] as PackedByteArray).has(0))
	veg_stroke.call(12, Vector3(-30, 0, -30), 8)
	check("vegetation reset = biome density again", _mesh_hash(terrain) == hash_veg0 and _brush_paint(terrain).is_empty())
	plugin._toolbar_undo()
	plugin._toolbar_undo()
	plugin._builder.flush_deferred()
	# One decor type: the list holds the biome layers; painting Rocks only
	# changes rocks (a layer that ignores "All plants").
	plugin._set_tool(10)
	var veg_select: OptionButton = toolbar.get_vegetation_select()
	var rocks_index := -1
	for i in veg_select.item_count:
		if veg_select.get_item_text(i) == "Rocks":
			rocks_index = i
	check("vegetation list: All plants + biome layers (%d items)" % veg_select.item_count, veg_select.visible and veg_select.get_item_text(0) == "All plants" and rocks_index > 0)
	veg_select.select(rocks_index)
	veg_select.item_selected.emit(rocks_index)
	check("vegetation target picked", plugin._strokes.vegetation_target == "Rocks")
	veg_stroke.call(10, Vector3(20, 0, 20), 5)
	var counts_rocks: Dictionary = veg_counts.call()
	check("painting Rocks adds rocks only (%d -> %d), plants kept" % [counts0["others"], counts_rocks["others"]],
		counts_rocks["others"] > counts0["others"] and counts_rocks["plants"] == counts0["plants"] and _brush_paint(terrain).keys() == ["Rocks"])
	plugin._toolbar_undo()
	plugin._builder.flush_deferred()
	plugin._set_tool(3)
	check("vegetation list stays shown with other tools", veg_select.visible)
	veg_select.select(0)
	veg_select.item_selected.emit(0)
	check("picking a decor type selects the Vegetation tool", plugin._tool == 10 and plugin._strokes.vegetation_target == "")
	check("no tool hint in the toolbar (%s)" % toolbar._status_label.text, not toolbar._status_label.text.contains("drag"))
	plugin._set_tool(0)
	check("vegetation strokes undone", _mesh_hash(terrain) == hash_veg0 and _brush_paint(terrain).is_empty())
	var CanvasScript = load("res://addons/lowpoly_terrain_editor/editing/canvas.gd")
	var veg_small := Node3D.new()
	veg_small.set_meta("_lte_resolution", 5)
	veg_small.set_meta("_lte_world_size", 4.0)
	var veg_m := PackedFloat32Array(); veg_m.resize(25)
	veg_small.set_meta("_lte_mask", veg_m)
	veg_small.set_meta("_lte_heights", veg_m.duplicate())
	var veg_v := PackedByteArray(); veg_v.resize(16); veg_v.fill(64); veg_v[5] = 200
	veg_small.set_meta("_lte_cell_vegetation", {"": veg_v, "Rocks": veg_v})
	CanvasScript.expand(veg_small, 2)
	var veg_v2: PackedByteArray = veg_small.get_meta("_lte_cell_vegetation")["Rocks"]
	check("grow canvas keeps the vegetation paint", veg_v2.size() == 64 and veg_v2[3 * 8 + 3] == 200 and veg_v2.count(64) == 63)
	veg_small.free()
	plugin._toolbar_undo()
	await _frames(2)
	check("undo generate map", int(terrain.get_meta("_lte_resolution")) == res_before_map and not terrain.has_meta("_lte_detail_seed"))

	# Custom Materials: Ground Material / Detail Material of the biome.
	var mat_chunks: Node = terrain.get_node("_GeneratedTerrainChunks")
	var custom_ground := StandardMaterial3D.new()
	var custom_detail := StandardMaterial3D.new()
	var colored_before := _colored_surface_materials(mat_chunks)
	var details_before := _detail_materials(mat_chunks)
	var biome_before: Variant = terrain.get_meta("_lte_biome", null)
	var themed: Resource = TerrainBiomeScript.of(terrain).duplicate()
	themed.set("ground_material", custom_ground)
	themed.set("detail_material", custom_detail)
	terrain.set_meta("_lte_biome", themed)
	plugin._builder.rebuild_all(terrain)
	check("biome ground material on every coloured chunk surface (%d)" % colored_before.size(), colored_before.size() > 0 and _colored_surface_materials(mat_chunks).all(func(m): return m == custom_ground))
	check("biome detail material on every detail node (%d)" % details_before.size(), details_before.size() > 0 and _detail_materials(mat_chunks).all(func(m): return m == custom_detail))
	await _frames(2)
	var material_pickers := EditorInterface.get_base_control().find_children("*", "EditorResourcePicker", true, false).filter(func(p): return p.base_type == "Material")
	check("terrain Inspector: no material slot, they are in the biome (%d)" % material_pickers.size(), material_pickers.is_empty())
	if biome_before == null:
		terrain.remove_meta("_lte_biome")
	else:
		terrain.set_meta("_lte_biome", biome_before)
	plugin._builder.rebuild_all(terrain)
	check("biome without materials: built-in materials back", _colored_surface_materials(mat_chunks) == colored_before and _detail_materials(mat_chunks) == details_before)

	# Customise Road / Water: an editable material put in the biome, undoable.
	var own_biome: Resource = TerrainBiomeScript.of(terrain).duplicate(true)
	terrain.set_meta("_lte_biome", own_biome)
	plugin.customise_feature_material(terrain, false)
	plugin.customise_feature_material(terrain, true)
	var road_mat: Variant = own_biome.get("road_material")
	var water_mat: Variant = own_biome.get("water_material")
	check("Customise Road puts an editable road material in the biome", road_mat is StandardMaterial3D)
	check("Customise Water puts an editable water shader in the biome", water_mat is ShaderMaterial and (water_mat as ShaderMaterial).get_shader_parameter("normal_texture") is NoiseTexture2D)
	plugin._toolbar_undo()
	plugin._toolbar_undo()
	check("undo Customise: biome materials empty again", own_biome.get("road_material") == null and own_biome.get("water_material") == null)
	await _frames(2)
	if biome_before == null:
		terrain.remove_meta("_lte_biome")
	else:
		terrain.set_meta("_lte_biome", biome_before)
	EditorInterface.edit_node(terrain)
	await _frames(2)

	# Step 5: the Level JSON menu is gone; old scenes lose their level path.
	check("no Level menu in the toolbar", toolbar.find_children("*", "MenuButton", true, false).is_empty() and not FileAccess.file_exists("res://addons/lowpoly_terrain_editor/io/level_serializer.gd"))
	terrain.set_meta("_lte_level_path", "res://terrain_levels/old.json")
	load("res://addons/lowpoly_terrain_editor/core/terrain_data.gd").ensure_defaults(terrain)
	check("old Level path removed", not terrain.has_meta("_lte_level_path"))
	EditorInterface.get_selection().clear()
	terrain.get_parent().remove_child(terrain)
	terrain.queue_free()
	plugin._active_terrain = null
	plugin._set_tool(0)
	plugin._update_toolbar_state()
	await _frames(2)

	# Step 1 of the simplicity audit: a new user's first clicks.
	await _frames(3)
	check("no terrain again: tools hidden", not toolbar._terrain_row.visible)
	toolbar.new_terrain_pressed.emit()
	await _frames(3)
	var fresh: Node3D = plugin._active_terrain
	check("terrain: tools shown", toolbar._terrain_row.visible)
	var fresh_list: OptionButton = toolbar.get_ground_select()
	var first_style: Resource = plugin._styles_of(fresh)[0]
	check("new terrain: ground list on the biome's first style (%s)" % fresh_list.get_item_text(fresh_list.selected), fresh_list.selected == 0 and (fresh.get_meta("_lte_brush_top_color") as Color).is_equal_approx(first_style.top_color))
	EditorInterface.inspect_object(fresh)
	await _frames(5)
	var preset_lists := EditorInterface.get_inspector().find_children("*", "OptionButton", true, false).filter(func(o): return o.item_count > 1 and o.get_item_text(o.item_count - 1) == "Custom Recipe...")
	check("Inspector: Map Preset list (%s)" % (preset_lists[0].get_item_text(preset_lists[0].selected) if preset_lists.size() == 1 else "missing"), preset_lists.size() == 1 and preset_lists[0].item_count >= 3 and preset_lists[0].selected < preset_lists[0].item_count - 1)
	check("empty terrain, no recipe", not fresh.has_meta("_lte_map_recipe") and not (fresh.get_meta("_lte_cell_active") as PackedByteArray).has(1))
	plugin.generate_map(fresh)
	await _frames(1)
	check("Generate Map: progress bar while it runs (%s)" % toolbar._status_label.text, toolbar.is_progress_shown() and toolbar._status_label.text.begins_with("Map: "))
	for i in 60:
		if plugin._generating == null:
			break
		await get_tree().process_frame
	check("Generate Map: progress bar gone once done", plugin._generating == null and not toolbar.is_progress_shown())
	check("Generate Map without a recipe uses the default preset", fresh.get_meta("_lte_map_recipe", null) != null and (fresh.get_meta("_lte_cell_active") as PackedByteArray).has(1))
	plugin._update_toolbar_state()
	var summary: String = toolbar._status_label.text
	check("Generate Map summary short and kept (%s)" % summary, summary.begins_with("Map seed ") and summary.length() <= 17 and toolbar._status_label.tooltip_text.contains("waterholes") and toolbar._status_label.mouse_filter != Control.MOUSE_FILTER_IGNORE)
	var tool_mode: GDScript = load("res://addons/lowpoly_terrain_editor/editing/tool_mode.gd")
	check("tool names match the buttons (%s / %s / %s)" % [tool_mode.display_name(2), tool_mode.display_name(3), tool_mode.display_name(4)],
		tool_mode.display_name(2) == "Ground: remove" and tool_mode.display_name(3) == "Relief" and tool_mode.display_name(4) == "Relief: dig")
	# Generate Map grows the biome on the whole map, exactly as Details
	# Everywhere would; ground painted later stays bare.
	plugin._builder.rebuild_all(fresh)
	var generated_count: int = detail_total.call(fresh)
	var generated_hash := _mesh_hash(fresh)
	fresh.set_meta("_lte_details_everywhere", true)
	plugin._builder.rebuild_all(fresh)
	check("Generate Map: details grown, same as everywhere (%d)" % generated_count, generated_count > 0 and _mesh_hash(fresh) == generated_hash)
	fresh.set_meta("_lte_details_everywhere", false)
	var fresh_grow: PackedByteArray = (fresh.get_meta("_lte_cell_vegetation") as Dictionary).get("#grow", PackedByteArray())
	check("Generate Map: grow cells = map cells", fresh_grow == fresh.get_meta("_lte_cell_active"))
	plugin._builder.rebuild_all(fresh)
	var map_style: Resource = plugin._styles_of(fresh)[0]
	check("generated map: brush follows its biome (%s, list %s)" % [map_style.name, fresh_list.get_item_text(fresh_list.selected)], (fresh.get_meta("_lte_brush_top_color") as Color).is_equal_approx(map_style.top_color) and fresh_list.selected == 0)
	plugin._toolbar_undo()
	await _frames(2)
	check("undo: empty terrain without recipe again", not fresh.has_meta("_lte_map_recipe") and not (fresh.get_meta("_lte_cell_active") as PackedByteArray).has(1))

	await _big_map(plugin)

	EditorInterface.set_plugin_enabled("lowpoly_terrain_editor", false)
	await _frames(3)
	check("plugin disabled cleanly", _find(EditorInterface.get_base_control(), "LowpolyTerrainToolbar") == null)
	_finish()

## Vegetation brush strokes of a terrain (without the "#grow" cells of a
## generated map).
func _brush_paint(t: Node3D) -> Dictionary:
	var paint: Dictionary = (t.get_meta("_lte_cell_vegetation", {}) as Dictionary).duplicate()
	paint.erase("#grow")
	return paint

func _colored_surface_materials(root: Node) -> Array:
	var out := []
	for node in root.find_children("*", "MeshInstance3D", true, false):
		var mesh := (node as MeshInstance3D).mesh
		if mesh:
			for surface in mesh.get_surface_count():
				if mesh.surface_get_format(surface) & Mesh.ARRAY_FORMAT_COLOR:
					out.append(mesh.surface_get_material(surface))
	return out

func _detail_materials(root: Node) -> Array:
	var out := []
	for node in root.find_children("*", "MultiMeshInstance3D", true, false):
		out.append((node as MultiMeshInstance3D).material_override)
	return out

func _finish() -> void:
	for line in _log:
		print("SMOKE ", line)
	print("SMOKE_DONE")
	get_tree().quit()

## Phase 3: a 1024-cell map is built around the editor camera (runtime
## editor streaming), edits reach it, nothing generated is saved.
var _big_plugin: Object = null

func _big_map(plugin: Object) -> void:
	_big_plugin = plugin
	var scene_root := EditorInterface.get_edited_scene_root()
	var big := Node3D.new()
	big.name = "BigTerrain"
	scene_root.add_child(big)
	big.owner = scene_root
	load("res://addons/lowpoly_terrain_editor/core/terrain_data.gd").initialize(big)
	# Saved meshes: a big map must switch to Everything at runtime.
	big.set_meta("_lte_runtime_build", 0)
	var recipe: Resource = load("res://addons/lowpoly_terrain_editor/generation/presets/senegal_savanna_map.tres").duplicate()
	recipe.size = 1024
	recipe.cell_size = 1.5
	load("res://addons/lowpoly_terrain_editor/generation/map_generator.gd").generate(big, recipe, 7)
	var t0 := Time.get_ticks_msec()
	plugin._edit(big)
	var edit_ms := Time.get_ticks_msec() - t0
	var runtime: Node = big.get_node_or_null("_LowpolyTerrainRuntime")
	check("big map: streamed in the editor (select took %d ms)" % edit_ms, runtime != null and runtime.is_editor_streaming() and edit_ms < 3000)
	if runtime == null or not runtime.is_editor_streaming():
		return
	check("big map: Runtime Build = Everything, stream_ground on", int(big.get_meta("_lte_runtime_build")) == 2 and runtime.stream_ground)
	var big_toolbar: Object = plugin._toolbar
	await _frames(2)
	check("big map: loading progress shown (%s)" % big_toolbar._status_label.text, big_toolbar.is_progress_shown() and big_toolbar._status_label.text.begins_with("Loading"))
	var ready_ms := -1
	for i in 3000:
		if runtime.is_ground_ready and ready_ms < 0:
			ready_ms = Time.get_ticks_msec() - t0
		if runtime.is_finished:
			break
		await get_tree().process_frame
	print("SMOKE INFO big map: ground ready %d ms, finished %d ms" % [ready_ms, Time.get_ticks_msec() - t0])
	check("big map: finished loading", runtime.is_finished)
	check("big map: progress bar gone once loaded", not big_toolbar.is_progress_shown())
	await _wait_idle(runtime)
	var count: int = TerrainMesherRef.chunk_count(big)
	var chunk_nodes: Array = big.get_node("_GeneratedTerrainChunks").get_children()
	check("big map: only the chunks near the camera (%d of %d)" % [chunk_nodes.size(), count * count], chunk_nodes.size() > 0 and chunk_nodes.size() < count * count / 4)
	var far_root := big.get_node_or_null("_FarGround")
	check("big map: far blocks (%d)" % (far_root.get_child_count() if far_root else 0), far_root != null and far_root.get_child_count() > 0)
	var saved := 0
	for node in big.find_children("*", "", true, false):
		if node.owner != null and node != runtime:
			saved += 1
	check("big map: nothing generated saved (%d owned)" % saved, saved == 0 or _only_feature_node_saved(big, runtime))
	check("big map: every chunk shown once", _coverage(runtime, big) == 0)

	# A Relief stroke where the camera looks: its chunk rebuilt at once.
	var focus: Vector2 = runtime._ground_focus
	var centre := Vector2i(int(floor((focus.x + runtime._half) / runtime._chunk_world)), int(floor((focus.y + runtime._half) / runtime._chunk_world)))
	var centre_chunk: MeshInstance3D = TerrainMesherRef.find_chunk(big, centre.x, centre.y)
	var before := _faces_hash(centre_chunk)
	plugin._strokes.mode = 3
	plugin._strokes.brush_radius = 6.0
	plugin._strokes.begin(big, Vector3(focus.x, 0, focus.y))
	plugin._strokes.update(big, Vector3(focus.x + 3, 0, focus.y + 2))
	plugin._strokes.end(big)
	var after := _faces_hash(TerrainMesherRef.find_chunk(big, centre.x, centre.y))
	check("big map: stroke rebuilt its chunk at once", after != before)
	await _wait_idle(runtime)
	check("big map: after the stroke, far blocks redone and every chunk shown once", runtime._far_dirty.is_empty() and runtime._stale.is_empty() and _coverage(runtime, big) == 0)
	plugin._toolbar_undo()
	await _wait_idle(runtime)
	check("big map: undo restores the chunk", _faces_hash(TerrainMesherRef.find_chunk(big, centre.x, centre.y)) == before)

	# Data changed under a far block (Undo of an edit made elsewhere): the
	# block is made again from the new heights.
	var far_chunk := Vector2i(-1, -1)
	for block: Vector2i in runtime._far_blocks:
		var mask: int = runtime._far_masks[block]
		if mask == 0:
			far_chunk = block * 4 + Vector2i(1, 1)
			break
	check("big map: a far block without detailed chunks", far_chunk.x >= 0)
	if far_chunk.x >= 0:
		var block_node: MeshInstance3D = runtime._far_blocks[far_chunk / 4]
		var block_before := _faces_hash(block_node)
		var heights: PackedFloat32Array = big.get_meta("_lte_heights")
		var original := heights.duplicate()
		var resolution: int = big.get_meta("_lte_resolution")
		for z in range(far_chunk.y * 32, far_chunk.y * 32 + 33):
			for x in range(far_chunk.x * 32, far_chunk.x * 32 + 33):
				heights[z * resolution + x] += 3.0
		big.set_meta("_lte_heights", heights)
		var spacing: float = float(big.get_meta("_lte_world_size")) / float(resolution - 1)
		var half: float = float(big.get_meta("_lte_world_size")) * 0.5
		var rect := Rect2(far_chunk.x * 32 * spacing - half, far_chunk.y * 32 * spacing - half, 32 * spacing, 32 * spacing)
		plugin._builder.rebuild_area(big, rect, {"details": false})
		await _wait_idle(runtime)
		var block_after := _faces_hash(runtime._far_blocks.get(far_chunk / 4))
		check("big map: far block redone after its data changed", block_after != block_before and _coverage(runtime, big) == 0)
		big.set_meta("_lte_heights", original)
		plugin._builder.rebuild_area(big, rect, {"details": false})
		await _wait_idle(runtime)
		check("big map: far block back", _faces_hash(runtime._far_blocks.get(far_chunk / 4)) == block_before)

	# A waterhole placed where the camera looks: its plates come.
	var holes_before: int = (big.get_meta("_lte_waterholes", []) as Array).size()
	plugin._strokes.mode = 9
	plugin._strokes.brush_radius = 5.0
	plugin._strokes.begin(big, Vector3(focus.x - 20, 0, focus.y - 20))
	plugin._strokes.end(big)
	var holes_after: int = (big.get_meta("_lte_waterholes", []) as Array).size()
	await _wait_idle(runtime)
	var plates := big.get_node_or_null("_GeneratedWaterholes/Waterhole_%d" % (holes_after - 1)) as MeshInstance3D
	check("big map: new waterhole built (%d -> %d)" % [holes_before, holes_after], holes_after == holes_before + 1 and plates != null and plates.mesh != null)
	plugin._toolbar_undo()
	await _wait_idle(runtime)
	check("big map: undo removes its plates", big.get_node_or_null("_GeneratedWaterholes/Waterhole_%d" % (holes_after - 1)) == null)
	plugin._strokes.mode = 1

	# Back to a small map: built whole again.
	recipe.size = 128
	load("res://addons/lowpoly_terrain_editor/generation/map_generator.gd").generate(big, recipe, 7)
	plugin._rebuild_all(big)
	var small_count: int = TerrainMesherRef.chunk_count(big)
	check("small again: built whole (%d chunks), streaming stopped" % big.get_node("_GeneratedTerrainChunks").get_child_count(), not runtime.is_editor_streaming() and big.get_node("_GeneratedTerrainChunks").get_child_count() == small_count * small_count and big.get_node_or_null("_FarGround") == null)
	scene_root.remove_child(big)
	big.free()

## Roads / rivers node: the plugin keeps it in the scene file (empty mesh
## when built at runtime), as for any terrain.
func _only_feature_node_saved(terrain: Node3D, runtime: Node) -> bool:
	for node in terrain.find_children("*", "", true, false):
		if node.owner != null and node != runtime and node.name != "_GeneratedTerrainMesh":
			print("SMOKE INFO saved: %s" % terrain.get_path_to(node))
			return false
	return true

func _wait_idle(runtime: Node) -> void:
	for i in 1200:
		await get_tree().process_frame
		if _big_plugin._builder.has_deferred():
			continue
		if runtime.is_finished and runtime.is_streaming_idle and runtime._ground_tasks.is_empty() and runtime._far_queue.is_empty() and runtime._stale.is_empty() and runtime._far_dirty.is_empty() and runtime._retarget_in > 0.0 and i > 10:
			return

func _faces_hash(node: MeshInstance3D) -> int:
	if node == null or node.mesh == null:
		return 0
	return hash(node.mesh.get_faces())

func _coverage(runtime: Node, terrain: Node3D) -> int:
	var errors := 0
	var count: int = TerrainMesherRef.chunk_count(terrain)
	for z in count:
		for x in count:
			var chunk: MeshInstance3D = TerrainMesherRef.find_chunk(terrain, x, z)
			var detailed := chunk != null and not chunk.is_queued_for_deletion() and chunk.visible
			var block := Vector2i(x / 4, z / 4)
			var far := false
			if runtime._far_blocks.has(block):
				var mask: int = runtime._far_masks[block]
				far = (mask & (1 << ((z % 4) * 4 + x % 4))) == 0
			var shown := int(detailed) + int(far)
			var distance: float = runtime._chunk_distance(Vector2i(x, z), runtime._ground_focus)
			if shown > 1 or (shown == 0 and distance <= runtime.far_distance):
				errors += 1
				if errors <= 3:
					print("SMOKE INFO chunk %s shown %d times (%.0f m)" % [Vector2i(x, z), shown, distance])
	return errors
