class_name RaceManager
extends Node
## Turns gate hits into a race: laps, lap times and "all checkpoints collected"
## before a finish counts. Add one RaceManager anywhere in the level; it finds
## the car and every Checkpoint gate (start, checkpoint, finish) by itself.
##
## Track styles it supports:
##   Loop             - a START gate and no FINISH gate. Driving through START
##                      again, after collecting every checkpoint, completes a lap.
##   Point to point   - add a FINISH gate. Reaching it with every checkpoint
##                      collected ends the race (one lap, `total_laps` ignored).
## Driving through the finish early is ignored and reported through
## `finish_rejected`, so shortcuts and wrong-way laps don't count.
##
## The clock starts as soon as the level starts. A lap gate only counts once the
## car has been `arm_distance` meters away from it, so sitting on or just behind
## the start line at launch can't complete a lap.

signal race_started
signal checkpoint_collected(collected: int, total: int)
## Driving through the finish before every checkpoint was collected.
signal finish_rejected(missing: int)
signal lap_completed(lap: int, lap_time: float)
signal race_finished(total_time: float)

## The car to track. Leave empty to auto-detect (the node in the "car" group).
@export var car: Node3D
## Laps for a loop track. Ignored when the level has a FINISH gate.
@export_range(1, 99) var total_laps := 3
## Distance the car must get from the lap gate before crossing it counts.
@export_range(5.0, 200.0, 1.0, "or_greater") var arm_distance := 30.0
## Draw a small lap / checkpoint / timer readout in the top-left corner.
@export var show_hud := true
## When the race finishes, show the "Race Complete" screen (the pause menu with
## the times). Turn off to handle the `race_finished` signal yourself.
@export var show_results_screen := true
## Put the car on the START gate when the level starts, facing the driving
## direction, so moving the gate also moves the starting spot.
@export var place_car_at_start := true
## How far behind the start line the car's center is placed (meters).
@export_range(0.0, 30.0, 0.5) var start_offset := 3.0

var start_gate: Checkpoint
var finish_gate: Checkpoint
var checkpoints: Array[Checkpoint] = []

var lap := 1
var lap_time := 0.0
var race_time := 0.0
var lap_times: Array[float] = []
var running := false
var finished := false

## Fastest speed on the current lap, km/h (reset each lap).
var top_speed_kmh := 0.0

var _collected := {}
var _armed := false
var _label: Label
var _level_id := ""
var _records: Node # the Records autoload (race/records.gd)
var _new_best_lap := false # a lap this race beat the saved best lap


func _ready() -> void:
	# Gates register themselves in their own _ready; wait until everyone is in.
	_setup.call_deferred()


func _setup() -> void:
	for node in get_tree().get_nodes_in_group("checkpoints"):
		var gate := node as Checkpoint
		if gate == null:
			continue
		match gate.kind:
			Checkpoint.Kind.START:
				start_gate = gate
			Checkpoint.Kind.FINISH:
				finish_gate = gate
			_:
				checkpoints.append(gate)
		gate.car_passed.connect(_on_gate_passed)

	if car == null:
		car = get_tree().get_first_node_in_group("car") as Node3D
	if car == null:
		push_warning("RaceManager: no car found.")
	elif place_car_at_start and start_gate != null:
		_place_car_at_start()
	if _lap_gate() == null:
		push_warning("RaceManager: add a START gate (or a FINISH gate) so the race can end.")
	if show_hud:
		_build_hud()
	_records = get_node_or_null("/root/Records")
	_level_id = get_tree().current_scene.scene_file_path
	running = true
	race_started.emit()


func _physics_process(delta: float) -> void:
	if not running:
		return
	race_time += delta
	lap_time += delta
	if car != null and "speed" in car:
		top_speed_kmh = maxf(top_speed_kmh, absf(car.speed) * 3.6)
	var gate := _lap_gate()
	if not _armed and car != null and gate != null:
		_armed = car.global_position.distance_to(gate.global_position) > arm_distance
	_update_hud()


