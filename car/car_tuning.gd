class_name CarTuning
extends Resource
## A saved handling setup (a "preset") for the raycast car: engine, gearbox
## and the main grip/aero numbers in one file. Drop a .tres of this into the
## Car's `tuning` slot and it overrides those values when the car spawns.
## Leave the slot empty to use whatever is set on the Car / Engine / Gearbox
## nodes themselves (handy while experimenting).
##
## Presets live in res://car/presets/. To make a new one: duplicate a .tres,
## rename it, change the numbers.

@export_group("Engine")
@export var peak_torque := 480.0
@export var redline_rpm := 7500.0
@export var idle_rpm := 1000.0
@export var launch_rpm := 3500.0
@export var engine_braking := 110.0
## Leave empty to keep the Engine node's own torque curve.
@export var torque_curve: Curve

@export_group("Gearbox")
@export var ratios: PackedFloat32Array = [3.0, 2.25, 1.78, 1.47, 1.25]
@export var reverse_ratio := 3.2
@export var final_drive := 3.9
@export var shift_time := 0.2
@export var upshift_rpm_frac := 0.92
@export var downshift_rpm_frac := 0.45

@export_group("Car")
@export var drag_coefficient := 1.5
@export var rolling_resistance := 1.0
@export var tire_friction := 1.6
@export var front_grip := 18.0
@export var rear_grip := 16.0
@export var handbrake_rear_grip := 0.2


## Copy every value onto the car and its Engine / Gearbox nodes.
func apply_to(car: Car) -> void:
	var e := car.engine
	e.peak_torque = peak_torque
	e.redline_rpm = redline_rpm
	e.idle_rpm = idle_rpm
	e.launch_rpm = launch_rpm
	e.engine_braking = engine_braking
	if torque_curve != null:
		e.torque_curve = torque_curve
	var g := car.gearbox
	g.ratios = ratios
	g.reverse_ratio = reverse_ratio
	g.final_drive = final_drive
	g.shift_time = shift_time
	g.upshift_rpm_frac = upshift_rpm_frac
	g.downshift_rpm_frac = downshift_rpm_frac
	car.drag_coefficient = drag_coefficient
	car.rolling_resistance = rolling_resistance
	car.tire_friction = tire_friction
	car.front_grip = front_grip
	car.rear_grip = rear_grip
	car.handbrake_rear_grip = handbrake_rear_grip
