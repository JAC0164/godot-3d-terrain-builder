@tool
extends HBoxContainer
## Toolbar shown in the 3D editor menu. Emits signals only; the plugin owns
## the state and calls set_active_tool() / update_state() back.
##
## One row of flat icon buttons (like Godot's own 3D toolbar), the tool name
## and a hint in the tooltip. 7 tools: the opposite gestures are Ctrl / Shift
## of the same button (Ground: Ctrl = erase; Relief: Ctrl = dig; Shift =
## smooth), the modes ERASE / LOWER / SMOOTH have no button of their own. Without a terrain only "New Terrain" (with its
## name) and the status are shown: every other control needs a terrain; with
## one, New Terrain shrinks to its icon to leave room for the tools.
## Undo / Redo are Godot's own Ctrl+Z / Ctrl+Shift+Z. Godot's 3D menu is a flow container: the row
## sits next to Godot's items when it fits, else on its own line, never split.
##
## Keep it narrower than Godot's own 3D menu row (~710 px): the 3D editor
## cannot be narrower than its widest menu item, and the old 1300 px text
## toolbar pushed the Inspector dock off-screen on small / scaled screens.
## No ScrollContainer here: it can collapse to a tiny viewport in the editor.

const ToolMode = preload("../editing/tool_mode.gd")
const ToolIcons = preload("tool_icons.gd")

signal new_terrain_pressed
## A tool button was clicked (the plugin decides whether it toggles off).
signal tool_pressed(mode: ToolMode.Mode)
signal brush_radius_changed(value: float)
signal brush_strength_changed(value: float)
## Vegetation brush target picked: "" = all plants, else a detail layer name.
signal vegetation_target_changed(target: String)
## Ground style picked in the list next to Ground: its index in the biome's
## ground styles, or -1 for "Custom" (Inspector > Advanced > Custom Ground Style).
signal ground_style_changed(index: int)

const _TOOLS := [
	[ToolMode.Mode.PAINT, "paint", "Ground\nDrag to add ground in the style picked in the list next to this button.\nCtrl+drag: remove ground (a stroke that starts on a road / river removes it; a click in a waterhole removes it) · Shift+drag: smooth"],
	null,
	[ToolMode.Mode.RAISE, "raise", "Relief\nDrag to raise the ground.\nCtrl+drag: dig · Shift+drag: smooth"],
	[ToolMode.Mode.FLATTEN, "flatten", "Flatten\nLevel the ground to the height where the stroke starts.\nShift+drag: smooth"],
	null,
	[ToolMode.Mode.ROAD, "road", "Road / track\nDrag to draw. The Size field (or [ ]) sets the width. Color: Inspector > Roads, Rivers & Waterholes.\nRemove: Ctrl+drag with Ground, starting on the road."],
	[ToolMode.Mode.RIVER, "river", "River\nDrag to draw. The Size field (or [ ]) sets the width. Depth, color: Inspector > Roads, Rivers & Waterholes.\nRemove: Ctrl+drag with Ground, starting on the river."],
	[ToolMode.Mode.WATERHOLE, "waterhole", "Waterhole\nClick to place a dried waterhole (cracked mud) of the brush Size. Depth: Inspector > Roads, Rivers & Waterholes. Colors: the biome (Inspector > Look > Edit Biome > Waterholes).\nRemove: Ctrl+click in it with Ground."],
	null,
	[ToolMode.Mode.VEGETATION, "vegetation", "Vegetation\nDrag for more trees, grass, rocks... (trees and other sparse layers up to x25 the biome density, grass up to x4). Pick what to paint in the list next to this button.\nCtrl+drag: fewer, then none (clearings, fields) · Shift+drag: back to the biome density."],
]
## Keys of every tool (appended to the tool tooltips).
const _KEYS_HINT := "\n\nIn the 3D view: [ ] size · - = strength · Esc leave the tool"
const _RADIUS_TIP := "Brush size: radius in m (also the waterhole radius).\n[ ] in the 3D view."
const _STRENGTH_TIP := "Brush strength.\n- = in the 3D view."
## Width of the Ground / Vegetation lists at editor scale 1 (a longer name is
## clipped; the opened list shows it in full).
const _SELECT_WIDTH := 100.0

