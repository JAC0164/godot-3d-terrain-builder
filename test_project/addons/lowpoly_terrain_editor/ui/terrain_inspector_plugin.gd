@tool
extends EditorInspectorPlugin
## Custom "LowPoly Terrain" panel shown in the Inspector for terrain nodes.
##
## Most controls write terrain metadata directly. Settings that need a mesh
## rebuild or Undo/Redo go through `host` (the EditorPlugin), which must
## provide: set_tuning_setting(terrain, key, value), grow_canvas(terrain),
## generate_from_image(terrain), set_biome(terrain, biome),
## copy_biome_to_terrain(terrain), biome_is_shared(terrain), create_biome(terrain),
## use_ground_style(terrain, style), generate_map(terrain), get_map_presets()
## and default_map_recipe(terrain).

const Meta = preload("../core/terrain_meta.gd")
const TerrainData = preload("../core/terrain_data.gd")
const MaterialFactory = preload("../materials/material_factory.gd")
const TerrainBiome = preload("../biomes/terrain_biome.gd")
const GroundStyle = preload("../biomes/ground_style.gd")
const StylePalette = preload("../styles/style_palette.gd")
const DetailCollision = preload("../mesh/detail_collision.gd")
const WaterholeStyle = preload("../styles/waterhole_style.gd")
const MapPresets = preload("../generation/map_presets.gd")
const ToolMode = preload("../editing/tool_mode.gd")
const LowpolyTerrainPlugin = preload("../plugin.gd")


var host: LowpolyTerrainPlugin
## Remembers foldout states across Inspector rebuilds (keyed by title).
var _foldout_states: Dictionary = {}

func _init(p_host: LowpolyTerrainPlugin) -> void:
	host = p_host

func _can_handle(object: Object) -> bool:
	return Meta.is_terrain(object)

func _parse_begin(object: Object) -> void:
	var terrain := object as Node3D
	TerrainData.ensure_defaults(terrain)

	var panel := VBoxContainer.new()
	panel.name = "LowPoly Terrain"

	_add_category(panel, "LowPoly Terrain")

	# Four short sections in the order of a first map, then everything else
	# in a closed "Advanced". No paragraphs: every explanation is a tooltip
	# (on the section titles too).
	_build_map_section(panel, terrain)
	_build_look_section(panel, terrain)
	_build_features_section(panel, terrain)
	_build_game_section(panel, terrain)
	_build_advanced_section(panel, terrain)

	_make_shrinkable(panel)
	add_custom_control(panel)

## Godot never shortens text by default: every label, button and check box
## kept its full text width, so the panel needed ~370 px and the Inspector
## dock could not be made narrower than that (Godot's own panels go down to
## ~150 px). Long texts are cut with "..." instead; the full text stays in
## the tooltip. Wrapped help texts already shrink.
func _make_shrinkable(node: Node) -> void:
	if node is Button:
		var button := node as Button
		button.clip_text = true
		button.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if button.tooltip_text.is_empty() and not button.text.is_empty() and not button.flat:
			button.tooltip_text = button.text
		if button is OptionButton:
			# Otherwise sized to its longest item.
			(button as OptionButton).fit_to_longest_item = false
	elif node is Label and (node as Label).autowrap_mode == TextServer.AUTOWRAP_OFF:
		var label := node as Label
		label.clip_text = true
		label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		if label.tooltip_text.is_empty():
			label.tooltip_text = label.text
		# Keep a few letters readable.
		label.custom_minimum_size.x = maxf(label.custom_minimum_size.x, 48.0)
	for child in node.get_children():
		_make_shrinkable(child)

# -----------------------------------------------------------------------------
# Setting writers
# -----------------------------------------------------------------------------

## Geometry-affecting setting: rebuilds meshes through the plugin.
func _tuning_setter(terrain: Node3D, key: String, as_int: bool = false) -> Callable:
	return func(value: Variant) -> void:
		var setting: Variant = value
		if as_int:
			var int_value: int = value
			setting = int_value
		host.set_tuning_setting(terrain, key, setting)

## Canvas setting: refreshes the Inspector.
func _canvas_setter(terrain: Node3D, key: String) -> Callable:
	return func(value: Variant) -> void:
		if not is_instance_valid(terrain):
			return
		var int_value: int = value
		terrain.set_meta(key, int_value)
		terrain.notify_property_list_changed()
		EditorInterface.mark_scene_as_unsaved()

## Brush / generator / feature setting: only read when painting, drawing or
## generating, so existing geometry is not restyled and the Inspector is not
## rebuilt (which would disturb the UI state while picking colours).
func _plain_setter(terrain: Node3D, key: String, refresh_inspector: bool = false) -> Callable:
	return func(value: Variant) -> void:
		if not is_instance_valid(terrain):
			return
		Meta.set_optional(terrain, key, value)
		if refresh_inspector:
			terrain.notify_property_list_changed()

# -----------------------------------------------------------------------------
# Sections
# -----------------------------------------------------------------------------

