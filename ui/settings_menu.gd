class_name SettingsMenu
extends VBoxContainer
## The settings screen, built in code. Used by the main menu and the pause
## menu: add one as a child, listen for `back_pressed`, call focus_first()
## when you show it.
##
## Every row reads and writes the GameSettings autoload, which saves and
## applies the change right away. Rows marked "coming soon" are placeholders:
## their control is shown but disabled, so the layout is already in place.
## To add a working setting: add it to GameSettings.DEFAULTS, then add a row
## here with _option_row / _toggle_row / _slider_row.

signal back_pressed

const LABEL_WIDTH := 250.0
const CONTROL_WIDTH := 300.0
const FONT_SIZE := 20
const DIM := Color(1, 1, 1, 0.45)

## Controls tab: [shown name, input action]. Keys come from the Input Map
## (or the car's defaults if the car hasn't registered them yet).
const CONTROL_ROWS := [
	["Accelerate", "accelerate"],
	["Brake / reverse", "brake"],
	["Steer left", "steer_left"],
	["Steer right", "steer_right"],
	["Handbrake", "handbrake"],
	["Shift up (manual)", "shift_up"],
	["Shift down (manual)", "shift_down"],
	["Automatic / manual", "toggle_transmission"],
	["Reset car", "reset_car"],
	["Car debug view", "car_debug"],
	["Free camera (dev)", "DEV"],
]
## Keys handled outside the Input Map.
const FIXED_KEYS := [["Pause", "Escape"], ["Fullscreen", "F11 / Alt+Enter"]]

const FPS_CHOICES := [0, 30, 60, 120, 144, 240] # 0 = unlimited

var _settings: Node
var _tabs: TabContainer
# Each row adds a function that re-reads its value into its control, so the
# screen stays right after "Reset to defaults" or a change made elsewhere (G).
var _refreshers: Array[Callable] = []
# Key remapping: the action waiting for a key press ("" = not listening).
var _listening := ""
var _bind_status: Label
var _rebind_buttons := {} # action -> Button


func _ready() -> void:
	_settings = get_node("/root/GameSettings")
	add_theme_constant_override("separation", 14)

	var heading := Label.new()
	heading.text = "Settings"
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 30)
	add_child(heading)

	_tabs = TabContainer.new()
	_tabs.custom_minimum_size = Vector2(720, 420)
	_tabs.add_theme_font_size_override("font_size", FONT_SIZE)
	add_child(_tabs)
	_build_gameplay(_page("Gameplay"))
	_build_audio(_page("Audio"))
	_build_video(_page("Video"))
	_build_controls(_page("Controls"))

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	add_child(footer)
	footer.add_child(_make_button("Reset to defaults", _settings.reset_to_defaults))
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)
	footer.add_child(_make_button("Back", back_pressed.emit))

	_settings.changed.connect(_on_setting_changed)
	refresh()


func _on_setting_changed(_key: String, _value: Variant) -> void:
	refresh()


# --- Key remapping ----------------------------------------------------------

func _start_listening(action: String) -> void:
	if _listening == action: # pressing the button again cancels
		_cancel_listening()
		return
	_listening = action
	_bind_status.text = "Press the new key (Esc cancels)..."
	refresh()


func _cancel_listening() -> void:
	if _listening == "":
		return
	_listening = ""
	_bind_status.text = "Cancelled."
	refresh()


# Runs before the rest of the UI and the pause/back handlers, so the key we
# capture (including Esc) is used up here and doesn't also pause or go back.
func _input(event: InputEvent) -> void:
	if _listening == "":
		return
	if event is InputEventMouseButton and event.pressed:
		return # let the click through (it may be the Rebind/Cancel button itself)
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	get_viewport().set_input_as_handled()
	var code: int = key.physical_keycode if key.physical_keycode != KEY_NONE else key.keycode
	if code in [KEY_SHIFT, KEY_CTRL, KEY_ALT, KEY_META]:
		return # modifiers alone aren't bindable; keep waiting
	if code == KEY_ESCAPE:
		_cancel_listening()
		return
	if code in _settings.RESERVED_KEYS:
		_bind_status.text = "%s can't be rebound." % OS.get_keycode_string(code as Key)
		return
	var action := _listening
	_listening = ""
	var other: String = _settings.rebind(action, code)
	var key_name := OS.get_keycode_string(DisplayServer.keyboard_get_keycode_from_physical(code as Key))
	_bind_status.text = "%s is now %s." % [_action_label(action), key_name]
	if other != "":
		_bind_status.text += " (%s also used it: it now has %s.)" % [_action_label(other), _keys_for(other)]
	refresh()
	var button: Button = _rebind_buttons.get(action)
	if button != null:
		button.grab_focus.call_deferred()


