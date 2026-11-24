extends Control
## Phone controls for player/fps_player.gd (full-screen Control, put it in a
## CanvasLayer):
##   - left side: a stick that appears where the thumb lands (walk);
##   - right side: drag to look around;
##   - buttons: Jump (up when flying), Down (flying only), Run (on / off),
##     Fly (on / off), Menu (top right, `menu_pressed`).
## Every finger is followed on its own (InputEventScreenTouch index), so you
## can walk, look and jump at the same time. Sizes follow the screen height.
## The frame rate is shown top right (left of Menu).

signal menu_pressed

## Radians per pixel of drag = look_speed / screen height.
@export var look_speed := 3.2

var player: Node
## A line under the frame rate (e.g. the 3D scale of world/phone_quality.gd).
var status_text := ""

var _stick_finger := -1
var _stick_origin := Vector2.ZERO
var _stick_offset := Vector2.ZERO
var _look_finger := -1
## finger index -> button name
var _held := {}
var _fps := 0.0

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	if player != null:
		player.touch_mode = true

func _process(delta: float) -> void:
	_fps = lerpf(_fps, 1.0 / maxf(delta, 0.0001), 0.05)
	# Whole screen (anchors alone left it at 0 x 0 under a CanvasLayer).
	position = Vector2.ZERO
	size = get_viewport_rect().size
	queue_redraw()

## Button name -> [centre, radius] for the current screen.
func _buttons() -> Dictionary:
	var w := size.x
	var h := size.y
	var buttons := {
		"jump": [Vector2(w - 0.15 * h, h - 0.17 * h), 0.10 * h],
		"run": [Vector2(w - 0.15 * h, h - 0.42 * h), 0.075 * h],
		"fly": [Vector2(w - 0.37 * h, h - 0.30 * h), 0.075 * h],
		"menu": [Vector2(w - 0.08 * h, 0.08 * h), 0.05 * h],
	}
	if player != null and player.flying:
		buttons["down"] = [Vector2(w - 0.38 * h, h - 0.10 * h), 0.085 * h]
	return buttons

func _button_at(point: Vector2) -> String:
	var buttons := _buttons()
	for name in buttons:
		var b: Array = buttons[name]
		# A bit larger than drawn: easier to hit with a thumb.
		if point.distance_to(b[0]) <= float(b[1]) * 1.25:
			return name
	return ""

func _stick_radius() -> float:
	return 0.13 * size.y

func _input(event: InputEvent) -> void:
	if player == null:
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			var button := _button_at(touch.position)
			if button != "":
				_held[touch.index] = button
				_press(button)
			elif touch.position.x < size.x * 0.45 and _stick_finger < 0:
				_stick_finger = touch.index
				_stick_origin = touch.position
				_stick_offset = Vector2.ZERO
			elif _look_finger < 0:
				_look_finger = touch.index
		else:
			if _held.has(touch.index):
				_release(_held[touch.index])
				_held.erase(touch.index)
			if touch.index == _stick_finger:
				_stick_finger = -1
				_stick_offset = Vector2.ZERO
				player.touch_move = Vector2.ZERO
			if touch.index == _look_finger:
				_look_finger = -1
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == _stick_finger:
			_stick_offset = (drag.position - _stick_origin).limit_length(_stick_radius())
			player.touch_move = _stick_offset / _stick_radius()
		elif drag.index == _look_finger:
			player.look(drag.relative, look_speed / maxf(size.y, 1.0))
		get_viewport().set_input_as_handled()

func _press(button: String) -> void:
	match button:
		"jump":
			player.touch_up = true
		"down":
			player.touch_down = true
		"run":
			player.touch_run = not player.touch_run
		"fly":
			player.toggle_fly()
		"menu":
			menu_pressed.emit()

func _release(button: String) -> void:
	match button:
		"jump":
			player.touch_up = false
		"down":
			player.touch_down = false

func _draw() -> void:
	var h := size.y
	if h < 10.0:
		# Not laid out yet (first frame).
		return
	var font := get_theme_default_font()
	var font_size := int(0.04 * h)
	# Top right, left of the Menu button.
	var fps_text := "%d img/s" % roundi(_fps)
	var fps_width := font.get_string_size(fps_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string_outline(font, Vector2(size.x - 0.16 * h - fps_width, 0.095 * h), fps_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
		maxi(2, int(0.006 * h)), Color(0, 0, 0, 0.7))
	draw_string(font, Vector2(size.x - 0.16 * h - fps_width, 0.095 * h), fps_text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1, 1, 1, 0.95))
	if status_text != "":
		var small := int(font_size * 0.7)
		var status_width := font.get_string_size(status_text, HORIZONTAL_ALIGNMENT_LEFT, -1, small).x
		var at := Vector2(size.x - 0.16 * h - status_width, 0.095 * h + small * 1.3)
		draw_string_outline(font, at, status_text, HORIZONTAL_ALIGNMENT_LEFT, -1, small, maxi(2, int(0.005 * h)), Color(0, 0, 0, 0.7))
		draw_string(font, at, status_text, HORIZONTAL_ALIGNMENT_LEFT, -1, small, Color(1, 1, 1, 0.8))
	if player == null:
		return
	# Stick: a ring where the thumb landed, a knob where it is now.
	if _stick_finger >= 0:
		draw_circle(_stick_origin, _stick_radius(), Color(1, 1, 1, 0.12))
		draw_arc(_stick_origin, _stick_radius(), 0.0, TAU, 48, Color(1, 1, 1, 0.45), maxf(2.0, 0.004 * h))
		draw_circle(_stick_origin + _stick_offset, 0.055 * h, Color(1, 1, 1, 0.55))
	else:
		# Where to put the thumb.
		var hint := Vector2(0.22 * h, h - 0.22 * h)
		draw_arc(hint, _stick_radius(), 0.0, TAU, 48, Color(1, 1, 1, 0.22), maxf(2.0, 0.004 * h))
		draw_circle(hint, 0.05 * h, Color(1, 1, 1, 0.18))
	var labels := {"jump": "Haut" if player.flying else "Saut", "down": "Bas", "run": "Courir", "fly": "Voler", "menu": "Menu"}
	var held := _held.values()
	var buttons := _buttons()
	for name in buttons:
		var b: Array = buttons[name]
		var centre: Vector2 = b[0]
		var radius: float = b[1]
		var on: bool = held.has(name) or (name == "run" and player.touch_run) or (name == "fly" and player.flying)
		draw_circle(centre, radius, Color(1, 0.85, 0.55, 0.55) if on else Color(0, 0, 0, 0.32))
		draw_arc(centre, radius, 0.0, TAU, 48, Color(1, 1, 1, 0.6), maxf(2.0, 0.004 * h))
		var text: String = labels[name]
		var text_size := int(radius * 0.42)
		var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, text_size).x
		draw_string(font, centre + Vector2(-width * 0.5, text_size * 0.35), text, HORIZONTAL_ALIGNMENT_LEFT, -1, text_size, Color(1, 1, 1, 0.95))
