@tool
class_name TrackPiece
extends StaticBody3D
## One modular race-track piece: road surface, painted lines and striped
## barriers on both sides, plus matching collision. Everything is generated
## from the properties below, so tweak them in the Inspector and the piece
## rebuilds itself.
##
## Layout convention: the piece's ORIGIN is its ENTRY. Cars enter travelling
## toward -Z. The "Exit" marker shows where the next piece's origin belongs
## (and which way it faces). A TrackChain node does that placement for you.

signal shape_changed

## GAP builds no road at all: it just carries the chain forward by `length`
## (and up/down by `rise`) so the next piece lands on the far side of a jump
## or drop-down.
enum Kind { STRAIGHT, CURVE, RAMP, GAP }

@export var kind: Kind = Kind.STRAIGHT:
	set(value):
		kind = value
		_queue_rebuild()

@export_group("Straight")
## Length of a straight piece, in meters.
@export_range(4.0, 400.0, 0.5, "or_greater") var length := 40.0:
	set(value):
		length = value
		_queue_rebuild()

@export_group("Curve")
@export var turn_left := true:
	set(value):
		turn_left = value
		_queue_rebuild()
@export_range(5.0, 270.0, 0.5) var turn_angle_degrees := 90.0:
	set(value):
		turn_angle_degrees = value
		_queue_rebuild()
## Radius of the road's center line. Keep it bigger than half the road width.
@export_range(8.0, 400.0, 0.5, "or_greater") var radius := 20.0:
	set(value):
		radius = value
		_queue_rebuild()

@export_group("Ramp")
## How far the road climbs (positive) or drops (negative) over the piece's
## Length, in meters. A ramp reuses "length" as its horizontal run.
@export_range(-60.0, 60.0, 0.5, "or_greater", "or_less") var rise := 6.0:
	set(value):
		rise = value
		_queue_rebuild()

@export_group("Road")
@export_range(4.0, 60.0, 0.5, "or_greater") var road_width := 16.0:
	set(value):
		road_width = value
		_queue_rebuild()
@export_range(0.2, 6.0, 0.1) var barrier_height := 1.0:
	set(value):
		barrier_height = value
		_queue_rebuild()
@export_range(0.2, 4.0, 0.1) var barrier_thickness := 0.8:
	set(value):
		barrier_thickness = value
		_queue_rebuild()
## Distance between mesh samples along the road. Smaller = smoother curves.
@export_range(0.5, 10.0, 0.5) var sample_step := 2.0:
	set(value):
		sample_step = value
		_queue_rebuild()

const ASPHALT := Color(0.17, 0.17, 0.19)
const EDGE_LINE := Color(0.92, 0.92, 0.9)
const CENTER_LINE := Color(0.95, 0.78, 0.15)
const BARRIER_RED := Color(0.82, 0.1, 0.1)
const BARRIER_WHITE := Color(0.93, 0.93, 0.93)
const LINE_HEIGHT := 0.03 # paint sits slightly above the asphalt (no z-fighting)
const BARRIER_BASE := -0.2 # barriers reach a little below the road surface

static var _material: StandardMaterial3D

var _pts := PackedVector3Array()
var _dirs := PackedVector3Array()

var _verts := PackedVector3Array()
var _norms := PackedVector3Array()
var _cols := PackedColorArray()
var _idx := PackedInt32Array()
var _col_faces := PackedVector3Array()

var _mesh_instance: MeshInstance3D
var _shape_owner_id := -1
var _rebuild_queued := false


func _ready() -> void:
	_rebuild()


## Where this piece ends, relative to its own origin. Put the next piece's
## origin here (rotation included) to continue the road.
func get_exit_transform() -> Transform3D:
	if kind == Kind.STRAIGHT:
		return Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -length))
	elif kind == Kind.CURVE:
		var r := _effective_radius()
		var s := _turn_sign()
		var theta := s * deg_to_rad(turn_angle_degrees)
		var center := Vector3(-s * r, 0.0, 0.0)
		var pos := center + Vector3(s * r, 0.0, 0.0).rotated(Vector3.UP, theta)
		return Transform3D(Basis(Vector3.UP, theta), pos)
	else:
		# Ends level (the height curve is flat at both ends), so no rotation:
		# just higher or lower than where it started.
		return Transform3D(Basis.IDENTITY, Vector3(0.0, rise, -length))