func _action_label(action: String) -> String:
	for row: Array in CONTROL_ROWS:
		if row[1] == action:
			return row[0]
	return action


## Put keyboard / gamepad focus on the tab bar (call after showing the screen).
func focus_first() -> void:
	refresh()
	_tabs.get_tab_bar().grab_focus.call_deferred()


func refresh() -> void:
	for r in _refreshers:
		r.call()


# --- Tabs -------------------------------------------------------------------

func _build_gameplay(page: VBoxContainer) -> void:
	_option_row(page, "Transmission", ["Automatic", "Manual"],
			func() -> int: return 0 if _settings.get_value("automatic_transmission") else 1,
			func(i: int) -> void: _settings.set_value("automatic_transmission", i == 0),
			"Manual: E shifts up, Q shifts down. G switches while driving.")
	_option_row(page, "Speed units", ["km/h", "mph"],
			func() -> int: return 1 if _settings.get_value("speed_mph") else 0,
			func(i: int) -> void: _settings.set_value("speed_mph", i == 1))
	_slider_row(page, "Camera field of view", "camera_fov", 55.0, 95.0, 1.0,
			func(v: float) -> String: return "%d°" % roundi(v))
	_section(page, "Coming soon")
	_placeholder_row(page, "Ghost car (best lap)", _disabled_check())
	_placeholder_row(page, "Camera shake", _disabled_check())
	_placeholder_row(page, "Language", _disabled_option(["English"]))


func _build_audio(page: VBoxContainer) -> void:
	var percent := func(v: float) -> String: return "%d%%" % roundi(v * 100.0)
	_slider_row(page, "Master volume", "master_volume", 0.0, 1.0, 0.05, percent)
	_slider_row(page, "Music volume", "music_volume", 0.0, 1.0, 0.05, percent,
			"No music in the game yet; this is ready for it.")
	_slider_row(page, "Effects volume", "sfx_volume", 0.0, 1.0, 0.05, percent,
			"Engine and other sound effects.")


func _build_video(page: VBoxContainer) -> void:
	_toggle_row(page, "Fullscreen", "fullscreen", "Also F11 or Alt+Enter.")
	_toggle_row(page, "VSync", "vsync", "Stops screen tearing; caps FPS to the monitor.")
	var fps_names: Array = []
	for f: int in FPS_CHOICES:
		fps_names.append("Unlimited" if f == 0 else str(f))
	_option_row(page, "Max FPS", fps_names,
			func() -> int: return maxi(0, FPS_CHOICES.find(int(_settings.get_value("max_fps")))),
			func(i: int) -> void: _settings.set_value("max_fps", FPS_CHOICES[i]))
	_section(page, "Coming soon")
	_placeholder_row(page, "Graphics quality", _disabled_option(["High", "Medium", "Low"]))
	_placeholder_row(page, "Show FPS counter", _disabled_check())


func _build_controls(page: VBoxContainer) -> void:
	_bind_status = Label.new()
	_bind_status.text = "Click Rebind, then press the new key (Esc cancels)."
	_bind_status.modulate = DIM
	_bind_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	page.add_child(_bind_status)
	for row: Array in CONTROL_ROWS:
		var action: String = row[1]
		var keys := Label.new()
		keys.custom_minimum_size = Vector2(CONTROL_WIDTH - 170.0, 0)
		var rebind := Button.new()
		rebind.custom_minimum_size = Vector2(110, 0)
		rebind.pressed.connect(_start_listening.bind(action))
		var reset := Button.new()
		reset.text = "Reset"
		reset.tooltip_text = "Back to the default key"
		reset.custom_minimum_size = Vector2(60, 0)
		reset.pressed.connect(func() -> void:
			_cancel_listening()
			_settings.reset_action_keys(action)
			_bind_status.text = "%s reset to its default key." % row[0])
		_rebind_buttons[action] = rebind
		_refreshers.append(func() -> void:
			keys.text = "Press a key..." if _listening == action else _keys_for(action)
			rebind.text = "Cancel" if _listening == action else "Rebind"
			reset.disabled = _settings.is_default_binding(action))
		var right := HBoxContainer.new()
		right.add_theme_constant_override("separation", 6)
		right.add_child(keys)
		right.add_child(rebind)
		right.add_child(reset)
		_row(page, row[0], right)
	for fixed: Array in FIXED_KEYS:
		var label := Label.new()
		label.text = fixed[1]
		_row(page, fixed[0], label)
	_section(page, "Coming soon")
	_placeholder_row(page, "Gamepad bindings", _disabled_check())
	_placeholder_row(page, "Controller vibration", _disabled_check())
	_placeholder_row(page, "Steering sensitivity", _disabled_slider())


