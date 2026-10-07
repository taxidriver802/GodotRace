class_name Car
extends RigidBody3D
## Raycast arcade car. The car faces -Z.
##
## The body is a real rigid body: gravity pulls it, it can pitch, roll, flip
## and bounce off walls. It has no wheel colliders. Each of the 4 wheels is a
## downward ray (CarWheel, raycast_wheel.gd) and ONLY a wheel that touches the
## ground pushes on the body, at its own contact point:
##   1. suspension  spring + damper along the car's up      (holds the car up)
##   2. grip        cancels that wheel's sideways sliding    (makes it turn)
##   3. drive/brake along the wheel's rolling direction      (go and stop)
## Squat, dive, body roll and landing on two wheels all come out of those
## forces; nothing is faked.
##
## Why _physics_process and not _integrate_forces: apply_force() here is
## queued for exactly the next physics step, which is all a raycast car needs,
## and RayCast3D nodes (refreshed with force_raycast_update() right before
## reading them) are simple to use here. _integrate_forces only adds value when
## you need to overwrite the body's state mid-step.
##
## Controls (registered automatically, see _ensure_input_actions):
##   W / Up = accelerate, S / Down = brake & reverse,
##   A / Left, D / Right = steer, Space = handbrake (drift)
##   In the air: W/S pitch, A/D roll (gentle, see the Air group)
##   R = reset (put the car back on its wheels), 2 = car debug view,
##   1 = DEV free camera (dev/dev_camera.gd)

enum Drive { RWD, FWD, AWD }

#region Exports
@export_group("Drivetrain")
## Engine power and gearing live on the child nodes "Engine" (CarEngine) and
## "Gearbox" (Gearbox); select them in the scene tree to tune them.
## Optional saved setup (res://car/presets/*.tres). When set, it overrides the
## engine, gearbox and main grip/aero values when the car spawns. Leave empty
## to use the values on the nodes themselves.
@export var tuning: CarTuning
## Which wheels push. RWD = rear steps out more easily, AWD = most stable.
@export var drive: Drive = Drive.RWD
## Top speed backwards, m/s (the engine stops pushing past it).
@export var max_reverse_speed := 12.0

@export_group("Brakes")
## Braking strength, m/s². Higher = shorter stops.
@export var brake_decel := 28.0
## Tire rolling resistance with no pedal pressed, m/s². Engine braking and
## air drag add to it. Higher = coasts less far.
@export var rolling_resistance := 1.0
## Extra braking on the rear wheels while the handbrake is held, m/s².
@export var handbrake_decel := 5.0

@export_group("Steering")
## Front wheel angle at full lock (radians, 0.5 = ~29°). Higher = tighter turns.
@export var max_steer_angle := 0.5
## Share of max_steer_angle allowed at each fraction of steer_reference_speed.
## Lower on the right = calmer, more stable steering at high speed.
@export var steer_by_speed: Curve
## The speed (m/s) the right end of steer_by_speed means. About the car's
## top speed (50 = 180 km/h).
@export var steer_reference_speed := 50.0
## How fast the wheel turns toward your input (full lock per second).
## Higher = twitchier, lower = smoother.
@export var steer_speed := 5.0

@export_group("Grip")
## How quickly the FRONT tires stop a sideways slide (per second).
## Higher = more front grip = sharper turn-in. Too low = understeer.
@export var front_grip := 18.0
## How quickly the REAR tires stop a sideways slide (per second).
## Lower than front = the tail steps out (oversteer, easier drifts).
@export var rear_grip := 16.0
## Front grip multiplier by slip (x: 0 = rolling straight .. 1 = fully
## sideways). Dropping on the right means a sliding tire grips less.
@export var front_grip_curve: Curve
## Same for the rear. A deeper drop than the front makes slides last longer.
@export var rear_grip_curve: Curve
## Tire friction: the most a tire can push (grip + drive + brake combined) is
## this times the weight on it. Higher = more cornering/braking grip overall.
## This is the cap that keeps the car from rolling over in fast turns.
@export var tire_friction := 1.6
## Rear grip multiplier while the handbrake is held. Lower = bigger drifts.
@export_range(0.0, 1.0, 0.05) var handbrake_rear_grip := 0.2
## Push into the road that grows with speed (newtons per (m/s)²). Higher =
## more planted at speed, but drags the car down off crests sooner.
@export var downforce := 1.0

