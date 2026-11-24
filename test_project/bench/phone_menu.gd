extends Control
## First screen of the Android build (application/run/main_scene.android):
## explore the test map, explore a new random map, explore the open world
## (1.5 km, bench/explore.gd open_world), or run the performance
## test (bench/phone_bench.tscn). When user://autorun_series exists (a series
## started over adb) it goes straight to the performance test.

const Explore = preload("res://bench/explore.gd")
const EXPLORE_SCENE := "res://bench/explore.tscn"
const BENCH_SCENE := "res://bench/phone_bench.tscn"

func _ready() -> void:
	if FileAccess.file_exists("user://autorun_series"):
		get_tree().change_scene_to_file.call_deferred(BENCH_SCENE)
		return
	set_anchors_preset(Control.PRESET_FULL_RECT)
	var background := ColorRect.new()
	background.color = Color(0.16, 0.12, 0.09)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(background)
	var height := float(get_viewport().get_visible_rect().size.y)
	var font_size := maxi(18, int(height / 20.0))
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_CENTER)
	box.grow_horizontal = Control.GROW_DIRECTION_BOTH
	box.grow_vertical = Control.GROW_DIRECTION_BOTH
	box.add_theme_constant_override("separation", int(font_size * 0.8))
	add_child(box)
	var title := Label.new()
	title.text = "Savane low-poly"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", int(font_size * 1.3))
	box.add_child(title)
	_add_button(box, "Explorer la carte", font_size, func() -> void:
		Explore.map_seed = 7
		Explore.open_world = false
		get_tree().change_scene_to_file(EXPLORE_SCENE))
	_add_button(box, "Explorer une nouvelle carte", font_size, func() -> void:
		Explore.map_seed = randi_range(1, 99999)
		Explore.open_world = false
		get_tree().change_scene_to_file(EXPLORE_SCENE))
	_add_button(box, "Explorer le monde ouvert", font_size, func() -> void:
		Explore.map_seed = 7
		Explore.open_world = true
		get_tree().change_scene_to_file(EXPLORE_SCENE))
	_add_button(box, "Nouveau monde ouvert", font_size, func() -> void:
		Explore.map_seed = randi_range(1, 99999)
		Explore.open_world = true
		get_tree().change_scene_to_file(EXPLORE_SCENE))
	_add_button(box, "Test de performance", font_size, func() -> void:
		get_tree().change_scene_to_file(BENCH_SCENE))

func _add_button(box: Container, text: String, font_size: int, action: Callable) -> void:
	var button := Button.new()
	button.text = text
	button.add_theme_font_size_override("font_size", font_size)
	button.custom_minimum_size = Vector2(font_size * 14, font_size * 2.2)
	button.pressed.connect(action)
	box.add_child(button)