## Length of the road's center line, in meters.
func get_path_length() -> float:
	if kind == Kind.STRAIGHT:
		return length
	elif kind == Kind.CURVE:
		return _effective_radius() * deg_to_rad(turn_angle_degrees)
	else:
		#this is placeholder for RAMP
		return length


## A spot on the road's center line, `distance` meters from the entry, in this
## piece's local space. -Z of the result points along the direction of travel.
## Used by gates (checkpoints, start/finish) to snap onto the road.
func get_point_transform(distance: float) -> Transform3D:
	var d := clampf(distance, 0.0, get_path_length())
	if kind == Kind.STRAIGHT:
		return Transform3D(Basis.IDENTITY, Vector3(0.0, 0.0, -d))
	elif kind == Kind.CURVE:
		var r := _effective_radius()
		var s := _turn_sign()
		var theta := s * d / r
		var center := Vector3(-s * r, 0.0, 0.0)
		return Transform3D(Basis(Vector3.UP, theta), center + Vector3(s * r, 0.0, 0.0).rotated(Vector3.UP, theta))
	else:
		# Sit on the hill and tilt to follow its slope.
		var pitch := atan(_ramp_slope(d))
		return Transform3D(Basis(Vector3.RIGHT, pitch), Vector3(0.0, _ramp_height(d), -d))


# Height of the ramp's road at `d` meters in. smoothstep eases from 0 to `rise`
# with zero slope at both ends, so it joins flat pieces without a bump.
func _ramp_height(d: float) -> float:
	return rise * smoothstep(0.0, 1.0, d / length)


# Slope (rise over run) at `d`: the derivative of _ramp_height.
func _ramp_slope(d: float) -> float:
	var t := clampf(d / length, 0.0, 1.0)
	return rise * 6.0 * t * (1.0 - t) / length


func _effective_radius() -> float:
	return maxf(radius, road_width * 0.5 + 1.0)


func _turn_sign() -> float:
	return 1.0 if turn_left else -1.0


func _queue_rebuild() -> void:
	if not is_inside_tree() or _rebuild_queued:
		return
	_rebuild_queued = true
	_rebuild.call_deferred()


func _rebuild() -> void:
	_rebuild_queued = false
	if not is_inside_tree():
		return
	if kind == Kind.GAP:
		_clear_geometry()
		_update_exit_marker()
		return
	_build_path()
	_verts.clear()
	_norms.clear()
	_cols.clear()
	_idx.clear()
	_col_faces.clear()

	var half := road_width * 0.5
	for i in range(_pts.size() - 1):
		# Asphalt.
		_strip(i, -half, half, 0.0, ASPHALT, true)
		# Painted edge lines and a dashed center line (4 m dash, 4 m gap).
		for s: float in [-1.0, 1.0]:
			_strip(i, s * (half - 0.9), s * (half - 0.5), LINE_HEIGHT, EDGE_LINE, false)
		if (i % 4) < 2:
			_strip(i, -0.15, 0.15, LINE_HEIGHT, CENTER_LINE, false)
		# Striped barriers on both sides (color flips every 4 m).
		var barrier_color := BARRIER_RED if ((i >> 1) & 1) == 0 else BARRIER_WHITE
		for s: float in [-1.0, 1.0]:
			var inner := s * half
			var outer := s * (half + barrier_thickness)
			_strip(i, inner, outer, barrier_height, barrier_color, true)
			_wall(i, inner, BARRIER_BASE, barrier_height, -s, barrier_color) # faces the road
			_wall(i, outer, BARRIER_BASE, barrier_height, s, barrier_color) # faces outward

	_apply_mesh()
	_apply_collision()
	_update_exit_marker()