@export_group("Aero")
## Air drag = 0.5 x air_density x drag_coefficient x frontal_area x speed².
## It grows with the square of speed, so it is what sets the top speed: the
## car stops accelerating where engine push = drag. Higher = lower top speed
## and the car slows down faster when you lift off.
## (Real cars are about 0.3; it's high here on purpose for arcade pace.)
@export var drag_coefficient := 1.5
## Front-on area of the car, m².
@export var frontal_area := 2.2
## kg/m³. 1.225 is sea level; lower = thinner air = less drag.
@export var air_density := 1.225

@export_group("Suspension")
## Spring length when it's not pushing (meters, mount to wheel center).
@export var rest_length := 0.5
## Extra droop past rest_length so the tire keeps touching through dips.
@export var travel := 0.15
## Tire radius (meters). Match the tire mesh.
@export var wheel_radius := 0.35
## Spring strength, N per meter squeezed. Higher = stiffer, rides higher.
## Too high + low damping = bouncy and jittery.
@export var spring_stiffness := 40000.0
## Damper, N per m/s. Higher = settles faster, less bounce; too high = harsh.
@export var spring_damping := 3500.0

@export_group("Air")
## Pitch control in the air (W/S). 0 = none. Keep it low for now.
@export var air_pitch := 1.0
## Roll control in the air (A/D). 0 = none.
@export var air_roll := 0.6
## Seconds upside down or on its side (and nearly stopped) before the car
## puts itself back on its wheels. 0 = never (use R).
@export var auto_right_delay := 2.0

@export_group("Debug")
## Draw rays, forces and a per-wheel readout. Toggle in game with 2.
@export var debug_draw := false:
	set(value):
		debug_draw = value
		if _debug != null:
			_debug.set_enabled(value)
#endregion

#region Public state
## Signed forward speed in m/s (negative when reversing). Handy for HUDs.
var speed := 0.0
## Smoothed steering, -1 (right) to 1 (left).
var steer := 0.0
## False while something else (the dev camera) has taken over: the car ignores
## the keys, lets go of the wheel and coasts to a stop.
var controls_enabled := true
## How many wheels touched the ground this tick (0 = airborne).
var grounded_wheels := 0

# --- Telemetry (read by the debug view and the HUD) ---
## Engine speed in rpm (0 = no engine model yet).
var engine_rpm := 0.0
## How hard the engine is being asked to work, 0..1 (for the engine sound).
var engine_load := 0.0
## Current gear: -1 = reverse, 0 = none/neutral, 1.. = forward gears.
var gear := 0
## Total push from the driven wheels along the car this tick, N (+ = forward).
var drive_force_total := 0.0
## Air drag on the body this tick, N.
var drag_force := 0.0
## Counts down after a manual downshift was refused (it would over-rev the
## engine). The HUD can flash while it's above 0.
var shift_blocked_time := 0.0
#endregion

const ACTIONS := {
	"accelerate": [KEY_W, KEY_UP],
	"brake": [KEY_S, KEY_DOWN],
	"steer_left": [KEY_A, KEY_LEFT],
	"steer_right": [KEY_D, KEY_RIGHT],
	"handbrake": [KEY_SPACE],
	"reset_car": [KEY_R],
	"car_debug": [KEY_2],
	"shift_up": [KEY_E],
	"shift_down": [KEY_Q],
	"toggle_transmission": [KEY_G],
	"DEV": [KEY_1],
}

var wheels: Array[CarWheel] = []
@onready var engine: CarEngine = $Engine
@onready var gearbox: Gearbox = $Gearbox
var _debug: CarDebug
var _camera: Node
var _tipped_time := 0.0


