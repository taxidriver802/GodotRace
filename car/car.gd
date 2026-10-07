extends CharacterBody3D
## Simple arcade car. The car faces -Z (Godot's "forward").
## Tweak the exported values in the Inspector, or script off this file.
##
## Controls (registered automatically, see _ensure_input_actions):
##   W / Up = accelerate, S / Down = brake & reverse,
##   A / Left, D / Right = steer, Space = handbrake (drift)
##   1 = DEV: flip between the car and the free camera (see dev/dev_camera.gd)
##
## How it moves: the car node itself only ever turns left/right (yaw), which
## keeps the chase camera level. While on the ground, driving happens in the
## plane of the road under the car, so slopes and ramps work. In the air there
## is no engine, steering or grip: just gravity, like a jump should be. The
## visible car (a "Visuals" node made in _ready) tilts to follow the road, and
## in the air its nose follows the flight path.
#region Export
@export_group("Engine")
@export var max_speed := 45.0 # m/s (about 160 km/h)
@export var max_reverse_speed := 12.0
@export var acceleration := 22.0
@export var brake_force := 40.0
@export var coast_drag := 5.0 # slow-down when you let off the throttle

@export_group("Handling")
@export var turn_speed := 2.0 # radians/sec of yaw at full steering
@export var steer_response := 6.0 # how quickly the steering input ramps
@export var max_wheel_angle := 0.5 # visual front-wheel angle (radians)
@export var grip := 10.0 # higher = less sideways sliding
@export var drift_grip := 1.5 # grip while the handbrake is held

@export_group("World")
@export var gravity := 30.0
@export var wheel_radius := 0.35 # only used for the wheel-spin visuals
## How quickly the car's body tilts to match the road (higher = snappier).
@export var ground_tilt_rate := 14.0
## How quickly the car's nose follows its flight path in the air.
@export var air_tilt_rate := 3.0
#endregion

#region Variables
# Signed forward speed in m/s (negative when reversing). Handy for HUDs.
var speed := 0.0
# Smoothed steering value, -1 (right) to 1 (left).
var steer := 0.0
# False while something else (the dev camera) has taken over: the car ignores
# the keys, lets go of the wheel and coasts to a stop.
var controls_enabled := true
#endregion

const ACTIONS := {
	"accelerate": [KEY_W, KEY_UP],
	"brake": [KEY_S, KEY_DOWN],
	"steer_left": [KEY_A, KEY_LEFT],
	"steer_right": [KEY_D, KEY_RIGHT],
	"handbrake": [KEY_SPACE],
	"DEV": [KEY_1]
}

@onready var body: Node3D = $Body
@onready var wheel_fl: Node3D = $WheelFL
@onready var wheel_fr: Node3D = $WheelFR
@onready var _spin_nodes: Array = [
	$WheelFL/Spin, $WheelFR/Spin, $WheelRL/Spin, $WheelRR/Spin
]

# Holds everything you can see of the car, so it can tilt without tilting the
# physics node or the camera.
var _visuals: Node3D
# Smoothed "up" direction of the visible car.
var _visual_up := Vector3.UP
# Was the car on the ground last frame? (Needed to launch off a ramp.)
var _was_grounded := false


func _ready() -> void:
	_ensure_input_actions()
	_visuals = Node3D.new()
	_visuals.name = "Visuals"
	add_child(_visuals)
	for node: Node3D in [body, wheel_fl, wheel_fr, $WheelRL, $WheelRR]:
		node.reparent(_visuals)


