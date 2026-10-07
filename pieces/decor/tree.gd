@tool
class_name DecorTree
extends StaticBody3D
## Low-poly roadside tree. Shape, height, lean and colour are all generated
## from a seed, so every tree you drop into a level looks a little different.
##
## Seed 0 = automatic: the seed comes from where the tree sits, so copies you
## scatter around a level all differ, and the same spot always gives the same
## tree (what you see in the editor is what you get in game). Moving an
## automatic tree in the editor re-rolls it. Set a non-zero seed, or press
## "Reroll", to pin a look you like.
##
## Sized against the car (about 1.8 m wide, 1.4 m tall, 4 m long): the default
## 5-8 m height puts a tree at roughly four to six car-heights.

enum Style { RANDOM, PINE, ROUND, POPLAR }

@export var style: Style = Style.RANDOM:
	set(value):
		style = value
		_queue_rebuild()

## 0 = pick automatically from position. Anything else pins this exact tree.
@export var tree_seed := 0:
	set(value):
		tree_seed = value
		_queue_rebuild()

@export_tool_button("Reroll", "RandomNumberGenerator") var reroll_action: Callable = _reroll

@export_group("Size")
@export_range(2.0, 25.0, 0.1, "or_greater") var min_height := 5.0:
	set(value):
		min_height = value
		_queue_rebuild()
@export_range(2.0, 25.0, 0.1, "or_greater") var max_height := 8.0:
	set(value):
		max_height = value
		_queue_rebuild()
## How far a tree may tilt off vertical, in a random direction.
@export_range(0.0, 15.0, 0.5) var max_lean_degrees := 4.0:
	set(value):
		max_lean_degrees = value
		_queue_rebuild()

@export_group("Colour")
@export var foliage_color := Color(0.24, 0.5, 0.2):
	set(value):
		foliage_color = value
		_queue_rebuild()
@export var pine_color := Color(0.17, 0.43, 0.25):
	set(value):
		pine_color = value
		_queue_rebuild()
@export var trunk_color := Color(0.36, 0.24, 0.15):
	set(value):
		trunk_color = value
		_queue_rebuild()
## How much each tree's greens drift from the base colour.
@export_range(0.0, 0.25, 0.01) var color_variation := 0.08:
	set(value):
		color_variation = value
		_queue_rebuild()

@export_group("Collision")
## Cars hit the trunk (and the low branches of a pine).
@export var solid := true:
	set(value):
		solid = value
		_queue_rebuild()

const GENERATED_META := &"decor_tree_generated"

# Unit meshes and colour-quantised materials shared by every tree, so a
# forest of these stays cheap.
static var _mesh_cache := {}
static var _material_cache := {}

var _visual: Node3D
var _rebuild_queued := false
var _built_seed := -1


func _ready() -> void:
	if Engine.is_editor_hint():
		set_notify_transform(true)
	_rebuild()


func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and tree_seed == 0 and is_inside_tree():
		if _effective_seed() != _built_seed:
			_queue_rebuild()


func _queue_rebuild() -> void:
	if not is_inside_tree() or _rebuild_queued:
		return
	_rebuild_queued = true
	_rebuild.call_deferred()


func _reroll() -> void:
	var new_seed := randi_range(1, 999_999)
	if Engine.has_singleton("EditorInterface"):
		var undo_redo = Engine.get_singleton("EditorInterface").get_editor_undo_redo()
		undo_redo.create_action("Reroll tree")
		undo_redo.add_do_property(self, "tree_seed", new_seed)
		undo_redo.add_undo_property(self, "tree_seed", tree_seed)
		undo_redo.commit_action()
	else:
		tree_seed = new_seed


func _effective_seed() -> int:
	if tree_seed != 0:
		return tree_seed
	# Snap to a half-metre grid so tiny float noise never changes the tree.
	var p := global_position if is_inside_tree() else position
	var cell := Vector3i(roundi(p.x * 2.0), roundi(p.y * 2.0), roundi(p.z * 2.0))
	return (hash(cell) & 0x7fffffff) | 1


func _rebuild() -> void:
	_rebuild_queued = false
	for child in get_children(true):
		if child.has_meta(GENERATED_META):
			remove_child(child)
			child.queue_free()

	_built_seed = _effective_seed()
	var rng := RandomNumberGenerator.new()
	rng.seed = _built_seed

	var kind := style
	if kind == Style.RANDOM:
		# Weighted: round trees most common, poplars a rare accent.
		var roll := rng.randf()
		kind = Style.ROUND if roll < 0.45 else (Style.PINE if roll < 0.85 else Style.POPLAR)

	var height := rng.randf_range(minf(min_height, max_height), maxf(min_height, max_height))

	_visual = Node3D.new()
	_visual.name = "Visual"
	_visual.set_meta(GENERATED_META, true)
	var yaw := rng.randf() * TAU
	var lean := deg_to_rad(rng.randf_range(0.0, max_lean_degrees))
	_visual.basis = Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, lean)
	add_child(_visual, false, Node.INTERNAL_MODE_FRONT)

	var trunk_mat := _material(_vary(trunk_color, rng, 0.5))
	var collide_radius := 0.3
	match kind:
		Style.PINE:
			collide_radius = _build_pine(rng, height, trunk_mat)
		Style.POPLAR:
			collide_radius = _build_poplar(rng, height, trunk_mat)
		_:
			collide_radius = _build_round(rng, height, trunk_mat)

	if solid:
		var shape := CylinderShape3D.new()
		shape.radius = collide_radius
		shape.height = height
		var col := CollisionShape3D.new()
		col.name = "Collision"
		col.shape = shape
		col.position.y = height * 0.5
		col.set_meta(GENERATED_META, true)
		add_child(col, false, Node.INTERNAL_MODE_FRONT)