func _ready() -> void:
	_ensure_input_actions()
	add_to_group("car")
	can_sleep = false # a sleeping body would ignore the suspension
	continuous_cd = true # don't tunnel through thin walls at speed
	# No hidden damping on top of the project default: aero drag and rolling
	# resistance are the only things slowing the car (see the Aero group).
	linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	linear_damp = 0.0
	for child in get_children():
		if child is CarWheel:
			wheels.append(child)
	if wheels.size() != 4:
		push_warning("Car: expected 4 CarWheel children, found %d." % wheels.size())
	_camera = get_node_or_null("ChaseCamera")
	_make_default_curves()
	if tuning != null:
		tuning.apply_to(self)
		engine.reset()
		gearbox.reset()
	# Automatic / manual comes from the player's settings, and follows them if
	# they change mid-race (G, or a settings screen).
	var settings := get_node_or_null("/root/GameSettings")
	if settings != null:
		_apply_transmission(settings.automatic_transmission)
		settings.transmission_changed.connect(_apply_transmission)
	_debug = CarDebug.new()
	_debug.name = "Debug"
	_debug.car = self
	add_child(_debug)
	_debug.set_enabled(debug_draw)


func _physics_process(delta: float) -> void:
	if Input.is_action_just_pressed("car_debug"):
		debug_draw = not debug_draw

	# --- Input ---
	var throttle := 0.0
	var steer_input := 0.0
	var handbrake := false
	if controls_enabled:
		throttle = Input.get_axis("brake", "accelerate")
		steer_input = Input.get_axis("steer_right", "steer_left")
		handbrake = Input.is_action_pressed("handbrake")
		if Input.is_action_just_pressed("reset_car"):
			_put_back_on_wheels()
			return
		if Input.is_action_just_pressed("toggle_transmission"):
			_toggle_transmission()
		if gearbox.mode == Gearbox.Mode.MANUAL:
			if Input.is_action_just_pressed("shift_up"):
				_manual_shift(1)
			if Input.is_action_just_pressed("shift_down"):
				_manual_shift(-1)
	shift_blocked_time = maxf(shift_blocked_time - delta, 0.0)
	steer = move_toward(steer, steer_input, steer_speed * delta)

	# --- Sense the ground ---
	var up := global_basis.y
	grounded_wheels = 0
	for w in wheels:
		w.sense(rest_length, travel, wheel_radius)
		if w.grounded:
			grounded_wheels += 1
	speed = linear_velocity.dot(-global_basis.z)
	var speed_frac := clampf(absf(speed) / steer_reference_speed, 0.0, 1.0)

	# --- What the pedals mean right now ---
	# Pressing against the way you're moving = brake. Nearly stopped + brake =
	# reverse. Nothing pressed = roll to a stop (and hold still once stopped).
	# In reverse gear the brake pedal is the gas, like most racing games.
	var braking := false
	var holding := false
	var engine_throttle := 0.0 # what the engine is asked for, 0..1
	if throttle > 0.0:
		if speed < -1.0:
			braking = true # rolling backwards: W brakes first
		else:
			if gearbox.gear < 1:
				gearbox.shift(1)
			engine_throttle = throttle
	elif throttle < 0.0:
		if speed > 1.0:
			braking = true
		else:
			if gearbox.gear != -1:
				gearbox.shift(-1)
			if -speed < max_reverse_speed:
				engine_throttle = -throttle
	elif absf(speed) < 0.5 and not handbrake:
		holding = true

	# --- Engine and gearbox ---
	# The engine is connected to the road when a gear is in and at least one
	# driven wheel touches the ground. Its torque, multiplied by the gear
	# ratio, becomes push at the tires: force = torque x ratio x efficiency / radius.
	var driven_down := false
	for w in wheels:
		if w.grounded and _is_driven(w):
			driven_down = true
	gearbox.update(delta, speed, wheel_radius, engine.redline_rpm, engine_throttle, driven_down)
	# Mid-shift the clutch is out: no drive (the car's nose dips) and the revs
	# swing to meet the new gear.
	var wheel_rpm := gearbox.rpm_at(speed, wheel_radius, gearbox.gear)
	var connected := driven_down and gearbox.gear != 0 and not gearbox.is_shifting()
	if gearbox.is_shifting():
		engine.rev_match(delta, wheel_rpm)
	else:
		engine.update(delta, wheel_rpm, connected, engine_throttle)
	engine_rpm = engine.rpm
	engine_load = engine_throttle
	gear = gearbox.gear
	var engine_force := 0.0 # N at the driven tires, all together (+ = forward)
	if connected:
		engine_force = engine.torque(engine_throttle) * gearbox.ratio() * gearbox.efficiency / wheel_radius
		if gearbox.gear < 0:
			engine_force = -engine_force

	var steer_angle := steer * max_steer_angle * _sample(steer_by_speed, speed_frac)
	var driven_count := 4 if drive == Drive.AWD else 2
	var wheel_mass := mass / 4.0

	# --- Per-wheel forces ---
	for w in wheels:
		w.steer_angle = steer_angle if w.is_front else 0.0
		if not w.grounded:
			continue
		var offset := w.contact_point - global_position
		# Velocity of the body at this wheel (includes spin, e.g. while turning).
		var point_vel := linear_velocity + angular_velocity.cross(offset)
		var wb := w.wheel_basis()
		var n := w.contact_normal
		# Wheel directions laid flat on the road surface.
		var roll_dir := _on_plane(-wb.z, n)
		var side_dir := _on_plane(wb.x, n)

		# 1. Suspension: spring (how squeezed) + damper (how fast it's squeezing).
		# The damper uses the body's speed at the wheel rather than the change in
		# compression, so a small step between road pieces doesn't spike it.
		if w.compression > 0.0:
			var squeeze_speed := -point_vel.dot(up)
			var f := spring_stiffness * w.compression + spring_damping * squeeze_speed
			w.suspension_force = up * maxf(f, 0.0) # a spring never pulls the car down

		# 2. Grip: remove part of the sideways sliding at this wheel each tick.
		var side_speed := point_vel.dot(side_dir)
		w.slip = clampf(absf(side_speed) / maxf(point_vel.length(), 2.0), 0.0, 1.0)
		var grip_rate: float
		if w.is_front:
			grip_rate = front_grip * _sample(front_grip_curve, w.slip)
		else:
			grip_rate = rear_grip * _sample(rear_grip_curve, w.slip)
			if handbrake:
				grip_rate *= handbrake_rear_grip
		var removed := side_speed * (1.0 - exp(-grip_rate * delta))
		w.grip_force = -side_dir * removed * wheel_mass / delta

		# 3. Drive / brake along the rolling direction.
		var roll_speed := point_vel.dot(roll_dir)
		var long_force := 0.0
		if _is_driven(w):
			# Split over ALL driven wheels, so a driven wheel in the air simply
			# loses its share of the power.
			long_force += engine_force / driven_count
		var stop_accel := 0.0
		if braking or holding:
			stop_accel = brake_decel
		elif throttle == 0.0:
			stop_accel = rolling_resistance
		if handbrake and not w.is_front:
			stop_accel += handbrake_decel
		if stop_accel > 0.0:
			# Never more than what brings this wheel to a stop this tick (no
			# overshooting into reverse, no jitter at rest).
			long_force -= signf(roll_speed) * wheel_mass * minf(stop_accel, absf(roll_speed) / delta)
		w.drive_force = roll_dir * long_force

		# Friction circle: a tire can only push as hard as friction x the weight
		# on it. Asking for more (hard cornering + throttle, a lightly loaded
		# wheel) scales grip and drive down together, so the tire slides.
		var limit := tire_friction * spring_stiffness * w.compression
		var tire_force := w.grip_force + w.drive_force
		if tire_force.length() > limit:
			var k := limit / tire_force.length()
			w.grip_force *= k
			w.drive_force *= k

		apply_force(w.suspension_force + w.grip_force + w.drive_force, offset)

	drive_force_total = 0.0
	for w in wheels:
		if _is_driven(w):
			drive_force_total += w.drive_force.dot(-global_basis.z)

	# --- Whole-car forces ---
	# Aero drag, opposite to the way the car is moving (in the air too).
	var v := linear_velocity
	var drag := 0.5 * air_density * drag_coefficient * frontal_area * v.length_squared()
	drag_force = drag
	if drag > 0.0:
		apply_central_force(-v.normalized() * drag)
	if grounded_wheels > 0:
		apply_central_force(-up * downforce * speed * speed)
	elif controls_enabled:
		# Gentle air control. Brake = nose up, accelerate = nose down; steer rolls.
		apply_torque(global_basis.x * -throttle * air_pitch * mass)
		apply_torque(global_basis.z * steer_input * air_roll * mass)

	_check_tipped(delta)

	# --- Visuals ---
	for w in wheels:
		var roll := speed
		if w.grounded:
			var off := w.contact_point - global_position
			roll = (linear_velocity + angular_velocity.cross(off)).dot(-w.wheel_basis().z)
		w.update_visual(roll, delta)
	if debug_draw:
		_debug.draw_frame(wheels, grounded_wheels)


