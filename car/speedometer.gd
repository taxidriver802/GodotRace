extends CanvasLayer
## Speedometer HUD. Add it as a child of the Car: a CanvasLayer draws on the
## screen (not in the 3D world), so it stays put no matter where the camera
## goes, and living under the car means it ships with every car instance.
## It reads the car's `speed_kmh()` every frame; nothing else needs wiring.

## Car to read from. Leave empty to use the parent node.
@export var car: Node3D
## Speed at the end of the dial (km/h, or mph when use_mph is on).
@export var dial_max := 180.0
@export var use_mph := false
## Size of the gauge in pixels (at the 1152x648 base resolution).
@export var gauge_size := 220.0
@export var margin := 24.0

var _gauge: Gauge


func _ready() -> void:
	if car == null:
		car = get_parent() as Node3D
	_gauge = Gauge.new()
	_gauge.dial_max = dial_max
	_gauge.unit = "mph" if use_mph else "km/h"
	# Anchor to the bottom-right corner; it stays there when the window resizes.
	_gauge.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_gauge.offset_left = -(gauge_size + margin)
	_gauge.offset_top = -(gauge_size + margin)
	_gauge.offset_right = -margin
	_gauge.offset_bottom = -margin
	_gauge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_gauge)
	# Units follow the player's setting (Settings > Gameplay > Speed units).
	var settings := get_node_or_null("/root/GameSettings")
	if settings != null:
		_set_units(settings.get_value("speed_mph"))
		settings.changed.connect(_on_setting_changed)


func _on_setting_changed(key: String, value: Variant) -> void:
	if key == "speed_mph":
		_set_units(value)


func _set_units(mph: bool) -> void:
	use_mph = mph
	_gauge.unit = "mph" if mph else "km/h"
	# Same needle sweep in either unit: 180 km/h -> 120 mph (rounded to 20s).
	_gauge.dial_max = roundf(dial_max * 0.621371 / 20.0) * 20.0 if mph else dial_max


func _process(delta: float) -> void:
	if car == null or not car.has_method("speed_kmh"):
		return
	var value: float = car.speed_kmh()
	if use_mph:
		value *= 0.621371
	# Light smoothing so the needle doesn't jitter.
	_gauge.value = lerpf(_gauge.value, value, clampf(delta * 12.0, 0.0, 1.0))

	# Tachometer and gear (only if the car has an engine and gearbox).
	var engine: Node = car.get("engine")
	var gearbox: Node = car.get("gearbox")
	_gauge.has_engine = engine != null and gearbox != null
	if _gauge.has_engine:
		var redline: float = engine.redline_rpm
		_gauge.rpm_frac = lerpf(_gauge.rpm_frac, clampf(engine.rpm / redline, 0.0, 1.0), clampf(delta * 20.0, 0.0, 1.0))
		_gauge.shift_frac = gearbox.upshift_rpm_frac
		var g: int = gearbox.gear
		_gauge.gear_text = "R" if g < 0 else ("N" if g == 0 else str(g))
		_gauge.mode_text = "AUTO" if gearbox.mode == Gearbox.Mode.AUTOMATIC else "MANUAL"
		_gauge.blocked = float(car.get("shift_blocked_time")) > 0.0
	_gauge.queue_redraw()