## Map: preset + seed + Generate, and the terrain size.
func _build_map_section(panel: VBoxContainer, terrain: Node3D) -> void:
	var section := _add_section(panel, "Map", true,
		"Generate a whole map (relief, plateaus, lowlands, ground patches, tracks, waterholes) from a preset and a seed. "
		+ "Same preset + seed = same map. You can then edit it by hand with the toolbar tools.")
	_add_map_preset_row(section, terrain)
	_add_int_row(section, terrain, "Map Seed", Meta.MAP_SEED, 0, 999999, 0, "Seed of the generated map: change it for another map of the same kind.", func(value: float) -> void:
		if is_instance_valid(terrain):
			terrain.set_meta(Meta.MAP_SEED, int(value)))
	_add_button(section, "Generate Map", "Replace this terrain by the map of the preset + seed (Ctrl+Z restores the previous terrain).",
		func() -> void: host.generate_map(terrain))
	_add_button(section, "Random Seed + Generate", "Pick a new seed and generate.", func() -> void: host.generate_random_map(terrain))

	var resolution: int = Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var world_size: float = Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE)
	var spacing: float = world_size / maxf(float(resolution - 1), 1.0)
	_add_value_row(section, "Terrain Size", "%d x %d m" % [roundi(world_size), roundi(world_size)],
		"%d x %d cells of %.2f m. Add ground near the edge to grow it (Advanced > Terrain Size)." % [resolution - 1, resolution - 1, spacing])

## "Map Preset" list: the presets of generation/presets/ by name, then
## "Custom Recipe..." which shows a picker for your own recipe. With no recipe
## assigned the default preset is shown, the one Generate Map then uses.
func _add_map_preset_row(section: VBoxContainer, terrain: Node3D) -> void:
	var tooltip := "Ready-made maps. Custom Recipe...: your own map recipe file (duplicate a preset to tune it for your game)."
	var row := _add_row(section, "Map Preset", tooltip)
	var option := OptionButton.new()
	option.tooltip_text = tooltip
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(option)

	var presets: Array[Resource] = host.get_map_presets()
	var current_object: Object = Meta.get_optional(terrain, Meta.MAP_RECIPE)
	var current := current_object as Resource
	var shown: Resource = current if current != null else host.default_map_recipe(terrain)
	var custom := shown == null or not MapPresets.is_preset(shown, presets)
	for recipe in presets:
		var recipe_name: String = recipe.get("name")
		option.add_item(recipe_name)
		if not custom and recipe.resource_path == shown.resource_path:
			option.select(option.item_count - 1)
	option.add_item("Custom Recipe...")
	var custom_index := option.item_count - 1
	if custom:
		option.select(custom_index)

	var recipe_row := _add_row(section, "Recipe", tooltip)
	recipe_row.visible = custom
	var picker := EditorResourcePicker.new()
	picker.base_type = "LowpolyMapRecipe"
	picker.edited_resource = current
	picker.tooltip_text = tooltip
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.resource_changed.connect(_plain_setter(terrain, Meta.MAP_RECIPE))
	# Deferred: switching the Inspector frees this panel.
	picker.resource_selected.connect(func(resource: Resource, _inspect: bool) -> void: EditorInterface.edit_resource.call_deferred(resource))
	recipe_row.add_child(picker)

	option.item_selected.connect(func(index: int) -> void:
		if not is_instance_valid(terrain):
			return
		recipe_row.visible = index == custom_index
		if index != custom_index:
			Meta.set_optional(terrain, Meta.MAP_RECIPE, presets[index])
			picker.edited_resource = presets[index])