# --- Row builders -----------------------------------------------------------

func _page(title: String) -> VBoxContainer:
	var scroll := ScrollContainer.new()
	scroll.name = title
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_tabs.add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 16)
	scroll.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	margin.add_child(box)
	return box


# One line: name on the left, control on the right, optional hint underneath.
func _row(page: VBoxContainer, text: String, control: Control, hint: String = "") -> void:
	var line := HBoxContainer.new()
	line.add_theme_constant_override("separation", 16)
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(LABEL_WIDTH, 0)
	label.add_theme_font_size_override("font_size", FONT_SIZE)
	line.add_child(label)
	control.custom_minimum_size.x = maxf(control.custom_minimum_size.x, CONTROL_WIDTH)
	line.add_child(control)
	page.add_child(line)
	if hint != "":
		var h := Label.new()
		h.text = hint
		h.modulate = DIM
		h.add_theme_font_size_override("font_size", 14)
		page.add_child(h)


func _section(page: VBoxContainer, text: String) -> void:
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 6)
	page.add_child(gap)
	var label := Label.new()
	label.text = text.to_upper()
	label.modulate = DIM
	label.add_theme_font_size_override("font_size", 14)
	page.add_child(label)
	page.add_child(HSeparator.new())


func _option_row(page: VBoxContainer, text: String, options: Array, getter: Callable,
		setter: Callable, hint: String = "") -> void:
	var option := OptionButton.new()
	for o: String in options:
		option.add_item(o)
	option.item_selected.connect(func(i: int) -> void: setter.call(i))
	_refreshers.append(func() -> void: option.select(getter.call()))
	_row(page, text, option, hint)


func _toggle_row(page: VBoxContainer, text: String, key: String, hint: String = "") -> void:
	var check := CheckButton.new()
	check.toggled.connect(func(on: bool) -> void: _settings.set_value(key, on))
	_refreshers.append(func() -> void: check.set_pressed_no_signal(_settings.get_value(key)))
	_row(page, text, check, hint)


func _slider_row(page: VBoxContainer, text: String, key: String, min_v: float, max_v: float,
		step: float, format: Callable, hint: String = "") -> void:
	var box := HBoxContainer.new()
	var slider := HSlider.new()
	slider.min_value = min_v
	slider.max_value = max_v
	slider.step = step
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var value_label := Label.new()
	value_label.custom_minimum_size = Vector2(60, 0)
	value_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	box.add_child(slider)
	box.add_child(value_label)
	slider.value_changed.connect(func(v: float) -> void:
		value_label.text = format.call(v)
		_settings.set_value(key, v))
	_refreshers.append(func() -> void:
		slider.set_value_no_signal(_settings.get_value(key))
		value_label.text = format.call(slider.value))
	_row(page, text, box, hint)


func _placeholder_row(page: VBoxContainer, text: String, control: Control) -> void:
	_row(page, text, control, "")
	control.tooltip_text = "Coming soon"


func _disabled_check() -> CheckButton:
	var c := CheckButton.new()
	c.disabled = true
	return c


func _disabled_option(options: Array) -> OptionButton:
	var o := OptionButton.new()
	for s: String in options:
		o.add_item(s)
	o.disabled = true
	return o


func _disabled_slider() -> HSlider:
	var s := HSlider.new()
	s.value = 50.0
	s.editable = false
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return s


func _make_button(text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(220, 52)
	button.add_theme_font_size_override("font_size", 22)
	button.pressed.connect(on_pressed)
	return button


# "W, Up" for an action: from the Input Map if it exists yet (it does once a
# car has loaded, and will hold remapped keys later), else the car's defaults.
func _keys_for(action: String) -> String:
	var names: PackedStringArray = []
	if InputMap.has_action(action):
		for ev in InputMap.action_get_events(action):
			var key := ev as InputEventKey
			if key == null:
				continue
			var code := key.keycode
			if key.physical_keycode != KEY_NONE:
				code = DisplayServer.keyboard_get_keycode_from_physical(key.physical_keycode)
			names.append(OS.get_keycode_string(code))
	elif Car.ACTIONS.has(action):
		for k: int in Car.ACTIONS[action]:
			names.append(OS.get_keycode_string(DisplayServer.keyboard_get_keycode_from_physical(k as Key)))
	return ", ".join(names) if not names.is_empty() else "-"
