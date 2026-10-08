class_name TrackDriveTest
extends Node
## Autopilot test harness for the track + car (TrackMilestone M0).
##
## Run res://tests/track_drive_test.tscn. It loads the level named in
## res://tests/tdt_config.json, drives the car along the level's TrackChain
## centerline by itself and logs everything that goes wrong:
##   seam      a wheel's suspension jumps faster than SEAM_RATE while the car
##             is driving normally (not right after a landing)
##   wheel_off a grounded wheel is standing on something that isn't the road
##             surface (barrier top, wall, ground beside the track)
##   body_wall / body_floor   the car BODY touches a wall / the road
##             (body_floor = suspension bottomed out or the car is scraping)
##   landing   every touchdown after >0.15 s in the air: pitch/roll vs. road,
##             impact speed, whether it bottomed out
##   flip      car up vs. road up < 0.3 for 0.25 s. The harness records what
##             happened in the second before, then resets the car ahead.
##   fell_off  the car left the track (below or beside the road)
## At the end it prints a summary prefixed "[TDT]" and writes the full report
## to user://track_drive_report.json, then quits.
##
## Config keys (all optional), see DEFAULTS.

const CONFIG_PATH := "res://tests/tdt_config.json"
const REPORT_PATH := "user://track_drive_report.json"
const STEP := 1.0 # meters between path samples
## A seam hit: the suspension's per-tick movement changes by more than this
## (meters) from one tick to the next. Smooth hills change it gradually.
const SEAM_STEP := 0.012
const WHEELBASE := 2.6
const MAX_EVENTS := 600

const DEFAULTS := {
	"level": "res://tests/stress_track.tscn",
	## "limit": as fast as each corner allows (full throttle on straights).
	## "fixed": hold target_kmh everywhere (still slows for corners).
	"speed_mode": "limit",
	"target_kmh": 400.0,
	## Lateral grip budget for the speed plan, as a multiple of the car's
	## gravity (9.8 x gravity_scale). Above ~1.5 the car can't hold the line.
	"corner_g": 1.0,
	"brake_decel": 18.0,
	## Drive this many meters right (+) or left (-) of the center line.
	## "outside" / "inside" hug the outside / inside of every turn instead.
	"line_offset": 0.0,
	"line": "center",
	"laps": 3,
	"max_time": 240.0,
	"label": "",
	## Reset the car ahead after a flip / falling off (false = end the run).
	"recover": true,
}

var cfg := {}
var level: Node
var car: Car
var chain: Node3D

# Path, one sample every STEP meters.
var path: Array[Transform3D] = []
var path_piece: PackedStringArray = []
var path_dist := PackedFloat32Array()
var path_width := PackedFloat32Array()
var path_gap: Array[bool] = []
var path_turn := PackedFloat32Array() # signed curvature (+ = left), 1/m
var vplan := PackedFloat32Array()
var closed := false

var idx := 0
var progress := 0 # samples driven (counts past a lap)
var time := 0.0
var started := false
var finished := false

var events: Array = []
var counts := {}
var seams_by_piece := {}
var wall_by_piece := {}
var landings: Array = []
var max_roll_deg := 0.0
var max_roll_piece := ""
var top_speed := 0.0

var _prev_comp: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _prev_grounded: Array[bool] = [false, false, false, false]
var _prev_rate: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _last_reset := 0.0
var _air_time := 0.0
var _since_landing := 99.0
var _pre_land_vel := Vector3.ZERO
var _landing: Dictionary = {}
var _flip_time := 0.0
var _recent: Array = [] # events in the last second, for flip causes
var _wall_cooldown := 0.0
var _floor_cooldown := 0.0
var _wheel_off_cooldown: Array[float] = [0.0, 0.0, 0.0, 0.0]
var _stuck_time := 0.0


