extends CanvasLayer
## In-game pause menu (registered as an autoload, so it works in every level).
## Escape (or gamepad B) pauses; Resume starts a 3-2-1 countdown before the game
## continues. Restart reloads the current level; Main Menu returns to the menu.
## It stays out of the way on the main menu itself.

const MENU_SCENE := "res://ui/main_menu.tscn"
const COUNTDOWN_SECONDS := 3

var _panel: Control
var _count_label: Label
var _title_label: Label
var _stats_label: Label
var _records_label: Label
var _resume_button: Button
var _restart_button: Button
var _counting := false
var _results := false # true while the panel is the end-of-race screen
var _menu_box: VBoxContainer
var _settings_menu: SettingsMenu


func _ready() -> void:
	layer = 100
	# Keep running while the tree is paused, otherwise we could never unpause.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_ui()
	_start_if_level.call_deferred()


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_action_pressed("ui_cancel") or not _in_level():
		return
	get_viewport().set_input_as_handled()
	if _settings_menu.visible:
		_close_settings() # Escape backs out of settings first
		return
	if _counting or _results:
		return # no resuming from the results screen
	if get_tree().paused:
		resume()
	else:
		pause()


func pause() -> void:
	_results = false
	_close_settings(false)
	_title_label.text = "Paused"
	_stats_label.hide()
	_records_label.hide()
	_resume_button.show()
	get_tree().paused = true
	_panel.show()
	_resume_button.grab_focus()


## End-of-race screen: the same panel as pause, titled "Race Complete" with the
## times, and without Resume. Called by the RaceManager when the race finishes.
## `info` is the RaceManager's saved-records report (see race/records.gd):
## new_best, previous, rank, new_best_lap, stats, level. Empty = no records.
func show_results(total_time: float, lap_times: Array, info: Dictionary = {}) -> void:
	_results = true
	_close_settings(false)
	get_tree().paused = true
	_title_label.text = "Race Complete"

	var total_line := "Total time   %s" % RaceManager.format_time(total_time)
	if info.get("new_best", false):
		total_line += "   NEW RECORD!"
	var lines: PackedStringArray = [total_line]
	var previous: float = info.get("previous", 0.0)
	if previous > 0.0:
		var diff := total_time - previous
		if diff < 0.0:
			lines.append("%.2fs faster than your best" % -diff)
		else:
			lines.append("Best %s  (+%.2fs)" % [RaceManager.format_time(previous), diff])

	if lap_times.size() > 1:
		var best_lap: float = lap_times.min()

		for i in range(lap_times.size()):
			var best_marker := " 🏆" if lap_times[i] == best_lap else ""
			lines.append(
				"Lap %d   %s%s" % [
					i + 1,
					RaceManager.format_time(lap_times[i]),
					best_marker
				]
			)

	_stats_label.text = "\n".join(lines)
	_stats_label.show()
	_records_label.text = _records_text(info)
	_records_label.visible = _records_label.text != ""
	_resume_button.hide()
	_panel.show()
	_restart_button.grab_focus()
## The saved-records block under the times: best lap, top times, totals.
func _records_text(info: Dictionary) -> String:
	if not info.has("stats"):
		return ""
	var s: Dictionary = info.stats
	var lines: PackedStringArray = []
	var lap_line := "%s  |  Best lap  %s" % [_level_title(info), RaceManager.format_time(s.best_lap)]
	if info.get("new_best_lap", false):
		lap_line += "   NEW BEST LAP!"
	lines.append(lap_line)
	var tops: Array = s.top_times
	if tops.size() > 1:
		var parts: PackedStringArray = []
		for i in tops.size():
			var t := RaceManager.format_time(tops[i])
			parts.append("[%s]" % t if i + 1 == info.get("rank", 0) else t)
		lines.append("Top times  " + "   ".join(parts))
	var settings := get_node_or_null("/root/GameSettings")
	var mph: bool = settings != null and settings.get_value("speed_mph")
	var speed: float = s.top_speed_kmh * (0.621371 if mph else 1.0)
	lines.append("Races %d  |  Laps %d  |  Driven %s  |  Top speed %d %s" % [
			s.races_finished, s.laps_completed, RaceManager.format_time(s.total_time),
			roundi(speed), "mph" if mph else "km/h"])
	return "\n".join(lines)