## The dial itself, drawn with code: arc, tick marks, needle and a digital readout.
class Gauge extends Control:
	var value := 0.0
	var dial_max := 180.0
	var unit := "km/h"
	# Tachometer / gear readout.
	var has_engine := false
	var rpm_frac := 0.0 # engine rpm / redline
	var shift_frac := 0.92 # where the shift light comes on
	var gear_text := "1"
	var mode_text := "AUTO"
	var blocked := false # a manual downshift was just refused

	const START := deg_to_rad(135.0) # bottom-left
	const SWEEP := deg_to_rad(270.0) # clockwise over the top to bottom-right

	func _draw() -> void:
		var c := size * 0.5
		var r := minf(size.x, size.y) * 0.5
		var font := ThemeDB.fallback_font
		var frac := clampf(value / dial_max, 0.0, 1.0)

		# Backing disc.
		draw_circle(c, r, Color(0.04, 0.04, 0.06, 0.65))
		draw_arc(c, r - 3.0, 0.0, TAU, 64, Color(1, 1, 1, 0.25), 2.0, true)

		# Dial track and the filled portion (green -> red as speed rises).
		draw_arc(c, r - 18.0, START, START + SWEEP, 64, Color(1, 1, 1, 0.15), 8.0, true)
		if frac > 0.002:
			var fill := Color(0.2, 0.9, 0.4).lerp(Color(1.0, 0.2, 0.15), frac)
			draw_arc(c, r - 18.0, START, START + SWEEP * frac, 64, fill, 8.0, true)

		# Tick marks and labels every 20 units (big ones every 40).
		var step := 20.0
		var n := int(dial_max / step)
		for i in range(n + 1):
			var a := START + SWEEP * (float(i) * step / dial_max)
			var dir := Vector2(cos(a), sin(a))
			var big := i % 2 == 0
			var r_out := r - 28.0
			var r_in := r_out - (12.0 if big else 6.0)
			draw_line(c + dir * r_in, c + dir * r_out, Color(1, 1, 1, 0.8 if big else 0.4), 2.0, true)
			if big:
				var label := str(int(i * step))
				var ts := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
				var p := c + dir * (r_in - 12.0)
				draw_string(font, p + Vector2(-ts.x * 0.5, ts.y * 0.3), label,
						HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(1, 1, 1, 0.8))

		# Needle.
		var na := START + SWEEP * frac
		var nd := Vector2(cos(na), sin(na))
		draw_line(c - nd * 10.0, c + nd * (r - 40.0), Color(1.0, 0.3, 0.2), 3.0, true)
		draw_circle(c, 7.0, Color(0.9, 0.9, 0.9))

		if has_engine:
			_draw_tach(c, r, font)

		# Digital readout and unit.
		var txt := str(int(round(value)))
		var fs := 40
		var tsz := font.get_string_size(txt, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_string(font, c + Vector2(-tsz.x * 0.5, r * 0.55), txt,
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color.WHITE)
		var usz := font.get_string_size(unit, HORIZONTAL_ALIGNMENT_LEFT, -1, 14)
		draw_string(font, c + Vector2(-usz.x * 0.5, r * 0.55 + 20.0), unit,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(1, 1, 1, 0.7))

	# Rev ring around the outside of the dial, the gear in the middle.
	func _draw_tach(c: Vector2, r: float, font: Font) -> void:
		var tr := r - 6.0
		# Redline zone (last 8% of the ring).
		draw_arc(c, tr, START + SWEEP * 0.92, START + SWEEP, 24, Color(0.9, 0.15, 0.1, 0.45), 5.0, true)
		if rpm_frac > 0.002:
			var col := Color(0.85, 0.9, 1.0)
			if rpm_frac >= shift_frac:
				col = Color(1.0, 0.25, 0.15) # shift now
			elif rpm_frac >= shift_frac - 0.15:
				col = Color(1.0, 0.7, 0.2) # getting close
			draw_arc(c, tr, START, START + SWEEP * rpm_frac, 64, col, 5.0, true)

		# Gear box above the hub. Flashes red when a downshift is refused.
		var box := Rect2(c + Vector2(-20.0, -r * 0.27 - 20.0), Vector2(40.0, 40.0))
		var box_col := Color(0.8, 0.1, 0.1, 0.85) if blocked else Color(0.0, 0.0, 0.0, 0.55)
		draw_rect(box, box_col, true)
		draw_rect(box, Color(1, 1, 1, 0.35), false, 1.5)
		var gfs := 30
		var gcol := Color(1.0, 0.3, 0.2) if rpm_frac >= shift_frac and gear_text != "R" else Color.WHITE
		var gsz := font.get_string_size(gear_text, HORIZONTAL_ALIGNMENT_LEFT, -1, gfs)
		draw_string(font, box.get_center() + Vector2(-gsz.x * 0.5, gsz.y * 0.32), gear_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, gfs, gcol)
		var msz := font.get_string_size(mode_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11)
		# AUTO / MANUAL under the km/h label.
		draw_string(font, c + Vector2(-msz.x * 0.5, r * 0.55 + 34.0), mode_text,
				HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, 0.6))