## Look: the biome (the terrain's theme: ground styles, shading, what grows,
## materials and ambience), details on / off and smooth ground.
func _build_look_section(panel: VBoxContainer, terrain: Node3D) -> void:
	var section := _add_section(panel, "Look", false,
		"How the terrain looks. Its biome is its theme: ground styles, shading, what grows, your own materials and the ambience. The ground style to paint is picked in the list next to the Ground tool.")
	var biome_object: Object = Meta.get_optional(terrain, Meta.BIOME)
	var biome := biome_object as Resource
	var shown: TerrainBiome = biome if biome != null else TerrainBiome.default_biome()

	var layer_names: PackedStringArray = []
	for layer in shown.detail_layers:
		if layer != null:
			layer_names.append(layer.name if layer.enabled else "%s (off)" % layer.name)
	var style_names: PackedStringArray = []
	for style in shown.ground_styles:
		if style != null:
			style_names.append(style.name)
	var biome_tip := ("The terrain's theme: ground styles, shading, waterhole colors, what grows on it, your own ground / detail / road / water materials and the ambience (Environment). Empty = built-in Temperate. "
		+ "Edit it in its own Inspector: the terrain updates at once, cells painted with a ground style follow it.\nGround styles (list next to the Ground tool): %s.\nWhat grows: %s." % [
			", ".join(style_names) if not style_names.is_empty() else "none", ", ".join(layer_names) if not layer_names.is_empty() else "nothing"])
	var biome_row := _add_row(section, "Biome", biome_tip)
	var picker := EditorResourcePicker.new()
	picker.base_type = "LowpolyTerrainBiome"
	picker.edited_resource = biome
	picker.tooltip_text = biome_tip
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.resource_changed.connect(func(resource: Resource) -> void: host.set_biome(terrain, resource))
	# Deferred: switching the Inspector frees this panel.
	picker.resource_selected.connect(func(resource: Resource, _inspect: bool) -> void: EditorInterface.edit_resource.call_deferred(resource))
	biome_row.add_child(picker)

	if biome == null:
		_add_button(section, "Create Editable Biome", "Put an editable copy of the built-in Temperate biome in this terrain (save it as a .tres from its Inspector to reuse it).",
			func() -> void: host.create_biome(terrain))
	else:
		var shared: bool = host.biome_is_shared(terrain)
		_add_button(section, "Edit Biome", _edit_biome_tip(shared), func() -> void: EditorInterface.edit_resource.call_deferred(biome))
		if shared:
			_add_button(section, "Copy Biome to This Terrain",
				"Give this terrain its own copy of %s, stored in the scene: edit it without changing the other terrains. Same look until you edit it. Ctrl+Z undoes it." % biome.resource_path.get_file(),
				func() -> void: host.copy_biome_to_terrain(terrain))

	_add_checkbox(section, "Show Details", "Grass, trees, rocks and props of the biome.",
		Meta.get_bool(terrain, Meta.DETAIL_ENABLED, Meta.DEFAULT_DETAIL_ENABLED), _tuning_setter(terrain, Meta.DETAIL_ENABLED))
	_add_button(section, "Replace Details",
		"Put the grass, rocks, trees and props on the ground as it is now. Painting and sculpting shape the ground only and leave them where they are: use this once the ground is done. The game builds them on the current ground anyway when Runtime Build rebuilds the details.",
		func() -> void: host.replace_details(terrain))
	_add_float_row(section, terrain, "Detail Density", Meta.DETAIL_DENSITY, 0.0, 4.0, 0.05, Meta.DEFAULT_DETAIL_DENSITY, "Multiplies how much grows (1 = as in the biome). Lower it for low-end phones.", _tuning_setter(terrain, Meta.DETAIL_DENSITY))
	_add_checkbox(section, "Smooth Ground",
		"Ground shaded smoothly: no visible triangle pattern. Off = faceted low-poly ground. Same cost either way; cliffs stay faceted. Up close, give the ground styles textures, or your own Ground Material (biome).",
		Meta.get_bool(terrain, Meta.SHADE_SMOOTH, Meta.DEFAULT_SHADE_SMOOTH), _tuning_setter(terrain, Meta.SHADE_SMOOTH))
	_add_float_row(section, terrain, "Ground Bumps", Meta.GROUND_BUMPS, 0.0, 2.0, 0.05, Meta.DEFAULT_GROUND_BUMPS,
		"Small bumps of about this height (m) all over the ground, so faceted ground catches the light (0 = flat). "
		+ "Written in the heights: collision, details, roads and rivers follow, the Relief tools work on top. Ctrl+Z undoes it.",
		func(value: float) -> void: host.set_ground_bumps(terrain, value))

## Roads, rivers and waterholes: what the toolbar tools draw next.
func _build_features_section(panel: VBoxContainer, terrain: Node3D) -> void:
	var section := _add_section(panel, "Roads, Rivers & Waterholes", false,
		"Shape of the next road, river or waterhole drawn with the toolbar tools; Ctrl+drag with Ground removes them. Their look (colors, materials) is the biome's.")
	_add_float_row(section, terrain, "Road Width", Meta.ROAD_WIDTH, ToolMode.FEATURE_WIDTH_MIN, ToolMode.FEATURE_WIDTH_MAX, ToolMode.FEATURE_WIDTH_STEP, Meta.DEFAULT_ROAD_WIDTH, "Width of the next road (also the Size field of the Road tool).", _plain_setter(terrain, Meta.ROAD_WIDTH))
	_add_float_row(section, terrain, "River Width", Meta.RIVER_WIDTH, ToolMode.FEATURE_WIDTH_MIN, ToolMode.FEATURE_WIDTH_MAX, ToolMode.FEATURE_WIDTH_STEP, Meta.DEFAULT_RIVER_WIDTH, "Width of the next river and of its bed (also the Size field of the River tool).", _plain_setter(terrain, Meta.RIVER_WIDTH))
	_add_float_row(section, terrain, "River Depth", Meta.RIVER_DEPTH, 0.0, 8.0, 0.05, Meta.DEFAULT_RIVER_DEPTH, "How deep the river bed is dug.", _plain_setter(terrain, Meta.RIVER_DEPTH))
	_add_float_row(section, terrain, "Water Level Drop", Meta.RIVER_SURFACE_DROP, -1.0, 4.0, 0.01, Meta.DEFAULT_RIVER_SURFACE_DROP, "How far below the ground around it the water surface of the next river is.", _plain_setter(terrain, Meta.RIVER_SURFACE_DROP))
	_add_button(section, "Customise Road", "Put an editable road material in the biome (Road Material) and open it: texture, color, roughness... Every road follows it.",
		func() -> void: host.customise_feature_material(terrain, false))
	_add_button(section, "Customise Water", "Put an editable copy of the built-in water in the biome (Water Material) and open it: color, waves, flow, refraction... Every river follows it.",
		func() -> void: host.customise_feature_material(terrain, true))

	var w := func(field: String) -> String: return WaterholeStyle.setting_key(field)
	var d: Dictionary = WaterholeStyle.DEFAULTS
	var depth_key: String = w.call("depth")
	var depth_default: float = d["depth"]
	var plate_size_key: String = w.call("plate_size")
	var plate_size_default: float = d["plate_size"]
	_add_float_row(section, terrain, "Waterhole Depth", depth_key, 0.0, 4.0, 0.05, depth_default, "Depth of the next waterhole below the ground around it. Its size is the brush Size.", _plain_setter(terrain, depth_key))
	_add_float_row(section, terrain, "Mud Plate Size", plate_size_key, 0.15, 4.0, 0.05, plate_size_default, "Average size of the cracked mud plates. Smaller = more triangles.", _plain_setter(terrain, plate_size_key))
	var count := WaterholeStyle.list(terrain).size()
	var on_terrain := "no waterhole yet" if count == 0 else ("1 waterhole" if count == 1 else "%d waterholes" % count)
	_add_button(section, "Apply to Existing Waterholes",
		"Give the waterholes already on this terrain (%s) the settings above and those of Advanced > Waterhole Shape. They keep their place, size and cracks. Ctrl+Z undoes it." % on_terrain,
		func() -> void: host.apply_waterhole_settings(terrain))