func _physics_process(delta: float) -> void:
	_keep_yaw_only()

	var throttle := 0.0
	var steer_input := 0.0
	var handbrake := false
	if controls_enabled:
		throttle = Input.get_axis("brake", "accelerate")
		steer_input = Input.get_axis("steer_right", "steer_left")
		handbrake = Input.is_action_pressed("handbrake")

	steer = move_toward(steer, steer_input, steer_response * delta)

	var grounded := is_on_floor()
	var up := get_floor_normal() if grounded else Vector3.UP

	# On the ground, move_and_slide() zeroes the up/down part of `velocity`, so
	# `velocity` is not the car's real motion on a slope. get_real_velocity() is
	# (how far it actually moved last frame), and is what driving is based on.
	var moving := get_real_velocity() if grounded else velocity

	if grounded:
		# --- Steering (yaw). No turning while stopped, reversed when backing up. ---
		var forward := _flat_forward(up)
		var current_forward_speed := moving.dot(forward)
		var low_speed_factor := clampf(current_forward_speed / 6.0, -1.0, 1.0)
		var high_speed_damping := 1.0 - 0.5 * clampf(absf(current_forward_speed) / max_speed, 0.0, 1.0)
		rotate_y(steer * turn_speed * low_speed_factor * high_speed_damping * delta)

		# --- Split velocity into forward and sideways parts (in the road plane) ---
		forward = _flat_forward(up)
		var right := forward.cross(up).normalized()
		var fwd_speed := moving.dot(forward)
		var side_speed := moving.dot(right)

		# --- Engine, brakes, drag ---
		if throttle > 0.0:
			if fwd_speed < -0.5:
				fwd_speed = move_toward(fwd_speed, 0.0, brake_force * delta)
			else:
				var headroom := 1.0 - clampf(fwd_speed / max_speed, 0.0, 1.0)
				fwd_speed += acceleration * throttle * headroom * delta
		elif throttle < 0.0:
			if fwd_speed > 0.5:
				fwd_speed = move_toward(fwd_speed, 0.0, brake_force * delta)
			else:
				fwd_speed = move_toward(fwd_speed, -max_reverse_speed, acceleration * -throttle * delta)
		else:
			fwd_speed = move_toward(fwd_speed, 0.0, coast_drag * delta)

		if handbrake:
			fwd_speed = move_toward(fwd_speed, 0.0, brake_force * 0.3 * delta)

		# --- Grip: bleed off sideways sliding ---
		var current_grip := drift_grip if handbrake else grip
		side_speed = lerpf(side_speed, 0.0, 1.0 - exp(-current_grip * delta))

		# Driving stays in the road's plane, so leaving a ramp launches the car
		# along the slope it was climbing.
		velocity = forward * fwd_speed + right * side_speed
	else:
		# Airborne: no engine, no steering, no grip. Just gravity. The frame the
		# car leaves the ground it keeps the motion it really had (up a ramp
		# means launched upward), not the flattened `velocity`.
		if _was_grounded:
			velocity = get_real_velocity()
		velocity.y -= gravity * delta
	_was_grounded = grounded

	move_and_slide()

	grounded = is_on_floor()
	up = get_floor_normal() if grounded else Vector3.UP
	speed = (get_real_velocity() if grounded else velocity).dot(_flat_forward(up))
	_update_visuals(delta, grounded, up)


func speed_kmh() -> float:
	return absf(speed) * 3.6


# The car's forward direction, flattened into the plane whose normal is `up`.
func _flat_forward(up: Vector3) -> Vector3:
	var f := -global_transform.basis.z
	return (f - up * f.dot(up)).normalized()


# Something else (a start gate on a ramp) may have placed the car tilted. This
# node only turns left/right, so strip any pitch and roll.
func _keep_yaw_only() -> void:
	if global_transform.basis.y.dot(Vector3.UP) > 0.9999:
		return
	var f := -global_transform.basis.z
	f.y = 0.0
	if f.length() > 0.001:
		global_transform.basis = Basis.looking_at(f.normalized(), Vector3.UP)


func _update_visuals(delta: float, grounded: bool, up: Vector3) -> void:
	# Wheels roll with the car's speed.
	var spin_angle := speed / wheel_radius * delta
	for spin: Node3D in _spin_nodes:
		spin.rotate_x(-spin_angle)

	# Front wheels turn with the steering.
	wheel_fl.rotation.y = steer * max_wheel_angle
	wheel_fr.rotation.y = steer * max_wheel_angle

	# Body leans slightly outward in corners.
	var lean := -steer * clampf(speed / max_speed, 0.0, 1.0) * 0.06
	body.rotation.z = lerpf(body.rotation.z, lean, 8.0 * delta)

	# Tilt the whole visible car: onto the road when grounded, along the flight
	# path when airborne.
	var heading := -global_transform.basis.z # level, since this node only yaws
	var side := heading.cross(Vector3.UP).normalized()
	var target_up := up
	var rate := ground_tilt_rate
	if not grounded:
		rate = air_tilt_rate
		if Vector2(velocity.x, velocity.z).length() > 4.0:
			var path := velocity.normalized()
			if path.dot(heading) < 0.0:
				path = -path
			target_up = side.cross(path).normalized()
	# lerp + normalize rather than slerp: slerp errors out when the two
	# directions are almost identical, which is most of the time.
	_visual_up = _visual_up.lerp(target_up, 1.0 - exp(-rate * delta)).normalized()

	var vis_right := heading.cross(_visual_up).normalized()
	var vis_forward := _visual_up.cross(vis_right)
	_visuals.global_transform.basis = Basis(vis_right, _visual_up, -vis_forward)


# Registers default key bindings if the project doesn't define them yet, so the
# car works out of the box. Once you add these actions in Project Settings >
# Input Map, your bindings are used instead.
func _ensure_input_actions() -> void:
	for action: String in ACTIONS:
		if InputMap.has_action(action):
			continue
		InputMap.add_action(action)
		for key: int in ACTIONS[action]:
			var event := InputEventKey.new()
			event.physical_keycode = key as Key
			InputMap.action_add_event(action, event)
