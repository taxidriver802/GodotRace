extends Control
## Main menu: Start (opens the level picker), Settings (placeholder), Exit.
## The whole UI is built in code and anchored to the window, so it scales with
## the screen. To add a level, add one entry to LEVELS below. The picker shows
## the levels as a grid of cards (COLUMNS x ROWS per page); Prev/Next buttons
## appear on their own once there are more levels than fit on one page.

const GAME_TITLE := "RACE"

## Levels shown after pressing Start. `path` is the scene that gets loaded.
## Optional: "image" is a texture path used as the card's thumbnail.
const LEVELS := [
	{"name": "Level 1", "path": "res://levels/level_1.tscn", "image": "res://images/level_1.png"},
	{"name": "Level 2", "path": "res://levels/level_2.tscn", "image": "res://images/level_2.png"},
	{"name": "Level 3", "path": "res://levels/level_3.tscn", "image": "res://images/level_3.png"},
	{"name": "Level 4", "path": "res://levels/level_4.tscn", "image": "res://images/level_4.png"},
	{"name": "Level 5", "path": "res://levels/level_5.tscn", "image": "res://images/level_5.png"},
	{"name": "Demo Track", "path": "res://levels/track_demo.tscn", "image": "res://images/demo_track.png"},
	{"name": "Car Test", "path": "res://levels/car_test.tscn", "image": "res://images/car_test.png"},
]

const COLUMNS := 3
const ROWS := 2
const CARD_SIZE := Vector2(240, 150)
const GRID_GAP := 16
const ACCENT := Color(0.9, 0.15, 0.12)

var _levels: Array = LEVELS.duplicate()
var _page := 0

var _stack: VBoxContainer
var _header: VBoxContainer
var _main_panel: VBoxContainer
var _levels_panel: VBoxContainer
var _settings_panel: VBoxContainer
var _panels: Array[VBoxContainer] = []

var _grid: GridContainer
var _pager: HBoxContainer
var _prev_button: Button
var _next_button: Button
var _page_label: Label


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var background := ColorRect.new()
	background.color = Color(0.06, 0.07, 0.10)
	background.set_anchors_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)

	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_stack = VBoxContainer.new()
	_stack.add_theme_constant_override("separation", 14)
	center.add_child(_stack)

	# Big title; hidden on the level picker to leave room for the grid.
	_header = VBoxContainer.new()
	_header.add_theme_constant_override("separation", 14)
	_stack.add_child(_header)

	var title := Label.new()
	title.text = GAME_TITLE
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 96)
	_header.add_child(title)

	var stripe := ColorRect.new()
	stripe.color = ACCENT
	stripe.custom_minimum_size = Vector2(0, 6)
	_header.add_child(stripe)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 24)
	_header.add_child(gap)

	# Create every panel first: the buttons below refer to each other's panels.
	_main_panel = _make_panel()
	_levels_panel = _make_panel()
	_settings_panel = _make_panel()
	_build_main_panel()
	_build_levels_panel()
	_build_settings_panel()
	_show_panel(_main_panel)


func _unhandled_input(event: InputEvent) -> void:
	# Escape / B goes back from the sub-menus.
	if event.is_action_pressed("ui_cancel") and not _main_panel.visible:
		_show_panel(_main_panel)
		get_viewport().set_input_as_handled()


func _build_main_panel() -> void:
	_main_panel.add_child(_make_button("Start", _show_panel.bind(_levels_panel)))
	_main_panel.add_child(_make_button("Settings", _show_panel.bind(_settings_panel)))
	_main_panel.add_child(_make_button("Exit", get_tree().quit))


func _build_levels_panel() -> void:
	_levels_panel.add_child(_make_heading("Select Level"))

	_grid = GridContainer.new()
	_grid.columns = COLUMNS
	_grid.add_theme_constant_override("h_separation", GRID_GAP)
	_grid.add_theme_constant_override("v_separation", GRID_GAP)
	# Reserve the full grid size so the layout doesn't jump on a partly filled page.
	_grid.custom_minimum_size = Vector2(
			COLUMNS * CARD_SIZE.x + (COLUMNS - 1) * GRID_GAP,
			ROWS * CARD_SIZE.y + (ROWS - 1) * GRID_GAP)
	_levels_panel.add_child(_grid)

	# Footer: Back on the left, page controls on the right (only with 2+ pages).
	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 10)
	_levels_panel.add_child(footer)

	var back := _make_button("Back", _show_panel.bind(_main_panel))
	back.custom_minimum_size = Vector2(160, 52)
	footer.add_child(back)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(spacer)

	_pager = HBoxContainer.new()
	_pager.add_theme_constant_override("separation", 10)
	footer.add_child(_pager)

	_prev_button = _make_button("<", _change_page.bind(-1))
	_prev_button.custom_minimum_size = Vector2(64, 52)
	_pager.add_child(_prev_button)

	_page_label = Label.new()
	_page_label.custom_minimum_size = Vector2(110, 0)
	_page_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_pager.add_child(_page_label)

	_next_button = _make_button(">", _change_page.bind(1))
	_next_button.custom_minimum_size = Vector2(64, 52)
	_pager.add_child(_next_button)

	_rebuild_level_grid()