func _level_title(info: Dictionary) -> String:
	var id: String = info.get("level", "")
	return id.get_file().get_basename().replace("_", " ").capitalize()


## Hides the menu, counts down, then un-pauses.
func resume() -> void:
	_countdown()


## Switch to a level scene and start it with the countdown.
func load_level(path: String) -> void:
	get_tree().change_scene_to_file(path)
	_countdown()


func _restart() -> void:
	_results = false
	_panel.hide()
	get_tree().reload_current_scene()
	_countdown()


# A level run directly from the editor (no menu) gets the countdown too.
func _start_if_level() -> void:
	await get_tree().process_frame # the main scene isn't current yet at autoload time
	if _in_level():
		_countdown()


func _to_main_menu() -> void:
	_close()
	get_tree().change_scene_to_file(MENU_SCENE)


func _close() -> void:
	_results = false
	get_tree().paused = false
	_panel.hide()


func _in_level() -> bool:
	var scene := get_tree().current_scene
	return scene != null and scene.scene_file_path != MENU_SCENE


func _show_count(text: String) -> void:
	_count_label.text = text
	_count_label.pivot_offset = _count_label.size * 0.5
	_count_label.scale = Vector2(1.5, 1.5)
	var tween := create_tween().set_pause_mode(Tween.TWEEN_PAUSE_PROCESS)
	tween.tween_property(_count_label, "scale", Vector2.ONE, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)

## 3-2-1-GO, then the game runs. Freezes the game itself, so it works right when
## a level starts, restarts or resumes.
func _countdown() -> void:
	if _counting:
		return
	_counting = true
	get_tree().paused = true
	_panel.hide()
	_count_label.show()
	for n in range(COUNTDOWN_SECONDS, 0, -1):
		_show_count(str(n))
		await get_tree().create_timer(1.0).timeout # keeps ticking while paused
	get_tree().paused = false
	_show_count("GO!")
	await get_tree().create_timer(0.6).timeout
	_count_label.hide()
	_counting = false

func _build_ui() -> void:
	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.hide()
	add_child(_panel)

	var dim := ColorRect.new()
	dim.color = Color(0.0, 0.0, 0.0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(dim) # blocks clicks reaching anything underneath

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.add_child(center)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	center.add_child(box)
	_menu_box = box

	# The same settings screen as the main menu, swapped in over the buttons.
	_settings_menu = SettingsMenu.new()
	_settings_menu.hide()
	_settings_menu.back_pressed.connect(_close_settings)
	center.add_child(_settings_menu)

	_title_label = Label.new()
	_title_label.text = "Paused"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_font_size_override("font_size", 56)
	box.add_child(_title_label)

	# Only shown on the end-of-race screen.
	_stats_label = Label.new()
	_stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_stats_label.add_theme_font_size_override("font_size", 24)
	_stats_label.hide()
	box.add_child(_stats_label)

	# Saved records (best lap, top times, totals): end-of-race screen only.
	_records_label = Label.new()
	_records_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_records_label.add_theme_font_size_override("font_size", 16)
	_records_label.modulate = Color(1, 1, 1, 0.75)
	_records_label.hide()
	box.add_child(_records_label)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 4)
	box.add_child(gap)

	_resume_button = _make_button("Resume", resume)
	box.add_child(_resume_button)
	_restart_button = _make_button("Restart", _restart)
	box.add_child(_restart_button)
	box.add_child(_make_button("Settings", _open_settings))
	box.add_child(_make_button("Main Menu", _to_main_menu))

	_count_label = Label.new()
	_count_label.set_anchors_preset(Control.PRESET_FULL_RECT)
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count_label.add_theme_font_size_override("font_size", 180)
	_count_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_count_label.add_theme_constant_override("outline_size", 14)
	_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count_label.hide()
	add_child(_count_label)


func _open_settings() -> void:
	_menu_box.hide()
	_settings_menu.show()
	_settings_menu.focus_first()


## Back from settings to the pause / results buttons.
func _close_settings(refocus: bool = true) -> void:
	if _settings_menu == null:
		return
	_settings_menu.hide()
	_menu_box.show()
	if refocus:
		(_resume_button if _resume_button.visible else _restart_button).grab_focus()


func _make_button(text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(340, 58)
	button.add_theme_font_size_override("font_size", 24)
	button.pressed.connect(on_pressed)
	return button
