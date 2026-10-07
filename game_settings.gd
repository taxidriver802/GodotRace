extends Node
## Player settings that outlive a single race (registered as the GameSettings
## autoload). Saved to user://settings.cfg, so they stick between launches.
##
## Every setting lives in `values` under a key listed in DEFAULTS. Read with
## get_value("key"), change with set_value("key", v): that applies it right
## away (volume, window, fps...), saves the file and emits `changed`, so
## anything showing or using a setting can listen and update (the car, the
## speedometer, the camera, the settings screen).
##
## To add a setting: add a default to DEFAULTS, show it in
## ui/settings_menu.gd, and (if it does something global) handle it in _apply().

signal changed(key: String, value: Variant)
## Kept for the car (same as changed("automatic_transmission", ...)).
signal transmission_changed(automatic: bool)

const PATH := "user://settings.cfg"
const SECTION := "settings"
const KEY_SECTION := "keybinds"

const DEFAULTS := {
	# Gameplay
	"automatic_transmission": true,
	"speed_mph": false,
	"camera_fov": 70.0,
	# Audio (0..1, linear)
	"master_volume": 1.0,
	"music_volume": 0.8,
	"sfx_volume": 1.0,
	# Video
	"fullscreen": false,
	"vsync": true,
	"max_fps": 0, # 0 = no limit
}

## Audio buses the game uses (made at startup if they don't exist). Route a
## sound to one with AudioStreamPlayer.bus = "Music" / "SFX".
const BUSES := {"master_volume": "Master", "music_volume": "Music", "sfx_volume": "SFX"}

var values: Dictionary = DEFAULTS.duplicate()

## true = the gearbox shifts for you; false = manual (E up / Q down).
var automatic_transmission: bool:
	get:
		return values["automatic_transmission"]
	set(value):
		set_value("automatic_transmission", value)


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for key: String in BUSES:
		_ensure_bus(BUSES[key])
	_load()
	_setup_keybinds()
	for key: String in values:
		_apply(key)
	# F11 / Alt+Enter also changes fullscreen: keep the setting in step.
	var wm := get_node_or_null("/root/WindowManager")
	if wm != null:
		wm.fullscreen_toggled.connect(func(on: bool) -> void:
			if values["fullscreen"] != on:
				values["fullscreen"] = on
				save()
				changed.emit("fullscreen", on))


func get_value(key: String) -> Variant:
	return values.get(key, DEFAULTS.get(key))


func set_value(key: String, value: Variant) -> void:
	if not DEFAULTS.has(key):
		push_warning("GameSettings: unknown setting '%s'" % key)
		return
	if values.get(key) == value:
		return
	values[key] = value
	_apply(key)
	save()
	changed.emit(key, value)
	if key == "automatic_transmission":
		transmission_changed.emit(value)


func toggle_transmission() -> void:
	set_value("automatic_transmission", not values["automatic_transmission"])


func reset_to_defaults() -> void:
	for key: String in DEFAULTS:
		set_value(key, DEFAULTS[key])
	reset_keys()


# --- Key bindings -----------------------------------------------------------
# The bindable actions and their default keys are Car.ACTIONS. Bindings live in
# the Input Map (so Input.is_action_pressed just works) and only the ones that
# differ from the defaults are saved, under [keybinds] in the settings file.
# Keys are stored as physical keycodes (position on the keyboard).

## Keys that can't be bound: they are handled outside the Input Map.
const RESERVED_KEYS := [KEY_ESCAPE, KEY_F11]

## Fired after any key binding changes.
signal keys_changed


## Physical keycodes currently bound to `action`.
func get_keys(action: String) -> Array:
	var out: Array = []
	if InputMap.has_action(action):
		for ev in InputMap.action_get_events(action):
			var k := ev as InputEventKey
			if k != null:
				out.append(k.physical_keycode if k.physical_keycode != KEY_NONE else k.keycode)
	return out


func default_keys(action: String) -> Array:
	return Car.ACTIONS.get(action, [])


