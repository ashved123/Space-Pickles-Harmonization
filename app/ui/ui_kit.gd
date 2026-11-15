## Shared look for side panels, labels and buttons: the dark palette of the map screen.
## Static helpers only. Used by the sim screen (main.gd); the map still has its own copies.
## Buttons made here never take keyboard focus, so Space and the arrow keys stay shortcuts.
extends RefCounted

const SURFACE := Color("#1a1a19")
const PANEL_BG := Color("#222220")
const INK := Color("#f0efec")
const INK_2 := Color("#c3c2b7")
const INK_3 := Color("#8a897f")
const BTN := Color("#34342f")          # button fill
const BTN_HOVER := Color("#42423d")
const BTN_PRESSED := Color("#55554f")
const BTN_DISABLED := Color("#262624")
const PANEL_W := 340.0
const INNER_W := PANEL_W - 30.0


## A scrolling panel on the right edge of `parent` (a CanvasLayer or Control). Returns the
## column to add things to.
static func side_panel(parent: Node) -> VBoxContainer:
	var bg := Panel.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	bg.add_theme_stylebox_override("panel", sb)
	bg.anchor_left = 1.0
	bg.anchor_right = 1.0
	bg.anchor_bottom = 1.0
	bg.offset_left = -PANEL_W
	parent.add_child(bg)
	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left = 14
	scroll.offset_right = -6
	scroll.offset_top = 12
	scroll.offset_bottom = -12
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	bg.add_child(scroll)
	var box := VBoxContainer.new()
	box.custom_minimum_size.x = INNER_W
	box.add_theme_constant_override("separation", 6)
	scroll.add_child(box)
	return box


static func heading(box: Node, t: String, size: int = 15) -> Label:
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", INK)
	box.add_child(l)
	return l


## Wrapping text as wide as the panel.
static func text(box: Node, t: String, color: Color = INK_3, size: int = 12) -> Label:
	var l := Label.new()
	l.text = t
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.custom_minimum_size.x = INNER_W
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	box.add_child(l)
	return l


