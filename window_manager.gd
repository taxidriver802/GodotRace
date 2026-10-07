extends Node
## Global window handling (registered as an autoload).
##   - Keeps the window from shrinking below MIN_WINDOW_SIZE.
##   - F11 or Alt+Enter toggles fullscreen. Alt+Enter exists because macOS
##     claims F11 (volume / Show Desktop), so the game never receives it there.
##     Leaving fullscreen restores the previous window.

signal fullscreen_toggled(is_fullscreen: bool)

const MIN_WINDOW_SIZE := Vector2i(1152, 648)


func _ready() -> void:
	# Keep the fullscreen shortcut working while the game is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_window().min_size = MIN_WINDOW_SIZE
	_fit_window_to_screen()


# The starting size (Project Settings > Display > Window > Size > Window
# Width/Height Override) can be bigger than a small screen. Shrink the window
# to fit the usable screen area (same shape, never below the minimum), then
# center it.
func _fit_window_to_screen() -> void:
	var window := get_window()
	if window.mode != Window.MODE_WINDOWED:
		return
	var usable := DisplayServer.screen_get_usable_rect(window.current_screen)
	var room := Vector2(usable.size) * 0.95
	var scale_down := minf(1.0, minf(room.x / window.size.x, room.y / window.size.y))
	var fitted := Vector2i(Vector2(window.size) * scale_down).max(MIN_WINDOW_SIZE)
	window.size = fitted
	window.position = usable.position + (usable.size - fitted) / 2


func _unhandled_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	var is_f11 := key.keycode == KEY_F11
	var is_alt_enter := key.alt_pressed and (key.keycode == KEY_ENTER or key.keycode == KEY_KP_ENTER)
	if is_f11 or is_alt_enter:
		toggle_fullscreen()
		get_viewport().set_input_as_handled()


func toggle_fullscreen() -> void:
	var window := get_window()
	if window.mode == Window.MODE_FULLSCREEN or window.mode == Window.MODE_EXCLUSIVE_FULLSCREEN:
		window.mode = Window.MODE_WINDOWED
	else:
		window.mode = Window.MODE_FULLSCREEN
	fullscreen_toggled.emit(window.mode == Window.MODE_FULLSCREEN)