func is_default_binding(action: String) -> bool:
	return get_keys(action) == default_keys(action)


## Make `keycode` the one key for `action`. If another action used that key it
## loses it (and takes this action's old key if that leaves it with none: a
## swap). Returns the other action's name, or "" if nothing was affected.
func rebind(action: String, keycode: int) -> String:
	if keycode in RESERVED_KEYS or not Car.ACTIONS.has(action):
		return ""
	var old := get_keys(action)
	var affected := ""
	for other: String in Car.ACTIONS:
		if other == action:
			continue
		var keys := get_keys(other)
		if keycode in keys:
			keys.erase(keycode)
			if keys.is_empty():
				keys = old.slice(0, 1)
			_set_keys(other, keys)
			affected = other
	_set_keys(action, [keycode])
	save()
	keys_changed.emit()
	return affected


func reset_action_keys(action: String) -> void:
	_set_keys(action, default_keys(action))
	save()
	keys_changed.emit()


func reset_keys() -> void:
	for action: String in Car.ACTIONS:
		_set_keys(action, default_keys(action))
	save()
	keys_changed.emit()


func _set_keys(action: String, keys: Array) -> void:
	if not InputMap.has_action(action):
		InputMap.add_action(action)
	InputMap.action_erase_events(action)
	for code: int in keys:
		var ev := InputEventKey.new()
		ev.physical_keycode = code as Key
		InputMap.action_add_event(action, ev)


# At startup: make sure every action exists with its default keys (unless the
# project's Input Map already defines it), then apply the saved changes.
func _setup_keybinds() -> void:
	var cfg := ConfigFile.new()
	var has_file := cfg.load(PATH) == OK
	for action: String in Car.ACTIONS:
		if not InputMap.has_action(action):
			_set_keys(action, default_keys(action))
		if has_file and cfg.has_section_key(KEY_SECTION, action):
			var saved: Variant = cfg.get_value(KEY_SECTION, action)
			if saved is Array and not (saved as Array).is_empty():
				_set_keys(action, saved)


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH) # keep any other sections
	for key: String in values:
		cfg.set_value(SECTION, key, values[key])
	for action: String in Car.ACTIONS:
		# Only changed bindings are stored, so new default keys still apply.
		cfg.set_value(KEY_SECTION, action, null if is_default_binding(action) else get_keys(action))
	cfg.save(PATH)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	# Older saves kept the transmission under [driving].
	if cfg.has_section_key("driving", "automatic_transmission"):
		values["automatic_transmission"] = cfg.get_value("driving", "automatic_transmission")
	for key: String in DEFAULTS:
		if cfg.has_section_key(SECTION, key):
			values[key] = cfg.get_value(SECTION, key)


# Makes a setting take effect. Settings only one object cares about (units,
# camera fov, transmission) are handled by that object listening to `changed`.
func _apply(key: String) -> void:
	var value: Variant = values[key]
	if BUSES.has(key):
		var bus := AudioServer.get_bus_index(BUSES[key])
		if bus >= 0:
			AudioServer.set_bus_volume_db(bus, linear_to_db(maxf(value, 0.0001)))
			AudioServer.set_bus_mute(bus, value <= 0.001)
		return
	match key:
		"fullscreen":
			var window := get_window()
			var is_full := window.mode == Window.MODE_FULLSCREEN or window.mode == Window.MODE_EXCLUSIVE_FULLSCREEN
			if value != is_full:
				window.mode = Window.MODE_FULLSCREEN if value else Window.MODE_WINDOWED
		"vsync":
			DisplayServer.window_set_vsync_mode(
					DisplayServer.VSYNC_ENABLED if value else DisplayServer.VSYNC_DISABLED)
		"max_fps":
			Engine.max_fps = int(value)


func _ensure_bus(bus_name: String) -> void:
	if AudioServer.get_bus_index(bus_name) != -1:
		return
	AudioServer.add_bus()
	var idx := AudioServer.bus_count - 1
	AudioServer.set_bus_name(idx, bus_name)
	AudioServer.set_bus_send(idx, "Master")
