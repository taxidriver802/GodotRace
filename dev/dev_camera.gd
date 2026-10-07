extends Node
## Developer free camera (registered as an autoload). Handy for screenshots.
##
## Press the DEV key (the "DEV" input action, bound to 1) to flip between the
## car and a free-flying camera. While it's active the car ignores the keys and
## coasts to a stop. The car's own chase camera is never touched, so pressing
## DEV again just switches back to it, exactly where it was.
##
##   Right mouse + move : look          W A S D : move
##   Q / E : down / up                  Shift : fast
##   Mouse wheel : change speed         H : hide / show the HUD
##
## The free camera always starts from wherever the chase camera currently is.

const LOOK_SENSITIVITY := 0.003
const BASE_SPEED := 15.0 # m/s at the start of every session
const FAST_MULTIPLIER := 4.0

var active := false

var _car: Node
var _game_camera: Camera3D
var _camera: Camera3D
var _overlay: CanvasLayer
var _speed := BASE_SPEED
var _yaw := 0.0
var _pitch := 0.0
var _hud_hidden := false
var _hidden_layers: Array[CanvasLayer] = []


func _ready() -> void:
	_build_overlay()


func _unhandled_input(event: InputEvent) -> void:
	if InputMap.has_action("DEV") and event.is_action_pressed("DEV"):
		toggle()
		get_viewport().set_input_as_handled()
		return
	if not active:
		return

	var button := event as InputEventMouseButton
	if button != null:
		match button.button_index:
			MOUSE_BUTTON_RIGHT:
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if button.pressed else Input.MOUSE_MODE_VISIBLE
			MOUSE_BUTTON_WHEEL_UP:
				_speed = minf(_speed * 1.25, 300.0)
			MOUSE_BUTTON_WHEEL_DOWN:
				_speed = maxf(_speed / 1.25, 1.0)
		return

	var motion := event as InputEventMouseMotion
	if motion != null and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= motion.relative.x * LOOK_SENSITIVITY
		_pitch = clampf(_pitch - motion.relative.y * LOOK_SENSITIVITY, deg_to_rad(-89.0), deg_to_rad(89.0))
		return

	var key := event as InputEventKey
	if key != null and key.pressed and not key.echo and key.physical_keycode == KEY_H:
		_set_hud_hidden(not _hud_hidden)


func _process(delta: float) -> void:
	if not active:
		return
	# The level changed under us (restart, back to the menu): drop out cleanly.
	if not is_instance_valid(_car) or not is_instance_valid(_game_camera):
		_exit()
		return

	var move := Vector3.ZERO
	move.x = float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
	move.z = float(Input.is_physical_key_pressed(KEY_S)) - float(Input.is_physical_key_pressed(KEY_W))
	var lift := float(Input.is_physical_key_pressed(KEY_E)) - float(Input.is_physical_key_pressed(KEY_Q))
	var speed := _speed * (FAST_MULTIPLIER if Input.is_physical_key_pressed(KEY_SHIFT) else 1.0)

	_camera.rotation = Vector3(_pitch, _yaw, 0.0)
	_camera.global_position += (_camera.global_transform.basis * move + Vector3.UP * lift) * speed * delta


func toggle() -> void:
	if active:
		_exit()
	else:
		_enter()


func _enter() -> void:
	var car := _find_car()
	var current := get_viewport().get_camera_3d()
	if car == null or current == null:
		return # not in a level
	_car = car
	_game_camera = current
	_car.set("controls_enabled", false)

	_camera = Camera3D.new()
	_camera.fov = current.fov
	_camera.near = current.near
	_camera.far = current.far
	add_child(_camera)
	_camera.global_transform = current.global_transform
	var euler := _camera.global_transform.basis.get_euler(EULER_ORDER_YXZ)
	_pitch = euler.x
	_yaw = euler.y
	_speed = BASE_SPEED
	_camera.make_current()

	_overlay.show()
	active = true


func _exit() -> void:
	active = false
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	if is_instance_valid(_car):
		_car.set("controls_enabled", true)
	# Back to the untouched chase camera, then throw the free camera away.
	if is_instance_valid(_game_camera):
		_game_camera.make_current()
	if _camera != null:
		_camera.queue_free()
		_camera = null
	_set_hud_hidden(false)
	_overlay.hide()


# The car is the node in the "car" group (same lookup as RaceManager).
func _find_car() -> Node:
	return get_tree().get_first_node_in_group("car")


# Hides every on-screen HUD layer (speedometer, race timer...) for clean shots.
func _set_hud_hidden(hidden: bool) -> void:
	_hud_hidden = hidden
	if hidden:
		_hidden_layers.clear()
		var pause_menu := get_node_or_null("/root/PauseMenu")
		for node in get_tree().root.find_children("*", "CanvasLayer", true, false):
			var layer := node as CanvasLayer
			if layer != null and layer.visible and layer != _overlay and layer != pause_menu:
				layer.hide()
				_hidden_layers.append(layer)
		_overlay.hide()
	else:
		for layer in _hidden_layers:
			if is_instance_valid(layer):
				layer.show()
		_hidden_layers.clear()
		if active:
			_overlay.show()


func _build_overlay() -> void:
	_overlay = CanvasLayer.new()
	_overlay.layer = 90 # under the pause menu
	_overlay.hide()
	add_child(_overlay)

	var label := Label.new()
	label.text = "DEV CAMERA   |   hold right mouse: look   WASD: move   Q/E: down/up   Shift: fast   wheel: speed   H: hide HUD   1: back to car"
	label.set_anchors_preset(Control.PRESET_TOP_WIDE)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.offset_top = 8
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_outline_color", Color.BLACK)
	label.add_theme_constant_override("outline_size", 5)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.add_child(label)
