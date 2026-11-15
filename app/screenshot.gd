## Opens a screen in a window of a given size and saves a screenshot, to check the layout at
## different resolutions. Needs a real window (not --headless):
##   godot --path app -s screenshot.gd -- <map|calendar|sim> <width> <height>
## Example: godot --path app -s screenshot.gd -- calendar 1600 900
## The PNG goes to user://screenshot_<screen>_<w>x<h>.png (printed at the end). The sim opens on
## test terrain with a fire already burning. The window can't be bigger than your screen.
extends SceneTree

const SCENES := {
	"map": "res://ui/map_view.tscn",
	"calendar": "res://ui/calendar_view.tscn",
	"sim": "res://main.tscn",
}
const WAIT_FRAMES := 360  # time for map tiles to arrive

var screen := ""
var size := Vector2i(1200, 800)
var scene: Node
var frames := 0


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 3 or not SCENES.has(args[0]):
		print("usage: -s screenshot.gd -- <map|calendar|sim> <width> <height>")
		quit(1)
		return
	screen = args[0]
	size = Vector2i(int(args[1]), int(args[2]))
	DisplayServer.window_set_size(size)
	scene = load(SCENES[screen]).instantiate()
	root.add_child(scene)


func _process(_delta: float) -> bool:
	frames += 1
	if frames == 8:
		if screen == "calendar":
			scene.select_month(2018, 11)
		elif screen == "sim":
			scene.sim.ignite(100, 100)
			for i in 150:
				scene.step_once()
	if frames == WAIT_FRAMES:
		var path := "user://screenshot_%s_%dx%d.png" % [screen, size.x, size.y]
		root.get_texture().get_image().save_png(path)
		print("window %s, layout size %s, saved %s" % [DisplayServer.window_get_size(), root.get_visible_rect().size, ProjectSettings.globalize_path(path)])
		return true
	return false