## Game: what matters once the scene runs (collision, file size, performance).
func _build_game_section(panel: VBoxContainer, terrain: Node3D) -> void:
	var section := _add_section(panel, "Game", false, "What matters in the game: collision, scene size and loading, performance.")
	var trees := "Trees with a Collision Radius (biome layers) get trunk collision in the game." if DetailCollision.has_collision_layers(terrain) \
		else "No biome layer has a Collision Radius yet: trees have no collision."
	_add_checkbox(section, "Walkable Collision", "Collision for the ground and cliffs, built from the visible terrain. " + trees,
		Meta.get_bool(terrain, Meta.COLLISION_ENABLED, false), _tuning_setter(terrain, Meta.COLLISION_ENABLED))
	_add_int_row(section, terrain, "Collision Layer", Meta.COLLISION_LAYER, 1, 32, 1, "Physics layer of the terrain collision.", _tuning_setter(terrain, Meta.COLLISION_LAYER, true))
	_add_checkbox(section, "Road Collision", "Roads drawn next are part of the walkable collision.",
		Meta.get_bool(terrain, Meta.ROAD_COLLISION, true), _plain_setter(terrain, Meta.ROAD_COLLISION))
	_add_checkbox(section, "Water Surface Collision", "Characters walk on the water surface of the rivers drawn next instead of their bed. Off for most games.",
		Meta.get_bool(terrain, Meta.RIVER_COLLISION, false), _plain_setter(terrain, Meta.RIVER_COLLISION))
	_add_button(section, "Bake Navigation",
		"Make the navigation mesh of the walkable ground for NavigationAgent3D: a NavigationRegion3D child named Navigation (added the first time). Empty cells, cliffs and river beds are left out; trunks with collision are obstacles. Bake again after editing the ground; in game, LowpolyTerrainRuntime.bake_navigation() rebakes around the player.",
		func() -> void: host.bake_navigation(terrain))

	var row := _add_row(section, "Runtime Build", "")
	var option := OptionButton.new()
	option.add_item("Save everything", Meta.RUNTIME_BUILD_NOTHING)
	option.add_item("Details at runtime", Meta.RUNTIME_BUILD_DETAILS)
	option.add_item("All at runtime", Meta.RUNTIME_BUILD_ALL)
	option.select(option.get_item_index(Meta.get_int(terrain, Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_NOTHING)))
	option.tooltip_text = ("What the scene file stores.\nSave everything: biggest file, fastest loading.\n"
		+ "Details at runtime: grass, trees and props are rebuilt when the scene loads (much smaller file).\n"
		+ "All at runtime: only the terrain data is saved, the rest is rebuilt when the scene loads, nearest first (smallest file, longer loading).\n"
		+ "Tip: save big maps as .scn instead of .tscn: about 5x smaller and 10x faster to open.")
	var row_label: Label = row.get_child(0)
	row_label.tooltip_text = option.tooltip_text
	# Half the row: "Everything at runtime" was cut to "Every" at 90 px.
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	option.item_selected.connect(func(index: int) -> void: host.set_runtime_build(terrain, option.get_item_id(index)))
	row.add_child(option)

	_add_float_row(section, terrain, "Detail Draw Distance", Meta.DETAIL_DRAW_DISTANCE, 0.0, 1000.0, 5.0, Meta.DEFAULT_DETAIL_DRAW_DISTANCE, "Grass, trees and props are hidden beyond this distance from the camera (0 = always shown; a biome layer can set its own). Lower is cheaper on mobile.", _tuning_setter(terrain, Meta.DETAIL_DRAW_DISTANCE))
	_add_checkbox(section, "Mobile Water (No Refraction)", "Water without refraction on every river of this terrain: much cheaper. Phones always get it (the refraction costs ~8 ms per frame there); tick it to see the same water on a computer, or for the Compatibility renderer.",
		Meta.get_bool(terrain, Meta.RIVER_MOBILE_WATER, false), _tuning_setter(terrain, Meta.RIVER_MOBILE_WATER))
	_add_checkbox(section, "Ground Casts Shadows", "Hills cast sun shadows on the ground around them. Off = cheaper on phones (fewer shadow triangles to draw); trees, rocks and props keep their shadows, the side of a hill away from the sun stays darker.",
		Meta.get_bool(terrain, Meta.GROUND_SHADOWS, true), func(enabled: bool) -> void: host.set_ground_shadows(terrain, enabled))
	_add_int_row(section, terrain, "Detail Seed", Meta.DETAIL_SEED, 0, 999999, 0, "Another placement of the same grass, trees and props on the same ground (Generate Map sets it to the map seed).", _tuning_setter(terrain, Meta.DETAIL_SEED, true))

