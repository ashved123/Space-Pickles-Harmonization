## Makes app/datasets/sensor_counts.bin: raw detections per satellite, cell and month, counted once
## from datasets/hotspots/<year>.bin so the app (above all the web build) doesn't have to.
## Re-run after the hotspot files change (pipeline/export_app_data.py --hotspots ...):
##   godot --headless --path app -s build_sensor_counts.gd
## test_calendar_data.gd fails if the file is out of date.
extends SceneTree

const CalendarData = preload("res://data/calendar_data.gd")


func _init() -> void:
	var d = CalendarData.new()
	if not d.load_all("res://datasets", false):
		print("can't load app/datasets")
		quit(1)
		return
	var t := Time.get_ticks_msec()
	for y in range(d.FIRST_YEAR, d.last_year + 1):
		d.count_sensor_year(y)
	var path := "res://datasets/sensor_counts.bin"
	var ok: bool = d.save_sensor_counts(path)
	print("counted %d-%d in %d ms, wrote %s: %s (%d bytes)" % [d.FIRST_YEAR, d.last_year, Time.get_ticks_msec() - t,
		path, "ok" if ok else "FAILED", FileAccess.get_file_as_bytes(path).size() if ok else 0])
	quit(0 if ok else 1)