var _tool_buttons: Dictionary = {}
var _new_button: Button
var _brush_radius_spin: SpinBox
var _brush_strength_spin: SpinBox
var _size_icon: TextureRect
var _strength_icon: TextureRect
var _terrain_enabled := false
var _context_mode: ToolMode.Mode = ToolMode.Mode.NONE
## Changing the field range can clamp (and signal) its value: not a user edit.
var _updating_context := false
var _status_label: Label
## Shown with the status while a map is generated or loaded (set_progress).
var _progress_bar: ProgressBar
## The status, kept while the progress text takes its place.
var _status_text := ""
var _status_detail := ""
## Every control but New Terrain and the status (hidden without a terrain).
var _terrain_row: HBoxContainer
## What the Vegetation brush paints (shown with that tool only).
var _vegetation_select: OptionButton
## Ground style of the Ground tool (biome ground styles + Custom).
var _ground_select: OptionButton
const _GROUND_TIP := "Ground style the Ground tool paints (from the biome).\nCustom: the colors / textures of Inspector > Advanced > Custom Ground Style."
const _VEGETATION_TIP := "What the Vegetation brush paints.\nAll plants: every layer that follows the brush (grass, shrubs, trees; set per layer in Biome > layer > Advanced > Vegetation Brush).\nA layer: that layer only (rocks and termite mounds too)."

func _init(initial_radius: float = 3.0, initial_strength: float = 1.0) -> void:
	name = "LowpolyTerrainToolbar"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var scale := EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0
	add_theme_constant_override("separation", int(roundf(2.0 * scale)))

	_new_button = _add_icon_button("new", "New Terrain\nCreate a new editable low-poly terrain in the current scene.",
		func() -> void: new_terrain_pressed.emit())
	_new_button.text = "New Terrain"
	_terrain_row = HBoxContainer.new()
	_terrain_row.add_theme_constant_override("separation", int(roundf(2.0 * scale)))
	add_child(_terrain_row)
	_add_separator()
	for entry: Variant in _TOOLS:
		if entry == null:
			_add_separator()
			continue
		var tool: Array = entry
		var tool_mode: ToolMode.Mode = tool[0]
		var icon_name: String = tool[1]
		var tooltip: String = tool[2]
		_add_tool_button(tool_mode, icon_name, tooltip + _KEYS_HINT)
		if tool_mode == ToolMode.Mode.PAINT:
			_ground_select = _add_select(_GROUND_TIP, _SELECT_WIDTH * scale, func(index: int) -> void:
				var style_index: int = _ground_select.get_item_metadata(index)
				ground_style_changed.emit(style_index))
	_vegetation_select = _add_select(_VEGETATION_TIP, _SELECT_WIDTH * scale, func(index: int) -> void:
		var target: String = _vegetation_select.get_item_metadata(index)
		vegetation_target_changed.emit(target))
	_add_separator()

	_size_icon = _add_field_icon("size", _RADIUS_TIP)
	_brush_radius_spin = _add_spin(ToolMode.BRUSH_RADIUS_MIN, ToolMode.BRUSH_RADIUS_MAX, ToolMode.BRUSH_RADIUS_STEP, initial_radius, _RADIUS_TIP, func(value: float) -> void:
		if not _updating_context:
			brush_radius_changed.emit(value))
	_strength_icon = _add_field_icon("strength", _STRENGTH_TIP)
	_brush_strength_spin = _add_spin(ToolMode.BRUSH_STRENGTH_MIN, ToolMode.BRUSH_STRENGTH_MAX, ToolMode.BRUSH_STRENGTH_STEP, initial_strength, _STRENGTH_TIP, func(value: float) -> void: brush_strength_changed.emit(value))

	_add_separator()

	_progress_bar = ProgressBar.new()
	_progress_bar.custom_minimum_size.x = 80.0
	_progress_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_progress_bar.visible = false
	add_child(_progress_bar)

	_status_label = Label.new()
	_status_label.clip_text = true
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	# Takes the free end of the line (full messages when there is room).
	_status_label.custom_minimum_size.x = 60.0
	_status_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# A Label ignores the mouse by default: without this its tooltip (the
	# full message) never shows.
	_status_label.mouse_filter = Control.MOUSE_FILTER_PASS
	set_status("No terrain selected")
	add_child(_status_label)

## Godot wraps plugin controls of the 3D menu in an HBoxContainer inside a
## PanelContainer, itself in the menu's HFlowContainer. Let both stretch so
## the status text can use the free end of the line (the row never wraps).
func _notification(what: int) -> void:
	if what == NOTIFICATION_PARENTED:
		var wrapper := get_parent() as Control
		for i in 2:
			if wrapper == null or wrapper is FlowContainer:
				break
			wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			wrapper = wrapper.get_parent() as Control