## Advanced (closed): everything a first map does not need.
func _build_advanced_section(panel: VBoxContainer, terrain: Node3D) -> void:
	var advanced := _add_section(panel, "Advanced", false, "Fine tuning and rare settings. A first map needs none of them.")
	_build_size_section(advanced, terrain)
	_build_heights_section(advanced, terrain)
	_build_custom_style_section(advanced, terrain)
	_build_waterhole_shape_section(advanced, terrain)
	_build_advanced_details_section(advanced, terrain)
	_build_pixel_map_section(advanced, terrain)

func _build_size_section(parent: VBoxContainer, terrain: Node3D) -> void:
	var section := _add_section(parent, "Terrain Size", false, "The terrain grows by itself when you paint near its edge.")
	_add_checkbox(section, "Grow While Painting", "Grow the terrain when the Ground tool gets close to its edge.",
		Meta.get_bool(terrain, Meta.AUTO_EXPAND, true), func(enabled: bool) -> void:
			if is_instance_valid(terrain):
				terrain.set_meta(Meta.AUTO_EXPAND, enabled)
				terrain.notify_property_list_changed()
	)
	_add_int_row(section, terrain, "Maximum Cells", Meta.MAX_RESOLUTION, 64, 1024, Meta.DEFAULT_MAX_RESOLUTION, "The terrain never grows beyond this many cells per side.", _canvas_setter(terrain, Meta.MAX_RESOLUTION))
	_add_button(section, "Grow Terrain", "Grow the terrain by a few cells on every side.", func() -> void:
		host.grow_canvas(terrain)
	)
	_add_button(section, "Import Heightmap", "Heights from an EXR (metres), a PNG (8 or 16 bit) or a .r16 / .raw file, resized to the terrain. A PNG / raw spans the range of the .json beside it, else the current lowest to highest ground. Ctrl+Z undoes it.", func() -> void:
		host.import_heightmap(terrain)
	)
	_add_button(section, "Export Heightmap", "Write the heights as <name>.exr (metres), <name>.png (16-bit, lowest = black, highest = white) and <name>.json (that range), to shape them in another tool.", func() -> void:
		host.export_heightmap(terrain)
	)

func _build_heights_section(parent: VBoxContainer, terrain: Node3D) -> void:
	var section := _add_section(parent, "Heights & Offsets", false,
		"How high and how deep the ground can go.")
	_add_float_row(section, terrain, "Highest Ground", Meta.HEIGHT_MAX, 0.0, 128.0, 0.1, Meta.DEFAULT_HEIGHT_MAX, "Highest height the ground can be raised to (Relief tool, generated hills).", _tuning_setter(terrain, Meta.HEIGHT_MAX))
	_add_float_row(section, terrain, "Lowest Ground", Meta.HEIGHT_MIN, -128.0, 0.0, 0.1, Meta.DEFAULT_HEIGHT_MIN, "Lowest height the ground can be dug to (Relief tool with Ctrl, generated dips). Keep it above Cliff Bottom.", _tuning_setter(terrain, Meta.HEIGHT_MIN))
	_add_float_row(section, terrain, "Cliff Bottom", Meta.BASE_Y, -32.0, 8.0, 0.05, Meta.DEFAULT_BASE_Y, "Height of the bottom of the cliffs around the terrain.", _tuning_setter(terrain, Meta.BASE_Y))

func _build_custom_style_section(parent: VBoxContainer, terrain: Node3D) -> void:
	var section := _add_section(parent, "Custom Ground Style", false,
		"The colors / textures the Ground tool paints now. Picking a ground style (list next to the Ground tool) fills them in; change them here for a style of your own (the list then shows Custom).")
	_add_color_row(section, terrain, "Top Color", Meta.BRUSH_TOP_COLOR, Meta.DEFAULT_TOP_COLOR, "Color of the ground painted next (when Top Texture is empty).", _plain_setter(terrain, Meta.BRUSH_TOP_COLOR))
	_add_color_row(section, terrain, "Side Color", Meta.BRUSH_CLIFF_COLOR, Meta.DEFAULT_CLIFF_COLOR, "Color of the cliffs painted next (when Side Texture is empty).", _plain_setter(terrain, Meta.BRUSH_CLIFF_COLOR))
	_add_texture_row(section, terrain, "Top Texture", Meta.BRUSH_TOP_TEXTURE, "Optional repeating texture of the ground painted next.", _plain_setter(terrain, Meta.BRUSH_TOP_TEXTURE))
	_add_float_row(section, terrain, "Top Texture Tile Size", Meta.BRUSH_TOP_TILE_SIZE, 0.1, 64.0, 0.1, Meta.DEFAULT_TILE_SIZE, "Size (m) of one repeat of the top texture.", _plain_setter(terrain, Meta.BRUSH_TOP_TILE_SIZE))
	_add_texture_row(section, terrain, "Side Texture", Meta.BRUSH_CLIFF_TEXTURE, "Optional repeating texture of the cliffs painted next.", _plain_setter(terrain, Meta.BRUSH_CLIFF_TEXTURE))
	_add_float_row(section, terrain, "Side Texture Tile Size", Meta.BRUSH_CLIFF_TILE_SIZE, 0.1, 64.0, 0.1, Meta.DEFAULT_TILE_SIZE, "Size (m) of one repeat of the side texture.", _plain_setter(terrain, Meta.BRUSH_CLIFF_TILE_SIZE))