# Gap pieces have no road: drop any mesh and collision left from another kind.
func _clear_geometry() -> void:
	if _mesh_instance != null and is_instance_valid(_mesh_instance):
		_mesh_instance.mesh = null
	if _shape_owner_id != -1:
		shape_owner_clear_shapes(_shape_owner_id)


func _update_exit_marker() -> void:
	var exit_marker := get_node_or_null("Exit") as Node3D
	if exit_marker != null:
		exit_marker.transform = get_exit_transform()
	shape_changed.emit()


# Samples the road's center line: positions and travel directions.
func _build_path() -> void:
	_pts.clear()
	_dirs.clear()
	if kind == Kind.STRAIGHT or kind == Kind.RAMP:
		var n := maxi(1, roundi(length / sample_step))
		for i in range(n + 1):
			var d := length * i / n
			var y := _ramp_height(d) if kind == Kind.RAMP else 0.0
			_pts.append(Vector3(0.0, y, -d))
			# Directions stay horizontal: they only decide "which way is right".
			_dirs.append(Vector3(0.0, 0.0, -1.0))
	else:
		var r := _effective_radius()
		var s := _turn_sign()
		var total := deg_to_rad(turn_angle_degrees)
		var n := maxi(2, roundi(r * total / sample_step))
		var center := Vector3(-s * r, 0.0, 0.0)
		var start := Vector3(s * r, 0.0, 0.0)
		for i in range(n + 1):
			var theta := s * total * i / n
			_pts.append(center + start.rotated(Vector3.UP, theta))
			_dirs.append(Vector3(0.0, 0.0, -1.0).rotated(Vector3.UP, theta))


func _right(i: int) -> Vector3:
	var d := _dirs[i]
	return Vector3(-d.z, 0.0, d.x)


func _pt(i: int, offset: float, y: float) -> Vector3:
	return _pts[i] + _right(i) * offset + Vector3(0.0, y, 0.0)


# Flat strip between two sideways offsets, from sample i to i + 1.
func _strip(i: int, o0: float, o1: float, y: float, color: Color, collide: bool) -> void:
	_add_quad(_pt(i, o0, y), _pt(i + 1, o0, y), _pt(i + 1, o1, y), _pt(i, o1, y),
			Vector3.UP, color, collide)


# Vertical face at a sideways offset. side = which way the face looks (+1 = right).
func _wall(i: int, offset: float, y0: float, y1: float, side: float, color: Color) -> void:
	_add_quad(_pt(i, offset, y0), _pt(i + 1, offset, y0), _pt(i + 1, offset, y1), _pt(i, offset, y1),
			_right(i) * side, color, true)


# Adds a quad whose front side faces `normal`. Winding is fixed automatically
# (Godot treats clockwise triangles as front faces).
func _add_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3, color: Color, collide: bool) -> void:
	if (b - a).cross(c - a).dot(normal) > 0.0:
		var tmp := b
		b = d
		d = tmp
	var base := _verts.size()
	for v in [a, b, c, d]:
		_verts.append(v)
		_norms.append(normal)
		_cols.append(color)
	_idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	if collide:
		_col_faces.append_array([a, b, c, a, c, d])


func _apply_mesh() -> void:
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = _verts
	arrays[Mesh.ARRAY_NORMAL] = _norms
	arrays[Mesh.ARRAY_COLOR] = _cols
	arrays[Mesh.ARRAY_INDEX] = _idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(0, _get_material())
	if _mesh_instance == null or not is_instance_valid(_mesh_instance):
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "GeneratedMesh"
		# Internal child: hidden from the scene dock and never saved.
		add_child(_mesh_instance, false, Node.INTERNAL_MODE_BACK)
	_mesh_instance.mesh = mesh


func _apply_collision() -> void:
	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(_col_faces)
	shape.backface_collision = true
	if _shape_owner_id == -1:
		_shape_owner_id = create_shape_owner(self)
	else:
		shape_owner_clear_shapes(_shape_owner_id)
	shape_owner_add_shape(_shape_owner_id, shape)


static func _get_material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.vertex_color_use_as_albedo = true
		_material.vertex_color_is_srgb = true
		_material.roughness = 0.85
	return _material
