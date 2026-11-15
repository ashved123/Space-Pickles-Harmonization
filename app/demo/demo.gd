## Presentation demo mode (autoload "Demo"): a scripted walk through Unisim with a caption bar.
## The steps follow the team's 4-minute demo script (hook, problem, harmonization, layers, fire sim,
## risk model, close); each caption is the on-screen cue for what the speaker is saying.
##
## Start: on the map, type START_CODE ("demo"), or press F9, or click the Demo button.
## Next: Right arrow (also Page Down or Enter, so a presentation clicker works).
## Back: Left arrow (also Page Up or Backspace). A: move on by itself, A again to stop. Esc: leave.
## The bar shows only the caption: no buttons or key hints, since an audience is watching.
## (In a browser's fullscreen mode the first Esc leaves fullscreen; press it again to leave the demo.)
## While the demo runs the arrow keys belong to it, so in the sim they don't turn the wind.
##
## The story is the STEPS list below, plain data: edit the text, reorder or add steps freely.
## Each step names a screen and passes `args` to that screen's `demo_apply()`. The dictionary it
## returns fills the {placeholders} in the caption, so the numbers on screen are always live ones.
##
## Needs internet like the rest of the app (map tiles, the sim's live data). Run it once before
## presenting: that fills the tile caches and shows whether anything is unreachable.
extends CanvasLayer

const UI = preload("res://ui/ui_kit.gd")
const SCENES := {
	"map": "res://ui/map_view.tscn",
	"calendar": "res://ui/calendar_view.tscn",
	"sim": "res://main.tscn",
}
const START_CODE := "demo"   # typed on the map (not in a text box) to start the demo
const CAMP_FIRE := {"lat": 39.81, "lon": -121.44, "year": 2018, "doy": 312, "label": "the Camp Fire, hotspot 39.8100, -121.4400"}
const AUTO_SECONDS := 10.0
const WIDE := 660.0     # caption width at the top of the screen
const NARROW := 405.0   # caption width in the bottom-left corner: stays left of the calendar's year labels

# Layer sets used by several steps (layers not named are off, except as DEMO_LAYERS in map_view says).
const ONLY_HOTSPOTS := {"hotspots": true, "fires": false}
const NO_LAYERS := {"hotspots": false, "fires": false}

