extends SceneTree
## Stacks two screenshots (before above, after below) into one PNG.
##   godot --headless --path . --script res://tools/before_after.gd -- --before=a.png --after=b.png --out=c.png

func _initialize() -> void:
	var args := {}
	for arg in OS.get_cmdline_user_args():
		var parts := arg.trim_prefix("--").split("=", true, 1)
		if parts.size() == 2:
			args[parts[0]] = parts[1]
	var before := Image.load_from_file(args["before"])
	var after := Image.load_from_file(args["after"])
	before.convert(Image.FORMAT_RGB8)
	after.convert(Image.FORMAT_RGB8)
	var gap := 6
	var out := Image.create(before.get_width(), before.get_height() + gap + after.get_height(), false, Image.FORMAT_RGB8)
	out.fill(Color.WHITE)
	out.blit_rect(before, Rect2i(Vector2i.ZERO, before.get_size()), Vector2i.ZERO)
	out.blit_rect(after, Rect2i(Vector2i.ZERO, after.get_size()), Vector2i(0, before.get_height() + gap))
	out.save_png(args["out"])
	print("wrote ", args["out"])
	quit(0)
