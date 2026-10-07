extends Node
## Player settings that outlive a single race (registered as the GameSettings
## autoload). Saved to user://settings.cfg, so they stick between launches.
## A Settings screen can read and set these; the car listens for changes, so
## switching mid-race works.

signal transmission_changed(automatic: bool)

const PATH := "user://settings.cfg"

## true = the gearbox shifts for you; false = manual (E up / Q down).
var automatic_transmission := true:
	set(value):
		if value == automatic_transmission:
			return
		automatic_transmission = value
		transmission_changed.emit(value)
		save()


func _ready() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) == OK:
		automatic_transmission = cfg.get_value("driving", "automatic_transmission", true)


func toggle_transmission() -> void:
	automatic_transmission = not automatic_transmission


func save() -> void:
	var cfg := ConfigFile.new()
	cfg.load(PATH) # keep any other sections
	cfg.set_value("driving", "automatic_transmission", automatic_transmission)
	cfg.save(PATH)