func _build_settings_panel() -> void:
	_settings_panel.add_child(_make_heading("Settings"))
	var note := Label.new()
	note.text = "Coming soon."
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	note.modulate = Color(1, 1, 1, 0.6)
	_settings_panel.add_child(note)
	_settings_panel.add_child(_make_button("Back", _show_panel.bind(_main_panel)))


func _page_count() -> int:
	return maxi(1, ceili(float(_levels.size()) / (COLUMNS * ROWS)))


# Fills the grid with the cards for the current page and updates the pager.
func _rebuild_level_grid() -> void:
	for child in _grid.get_children():
		_grid.remove_child(child)
		child.queue_free()
	var per_page := COLUMNS * ROWS
	var first := _page * per_page
	for i in range(first, mini(first + per_page, _levels.size())):
		_grid.add_child(_make_level_card(_levels[i]))
	var pages := _page_count()
	_pager.visible = pages > 1
	_page_label.text = "Page %d / %d" % [_page + 1, pages]
	_prev_button.disabled = _page <= 0
	_next_button.disabled = _page >= pages - 1


func _change_page(delta: int) -> void:
	_page = clampi(_page + delta, 0, _page_count() - 1)
	_rebuild_level_grid()
	# Keep keyboard / gamepad focus somewhere sensible after the grid is rebuilt.
	if delta > 0 and not _next_button.disabled:
		_next_button.grab_focus()
	elif delta < 0 and not _prev_button.disabled:
		_prev_button.grab_focus()
	else:
		_focus_first_button(_levels_panel)


# One level card: a thumbnail on top and the level name underneath. Later this
# is the place to add best times, a lock icon, and so on.
func _make_level_card(level: Dictionary) -> Button:
	var path: String = level["path"]
	var card := Button.new()
	card.custom_minimum_size = CARD_SIZE
	card.disabled = not ResourceLoader.exists(path)
	card.pressed.connect(_start_level.bind(path))

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for side in ["left", "top", "right", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	card.add_child(margin)

	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 6)
	margin.add_child(box)

	box.add_child(_make_thumbnail(level))

	var label := Label.new()
	label.text = level["name"]
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 20)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)
	return card


# The level's picture if it has an "image", otherwise a flat placeholder.
func _make_thumbnail(level: Dictionary) -> Control:
	var image_path: String = level.get("image", "")
	if image_path != "" and ResourceLoader.exists(image_path):
		var picture := TextureRect.new()
		picture.texture = load(image_path)
		picture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		picture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
		picture.clip_contents = true
		picture.size_flags_vertical = Control.SIZE_EXPAND_FILL
		picture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		return picture
	if image_path != "":
		push_warning("Main menu: image not found for '%s': %s" % [level["name"], image_path])
	var placeholder := ColorRect.new()
	placeholder.color = Color(0.13, 0.15, 0.22)
	placeholder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	placeholder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return placeholder


func _start_level(path: String) -> void:
	# The PauseMenu autoload loads the level and runs the start countdown.
	get_node("/root/PauseMenu").load_level(path)


func _make_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.add_theme_constant_override("separation", 14)
	panel.visible = false
	_stack.add_child(panel)
	_panels.append(panel)
	return panel


func _make_heading(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 30)
	return label


func _make_button(text: String, on_pressed: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(340, 58)
	button.add_theme_font_size_override("font_size", 24)
	button.pressed.connect(on_pressed)
	return button


func _show_panel(panel: VBoxContainer) -> void:
	for p in _panels:
		p.visible = (p == panel)
	_header.visible = (panel != _levels_panel)
	_focus_first_button(panel)


# Keyboard / gamepad: focus the first enabled button found in the panel.
func _focus_first_button(node: Node) -> bool:
	for child in node.get_children():
		var button := child as Button
		if button != null and not button.disabled:
			button.grab_focus.call_deferred()
			return true
		if _focus_first_button(child):
			return true
	return false