## Small icon in front of a number field (instead of a text label).
func _add_field_icon(icon_name: String, tooltip: String) -> TextureRect:
	var icon := TextureRect.new()
	icon.texture = ToolIcons.get_icon(icon_name)
	icon.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	icon.tooltip_text = tooltip
	icon.mouse_filter = Control.MOUSE_FILTER_PASS
	_row().add_child(icon)
	return icon

## Where new controls go: the terrain row once it exists.
func _row() -> Control:
	return _terrain_row if _terrain_row else self

## Compact list next to a tool (always shown: a list that appears /
## disappears makes the row jump).
func _add_select(tooltip: String, min_width: float, on_selected: Callable) -> OptionButton:
	var select := OptionButton.new()
	select.tooltip_text = tooltip
	select.fit_to_longest_item = false
	select.clip_text = true
	select.custom_minimum_size.x = min_width
	select.item_selected.connect(on_selected)
	_row().add_child(select)
	return select

func _add_separator() -> void:
	_row().add_child(VSeparator.new())

func _add_icon_button(icon_name: String, tooltip: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.icon = ToolIcons.get_icon(icon_name)
	button.flat = true
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(on_pressed)
	_row().add_child(button)
	return button

func _add_spin(min_value: float, max_value: float, step: float, value: float, tooltip: String, on_changed: Callable) -> SpinBox:
	var spin := SpinBox.new()
	spin.min_value = min_value
	spin.max_value = max_value
	spin.step = step
	spin.value = value
	spin.tooltip_text = tooltip
	# Values like "12.25": 4 characters are enough (Godot's default is wider).
	spin.get_line_edit().add_theme_constant_override("minimum_character_width", 3)
	spin.value_changed.connect(on_changed)
	_row().add_child(spin)
	return spin

func _add_tool_button(mode: ToolMode.Mode, icon_name: String, tooltip: String) -> void:
	# Exclusivity is managed manually (see set_active_tool). ButtonGroup.toggled
	# can emit the old button's "off" signal while a different button is being
	# pressed, which produced a two-click switching behaviour.
	var button := _add_icon_button(icon_name, tooltip, func() -> void: tool_pressed.emit(mode))
	button.toggle_mode = true
	_tool_buttons[mode] = button

## Shows `mode` as the only pressed tool button (NONE releases all). The
## Ctrl / Shift modes show their button (Erase -> Ground, Lower -> Relief).
func set_active_tool(mode: ToolMode.Mode) -> void:
	var shown := button_mode(mode)
	for key: ToolMode.Mode in _tool_buttons:
		var button: Button = _tool_buttons[key]
		button.set_pressed_no_signal(key == shown)

## The toolbar button of `mode`.
static func button_mode(mode: ToolMode.Mode) -> ToolMode.Mode:
	match mode:
		ToolMode.Mode.ERASE: return ToolMode.Mode.PAINT
		ToolMode.Mode.LOWER, ToolMode.Mode.SMOOTH: return ToolMode.Mode.RAISE
	return mode

## Fills the Ground style list: `names` with a swatch of `colors` ([top,
## side] per style), then "Custom"; selects `selected` (-1 = Custom).
func set_ground_styles(names: PackedStringArray, colors: Array, selected: int) -> void:
	_ground_select.clear()
	var icon_size := roundi(16.0 * (EditorInterface.get_editor_scale() if Engine.is_editor_hint() else 1.0))
	for i in names.size():
		var style_colors: Array = colors[i]
		var top_color: Color = style_colors[0]
		var side_color: Color = style_colors[1]
		_ground_select.add_icon_item(_swatch(top_color, side_color, icon_size), names[i])
		_ground_select.set_item_metadata(i, i)
	_ground_select.add_item("Custom")
	_ground_select.set_item_metadata(names.size(), -1)
	_ground_select.select(selected if selected >= 0 and selected < names.size() else names.size())

## Small square of the ground color with a strip of the side color.
static func _swatch(top: Color, side: Color, size: int) -> ImageTexture:
	var image := Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(top)
	image.fill_rect(Rect2i(size - maxi(size / 3, 2), 0, maxi(size / 3, 2), size), side)
	return ImageTexture.create_from_image(image)

## The Ground style list (tests).
func get_ground_select() -> OptionButton:
	return _ground_select

## Fills the Vegetation target list: "All plants" then `layer_names`, with
## `current` selected (not in the list = All plants). Returns the selection.
func set_vegetation_targets(layer_names: PackedStringArray, current: String) -> String:
	_vegetation_select.clear()
	_vegetation_select.add_item("All plants")
	_vegetation_select.set_item_metadata(0, "")
	var selected := 0
	for layer_name in layer_names:
		_vegetation_select.add_item(layer_name)
		_vegetation_select.set_item_metadata(_vegetation_select.item_count - 1, layer_name)
		if layer_name == current:
			selected = _vegetation_select.item_count - 1
	_vegetation_select.select(selected)
	var selected_target: String = _vegetation_select.get_item_metadata(selected)
	return selected_target

## The Vegetation target list (tests).
func get_vegetation_select() -> OptionButton:
	return _vegetation_select

## Tool button of `mode` (tests, shortcuts).
func get_tool_button(mode: ToolMode.Mode) -> Button:
	return _tool_buttons.get(mode)

## Keeps the Size field in sync when the radius (or width) changes elsewhere.
func set_brush_radius(value: float) -> void:
	_brush_radius_spin.set_value_no_signal(value)

func set_brush_strength(value: float) -> void:
	_brush_strength_spin.set_value_no_signal(value)

## Fits the Size / Strength fields to the active tool: Road / River edit the
## width of new features, Strength only exists for the brush tools.
func set_tool_context(mode: ToolMode.Mode, size_value: float) -> void:
	_context_mode = mode
	_updating_context = true
	var tip := _RADIUS_TIP
	if ToolMode.is_feature_tool(mode):
		tip = "Width of the next %s (m).\n[ ] in the 3D view. Also in Inspector > Roads, Rivers & Waterholes." % ("road" if mode == ToolMode.Mode.ROAD else "river")
		_brush_radius_spin.min_value = ToolMode.FEATURE_WIDTH_MIN
		_brush_radius_spin.max_value = ToolMode.FEATURE_WIDTH_MAX
		_brush_radius_spin.step = ToolMode.FEATURE_WIDTH_STEP
	else:
		_brush_radius_spin.min_value = ToolMode.BRUSH_RADIUS_MIN
		_brush_radius_spin.max_value = ToolMode.BRUSH_RADIUS_MAX
		_brush_radius_spin.step = ToolMode.BRUSH_RADIUS_STEP
	_brush_radius_spin.tooltip_text = tip
	_size_icon.tooltip_text = tip
	_brush_radius_spin.set_value_no_signal(size_value)
	_updating_context = false
	_apply_editable()

func _apply_editable() -> void:
	var uses_strength := ToolMode.is_brush_tool(_context_mode) or _context_mode == ToolMode.Mode.NONE
	_brush_radius_spin.editable = _terrain_enabled
	_brush_strength_spin.editable = _terrain_enabled and uses_strength
	_strength_icon.modulate.a = 1.0 if uses_strength else 0.35
	_brush_strength_spin.modulate.a = 1.0 if uses_strength else 0.5
	_brush_strength_spin.tooltip_text = _STRENGTH_TIP if uses_strength else "Not used by %s." % ToolMode.display_name(_context_mode)

## Enables the terrain-specific controls only when a terrain is selected.
func set_terrain_controls_enabled(enabled: bool) -> void:
	for mode: ToolMode.Mode in _tool_buttons:
		var button: Button = _tool_buttons[mode]
		button.disabled = not enabled
	_vegetation_select.disabled = not enabled
	_ground_select.disabled = not enabled
	_terrain_enabled = enabled
	_apply_editable()
	_terrain_row.visible = enabled
	# Its name only while it is alone; next to the tools, the icon is enough
	# (the tooltip still says "New Terrain").
	_new_button.text = "" if enabled else "New Terrain"

## Short message at the end of the toolbar; `detail` (else the text itself)
## is its tooltip, for what does not fit.
func set_status(text: String, detail: String = "") -> void:
	_status_text = text
	_status_detail = detail if detail != "" else text
	if not _progress_bar.visible:
		_status_label.text = _status_text
		_status_label.tooltip_text = _status_detail

func get_status() -> String:
	return _status_text

## Progress bar (0..1) with `text` in place of the status; a negative
## `fraction` hides it and shows the status again.
func set_progress(fraction: float, text: String = "") -> void:
	if fraction < 0.0:
		_progress_bar.visible = false
		_status_label.text = _status_text
		_status_label.tooltip_text = _status_detail
		return
	_progress_bar.visible = true
	_progress_bar.value = clampf(fraction, 0.0, 1.0) * 100.0
	_status_label.text = text
	_status_label.tooltip_text = text

func is_progress_shown() -> bool:
	return _progress_bar.visible