func _build_waterhole_shape_section(parent: VBoxContainer, terrain: Node3D) -> void:
	var section := _add_section(parent, "Waterhole Shape", false,
		"Shape of the next waterholes (Apply to Existing Waterholes gives it to those already placed). Biome layers choose where they grow around them (Waterhole Zone).")
	var w := func(field: String) -> String: return WaterholeStyle.setting_key(field)
	var d: Dictionary = WaterholeStyle.DEFAULTS
	var floor_key: String = w.call("floor")
	var floor_default: float = d["floor"]
	var irregularity_key: String = w.call("irregularity")
	var irregularity_default: float = d["irregularity"]
	var rim_key: String = w.call("rim")
	var rim_default: float = d["rim"]
	var lip_key: String = w.call("lip")
	var lip_default: float = d["lip"]
	var crack_width_key: String = w.call("crack_width")
	var crack_width_default: float = d["crack_width"]
	var curl_key: String = w.call("curl")
	var curl_default: float = d["curl"]
	_add_float_row(section, terrain, "Flat Floor", floor_key, 0.0, 0.95, 0.01, floor_default, "Part of the radius that is flat cracked floor; the rest is the bank.", _plain_setter(terrain, floor_key))
	_add_float_row(section, terrain, "Irregularity", irregularity_key, 0.0, 0.6, 0.01, irregularity_default, "How far the outline wobbles away from a circle.", _plain_setter(terrain, irregularity_key))
	_add_float_row(section, terrain, "Rim Width", rim_key, 0.01, 2.0, 0.01, rim_default, "Width of the trampled clay ring around the basin, as a part of the radius.", _plain_setter(terrain, rim_key))
	_add_float_row(section, terrain, "Rim Lip", lip_key, 0.0, 1.0, 0.01, lip_default, "Height of the small earth bank around the basin.", _plain_setter(terrain, lip_key))
	_add_float_row(section, terrain, "Crack Width", crack_width_key, 0.0, 1.0, 0.01, crack_width_default, "Average width of the cracks between mud plates.", _plain_setter(terrain, crack_width_key))
	_add_float_row(section, terrain, "Plate Curl", curl_key, 0.0, 0.5, 0.01, curl_default, "How much the plate edges curl up as the mud dries.", _plain_setter(terrain, curl_key))

func _build_advanced_details_section(parent: VBoxContainer, terrain: Node3D) -> void:
	var section := _add_section(parent, "Details", false, "Grass, trees, rocks and props of the biome.")
	# Old scenes only (new terrains start without it).
	if Meta.get_bool(terrain, Meta.DETAILS_EVERYWHERE, Meta.DEFAULT_DETAILS_EVERYWHERE):
		_add_checkbox(section, "Details Everywhere",
			"On: the biome's grass, trees and props grow by themselves on all ground, also on ground painted later (scenes made before this setting). "
			+ "Off (new terrains): they grow on the map Generate Map made and where you paint with the Vegetation tool; ground painted by hand stays bare.",
			true, _tuning_setter(terrain, Meta.DETAILS_EVERYWHERE))
	_add_float_row(section, terrain, "Detail Size", Meta.DETAIL_SCALE, 0.1, 4.0, 0.05, Meta.DEFAULT_DETAIL_SCALE, "Multiplies the size of every detail (1 = as in the biome).", _tuning_setter(terrain, Meta.DETAIL_SCALE))

func _build_pixel_map_section(parent: VBoxContainer, terrain: Node3D) -> void:
	var generator := _add_section(parent, "Pixel Map (Import from Image)", false,
		"Build the terrain from a small image: white or transparent = no ground, green = ground, red = raised ground, blue = lowered ground. Up to 256 x 256 pixels.")
	_add_texture_row(generator, terrain, "Source Image", Meta.GENERATOR_IMAGE,
		"Image to build from: white or transparent = no ground, green = ground, red = raised ground, blue = lowered ground. Up to 256 x 256 pixels.", _plain_setter(terrain, Meta.GENERATOR_IMAGE))
	var height_max: float = maxf(0.0, Meta.get_float(terrain, Meta.HEIGHT_MAX, Meta.DEFAULT_HEIGHT_MAX))
	var depth_max: float = maxf(0.0, -Meta.get_float(terrain, Meta.HEIGHT_MIN, Meta.DEFAULT_HEIGHT_MIN))
	_add_float_row(generator, terrain, "Raised Ground Height", Meta.GENERATOR_RAISE_HEIGHT, 0.0, height_max, 0.1, minf(Meta.DEFAULT_GENERATOR_RAISE_HEIGHT, height_max), "Height of the red pixels (at most Heights & Offsets > Highest Ground).", _plain_setter(terrain, Meta.GENERATOR_RAISE_HEIGHT))
	_add_float_row(generator, terrain, "Lowered Ground Depth", Meta.GENERATOR_LOWER_DEPTH, 0.0, depth_max, 0.1, minf(Meta.DEFAULT_GENERATOR_LOWER_DEPTH, depth_max), "Depth of the blue pixels (at most Heights & Offsets > Lowest Ground).", _plain_setter(terrain, Meta.GENERATOR_LOWER_DEPTH))
	_add_float_row(generator, terrain, "Color Tolerance", Meta.GENERATOR_COLOR_TOLERANCE, 0.0, 0.5, 0.01, Meta.DEFAULT_GENERATOR_COLOR_TOLERANCE, "How far a pixel may be from pure white / green / red / blue.", _plain_setter(terrain, Meta.GENERATOR_COLOR_TOLERANCE))
	_add_float_row(generator, terrain, "Hill Smoothness", Meta.GENERATOR_SMOOTHNESS, 0.0, 32.0, 0.5, 0.0, "Width (cells) of the slopes around red and blue areas. 0 = flat areas with steps.", _plain_setter(terrain, Meta.GENERATOR_SMOOTHNESS))

	_add_checkbox(generator, "One Style for All Colors",
		"Green, red and blue all get the ground style the Ground tool paints. Off = each color gets the biome ground style picked below.",
		Meta.get_bool(terrain, Meta.GENERATOR_USE_SINGLE_STYLE, true), _plain_setter(terrain, Meta.GENERATOR_USE_SINGLE_STYLE))
	_add_generator_style_choice(generator, terrain, "Green Style", "green")
	_add_generator_style_choice(generator, terrain, "Red Style", "red")
	_add_generator_style_choice(generator, terrain, "Blue Style", "blue")

	_add_button(generator, "Generate from Image", "Rebuild the terrain from the image (Ctrl+Z restores the previous terrain).", func() -> void:
		host.generate_from_image(terrain)
	)