## A square-cornered fill with no outline: buttons are plain blocks, not outlined or rounded.
static func flat(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.content_margin_left = 6
	s.content_margin_right = 6
	s.content_margin_top = 5
	s.content_margin_bottom = 5
	return s


## Dark when off, light when on.
static func style_toggle(b: Button) -> void:
	b.add_theme_stylebox_override("normal", flat(BTN))
	b.add_theme_stylebox_override("hover", flat(BTN_HOVER))
	b.add_theme_stylebox_override("pressed", flat(Color("#e8e7e2")))
	b.add_theme_stylebox_override("hover_pressed", flat(INK))
	b.add_theme_stylebox_override("disabled", flat(BTN_DISABLED))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", INK_2)
	b.add_theme_color_override("font_hover_color", INK)
	b.add_theme_color_override("font_pressed_color", SURFACE)
	b.add_theme_color_override("font_hover_pressed_color", SURFACE)
	b.add_theme_color_override("font_disabled_color", Color("#5c5b55"))
	b.add_theme_font_size_override("font_size", 13)
	b.focus_mode = Control.FOCUS_NONE


## A plain push button.
static func button(box: Node, t: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.tooltip_text = tip
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_stylebox_override("normal", flat(BTN))
	b.add_theme_stylebox_override("hover", flat(BTN_HOVER))
	b.add_theme_stylebox_override("pressed", flat(BTN_PRESSED))
	b.add_theme_stylebox_override("disabled", flat(BTN_DISABLED))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_color_override("font_color", INK)
	b.add_theme_color_override("font_disabled_color", Color("#5c5b55"))
	b.add_theme_font_size_override("font_size", 13)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	box.add_child(b)
	return b


## An on/off option that can be combined with others: a check box (a square that fills when on).
## It must not look like segmented(), where exactly one button is on. `cb` gets the new state.
static func toggle(box: Node, t: String, tip: String, on: bool, cb: Callable) -> Button:
	var b := CheckBox.new()
	b.text = t
	b.tooltip_text = tip
	b.button_pressed = on
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for state in ["normal", "pressed", "disabled"]:
		b.add_theme_stylebox_override(state, flat(BTN_DISABLED if state == "disabled" else BTN))
	for state in ["hover", "hover_pressed"]:
		b.add_theme_stylebox_override(state, flat(BTN_HOVER))
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	b.add_theme_icon_override("checked", _check_icon(true))
	b.add_theme_icon_override("unchecked", _check_icon(false))
	b.add_theme_icon_override("checked_disabled", _check_icon(true))
	b.add_theme_icon_override("unchecked_disabled", _check_icon(false))
	b.add_theme_constant_override("h_separation", 7)
	b.add_theme_color_override("font_color", INK_2)
	b.add_theme_color_override("font_hover_color", INK)
	b.add_theme_color_override("font_pressed_color", INK)
	b.add_theme_color_override("font_hover_pressed_color", INK)
	b.add_theme_color_override("font_disabled_color", Color("#5c5b55"))
	b.add_theme_font_size_override("font_size", 13)
	b.focus_mode = Control.FOCUS_NONE
	b.toggled.connect(cb)
	box.add_child(b)
	return b


static var _check_icons := {}


## 14 px square: an outline when off, filled with a dark tick when on.
static func _check_icon(on: bool) -> ImageTexture:
	if _check_icons.has(on):
		return _check_icons[on]
	var n := 14
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	img.fill(INK if on else Color(0, 0, 0, 0))
	if on:
		# Tick: a short stroke down to (5, 10), then a long one up to (11, 3), 2 px thick.
		for p in [[3, 7], [4, 8], [5, 9], [6, 8], [7, 7], [8, 6], [9, 5], [10, 4]]:
			img.set_pixel(p[0], p[1], SURFACE)
			img.set_pixel(p[0], p[1] + 1, SURFACE)
	else:
		for i in n:
			for edge in [0, 1, n - 2, n - 1]:
				img.set_pixel(i, edge, INK_3)
				img.set_pixel(edge, i, INK_3)
	_check_icons[on] = ImageTexture.create_from_image(img)
	return _check_icons[on]


## A row of buttons where exactly one is on. `cb` gets the index. Returns the buttons.
static func segmented(box: Node, labels: Array, selected: int, cb: Callable) -> Array:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	box.add_child(row)
	var group := ButtonGroup.new()
	var out := []
	for i in labels.size():
		var b := Button.new()
		b.text = labels[i]
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = i == selected
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		style_toggle(b)
		b.add_theme_font_size_override("font_size", 12)
		b.pressed.connect(cb.bind(i))
		row.add_child(b)
		out.append(b)
	return out


## A value label with - and + buttons on its right. Returns the label.
static func stepper(box: Node, tip_minus: String, tip_plus: String, on_minus: Callable, on_plus: Callable) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	box.add_child(row)
	var l := Label.new()
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", INK_2)
	row.add_child(l)
	for spec in [["-", tip_minus, on_minus], ["+", tip_plus, on_plus]]:
		var b := Button.new()
		b.text = spec[0]
		b.tooltip_text = spec[1]
		b.custom_minimum_size = Vector2(38, 28)
		style_toggle(b)
		b.add_theme_font_size_override("font_size", 16)
		b.pressed.connect(spec[2])
		row.add_child(b)
	return l


## A colour square with a name, for legends.
static func swatch(box: Node, color: Color, t: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(row)
	var holder := CenterContainer.new()
	row.add_child(holder)
	var c := ColorRect.new()
	c.color = color
	c.custom_minimum_size = Vector2(12, 12)
	holder.add_child(c)
	var l := Label.new()
	l.text = t
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_color_override("font_color", INK_2)
	row.add_child(l)


## How far a mouse wheel event scrolled, in notches of an ordinary wheel. Desktop reports 1.0 per
## notch, a browser 3.0 (checked in Chromium); trackpads send many small ones. Capped, so one huge
## event can't throw the zoom. Zoom by `step * wheel_notches(event)`, not by a fixed step per event.
static func wheel_notches(event: InputEventMouseButton) -> float:
	var f: float = event.factor
	if f <= 0.0:
		f = 1.0
	if OS.has_feature("web"):
		f /= 3.0
	return clampf(f, 0.02, 3.0)


## Makes everything that is not styled by hand square-cornered and drops the focus outline:
## text fields, scroll bars, lists and tooltips come from Godot's default theme, which is rounded.
## Call once at start (the AppState autoload does).
static func square_default_theme() -> void:
	var theme := ThemeDB.get_default_theme()
	for type in theme.get_stylebox_type_list():
		for sb_name in theme.get_stylebox_list(type):
			if sb_name == "focus":
				theme.set_stylebox(sb_name, type, StyleBoxEmpty.new())
				continue
			var sb := theme.get_stylebox(sb_name, type)
			if sb is StyleBoxFlat:
				sb.set_corner_radius_all(0)


## 12345 -> "12,345".
static func thousands(n: int) -> String:
	var s := str(n)
	var out := ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return s + out


## Compass point for a bearing in degrees: 0 -> N, 90 -> E, 225 -> SW.
static func compass(deg: float) -> String:
	return ["N", "NE", "E", "SE", "S", "SW", "W", "NW"][int(round(fposmod(deg, 360.0) / 45.0)) % 8]