func speed_kmh() -> float:
	return absf(speed) * 3.6


## Teleport the car (spawns, restarts, resets) and stop it dead: no leftover
## speed or spin. Put `xf` slightly above the road so the springs settle the
## car instead of popping it out of the ground.
func reset_to(xf: Transform3D) -> void:
	var rid := get_rid()
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, Vector3.ZERO)
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, Vector3.ZERO)
	global_transform = xf
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	steer = 0.0
	speed = 0.0
	_tipped_time = 0.0
	if gearbox != null:
		gearbox.reset()
	if engine != null:
		engine.reset()
	reset_physics_interpolation()
	if _camera != null and _camera.has_method("snap"):
		_camera.snap()


# Upside down or on its side and barely moving for auto_right_delay seconds:
# put it back on its wheels.
func _check_tipped(delta: float) -> void:
	if auto_right_delay <= 0.0:
		return
	if global_basis.y.dot(Vector3.UP) < 0.35 and linear_velocity.length() < 4.0:
		_tipped_time += delta
		if _tipped_time >= auto_right_delay:
			_put_back_on_wheels()
	else:
		_tipped_time = 0.0


# Upright, same heading, lifted a little, stopped.
func _put_back_on_wheels() -> void:
	var heading := -global_basis.z
	heading.y = 0.0
	if heading.length() < 0.1: # nose straight up/down: use the roof direction
		heading = global_basis.y
		heading.y = 0.0
	if heading.length() < 0.1:
		heading = Vector3.FORWARD
	reset_to(Transform3D(Basis.looking_at(heading.normalized(), Vector3.UP), global_position + Vector3.UP * 1.0))


