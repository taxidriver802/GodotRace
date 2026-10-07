class_name Gearbox
extends Node
## The car's transmission: gear ratios between the engine and the wheels.
## Child of the Car; the car drives it every physics tick (it never processes
## on its own).
##
## A gear ratio multiplies torque and divides speed. Low gears (big ratios)
## push hard but rev out at low speed; high gears (small ratios) push gently
## but let the car go fast. final_drive applies on top of every gear.
##
## AUTOMATIC: shifts up when the revs pass upshift_rpm_frac x redline, and
## down when they fall under downshift_rpm_frac x redline (only if the lower
## gear won't over-rev). The gap between the two, plus shift_cooldown, stops
## it hunting back and forth between two gears.

enum Mode { AUTOMATIC, MANUAL }

## Forward gear ratios, 1st first.
@export var ratios: PackedFloat32Array = [3.0, 2.25, 1.78, 1.47, 1.25]
## Reverse gear ratio.
@export var reverse_ratio := 3.2
## Extra reduction on top of every gear (the differential).
@export var final_drive := 3.9
## Share of engine torque that reaches the wheels (the rest is lost in the
## gearbox and axles).
@export_range(0.5, 1.0, 0.01) var efficiency := 0.85
## Seconds the clutch is out for each shift: no drive, so the car's nose dips
## and the revs drop to meet the new gear. Lower = snappier, racier shifts.
@export_range(0.0, 1.0, 0.01) var shift_time := 0.2

@export_group("Automatic")
## Upshift above this share of redline. Higher = holds gears longer.
@export_range(0.5, 1.0, 0.01) var upshift_rpm_frac := 0.92
## Downshift below this share of redline. Higher = drops gears sooner
## (more pull out of corners, busier gearbox).
@export_range(0.2, 0.8, 0.01) var downshift_rpm_frac := 0.45
## Minimum seconds between shifts.
@export var shift_cooldown := 0.4

## -1 = reverse, 0 = neutral, 1.. = forward gears.
var gear := 1
var mode := Mode.AUTOMATIC

var _cooldown := 0.0
var _shift_timer := 0.0


## Back to 1st, no shift in progress (spawns, restarts, resets).
func reset() -> void:
	gear = 1
	_cooldown = 0.0
	_shift_timer = 0.0


## True during a shift (clutch out, no drive).
func is_shifting() -> bool:
	return _shift_timer > 0.0


## Total ratio engine -> wheels in the current gear (0 in neutral). Always
## positive; which way the car is pushed is up to the car (reverse = backwards).
func ratio() -> float:
	return ratio_for(gear)


## Total ratio engine -> wheels in gear `g` (0 in neutral).
func ratio_for(g: int) -> float:
	if g == 0:
		return 0.0
	if g < 0:
		return reverse_ratio * final_drive
	return ratios[clampi(g, 1, ratios.size()) - 1] * final_drive


## Engine rpm the wheels would turn the engine at, at `speed` m/s in gear `g`.
func rpm_at(speed: float, wheel_radius: float, g: int) -> float:
	return absf(speed) / wheel_radius * ratio_for(g) * 60.0 / TAU


func top_gear() -> int:
	return ratios.size()


## Put it in gear `to` (-1 = reverse). Returns false if that gear doesn't exist.
func shift(to: int) -> bool:
	if to < -1 or to > ratios.size() or to == gear:
		return false
	# Pulling away (into 1st or reverse from a standstill) needs no clutch
	# pause; every other change takes shift_time.
	var from_rest := gear <= 0 or to <= 0
	gear = to
	_cooldown = shift_cooldown
	_shift_timer = 0.0 if from_rest else shift_time
	return true


## Called by the car every physics tick. In AUTOMATIC, picks the forward gear.
## speed: forward speed (m/s); redline: the engine's redline_rpm;
## grounded: a driven wheel touches the road (no shifting in the air).
func update(delta: float, speed: float, wheel_radius: float, redline: float,
		throttle: float, grounded: bool) -> void:
	_cooldown = maxf(_cooldown - delta, 0.0)
	_shift_timer = maxf(_shift_timer - delta, 0.0)
	if mode != Mode.AUTOMATIC or gear < 1 or not grounded or _cooldown > 0.0:
		return
	var rpm := rpm_at(speed, wheel_radius, gear)
	if throttle > 0.0 and gear < top_gear() and rpm > redline * upshift_rpm_frac:
		shift(gear + 1)
	elif gear > 1 and rpm < redline * downshift_rpm_frac:
		# Only drop a gear if the lower gear won't land too high in the revs.
		if rpm_at(speed, wheel_radius, gear - 1) < redline * upshift_rpm_frac * 0.95:
			shift(gear - 1)