func _place_car_at_start() -> void:
	var gate_xf := start_gate.global_transform.orthonormalized()
	var forward := -gate_xf.basis.z
	# A little above the road (along the gate's up, so ramps work too): the
	# suspension settles the car instead of popping it out of the ground.
	var xf := Transform3D(gate_xf.basis, gate_xf.origin - forward * start_offset + gate_xf.basis.y * 0.15)
	if car.has_method("reset_to"):
		car.reset_to(xf)
	else:
		car.global_transform = xf


## The gate that closes a lap: the FINISH gate if there is one, else START.
func _lap_gate() -> Checkpoint:
	return finish_gate if finish_gate != null else start_gate


func laps_in_race() -> int:
	return 1 if finish_gate != null else total_laps


## Start over: clears collected checkpoints and all times.
func restart() -> void:
	lap = 1
	lap_time = 0.0
	race_time = 0.0
	lap_times.clear()
	top_speed_kmh = 0.0
	_new_best_lap = false
	finished = false
	running = true
	_armed = false
	_reset_checkpoints()
	race_started.emit()


func _reset_checkpoints() -> void:
	_collected.clear()
	for gate in checkpoints:
		gate.set_collected(false)


func _on_gate_passed(gate: Checkpoint, body: Car) -> void:
	if finished or body != car:
		return
	if gate.kind == Checkpoint.Kind.CHECKPOINT:
		if not _collected.has(gate):
			_collected[gate] = true
			gate.set_collected(true)
			checkpoint_collected.emit(_collected.size(), checkpoints.size())
		return
	# Start/finish gates: only the one that closes the lap matters.
	if gate != _lap_gate() or not _armed:
		return
	var missing := checkpoints.size() - _collected.size()
	if missing > 0:
		finish_rejected.emit(missing)
		return
	lap_times.append(lap_time)
	lap_completed.emit(lap, lap_time)
	# Saved records (best lap, totals). Done before the race result below.
	if _records != null and _records.submit_lap(_level_id, lap_time, top_speed_kmh):
		_new_best_lap = true
	if lap >= laps_in_race():
		finished = true
		running = false
		var result := {}
		if _records != null:
			result = _records.submit_race(_level_id, race_time)
			result["new_best_lap"] = _new_best_lap
			result["stats"] = _records.get_stats(_level_id)
			result["level"] = _level_id
		race_finished.emit(race_time)
		_update_hud()
		if show_results_screen:
			# Deferred: we're inside a physics callback.
			get_node("/root/PauseMenu").call_deferred("show_results", race_time, lap_times.duplicate(), result)
		return
	lap += 1
	lap_time = 0.0
	top_speed_kmh = 0.0
	_armed = false
	_reset_checkpoints()


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "RaceHud"
	_label = Label.new()
	_label.position = Vector2(24, 20)
	_label.add_theme_font_size_override("font_size", 26)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 6)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_label)
	add_child(layer)


func _update_hud() -> void:
	if _label == null:
		return
	var lines: PackedStringArray = []
	if finished:
		lines.append("FINISHED  %s" % format_time(race_time))
	else:
		if finish_gate == null:
			lines.append("Lap %d / %d" % [lap, laps_in_race()])
		lines.append("Checkpoints %d / %d" % [_collected.size(), checkpoints.size()])
		lines.append("Time %s" % format_time(race_time))
	if not lap_times.is_empty():
		lines.append("Last lap %s" % format_time(lap_times[-1]))
	if _records != null:
		var saved: Dictionary = _records.get_stats(_level_id)
		if saved.best_race > 0.0:
			lines.append("Best %s" % format_time(saved.best_race))
		if finish_gate == null and saved.best_lap > 0.0:
			lines.append("Best lap %s" % format_time(saved.best_lap))
	_label.text = "\n".join(lines)


static func format_time(seconds: float) -> String:
	return "%d:%05.2f" % [floori(seconds / 60.0), fmod(seconds, 60.0)]