func _apply_transmission(automatic: bool) -> void:
	gearbox.mode = Gearbox.Mode.AUTOMATIC if automatic else Gearbox.Mode.MANUAL


func _toggle_transmission() -> void:
	var settings := get_node_or_null("/root/GameSettings")
	if settings != null:
		settings.toggle_transmission() # saves it and calls _apply_transmission
	else:
		_apply_transmission(gearbox.mode == Gearbox.Mode.MANUAL)


# Manual mode: E / Q. Reverse is still picked by braking at a standstill.
func _manual_shift(direction: int) -> void:
	if gearbox.is_shifting():
		return
	var to := gearbox.gear + direction
	if gearbox.gear == -1:
		if direction < 0 or absf(speed) > 1.0:
			return
		to = 1
	if to < 1 or to > gearbox.top_gear():
		return
	# Refuse a downshift that would spin the engine past redline.
	if direction < 0 and gearbox.rpm_at(speed, wheel_radius, to) > engine.redline_rpm:
		shift_blocked_time = 0.6
		return
	gearbox.shift(to)


func _is_driven(w: CarWheel) -> bool:
	match drive:
		Drive.FWD:
			return w.is_front
		Drive.RWD:
			return not w.is_front
	return true


static func _on_plane(v: Vector3, normal: Vector3) -> Vector3:
	return (v - normal * v.dot(normal)).normalized()


static func _sample(curve: Curve, x: float) -> float:
	return curve.sample_baked(x) if curve != null else 1.0


# Sensible curves if the scene didn't provide them.
func _make_default_curves() -> void:
	if steer_by_speed == null:
		steer_by_speed = _curve([Vector2(0.0, 1.0), Vector2(0.5, 0.55), Vector2(1.0, 0.35)])
	if front_grip_curve == null:
		front_grip_curve = _curve([Vector2(0.0, 1.0), Vector2(0.35, 0.9), Vector2(1.0, 0.7)])
	if rear_grip_curve == null:
		rear_grip_curve = _curve([Vector2(0.0, 1.0), Vector2(0.3, 0.8), Vector2(1.0, 0.5)])


static func _curve(points: Array) -> Curve:
	var c := Curve.new()
	for p: Vector2 in points:
		c.add_point(p)
	return c


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
