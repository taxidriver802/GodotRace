extends AudioStreamPlayer
## Engine sound, generated in code (no audio files needed). Child of the Car;
## it reads the car's engine_rpm and engine_load every frame.
##
## A 4-cylinder fires twice per revolution, so the base tone is
## rpm / 60 x 2 Hz (33 Hz at idle, 250 Hz at 7500 rpm). A few harmonics give
## it body, and a little noise that grows with throttle gives it grit. Swap
## this for a recorded engine loop later by giving the node a real stream and
## setting pitch_scale from rpm instead.

## Overall loudness. Raise toward 0 for louder.
@export_range(-40.0, 6.0, 0.5) var engine_volume_db := -14.0
## Firing pulses per revolution (cylinders / 2 for a 4-stroke).
@export var pulses_per_rev := 2.0
## How much rasp the throttle adds (0 = smooth hum).
@export_range(0.0, 1.0, 0.05) var grit := 0.35

const MIX_RATE := 22050.0

var car: Node
var _playback: AudioStreamGeneratorPlayback
var _phase := 0.0
var _freq := 33.0
var _amp := 0.3
var _noise := 0.0


func _ready() -> void:
	car = get_parent()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = MIX_RATE
	gen.buffer_length = 0.2 # room for a slow frame without crackling
	stream = gen
	volume_db = engine_volume_db
	play()
	_playback = get_stream_playback() as AudioStreamGeneratorPlayback


func _process(_delta: float) -> void:
	if _playback == null or car == null:
		return
	volume_db = engine_volume_db
	var rpm: float = car.get("engine_rpm")
	var throttle_load: float = car.get("engine_load")
	var target_freq := maxf(rpm, 600.0) / 60.0 * pulses_per_rev
	var target_amp := 0.22 + 0.33 * throttle_load
	var frames := _playback.get_frames_available()
	for i in range(frames):
		# Glide toward the target so pitch changes are smooth, not stepped.
		_freq += (target_freq - _freq) * 0.002
		_amp += (target_amp - _amp) * 0.001
		_phase = fmod(_phase + _freq / MIX_RATE, 1.0)
		var p := _phase * TAU
		var s := 0.55 * sin(p) + 0.3 * sin(2.0 * p + 0.6) + 0.18 * sin(3.0 * p + 1.1) + 0.1 * sin(0.5 * p)
		# Low-passed noise, louder on throttle.
		_noise += (randf_range(-1.0, 1.0) - _noise) * 0.25
		s += _noise * grit * (0.3 + throttle_load)
		s *= _amp
		_playback.push_frame(Vector2(s, s))