# scene: map / calendar / sim.  part: section and speaker from the script (a note for us; not shown).
# place: "top" (default) or "bottom_left".  secs: auto-advance time.
const STEPS: Array[Dictionary] = [
	# 0:00 Hook
	{"scene": "map", "part": "Hook · Speaker 1", "title": "Unisim, by Space Pickles",
		"text": "Every red dot is a fire NASA's satellites detected in California in 2020: {hotspots} detections. We have 25 years of dots like these. The problem: you can't compare them.",
		"args": {"year": 2020, "month": 0, "day": 0, "view": "fit", "layers": ONLY_HOTSPOTS}},
	# 0:15 The problem
	{"scene": "map", "part": "The problem · Speaker 1", "title": "Two generations of satellites",
		"text": "9 September 2020. Blue rings: MODIS, since 2000, 1 km pixels: {modis} detections that day. Yellow and aqua rings: VIIRS, since 2012, 375 m pixels: {viirs}.",
		"args": {"year": 2020, "month": 9, "day": 9, "view": "fit",
			"layers": {"hotspots": true, "fires": false, "satellite_colours": true}}},
	{"scene": "map", "part": "The problem · Speaker 1", "title": "Same fire, different counts", "secs": 14.0,
		"text": "One fire, the August Complex. A handful of blue MODIS dots, dozens of VIIRS dots. Stack the raw records and California seems to burn far more from 2012 on. That jump is the satellites, not the fires.",
		"args": {"layers": {"hotspots": true, "fires": false, "satellite_colours": true},
			"fly": {"lat": 39.95, "lon": -122.95, "zoom": 9.6, "secs": 4.0}}},
	# 0:45 Harmonization
	{"scene": "map", "part": "Harmonization · Speaker 2", "title": "One common unit: the fire cell-day",
		"text": "Every detection is snapped to a 1 km grid, and a cell counts once per day however many pixels landed in it. The MODIS-to-VIIRS conversion is fitted per latitude band, in and out of fire season, on the years both flew. This is the harmonized burning grid.",
		"args": {"view": "fit", "layers": {"hotspots": false, "fires": false, "grid": true}}},
	{"scene": "calendar", "part": "Harmonization · Speaker 2", "place": "bottom_left", "title": "25 years on one scale",
		"text": "No jump at the 2012 line. On years the fit never saw, it is about 12% off in a typical month. Hatched cells are months with no record: missing data is never shown as zero.",
		"args": {"view": 0, "month": [2020, 9]}},
	# 1:20 Layers
	{"scene": "map", "part": "Layers · Speaker 3", "title": "Layer: hotspots",
		"text": "Everything on the map is a layer you can mix. Hotspots are NASA FIRMS detections, cleaned down to vegetation fires: {hotspots} on this day.",
		"args": {"view": "fit", "layers": ONLY_HOTSPOTS}},
	{"scene": "map", "part": "Layers · Speaker 3", "title": "Layer: fire outlines",
		"text": "Our script groups nearby detections in space and time into individual fires: {fires} fire events were burning on this day.",
		"args": {"layers": {"hotspots": false, "fires": true}}},
	{"scene": "map", "part": "Layers · Speaker 3", "title": "Layer: burning grid",
		"text": "The harmonized data per 25 km cell, the same numbers the calendar adds up.",
		"args": {"layers": {"hotspots": false, "fires": false, "grid": true}}},
	{"scene": "map", "part": "Layers · Speaker 3", "title": "Layer: clouds and smoke",
		"text": "NASA's satellite image for the selected day (MODIS Terra, via GIBS), here the smoke of 9 September 2020. Built in the Godot engine: each layer is drawn over the map tiles.",
		"args": {"layers": {"hotspots": false, "fires": false, "clouds": true}}},
	# 1:50 Fire sim
	{"scene": "map", "part": "Fire sim · Speaker 4", "title": "8 November 2018: the Camp Fire", "secs": 14.0,
		"text": "Paradise, Butte County. The deadliest wildfire in California's history. {hotspots} detections across the state that day.",
		"args": {"year": 2018, "month": 11, "day": 8, "view": "fit", "layers": ONLY_HOTSPOTS,
			"fly": {"lat": 39.78, "lon": -121.55, "zoom": 10.0, "secs": 5.0}}},
	{"scene": "sim", "part": "Fire sim · Speaker 4", "title": "Open it in the fire sim", "secs": 16.0,
		"text": "Unisim builds the real ground: fuel types from LANDFIRE, terrain from open elevation data, and that day's weather. The fire starts from the {seeds} detections the satellites made.",
		"args": {"reset": true, "seed": 7, "aerial": true, "speed": 3, "play": true}},
	{"scene": "sim", "part": "Fire sim · Speaker 4", "title": "Change the wind",
		"text": "Turn the wind a quarter turn, and the fire runs a different way.",
		"args": {"wind": [90.0, 0.0], "play": true}},
	{"scene": "sim", "part": "Fire sim · Speaker 4", "title": "Drop a firebreak", "secs": 16.0,
		"text": "Same fire and recorded weather, +{hours} hours. No firebreak: {base_area} ha. With a 24 km firebreak (pale line) in the wind's path: {area} ha, {saved_pct}% less. A training and what-if tool, not a prediction: it isn't calibrated yet and overburns about three times.",
		"args": {"seed": 7, "aerial": true, "play": false, "compare": {"hours": 8, "firebreaks": [[244, 16, 357, 129]]}}},
	# 2:40 Risk model
	{"scene": "map", "part": "Risk model · Speaker 5", "title": "Looking ahead: the outlook",
		"text": "A random forest trained on our own harmonized data: {cells} grid cells, month by month. For each cell it uses how often notable burning happened there, in that season and in neighbouring cells, in the 10 years before. Only earlier years: no peeking at the year it predicts.",
		"args": {"year": 2018, "month": 11, "day": 0, "view": "fit", "layers": {"hotspots": false, "fires": false, "outlook": true}}},
	{"scene": "map", "part": "Risk model · Speaker 5", "title": "Type a date: Aug 2027",
		"text": "Precomputed, so the answer is instant: {high} cells at High risk, {medium} at Medium. On years it never saw ({test_years}) it scores {auc} AUC, against {auc_base} for a simple baseline. An outlook from history, not a forecast.",
		"args": {"outlook": "Aug 2027", "view": "fit", "layers": NO_LAYERS}},
	# 3:35 Close
	{"scene": "map", "part": "Close · Speaker 6", "title": "One honest record",
		"text": "25 years. Two generations of satellites. Missing data shows as missing, and every number is labelled observed, harmonized, simulated or outlook. From looking at past fires to preparing for the next ones. We're Space Pickles. Thank you.",
		"args": {"year": 2020, "month": 0, "day": 0, "view": "fit", "layers": {"hotspots": true, "fires": false, "wind": true}}},
]

var active := false
var index := -1
var auto := false
var _busy := false
var _auto_left := 0.0
var _typed := ""   # last keys typed while the demo is off, to spot START_CODE
var _panel := PanelContainer.new()
var _title_label: Label
var _text_label: Label


func _ready() -> void:
	layer = 100
	process_mode = Node.PROCESS_MODE_ALWAYS
	_build_caption()
	_panel.visible = false


