@tool
class_name Checkpoint
extends Area3D
## A gate across the road that notices when the car drives through it.
## One script, three roles (set `kind`):
##   START       - the start line (also the finish line unless a FINISH exists)
##   CHECKPOINT  - must be driven through before a lap/race can finish
##   FINISH      - optional dedicated finish line, for point-to-point tracks
##
## Easiest placement: make the gate a CHILD of a TrackPiece and set `distance`
## (meters from that piece's entry). It snaps onto the road's center line, turns
## to face the driving direction, matches the road width, and follows the piece
## if you resize it or the TrackChain re-lays it out. A gate that is not under a
## piece (or has snap_to_piece off) stays wherever you put it; set `width` by hand.
##
## The gate only counts a car driving through it in the travel direction (-Z
## of the gate). Add a RaceManager to the scene to turn gate hits into laps.

signal car_passed(gate: Checkpoint, body: Car)

enum Kind { CHECKPOINT, START, FINISH }

@export var kind: Kind = Kind.CHECKPOINT:
	set(value):
		kind = value
		_queue_refresh()

@export_group("Placement")
## Snap onto the parent TrackPiece's center line (only when the parent is a TrackPiece).
@export var snap_to_piece := true:
	set(value):
		snap_to_piece = value
		_queue_refresh()
## Meters from the parent piece's entry, along the road.
@export_range(0.0, 400.0, 0.5, "or_greater") var distance := 4.0:
	set(value):
		distance = value
		_queue_refresh()
## Gate width when not snapped to a piece (snapped gates use the road width).
@export_range(4.0, 60.0, 0.5, "or_greater") var width := 16.0:
	set(value):
		width = value
		_queue_refresh()

@export_group("Gate")
@export_range(2.0, 20.0, 0.5) var height := 6.0:
	set(value):
		height = value
		_queue_refresh()
## How deep the trigger is along the road. Keep it generous so a fast car can't skip it.
@export_range(1.0, 20.0, 0.5) var trigger_depth := 4.0:
	set(value):
		trigger_depth = value
		_queue_refresh()
## Draw checkpoint gates while the game runs (they always show in the editor).
## Turn off for invisible checkpoints. Start and finish gates are always visible.
@export var show_in_game := true:
	set(value):
		show_in_game = value
		_queue_refresh()

## Set by the RaceManager: turns the gate green once it has been collected.
var collected := false

const POST_COLOR := Color(0.92, 0.92, 0.92)
const CHECKPOINT_COLOR := Color(0.1, 0.8, 1.0)
const START_COLOR := Color(0.2, 0.9, 0.3)
const FINISH_COLOR := Color(1.0, 0.25, 0.2)
const COLLECTED_COLOR := Color(0.35, 0.55, 0.38)
const CHECKER_HEIGHT := 0.06 # sits just above the road paint

static var _material: StandardMaterial3D

var _verts := PackedVector3Array()
var _norms := PackedVector3Array()
var _cols := PackedColorArray()
var _idx := PackedInt32Array()

var _mesh_instance: MeshInstance3D
var _shape_owner_id := -1
var _refresh_queued := false


func _ready() -> void:
	var piece := get_parent() as TrackPiece
	if piece != null and not piece.shape_changed.is_connected(_queue_refresh):
		piece.shape_changed.connect(_queue_refresh)
	_refresh()
	if Engine.is_editor_hint():
		return
	add_to_group("checkpoints")
	# The gate only detects; nothing should detect the gate.
	collision_layer = 0
	monitorable = false
	body_entered.connect(_on_body_entered)


## Width of the gate: the road width when snapped to a piece, else `width`.
func gate_width() -> float:
	var piece := get_parent() as TrackPiece
	if piece != null and snap_to_piece:
		return piece.road_width
	return width


func set_collected(value: bool) -> void:
	collected = value
	_rebuild()


func _on_body_entered(body: Node3D) -> void:
	var car := body as Car
	if car == null:
		return
	# Only count driving forward through the gate (gate -Z = direction of travel).
	if car.linear_velocity.dot(-global_transform.basis.z) <= 0.0:
		return
	car_passed.emit(self, car)


func _queue_refresh() -> void:
	if not is_inside_tree() or _refresh_queued:
		return
	_refresh_queued = true
	_refresh.call_deferred()


func _refresh() -> void:
	_refresh_queued = false
	if not is_inside_tree():
		return
	var piece := get_parent() as TrackPiece
	if piece != null and snap_to_piece:
		transform = piece.get_point_transform(distance)
	_rebuild()


