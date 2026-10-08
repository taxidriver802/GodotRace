class_name CarWheel
extends RayCast3D
## One wheel of the raycast car (see raycast_car.gd).
##
## The wheel has no collider. Instead this ray points straight down (in the
## car's frame) from the wheel's MOUNT, the spot where the suspension is bolted
## to the body. If the ray hits the road, the wheel is grounded and the car
## pushes on the body at the hit point: suspension, grip and drive.
##
##   mount ──┬── spring (rest_length long when relaxed, can droop `travel` more)
##           ●   wheel center
##           └── wheel_radius ── road
##
## The wheel only SENSES (sense()); the car decides the forces. The visible tire
## (child "Visual") is moved to where the wheel really is, so you can watch the
## suspension work, and it steers and spins.

## Front wheels steer. (Which wheels are driven is chosen on the car: `drive`.)
@export var is_front := false

# --- Filled in by sense() every physics tick (global space) ---
var grounded := false
var contact_point := Vector3.ZERO
var contact_normal := Vector3.UP
## Mount -> wheel center, in meters.
var spring_length := 0.0
## How far the spring is squeezed past its relaxed length (0 = not pushing).
var compression := 0.0

# --- Set by the car, used for visuals and the debug view ---
var steer_angle := 0.0
var suspension_force := Vector3.ZERO
var grip_force := Vector3.ZERO
var drive_force := Vector3.ZERO
var slip := 0.0

var _visual: Node3D
var _spin: Node3D
var _radius := 0.35


func _ready() -> void:
	_visual = get_node_or_null("Visual") as Node3D
	_spin = get_node_or_null("Visual/Spin") as Node3D


## Casts the ray right now and records what the wheel touches.
func sense(rest_length: float, travel: float, radius: float) -> void:
	_radius = radius
	var max_spring := rest_length + travel
	target_position = Vector3(0.0, -(max_spring + radius), 0.0)
	force_raycast_update()
	grounded = is_colliding()
	var raw_length := max_spring
	if grounded:
		contact_point = get_collision_point()
		contact_normal = get_collision_normal()
		raw_length = global_position.distance_to(contact_point) - radius
		spring_length = clampf(raw_length, 0.0, max_spring)
	else:
		spring_length = max_spring
		contact_normal = global_basis.y
		contact_point = global_position - global_basis.y * (max_spring + radius)
	# Not clamped at rest_length: past full travel (tire pushed up into the
	# body on a hard landing) compression keeps growing, so the bump stop can
	# push back instead of the body slamming the road.
	compression = maxf(0.0, rest_length - raw_length)
	suspension_force = Vector3.ZERO
	grip_force = Vector3.ZERO
	drive_force = Vector3.ZERO
	slip = 0.0


## The wheel's own axes in global space: the car's axes turned by the steering.
## -z is where the tire rolls, x is its sideways (grip) direction.
func wheel_basis() -> Basis:
	return global_basis * Basis(Vector3.UP, steer_angle)


## Places, steers and spins the visible tire. `roll_speed` is how fast the
## ground moves past the tire (m/s, positive = forward).
func update_visual(roll_speed: float, delta: float) -> void:
	if _visual == null:
		return
	_visual.position = Vector3(0.0, -spring_length, 0.0)
	_visual.rotation = Vector3(0.0, steer_angle, 0.0)
	if _spin != null:
		_spin.rotate_x(-roll_speed / _radius * delta)