func _build_caption() -> void:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.1, 0.1, 0.098, 0.98)
	sb.set_content_margin_all(16)
	_panel.add_theme_stylebox_override("panel", sb)
	add_child(_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	_panel.add_child(box)
	_title_label = UI.heading(box, "", 22)
	_text_label = UI.text(box, "", UI.INK_2, 16)
	# No buttons or key hints on the bar: it is shown to an audience. Keys only (see the top of this file).


# ---------- control ----------

func start() -> void:
	if active:
		return
	active = true
	_panel.visible = true
	_go(0)


func stop() -> void:
	if not active:
		return
	active = false
	auto = false
	_typed = ""
	_panel.visible = false
	if not _on_scene("map"):
		get_tree().change_scene_to_file(SCENES.map)


func next() -> void:
	_go(index + 1)


func back() -> void:
	_go(index - 1)


func set_auto(on: bool) -> void:
	auto = on
	_auto_left = _seconds(STEPS[maxi(index, 0)])


func _on_scene(key: String) -> bool:
	var s := get_tree().current_scene
	return s != null and s.scene_file_path == SCENES[key]


func _seconds(step: Dictionary) -> float:
	return step.get("secs", AUTO_SECONDS)


func _input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return  # typing in the outlook box
	if not active:
		if _on_scene("map") and (event.keycode == KEY_F9 or _code_typed(event)):
			start()
			get_viewport().set_input_as_handled()
		return
	match event.keycode:
		KEY_RIGHT, KEY_PAGEDOWN, KEY_ENTER, KEY_KP_ENTER:  # Page Down is what a clicker sends
			next()
		KEY_LEFT, KEY_PAGEUP, KEY_BACKSPACE:
			back()
		KEY_A:
			set_auto(not auto)
		KEY_ESCAPE:
			stop()
		_:
			return
	get_viewport().set_input_as_handled()  # before the screen underneath sees Esc, Space, arrows


## Adds the key to the letters typed so far; true when they end with START_CODE.
func _code_typed(event: InputEventKey) -> bool:
	if event.keycode < KEY_A or event.keycode > KEY_Z:
		_typed = ""
		return false
	_typed = (_typed + char(event.keycode).to_lower()).right(START_CODE.length())
	return _typed == START_CODE


func _process(delta: float) -> void:
	if not active or not auto or _busy or index >= STEPS.size() - 1:
		return
	_auto_left -= delta
	if _auto_left <= 0.0:
		next()


# ---------- running a step ----------

func _go(i: int) -> void:
	if _busy or not active:
		return
	_busy = true
	index = clampi(i, 0, STEPS.size() - 1)
	var step: Dictionary = STEPS[index]
	var tree := get_tree()
	_show_caption(step, _pending_values(step))
	if not _on_scene(step.scene):
		_prepare(step)
		tree.change_scene_to_file(SCENES[step.scene])
		await tree.process_frame
		await tree.process_frame
	var node := tree.current_scene
	var waited := 0.0
	while step.scene == "sim" and node.loading and waited < 60.0:
		await tree.create_timer(0.1).timeout  # the sim fetches its real inputs first
		waited += 0.1
	var result = await node.demo_apply(step.get("args", {}).duplicate(true))
	var values: Dictionary = result if typeof(result) == TYPE_DICTIONARY else {}
	_show_caption(step, values)
	_auto_left = _seconds(step)
	_busy = false


## Shows "…" for each {placeholder} in a step's text until the screen has produced the real numbers.
func _pending_values(step: Dictionary) -> Dictionary:
	var out := {}
	var re := RegEx.new()
	re.compile("[{](\\w+)[}]")
	for m in re.search_all(String(step.text)):
		out[m.get_string(1)] = "…"
	return out


## What a screen needs in AppState before it opens.
func _prepare(step: Dictionary) -> void:
	AppState.return_scene = SCENES.map
	match step.scene:
		"sim":
			AppState.sim_request = CAMP_FIRE.duplicate()
			AppState.sim_event = {}
		"calendar":
			AppState.selection = PackedInt32Array()  # all of California
			AppState.selected_year = 0


func _show_caption(step: Dictionary, values: Dictionary) -> void:
	_title_label.text = step.title
	_text_label.text = String(step.text).format(values)
	var narrow: bool = step.get("place", "top") == "bottom_left"
	var width := NARROW if narrow else WIDE
	_panel.custom_minimum_size.x = width
	_text_label.custom_minimum_size.x = width - 32.0
	_panel.reset_size()
	await get_tree().process_frame  # wrapped text needs a frame to know its height
	_panel.reset_size()
	var view := get_viewport().get_visible_rect().size
	_panel.position = Vector2(16.0, view.y - _panel.size.y - 16.0) if narrow else Vector2(110.0, 14.0)