func _ready() -> void:
	process_physics_priority = 100 # after the car, so wheel data is this tick's
	cfg = DEFAULTS.duplicate()
	if FileAccess.file_exists(CONFIG_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
		if parsed is Dictionary:
			cfg.merge(parsed, true)
	var packed := load(cfg.level) as PackedScene
	if packed == null:
		_fail("can't load level %s" % cfg.level)
		return
	level = packed.instantiate()
	# No race logic during tests: it would save lap records and pop the
	# results screen. The harness places the car on the start gate itself.
	var start_xf: Variant = null
	for rm in _all(level, func(n: Node) -> bool: return n is RaceManager):
		rm.get_parent().remove_child(rm)
		rm.free()
	add_child(level)
	for gate in _all(level, func(n: Node) -> bool: return n is Checkpoint):
		if gate.kind == Checkpoint.Kind.START:
			start_xf = gate.global_transform.orthonormalized()
	var cars := _all(level, func(n: Node) -> bool: return n is Car)
	var chains := _all(level, func(n: Node) -> bool: return n is TrackChain)
	if cars.is_empty() or chains.is_empty():
		_fail("level needs a Car and a TrackChain")
		return
	car = cars[0]
	chain = chains[0]
	car.max_contacts_reported = 16
	car.contact_monitor = true
	_setup.call_deferred(start_xf)


func _setup(start_xf: Variant) -> void:
	await get_tree().physics_frame # let the chain lay itself out
	_build_path()
	_plan_speed()
	if start_xf != null:
		var xf: Transform3D = start_xf
		var fwd := -xf.basis.z
		car.reset_to(Transform3D(xf.basis, xf.origin - fwd * 3.0 + xf.basis.y * 0.15))
	else:
		var xf := path[mini(6, path.size() - 1)]
		car.reset_to(Transform3D(xf.basis, xf.origin + xf.basis.y * 0.15))
	# The autopilot can't shift: force automatic whatever the saved setting is.
	car.gearbox.mode = Gearbox.Mode.AUTOMATIC
	idx = _nearest(car.global_position, 0, path.size())
	_log("level %s | %d m of path (%s) | mode %s corner_g %.2f line %s %.1f | ticks %d Hz | %s" % [
		cfg.level, path.size(), "loop" if closed else "open", cfg.speed_mode, cfg.corner_g,
		cfg.line, cfg.line_offset, Engine.physics_ticks_per_second, cfg.label])
	started = true


#region Path
func _build_path() -> void:
	for child in chain.get_children():
		var p := child as TrackPiece
		if p == null:
			continue
		var length := p.get_path_length()
		var n := maxi(1, ceili(length / STEP))
		for i in range(n):
			var d := length * i / n
			path.append((p.global_transform * p.get_point_transform(d)).orthonormalized())
			path_piece.append(p.name)
			path_dist.append(d)
			path_width.append(p.road_width)
			path_gap.append(p.kind == TrackPiece.Kind.GAP)
	var first := path[0].origin
	var last_piece: TrackPiece = null
	for child in chain.get_children():
		if child is TrackPiece:
			last_piece = child
	var end := (last_piece.global_transform * last_piece.get_exit_transform()).origin
	closed = end.distance_to(first) < 3.0
	# Signed horizontal curvature from the heading change over +/-3 m.
	var n := path.size()
	path_turn.resize(n)
	for i in range(n):
		var a := _heading(path[_wrap(i - 3)])
		var b := _heading(path[_wrap(i + 3)])
		var ang := atan2(a.cross(b).y, a.dot(b))
		path_turn[i] = ang / (6.0 * STEP)


func _heading(xf: Transform3D) -> Vector3:
	var f := -xf.basis.z
	f.y = 0.0
	return f.normalized()


func _wrap(i: int) -> int:
	if closed:
		return posmod(i, path.size())
	return clampi(i, 0, path.size() - 1)


func _plan_speed() -> void:
	var n := path.size()
	var g := float(ProjectSettings.get_setting("physics/3d/default_gravity")) * car.gravity_scale
	var a_lat: float = cfg.corner_g * g
	var top: float = cfg.target_kmh / 3.6
	vplan.resize(n)
	for i in range(n):
		var k := absf(path_turn[i])
		vplan[i] = top if k < 0.0005 or path_gap[i] else minf(top, sqrt(a_lat / k))
	# Brake ahead of corners: never faster than you can slow down from.
	var passes := 2 if closed else 1
	for _p in range(passes):
		for i in range(n - 2, -1, -1):
			var nxt := vplan[_wrap(i + 1)] if closed or i + 1 < n else vplan[i]
			vplan[i] = minf(vplan[i], sqrt(nxt * nxt + 2.0 * cfg.brake_decel * STEP))
		if closed:
			vplan[n - 1] = minf(vplan[n - 1], sqrt(vplan[0] * vplan[0] + 2.0 * cfg.brake_decel * STEP))


func _nearest(pos: Vector3, from: int, count: int) -> int:
	var best := _wrap(from)
	var best_d := INF
	for j in range(count):
		var i := _wrap(from + j)
		var d := path[i].origin.distance_squared_to(pos)
		if d < best_d:
			best_d = d
			best = i
	return best
#endregion


func _physics_process(delta: float) -> void:
	if not started or finished:
		return
	time += delta
	_track_progress()
	_drive()
	_measure(delta)
	if time > cfg.max_time:
		_finish("time limit")
	elif not closed and idx >= path.size() - 3:
		_finish("reached the end")
	elif closed and progress >= path.size() * int(cfg.laps):
		_finish("%d lap(s) done" % cfg.laps)


func _track_progress() -> void:
	var old := idx
	idx = _nearest(car.global_position, idx - 5, 45)
	var moved := idx - old
	if closed and moved < -path.size() / 2:
		moved += path.size()
	progress += maxi(moved, 0)


#region Driving
func _drive() -> void:
	var speed := car.linear_velocity.length()
	top_speed = maxf(top_speed, speed)
	if car.grounded_wheels == 0:
		_set_inputs(0.0, 0.0) # no air control from the autopilot
		return
	# Pure pursuit on the (offset) line.
	var look := clampf(6.0 + speed * 0.45, 6.0, 30.0)
	var ti := _wrap(idx + roundi(look / STEP))
	var target := path[ti].origin + path[ti].basis.x * _line_offset(ti)
	var local := car.global_transform.affine_inverse() * target
	var alpha := atan2(-local.x, -local.z) # + = target is to the left
	var want := atan(2.0 * WHEELBASE * sin(alpha) / maxf(local.length(), 1.0))
	var max_angle := car.max_steer_angle * Car._sample(car.steer_by_speed, clampf(speed / car.steer_reference_speed, 0.0, 1.0))
	var steer := clampf(want / maxf(max_angle, 0.01), -1.0, 1.0)
	# Speed: follow the plan a few meters ahead.
	var v_target: float = vplan[_wrap(idx + 4)]
	if cfg.speed_mode == "fixed":
		v_target = minf(v_target, cfg.target_kmh / 3.6)
	var throttle := 0.0
	var fwd := car.speed
	if fwd < v_target - 1.0:
		throttle = 1.0
	elif fwd > v_target + 1.5:
		throttle = -clampf((fwd - v_target) / 6.0, 0.3, 1.0)
	else:
		throttle = 0.35
	# Stuck against something: back off a bit.
	if fwd < 1.0 and time > 6.0:
		_stuck_time += get_physics_process_delta_time()
	else:
		_stuck_time = 0.0
	_set_inputs(throttle, steer)


func _line_offset(i: int) -> float:
	var half := path_width[i] * 0.5 - 2.0
	match str(cfg.line):
		# +offset = right of center. The outside of a left turn is the right.
		"outside":
			return signf(path_turn[i]) * half if absf(path_turn[i]) > 0.002 else 0.0
		"inside":
			return -signf(path_turn[i]) * half if absf(path_turn[i]) > 0.002 else 0.0
	return clampf(float(cfg.line_offset), -half, half)


func _set_inputs(throttle: float, steer: float) -> void:
	_axis("accelerate", "brake", throttle)
	_axis("steer_left", "steer_right", steer)


func _axis(pos: String, neg: String, value: float) -> void:
	if value > 0.01:
		Input.action_press(pos, value)
		Input.action_release(neg)
	elif value < -0.01:
		Input.action_press(neg, -value)
		Input.action_release(pos)
	else:
		Input.action_release(pos)
		Input.action_release(neg)
#endregion


#region Measuring
func _measure(delta: float) -> void:
	var frame := path[idx]
	var road_up := frame.basis.y
	var piece := path_piece[idx]
	var half := path_width[idx] * 0.5
	var cb := car.global_basis
	var speed_kmh := car.linear_velocity.length() * 3.6
	_wall_cooldown -= delta
	_floor_cooldown -= delta
	for k in range(_recent.size() - 1, -1, -1):
		if time - _recent[k].t > 1.0:
			_recent.remove_at(k)

	# Wheels.
	var driving_normally := car.grounded_wheels >= 3 and _since_landing > 0.5
	for w_i in range(car.wheels.size()):
		var w: CarWheel = car.wheels[w_i]
		_wheel_off_cooldown[w_i] -= delta
		if w.grounded:
			var rel := w.contact_point - frame.origin
			var lat := rel.dot(frame.basis.x)
			var up := rel.dot(road_up)
			var on_road := absf(lat) <= half + 0.1 and absf(up) < 0.25
			var collider := w.get_collider()
			var is_track := collider is TrackPiece
			# Over a gap the nearest frame is the gap itself, so only judge the
			# collider there (wheels can still be on the take-off/landing piece).
			if path_gap[idx]:
				on_road = true
			if (not on_road or not is_track) and _wheel_off_cooldown[w_i] <= 0.0:
				_wheel_off_cooldown[w_i] = 0.5
				var what := "barrier/top" if is_track and up > 0.3 else ("off-track ground" if not is_track else "edge")
				_event("wheel_off", piece, speed_kmh, {"wheel": w.name, "lateral": snappedf(lat, 0.01),
						"height": snappedf(up, 0.01), "hit": what, "collider": str(collider.name) if collider else "?"})
			# A seam is a JOLT: the suspension speed changes abruptly in one tick.
			# Smooth hills change it gradually, so they don't count.
			var rate := (w.compression - _prev_comp[w_i]) / delta
			if _prev_grounded[w_i] and driving_normally and time - _last_reset > 1.0:
				# In meters of suspension per tick, so 60 and 120 Hz compare.
				var jolt := absf(rate - _prev_rate[w_i]) * delta
				if jolt > SEAM_STEP:
					seams_by_piece[piece] = seams_by_piece.get(piece, 0) + 1
					_count("seam")
					if seams_by_piece[piece] <= 3:
						_event("seam", piece, speed_kmh, {"wheel": w.name, "jolt_mm": snappedf(jolt * 1000.0, 0.1),
								"d": snappedf(path_dist[idx], 0.1)}, false)
			_prev_rate[w_i] = rate
		else:
			_prev_rate[w_i] = 0.0
		_prev_comp[w_i] = w.compression
		_prev_grounded[w_i] = w.grounded

	# Landings.
	if car.grounded_wheels == 0:
		_air_time += delta
		_pre_land_vel = car.linear_velocity
	else:
		if _air_time > 0.15:
			var fwd_road := -frame.basis.z
			var pitch := rad_to_deg(asin(clampf((-cb.z).dot(road_up), -1.0, 1.0)))
			var roll := rad_to_deg(asin(clampf(cb.x.dot(road_up), -1.0, 1.0)))
			_landing = {"t": time, "piece": piece, "air_s": snappedf(_air_time, 0.01),
					"speed_kmh": roundi(speed_kmh), "pitch_deg": snappedf(pitch, 0.1),
					"roll_deg": snappedf(roll, 0.1), "impact_mps": snappedf(-_pre_land_vel.dot(road_up), 0.1),
					"first_wheels": car.grounded_wheels, "max_comp": 0.0, "bottomed": false}
			landings.append(_landing)
			_since_landing = 0.0
			_count("landing")
		_air_time = 0.0
	_since_landing += delta
	if not _landing.is_empty() and time - _landing.t < 0.5:
		for w in car.wheels:
			_landing.max_comp = maxf(_landing.max_comp, snappedf(w.compression, 0.01))

	# Body contacts.
	var state := PhysicsServer3D.body_get_direct_state(car.get_rid())
	if state != null:
		for c in range(state.get_contact_count()):
			var n := state.get_contact_local_normal(c)
			var other := state.get_contact_collider_object(c) as Node
			var floorish := absf(n.dot(road_up)) > 0.7
			if floorish:
				if not _landing.is_empty() and time - _landing.t < 0.5:
					_landing.bottomed = true
				if _floor_cooldown <= 0.0:
					_floor_cooldown = 0.5
					_event("body_floor", piece, speed_kmh, {"with": str(other.name) if other else "?",
							"after_landing": _since_landing < 0.5})
			elif _wall_cooldown <= 0.0:
				_wall_cooldown = 0.5
				wall_by_piece[piece] = wall_by_piece.get(piece, 0) + 1
				var rel_v := car.linear_velocity.dot(-n) # speed into the wall
				_event("body_wall", piece, speed_kmh, {"with": str(other.name) if other else "?",
						"into_wall_mps": snappedf(rel_v, 0.1),
						"contact_h": snappedf((state.get_contact_local_position(c) - frame.origin).dot(road_up), 0.01)})

	# Roll / flips.
	var up_dot := cb.y.dot(road_up)
	if car.grounded_wheels > 0:
		var roll_deg := absf(rad_to_deg(atan2(cb.x.dot(road_up), up_dot)))
		if roll_deg > max_roll_deg:
			max_roll_deg = roll_deg
			max_roll_piece = piece
	if up_dot < 0.3:
		_flip_time += delta
		if _flip_time > 0.25:
			var causes: Array = []
			for e in _recent:
				causes.append("%s(%s)" % [e.type, e.piece])
			_event("flip", piece, speed_kmh, {"before": causes, "d": snappedf(path_dist[idx], 0.1)})
			_recover()
	else:
		_flip_time = 0.0
	var below := (car.global_position - frame.origin).dot(road_up)
	var side := absf((car.global_position - frame.origin).dot(frame.basis.x))
	if not path_gap[idx] and (below < -4.0 or side > half + 6.0):
		_event("fell_off", piece, speed_kmh, {"below": snappedf(below, 0.1), "side": snappedf(side, 0.1)})
		_recover()
	if _stuck_time > 3.0:
		_event("stuck", piece, speed_kmh, {})
		_recover()


func _recover() -> void:
	_flip_time = 0.0
	_stuck_time = 0.0
	if not cfg.recover:
		_finish("stopped after %s" % events[-1].type)
		return
	var i := _wrap(idx + 15)
	while path_gap[i] and i < path.size() - 1:
		i = _wrap(i + 5)
	var xf := path[i]
	car.reset_to(Transform3D(xf.basis, xf.origin + xf.basis.y * 0.3))
	_last_reset = time
	idx = i
	_count("recovered")


func _event(type: String, piece: String, speed_kmh: float, data: Dictionary, count := true) -> void:
	if count:
		_count(type)
	var e := {"t": snappedf(time, 0.01), "type": type, "piece": piece, "kmh": roundi(speed_kmh)}
	e.merge(data)
	_recent.append(e)
	if events.size() < MAX_EVENTS:
		events.append(e)


func _count(type: String) -> void:
	counts[type] = counts.get(type, 0) + 1
#endregion


func _finish(reason: String) -> void:
	if finished:
		return
	finished = true
	_set_inputs(0.0, 0.0)
	_log("DONE (%s) after %.1f s, %d m driven, top speed %d km/h" % [reason, time, progress, roundi(top_speed * 3.6)])
	_log("counts %s" % JSON.stringify(counts))
	_log("max roll on the road %.1f deg (%s)" % [max_roll_deg, max_roll_piece])
	if not seams_by_piece.is_empty():
		_log("seams by piece %s" % JSON.stringify(seams_by_piece))
	if not wall_by_piece.is_empty():
		_log("wall hits by piece %s" % JSON.stringify(wall_by_piece))
	for l in landings:
		_log("landing %s" % JSON.stringify(l))
	for e in events:
		if e.type in ["flip", "fell_off", "stuck", "wheel_off", "body_floor", "seam"]:
			_log("event %s" % JSON.stringify(e))
	var report := {"config": cfg, "reason": reason, "time": time, "meters": progress,
			"ticks": Engine.physics_ticks_per_second, "counts": counts, "max_roll_deg": max_roll_deg,
			"seams_by_piece": seams_by_piece, "wall_by_piece": wall_by_piece,
			"landings": landings, "events": events}
	var f := FileAccess.open(REPORT_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(report, "  "))
	_log("report written to %s" % ProjectSettings.globalize_path(REPORT_PATH))
	await get_tree().create_timer(0.5).timeout
	get_tree().quit()


# Every node under `root` (root included) that passes `test`. find_children()
# can't match script class_names, so walk the tree by hand.
static func _all(root: Node, test: Callable) -> Array[Node]:
	var out: Array[Node] = []
	var stack: Array[Node] = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if test.call(n):
			out.append(n)
		stack.append_array(n.get_children())
	return out


func _fail(msg: String) -> void:
	push_error("[TDT] " + msg)
	finished = true


func _log(msg: String) -> void:
	print("[TDT] " + msg)