# --- Styles -----------------------------------------------------------------
# Each returns the radius to use for the collision cylinder.

func _build_pine(rng: RandomNumberGenerator, height: float, trunk_mat: Material) -> float:
	var trunk_r := height * rng.randf_range(0.035, 0.045)
	var trunk_h := height * 0.4
	_add_cylinder("trunk", trunk_mat, trunk_r, trunk_h, 0.0)

	var green := _material(_vary(pine_color, rng, 1.0))
	var tiers := rng.randi_range(3, 4)
	var base_y := height * rng.randf_range(0.18, 0.24)
	var span := height - base_y
	var tier_h := span / tiers * 1.7
	var widest := height * rng.randf_range(0.24, 0.3)
	for i in tiers:
		var t := float(i) / float(tiers - 1)
		var r := lerpf(widest, widest * 0.42, t)
		var y := base_y + span * t * (1.0 - tier_h / span * 0.75)
		var h := tier_h * lerpf(1.0, 0.8, t)
		if i == tiers - 1:
			h = height - y  # top tier always lands exactly on the full height
		var cone := _add_cylinder("cone", green, r, h, y)
		cone.rotation.y = rng.randf() * TAU
	return maxf(trunk_r, widest * 0.45)


func _build_round(rng: RandomNumberGenerator, height: float, trunk_mat: Material) -> float:
	var trunk_r := height * rng.randf_range(0.045, 0.06)
	var canopy_r := height * rng.randf_range(0.3, 0.36)
	var canopy_y := height - canopy_r
	_add_cylinder("trunk", trunk_mat, trunk_r, canopy_y, 0.0)

	var green := _material(_vary(foliage_color, rng, 1.0))
	var main := _add_blob(green, Vector3(0.0, canopy_y, 0.0), Vector3.ONE * canopy_r)
	main.rotation.y = rng.randf() * TAU

	# A few smaller lumps around the main canopy break up the silhouette.
	for i in rng.randi_range(2, 4):
		var angle := rng.randf() * TAU
		var r := canopy_r * rng.randf_range(0.5, 0.75)
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * canopy_r * rng.randf_range(0.5, 0.75)
		offset.y = rng.randf_range(-0.45, 0.15) * canopy_r
		var shade := green if rng.randf() < 0.6 else _material(_vary(foliage_color, rng, 1.0))
		var blob := _add_blob(shade, Vector3(0.0, canopy_y, 0.0) + offset, Vector3.ONE * r)
		blob.rotation.y = rng.randf() * TAU
	return trunk_r


func _build_poplar(rng: RandomNumberGenerator, height: float, trunk_mat: Material) -> float:
	var trunk_r := height * rng.randf_range(0.03, 0.04)
	var canopy_w := height * rng.randf_range(0.14, 0.18)
	var canopy_half_h := height * rng.randf_range(0.36, 0.42)
	var canopy_y := height - canopy_half_h
	_add_cylinder("trunk", trunk_mat, trunk_r, canopy_y, 0.0)

	var green := _material(_vary(foliage_color.lerp(pine_color, 0.4), rng, 1.0))
	var blob := _add_blob(green, Vector3(0.0, canopy_y, 0.0), Vector3(canopy_w, canopy_half_h, canopy_w))
	blob.rotation.y = rng.randf() * TAU
	return trunk_r


# --- Helpers ----------------------------------------------------------------

## Adds a cylinder/cone whose BASE sits at `base_y`.
func _add_cylinder(kind: String, mat: Material, radius: float, h: float, base_y: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh(kind)
	mi.material_override = mat
	mi.position.y = base_y + h * 0.5
	mi.scale = Vector3(radius, h, radius)
	_visual.add_child(mi)
	return mi


func _add_blob(mat: Material, center: Vector3, radii: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh("blob")
	mi.material_override = mat
	mi.position = center
	mi.scale = radii
	_visual.add_child(mi)
	return mi


## Nudges a colour's hue and brightness in small steps (so materials can be
## shared between trees that land on the same step).
func _vary(base: Color, rng: RandomNumberGenerator, amount: float) -> Color:
	var hue_step := rng.randi_range(-2, 2)
	var val_step := rng.randi_range(-2, 2)
	var k := color_variation * amount * 0.5
	return Color.from_hsv(
		fposmod(base.h + hue_step * k * 0.35, 1.0),
		clampf(base.s + val_step * k * 0.5, 0.0, 1.0),
		clampf(base.v * (1.0 + val_step * k), 0.0, 1.0))


static func _material(color: Color) -> StandardMaterial3D:
	var key := color.to_html(false)
	if _material_cache.has(key):
		return _material_cache[key]
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 0.9
	_material_cache[key] = mat
	return mat


## Unit-sized meshes (radius 1, height 1), scaled per part.
static func _mesh(kind: String) -> Mesh:
	if _mesh_cache.has(kind):
		return _mesh_cache[kind]
	var mesh: Mesh
	match kind:
		"trunk":
			var cyl := CylinderMesh.new()
			cyl.top_radius = 0.7
			cyl.bottom_radius = 1.0
			cyl.height = 1.0
			cyl.radial_segments = 7
			cyl.rings = 1
			mesh = cyl
		"cone":
			var cone := CylinderMesh.new()
			cone.top_radius = 0.0
			cone.bottom_radius = 1.0
			cone.height = 1.0
			cone.radial_segments = 8
			cone.rings = 1
			mesh = cone
		_:
			var sphere := SphereMesh.new()
			sphere.radius = 1.0
			sphere.height = 2.0
			sphere.radial_segments = 8
			sphere.rings = 5
			mesh = sphere
	_mesh_cache[kind] = mesh
	return mesh
