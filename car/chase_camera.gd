extends Node3D
## Chase camera for the raycast car. Put it as a child of the car with a
## SpringArm3D ("CameraArm") and a Camera3D under it.
##
## The car's body pitches and rolls on its suspension. If the camera were a
## plain child it would roll with it, which is sickening. So this node is
## `top_level` (it ignores the car's transform) and follows the car itself every
## physics tick: position and heading only, always level. The spring arm still
## pulls the camera in when a wall gets between it and the car.

## Height of the point the camera orbits, above the car's origin (meters).
@export var height := 1.6
## How tightly the camera keeps up sideways/forwards. Higher = less lag.
@export var follow_rate := 30.0
## How tightly it follows up/down. Lower = smoother over bumps and landings.
@export var height_rate := 8.0
## How quickly it swings around to stay behind the car. Lower = lazier.
@export var yaw_rate := 6.0
## 0 = always look along the car's nose. 1 = look where the car is actually
## going (shows the slide when drifting).
@export_range(0.0, 1.0, 0.05) var look_ahead := 0.3

var car: RigidBody3D

@onready var arm: SpringArm3D = $CameraArm


func _ready() -> void:
	top_level = true
	# Run after the car each physics tick.
	process_physics_priority = 100
	car = get_parent() as RigidBody3D
	if car == null:
		push_warning("ChaseCamera: parent should be the car (a RigidBody3D).")
		set_physics_process(false)
		return
	# The arm hangs off this (non-physics) node, so tell it to ignore the car's
	# own body or it would collide with it and pull the camera in.
	arm.add_excluded_object(car.get_rid())
	snap.call_deferred()
	# Field of view follows the player's setting (Settings > Gameplay).
	var settings := get_node_or_null("/root/GameSettings")
	if settings != null:
		_on_setting_changed("camera_fov", settings.get_value("camera_fov"))
		settings.changed.connect(_on_setting_changed)


func _on_setting_changed(key: String, value: Variant) -> void:
	var camera := arm.get_node_or_null("Camera3D") as Camera3D
	if key == "camera_fov" and camera != null:
		camera.fov = value


## Jump straight behind the car with no smoothing (spawns, resets).
func snap() -> void:
	if car == null:
		return
	global_position = car.global_position + Vector3.UP * height
	rotation = Vector3(0.0, _target_yaw(), 0.0)
	reset_physics_interpolation()


func _physics_process(delta: float) -> void:
	var target := car.global_position + Vector3.UP * height
	var pos := global_position
	var k := 1.0 - exp(-follow_rate * delta)
	pos.x = lerpf(pos.x, target.x, k)
	pos.z = lerpf(pos.z, target.z, k)
	pos.y = lerpf(pos.y, target.y, 1.0 - exp(-height_rate * delta))
	global_position = pos
	rotation = Vector3(0.0, lerp_angle(rotation.y, _target_yaw(), 1.0 - exp(-yaw_rate * delta)), 0.0)


# Heading to sit behind: the car's nose, leaned toward its travel direction.
func _target_yaw() -> float:
	var nose := -car.global_basis.z
	nose.y = 0.0
	if nose.length() < 0.1: # pointing straight up or down: keep the current heading
		return rotation.y
	nose = nose.normalized()
	var travel := car.linear_velocity
	travel.y = 0.0
	if travel.length() > 5.0 and travel.dot(nose) > 0.0:
		nose = nose.lerp(travel.normalized(), look_ahead).normalized()
	return atan2(-nose.x, -nose.z)
