extends Node
## Best times and stats for every level (registered as the Records autoload).
## Saved to user://records.cfg, separate from the settings, so "Reset to
## defaults" can never wipe your times.
##
## Levels are identified by their scene path, so each track keeps its own
## records. The RaceManager reports into this:
##   Records.submit_lap(level, lap_time, top_speed_kmh)   after every lap
##   Records.submit_race(level, race_time)                when a race finishes
## and anything can read a level's numbers with Records.get_stats(level).
##
## Stats kept per level:
##   best_race      fastest finished race, seconds (0 = none yet)
##   best_lap       fastest single lap, seconds (0 = none yet)
##   top_times      the 5 fastest finished races, best first
##   last_race      time of the most recent finished race
##   races_finished how many races were completed
##   laps_completed how many laps were completed
##   total_time     seconds spent on completed laps (all runs added up)
##   top_speed_kmh  fastest speed reached on a completed lap
##
## To add a stat: add it to _blank(), update it in submit_lap / submit_race,
## and show it where you like (the results screen is ui/pause_menu.gd).

signal records_changed(level: String)

const PATH := "user://records.cfg"
const TOP_COUNT := 5

# level id -> stats Dictionary (see the list above)
var _data: Dictionary = {}


func _ready() -> void:
	_load()


## "Level 2" from "res://levels/level_2.tscn", for showing to the player.
static func level_name(id: String) -> String:
	return id.get_file().get_basename().replace("_", " ").capitalize()


## A copy of a level's stats (all zero / empty if it has none yet).
func get_stats(level: String) -> Dictionary:
	return _data.get(level, _blank()).duplicate(true)


func has_stats(level: String) -> bool:
	return _data.has(level)


## Every level that has records.
func levels() -> Array:
	return _data.keys()


## Report a finished lap. Returns true if it is a new best lap.
func submit_lap(level: String, lap_time: float, top_speed_kmh: float = 0.0) -> bool:
	if level == "" or lap_time <= 0.0:
		return false
	var s: Dictionary = _stats_for(level)
	var is_best: bool = s["best_lap"] <= 0.0 or lap_time < s["best_lap"]
	if is_best:
		s["best_lap"] = lap_time
	s["laps_completed"] += 1
	s["total_time"] += lap_time
	s["top_speed_kmh"] = maxf(s["top_speed_kmh"], top_speed_kmh)
	_changed(level)
	return is_best


## Report a finished race. Returns what happened:
##   new_best  bool   - fastest race on this level so far
##   previous  float  - the best before this one (0 if none)
##   rank      int    - place in the top times (1 = best), 0 if not in them
func submit_race(level: String, race_time: float) -> Dictionary:
	var result := {"new_best": false, "previous": 0.0, "rank": 0}
	if level == "" or race_time <= 0.0:
		return result
	var s: Dictionary = _stats_for(level)
	result["previous"] = s["best_race"]
	result["new_best"] = s["best_race"] <= 0.0 or race_time < s["best_race"]
	if result["new_best"]:
		s["best_race"] = race_time
	s["last_race"] = race_time
	s["races_finished"] += 1
	var tops: Array = s["top_times"]
	tops.append(race_time)
	tops.sort()
	if tops.size() > TOP_COUNT:
		tops.resize(TOP_COUNT)
	s["top_times"] = tops
	result["rank"] = tops.find(race_time) + 1
	_changed(level)
	return result


func reset_level(level: String) -> void:
	if _data.erase(level):
		_changed(level)


func reset_all() -> void:
	var ids := _data.keys()
	_data.clear()
	save()
	for id: String in ids:
		records_changed.emit(id)


func save() -> void:
	var cfg := ConfigFile.new()
	for id: String in _data:
		for key: String in _data[id]:
			cfg.set_value(id, key, _data[id][key])
	cfg.save(PATH)


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(PATH) != OK:
		return
	for id: String in cfg.get_sections():
		var s := _blank()
		for key: String in s:
			if cfg.has_section_key(id, key):
				s[key] = cfg.get_value(id, key)
		_data[id] = s


func _stats_for(level: String) -> Dictionary:
	if not _data.has(level):
		_data[level] = _blank()
	return _data[level]


func _changed(level: String) -> void:
	save()
	records_changed.emit(level)


func _blank() -> Dictionary:
	return {
		"best_race": 0.0,
		"best_lap": 0.0,
		"top_times": [],
		"last_race": 0.0,
		"races_finished": 0,
		"laps_completed": 0,
		"total_time": 0.0,
		"top_speed_kmh": 0.0,
	}