## A pixel color's ground style: one of the biome's ground styles (written
## into the generator style settings), or what it holds now ("Custom").
func _add_generator_style_choice(parent: VBoxContainer, terrain: Node3D, title: String, prefix: String) -> void:
	var styles := TerrainBiome.of(terrain).ground_styles.filter(func(style: Resource) -> bool: return style != null)
	var keys := StylePalette.generator_style_keys(prefix)
	var row := _add_row(parent, title, "Ground style of the %s pixels (when One Style for All Colors is off)." % prefix)
	var option := OptionButton.new()
	option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var top: Color = terrain.get_meta(keys["top_color"], Meta.DEFAULT_TOP_COLOR)
	var side: Color = terrain.get_meta(keys["cliff_color"], Meta.DEFAULT_CLIFF_COLOR)
	var selected := -1
	for i in styles.size():
		var style: GroundStyle = styles[i]
		option.add_item(String(style.name), i)
		var same_colors := top.is_equal_approx(style.top_color) and side.is_equal_approx(style.side_color)
		var same_textures: bool = Meta.get_optional(terrain, keys["top_texture"]) == style.top_texture and Meta.get_optional(terrain, keys["cliff_texture"]) == style.side_texture
		if selected < 0 and same_colors and same_textures:
			selected = i
	if selected < 0:
		option.add_item("Custom", styles.size())
		selected = styles.size()
	option.select(option.get_item_index(selected))
	option.item_selected.connect(func(index: int) -> void:
		var id := option.get_item_id(index)
		if not is_instance_valid(terrain) or id >= styles.size():
			return
		var picked: GroundStyle = styles[id]
		terrain.set_meta(keys["top_color"], picked.top_color)
		terrain.set_meta(keys["cliff_color"], picked.side_color)
		Meta.set_optional(terrain, keys["top_texture"], picked.top_texture)
		Meta.set_optional(terrain, keys["cliff_texture"], picked.side_texture)
		terrain.set_meta(keys["top_tile_size"], picked.top_tile_size)
		terrain.set_meta(keys["cliff_tile_size"], picked.side_tile_size)
	)
	row.add_child(option)

# -----------------------------------------------------------------------------
# Widgets
# -----------------------------------------------------------------------------

## Foldout whose title explains the section in its tooltip.
func _edit_biome_tip(shared: bool) -> String:
	if shared:
		return "Open the biome in the Inspector. It is a file shared by every terrain that uses it: your edits change them all (Copy Biome to This Terrain to change this one only)."
	return "Open the biome in the Inspector. It is stored in this scene: your edits change this terrain only."

## Godot's own editor theme: the panel uses the same arrows, fonts, colours
## and widgets as the native Inspector (EditorInspectorCategory /
## EditorInspectorSection / EditorProperty), so it reads as part of it.
func _editor_theme() -> Theme:
	return EditorInterface.get_editor_theme()

## Title bar like a native Inspector category (class name over a band).
func _add_category(parent: VBoxContainer, text: String) -> void:
	var theme := _editor_theme()
	var band := PanelContainer.new()
	band.add_theme_stylebox_override("panel", theme.get_stylebox("bg", "EditorInspectorCategory"))
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_override("font", theme.get_font("bold", "EditorFonts"))
	label.add_theme_font_size_override("font_size", theme.get_font_size("bold_size", "EditorFonts"))
	band.add_child(label)
	parent.add_child(band)

func _add_section(parent: VBoxContainer, title_text: String, expanded: bool, tooltip: String) -> VBoxContainer:
	return _add_foldout(parent, title_text, expanded, tooltip)