func _rebuild() -> void:
	var w := gate_width()
	_build_shape(w)
	_build_visual(w)


func _build_shape(w: float) -> void:
	var shape := BoxShape3D.new()
	shape.size = Vector3(w, height, trigger_depth)
	if _shape_owner_id == -1:
		_shape_owner_id = create_shape_owner(self)
	else:
		shape_owner_clear_shapes(_shape_owner_id)
	shape_owner_add_shape(_shape_owner_id, shape)
	shape_owner_set_transform(_shape_owner_id, Transform3D(Basis.IDENTITY, Vector3(0.0, height * 0.5, 0.0)))


func _build_visual(w: float) -> void:
	_verts.clear()
	_norms.clear()
	_cols.clear()
	_idx.clear()

	var banner_color := COLLECTED_COLOR if collected else _kind_color()
	var post_x := w * 0.5 + 0.4
	# Two posts and a banner across the top.
	_box(Vector3(-post_x, height * 0.5, 0.0), Vector3(0.5, height, 0.5), POST_COLOR)
	_box(Vector3(post_x, height * 0.5, 0.0), Vector3(0.5, height, 0.5), POST_COLOR)
	_box(Vector3(0.0, height - 0.4, 0.0), Vector3(post_x * 2.0, 0.8, 0.35), banner_color)

	# Start and finish also get a checkered strip painted on the road.
	if kind != Kind.CHECKPOINT:
		var cols := maxi(2, roundi(w))
		var cell := w / cols
		for i in range(cols):
			for j in range(2):
				var c := Color.BLACK if (i + j) % 2 == 0 else Color.WHITE
				var x0 := -w * 0.5 + i * cell
				var z0 := -1.0 + j
				_quad(Vector3(x0, CHECKER_HEIGHT, z0), Vector3(x0 + cell, CHECKER_HEIGHT, z0),
						Vector3(x0 + cell, CHECKER_HEIGHT, z0 + 1.0), Vector3(x0, CHECKER_HEIGHT, z0 + 1.0),
						Vector3.UP, c)

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
		_mesh_instance.name = "GateMesh"
		# Internal child: hidden from the scene dock and never saved.
		add_child(_mesh_instance, false, Node.INTERNAL_MODE_BACK)
	_mesh_instance.mesh = mesh
	_mesh_instance.visible = Engine.is_editor_hint() or kind != Kind.CHECKPOINT or show_in_game


func _kind_color() -> Color:
	match kind:
		Kind.START:
			return START_COLOR
		Kind.FINISH:
			return FINISH_COLOR
	return CHECKPOINT_COLOR


# Axis-aligned box made of six flat-shaded quads.
func _box(center: Vector3, size: Vector3, color: Color) -> void:
	var h := size * 0.5
	for n: Vector3 in [Vector3.UP, Vector3.DOWN, Vector3.LEFT, Vector3.RIGHT, Vector3.FORWARD, Vector3.BACK]:
		var u := n.cross(Vector3.UP if absf(n.y) < 0.9 else Vector3.RIGHT).normalized()
		var v := n.cross(u)
		var fc := center + n * (absf(n.x) * h.x + absf(n.y) * h.y + absf(n.z) * h.z)
		var hu := absf(u.x) * h.x + absf(u.y) * h.y + absf(u.z) * h.z
		var hv := absf(v.x) * h.x + absf(v.y) * h.y + absf(v.z) * h.z
		_quad(fc - u * hu - v * hv, fc + u * hu - v * hv, fc + u * hu + v * hv, fc - u * hu + v * hv, n, color)


# Adds a quad whose front side faces `normal`. Winding is fixed automatically
# (Godot treats clockwise triangles as front faces).
func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3, color: Color) -> void:
	if (b - a).cross(c - a).dot(normal) > 0.0:
		var tmp := b
		b = d
		d = tmp
	var base := _verts.size()
	for p in [a, b, c, d]:
		_verts.append(p)
		_norms.append(normal)
		_cols.append(color)
	_idx.append_array([base, base + 1, base + 2, base, base + 2, base + 3])


static func _get_material() -> StandardMaterial3D:
	if _material == null:
		_material = StandardMaterial3D.new()
		_material.vertex_color_use_as_albedo = true
		_material.vertex_color_is_srgb = true
		_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_material.cull_mode = BaseMaterial3D.CULL_DISABLED
	return _material
