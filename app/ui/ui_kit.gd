## Shared look for side panels, labels and buttons: the dark palette of the map screen.
## Static helpers only. Used by the sim screen (main.gd); the map still has its own copies.
## Buttons made here never take keyboard focus, so Space and the arrow keys stay shortcuts.
extends RefCounted

const SURFACE := Color("#1a1a19")
const PANEL_BG := Color("#222220")
const INK := Color("#f0efec")
const INK_2 := Color("#c3c2b7")
const INK_3 := Color("#8a897f")
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


static func flat(bg: Color, border: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(4)
	s.content_margin_left = 6
	s.content_margin_right = 6
	s.content_margin_top = 5
	s.content_margin_bottom = 5
	return s


## Dark when off, light when on.
static func style_toggle(b: Button) -> void:
	b.add_theme_stylebox_override("normal", flat(Color("#2b2b29"), Color("#4a4a46")))
	b.add_theme_stylebox_override("hover", flat(Color("#383835"), INK_3))
	b.add_theme_stylebox_override("pressed", flat(Color("#e8e7e2"), Color("#e8e7e2")))
	b.add_theme_stylebox_override("hover_pressed", flat(INK, INK))
	b.add_theme_stylebox_override("disabled", flat(SURFACE, Color("#383835")))
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
	b.add_theme_stylebox_override("normal", flat(Color("#2b2b29"), INK_3))
	b.add_theme_stylebox_override("hover", flat(Color("#383835"), INK_3))
	b.add_theme_stylebox_override("pressed", flat(Color("#4a4a46"), INK))
	b.add_theme_stylebox_override("disabled", flat(SURFACE, Color("#383835")))
	b.add_theme_color_override("font_color", INK)
	b.add_theme_color_override("font_disabled_color", Color("#5c5b55"))
	b.add_theme_font_size_override("font_size", 13)
	b.focus_mode = Control.FOCUS_NONE
	b.pressed.connect(cb)
	box.add_child(b)
	return b


## An on/off button. `cb` gets the new state.
static func toggle(box: Node, t: String, tip: String, on: bool, cb: Callable) -> Button:
	var b := Button.new()
	b.text = t
	b.tooltip_text = tip
	b.toggle_mode = true
	b.button_pressed = on
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	style_toggle(b)
	b.toggled.connect(cb)
	box.add_child(b)
	return b


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