## Foldout like a native Inspector group: tree arrow, bold title, indented
## content. Its title explains the section in its tooltip.
func _add_foldout(parent: VBoxContainer, title_text: String, expanded: bool = false, tooltip: String = "") -> VBoxContainer:
	var theme := _editor_theme()
	var header := Button.new()
	header.text = title_text
	header.tooltip_text = tooltip
	header.toggle_mode = true
	header.alignment = HORIZONTAL_ALIGNMENT_LEFT
	header.flat = true
	header.focus_mode = Control.FOCUS_NONE
	header.add_theme_font_override("font", theme.get_font("bold", "EditorFonts"))
	header.add_theme_font_size_override("font_size", theme.get_font_size("bold_size", "EditorFonts"))
	var color := theme.get_color("font_color", "EditorInspectorSection")
	for state: String in ["font_color", "font_pressed_color", "font_hover_pressed_color"]:
		header.add_theme_color_override(state, color)
	header.add_theme_constant_override("h_separation", theme.get_constant("h_separation", "EditorInspectorSection"))
	# Button margins make a taller line than a native section title.
	var margin := 2.0 * EditorInterface.get_editor_scale()
	for state: String in ["normal", "hover", "pressed", "hover_pressed", "focus"]:
		var box := theme.get_stylebox(state, "Button").duplicate() as StyleBox
		box.content_margin_top = margin
		box.content_margin_bottom = margin
		header.add_theme_stylebox_override(state, box)
	# Otherwise sized to the tallest stylebox of all states (disabled...).
	header.add_theme_constant_override("align_to_largest_stylebox", 0)
	parent.add_child(header)

	# Godot can rebuild a custom Inspector after changing resources, colours or
	# metadata, so the default argument alone is not enough to preserve state.
	var initial_open: bool = _foldout_states.get(title_text, expanded)
	header.button_pressed = initial_open

	var indent_row := HBoxContainer.new()
	parent.add_child(indent_row)
	var spacer := Control.new()
	spacer.custom_minimum_size.x = float(theme.get_constant("indent_size", "EditorInspectorSection"))
	indent_row.add_child(spacer)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	indent_row.add_child(body)

	var update_header := func(open: bool) -> void:
		_foldout_states[title_text] = open
		header.icon = theme.get_icon("arrow" if open else "arrow_collapsed", "Tree")
		indent_row.visible = open

	update_header.call(initial_open)
	header.toggled.connect(update_header)
	return body

func _add_button(parent: VBoxContainer, text: String, tooltip: String, on_pressed: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.tooltip_text = tooltip
	button.pressed.connect(on_pressed)
	parent.add_child(button)

## On / off setting like a native bool property: name on the left, a check
## box "On" on the right.
func _add_checkbox(parent: VBoxContainer, text: String, tooltip: String, pressed: bool, on_toggled: Callable) -> void:
	var row := _add_row(parent, text, tooltip)
	var check := CheckBox.new()
	check.text = "On"
	check.tooltip_text = tooltip
	check.button_pressed = pressed
	check.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	check.toggled.connect(on_toggled)
	row.add_child(check)

## Label + read-only value row.
func _add_value_row(parent: VBoxContainer, label_text: String, value_text: String, tooltip: String) -> void:
	var row := _add_row(parent, label_text, tooltip)
	var value := Label.new()
	value.text = value_text
	value.tooltip_text = tooltip
	value.mouse_filter = Control.MOUSE_FILTER_PASS
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(value)

## Row like a native property: its name on the left half (property colour),
## the control the caller adds on the right half (SIZE_EXPAND_FILL).
func _add_row(parent: VBoxContainer, label_text: String, tooltip: String) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.tooltip_text = tooltip
	# Labels ignore the mouse by default: no tooltip without this.
	label.mouse_filter = Control.MOUSE_FILTER_PASS
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", _editor_theme().get_color("property_color", "EditorProperty"))
	row.add_child(label)
	parent.add_child(row)
	return row

## Number field like a native one (EditorSpinSlider: drag to change, click
## to type).
func _add_spin_row(parent: VBoxContainer, label_text: String, tooltip: String, min_value: float, max_value: float, step: float, value: float) -> EditorSpinSlider:
	var row := _add_row(parent, label_text, tooltip)
	var spin := EditorSpinSlider.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = value
	spin.tooltip_text = tooltip
	spin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spin)
	return spin

func _add_float_row(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, min_value: float, max_value: float, step: float, default_value: float, tooltip: String, on_changed: Callable) -> void:
	var spin := _add_spin_row(parent, label_text, tooltip, min_value, max_value, step, Meta.get_float(terrain, key, default_value))
	spin.value_changed.connect(on_changed)

func _add_int_row(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, min_value: int, max_value: int, default_value: int, tooltip: String, on_changed: Callable) -> void:
	var spin := _add_spin_row(parent, label_text, tooltip, min_value, max_value, 1, Meta.get_int(terrain, key, default_value))
	spin.value_changed.connect(on_changed)

## `feature_style` pickers edit alpha.
func _add_color_row(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, default_value: Color, tooltip: String, on_changed: Callable, feature_style: bool = false) -> void:
	var row := _add_row(parent, label_text, tooltip)
	var picker := ColorPickerButton.new()
	picker.color = terrain.get_meta(key, default_value)
	picker.tooltip_text = tooltip
	picker.edit_alpha = feature_style
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.color_changed.connect(on_changed)
	row.add_child(picker)

func _add_texture_row(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, tooltip: String, on_changed: Callable) -> EditorResourcePicker:
	var row := _add_row(parent, label_text, tooltip)
	var picker := EditorResourcePicker.new()
	picker.base_type = "Texture2D"
	var edited_object: Object = Meta.get_optional(terrain, key)
	picker.edited_resource = edited_object as Resource
	picker.tooltip_text = tooltip
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.resource_changed.connect(on_changed)
	row.add_child(picker)
	return picker
