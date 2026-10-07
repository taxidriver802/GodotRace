class_name CarEngine
extends Node
## The car's engine: how fast it spins (rpm) and how hard it twists (torque).
## Child of the Car. The car calls update() and torque() once per physics tick;
## this node never processes on its own, so the order of steps stays fixed.
##
## How rpm works:
## - Clutch locked (driving along): rpm is set by the wheels, rpm = wheel speed
##   x gear ratio. Faster car or lower gear = higher rpm.
## - Clutch slipping (pulling away, mid-shift, wheels in the air): the engine
##   spins freely toward a target set by the throttle, like revving in neutral.
##   When pulling away it holds around launch_rpm until the wheels catch up.

## Engine speed at rest (rpm).
@export var idle_rpm := 1000.0
## Rev limiter (rpm). Torque cuts out here until the revs drop a little.
@export var redline_rpm := 7500.0
## Revs the clutch slips at when pulling away from a stop. Higher = harder
## launch (more torque, more wheelspin).
@export var launch_rpm := 3500.0
## Maximum torque, N·m. The main "how strong is the engine" knob.
@export var peak_torque := 480.0
## Share of peak_torque at each rpm (x: rpm / redline_rpm, y: 0..1). Where the
## curve is high is the power band; that is where you want to stay.
@export var torque_curve: Curve
## How fast the revs rise / fall when the engine spins freely (rpm per second).
@export var rev_up_rate := 15000.0
@export var rev_down_rate := 8000.0
## Off the throttle the engine holds the car back with up to this much torque
## (N·m, at redline; fades to 0 at idle). Multiplied by the gear ratio, so it
## slows the car more in low gears. Higher = more slowing when you lift off.
@export var engine_braking := 110.0

## Current engine speed.
var rpm := 1000.0
## True while the rev limiter is cutting torque.
var limiter := false
## True when the engine is locked to the wheels (not slipping the clutch).
var clutch_locked := false

const LIMITER_DROP := 300.0 # rpm below redline before power comes back


func _ready() -> void:
	rpm = idle_rpm
	if torque_curve == null:
		torque_curve = Curve.new()
		for p: Vector2 in [Vector2(0.0, 0.5), Vector2(0.13, 0.6), Vector2(0.4, 0.88),
				Vector2(0.65, 1.0), Vector2(0.87, 0.93), Vector2(1.0, 0.82)]:
			torque_curve.add_point(p)


## Back to idle (spawns, restarts, resets).
func reset() -> void:
	rpm = idle_rpm
	limiter = false
	clutch_locked = false


## wheel_rpm: what the wheels would spin the engine at in the current gear.
## connected: a gear is engaged and a driven wheel is on the ground.
## throttle: 0..1.
func update(delta: float, wheel_rpm: float, connected: bool, throttle: float) -> void:
	var slip_target := lerpf(idle_rpm, launch_rpm, throttle)
	clutch_locked = connected and wheel_rpm >= slip_target
	if clutch_locked:
		rpm = wheel_rpm
	else:
		var target := slip_target if connected else lerpf(idle_rpm, redline_rpm, throttle)
		var rate := rev_up_rate if target > rpm else rev_down_rate
		rpm = move_toward(rpm, target, rate * delta)
	rpm = clampf(rpm, idle_rpm, redline_rpm + 500.0)
	if rpm >= redline_rpm:
		limiter = true
	elif rpm < redline_rpm - LIMITER_DROP:
		limiter = false


## During a shift (clutch out): the revs swing toward what the new gear needs.
func rev_match(delta: float, target_rpm: float) -> void:
	clutch_locked = false
	var target := maxf(target_rpm, idle_rpm)
	var rate := rev_up_rate if target > rpm else rev_down_rate
	rpm = move_toward(rpm, target, rate * delta)
	if rpm < redline_rpm - LIMITER_DROP:
		limiter = false


## Torque at the crank right now, N·m, for a throttle of 0..1. Negative off the
## throttle (engine braking) while the clutch is locked to the wheels.
func torque(throttle: float) -> float:
	if throttle <= 0.0:
		if not clutch_locked:
			return 0.0
		return -engine_braking * clampf((rpm - idle_rpm) / (redline_rpm - idle_rpm), 0.0, 1.0)
	if limiter:
		return 0.0
	return peak_torque * torque_curve.sample_baked(rpm / redline_rpm) * throttle
