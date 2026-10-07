class_name CarDebug
extends Node3D
## Debug view for the raycast car. The car creates it; toggle it with the car's
## `debug_draw` export or the "car_debug" key (2).
##
## In the world, per wheel:
##   gray   ray from the mount down to full droop (wheel in the air)
##   green  ray down to the contact point (wheel on the ground)
##   yellow suspension force          red    grip (sideways) force
##   blue   drive / brake force       white  car velocity (from the body)
## Arrow length: FORCE_SCALE meters per newton (4000 N = 1 m).
## On screen (top right): per-wheel grounded / compression / load / slip.

const FORCE_SCALE := 1.0 / 4000.0
const GRAY := Color(0.6, 0.6, 0.6)
const GREEN := Color(0.2, 1.0, 0.3)
const YELLOW := Color(1.0, 0.9, 0.1)
const RED := Color(1.0, 0.2, 0.2)
const BLUE := Color(0.3, 0.6, 1.0)

var car: Car

var _mesh := ImmediateMesh.new()
var _layer: CanvasLayer
var _label: Label


func _ready() -> void:
	top_level = true
	global_transform = Transform3D.IDENTITY

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.vertex_color_use_as_albedo = true
	mat.no_depth_test = true # draw on top of the car body
	var mi := MeshInstance3D.new()
	mi.mesh = _mesh
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)

	_layer = CanvasLayer.new()
	_layer.layer = 80
	add_child(_layer)
	_label = Label.new()
	_label.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_label.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_label.offset_right = -16
	_label.offset_top = 16
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_label.add_theme_font_size_override("font_size", 15)
	_label.add_theme_color_override("font_outline_color", Color.BLACK)
	_label.add_theme_constant_override("outline_size", 5)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(_label)
	set_enabled(false)


func set_enabled(on: bool) -> void:
	visible = on
	if _layer != null:
		_layer.visible = on
	if not on:
		_mesh.clear_surfaces()


## Called by the car at the end of each physics tick while enabled.
func draw_frame(wheels: Array[CarWheel], grounded_count: int) -> void:
	_mesh.clear_surfaces()
	_mesh.surface_begin(Mesh.PRIMITIVE_LINES)
	var gear_text := "R" if car.gear < 0 else ("-" if car.gear == 0 else str(car.gear))
	var lines: PackedStringArray = [
		"CAR DEBUG (2)   %.0f km/h   wheels down %d/4" % [car.speed_kmh(), grounded_count],
		"gear %s   %4.0f rpm   drive %5.0f N   drag %5.0f N" % [
			gear_text, car.engine_rpm, car.drive_force_total, car.drag_force],
	]
	for w in wheels:
		var mount := w.global_position
		if w.grounded:
			_line(mount, w.contact_point, GREEN)
			var p := w.contact_point + w.contact_normal * 0.05
			_line(p, p + w.suspension_force * FORCE_SCALE, YELLOW)
			_line(p, p + w.grip_force * FORCE_SCALE, RED)
			_line(p, p + w.drive_force * FORCE_SCALE, BLUE)
			lines.append("%s  ground  comp %.2f m  load %5.0f N  slip %.2f" % [
				w.name.trim_prefix("Wheel"), w.compression, w.suspension_force.length(), w.slip])
		else:
			_line(mount, w.contact_point, GRAY)
			lines.append("%s  AIR" % w.name.trim_prefix("Wheel"))
	var c := car.global_position + Vector3.UP * 1.5
	_line(c, c + car.linear_velocity * 0.1, Color.WHITE)
	_mesh.surface_end()
	_label.text = "\n".join(lines)


func _line(a: Vector3, b: Vector3, color: Color) -> void:
	_mesh.surface_set_color(color)
	_mesh.surface_add_vertex(a)
	_mesh.surface_set_color(color)
	_mesh.surface_add_vertex(b)
