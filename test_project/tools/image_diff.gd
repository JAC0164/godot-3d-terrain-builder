extends SceneTree
## Compares screenshots taken before / after a plugin change.
##
##   godot --headless --path . --script res://tools/image_diff.gd -- \
##       --before=res://results/before_optim/screenshots --after=res://results/screenshots
##
## Water is animated (TIME), so a few river pixels always differ between runs.

func _initialize() -> void:
	var before_dir := "res://results/before_optim/screenshots"
	var after_dir := "res://results/screenshots"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--before="): before_dir = arg.trim_prefix("--before=")
		if arg.begins_with("--after="): after_dir = arg.trim_prefix("--after=")

	for file_name in DirAccess.get_files_at(before_dir):
		if not file_name.ends_with(".png") or not FileAccess.file_exists(after_dir.path_join(file_name)):
			continue
		var a := Image.load_from_file(before_dir.path_join(file_name))
		var b := Image.load_from_file(after_dir.path_join(file_name))
		if a.get_size() != b.get_size():
			print("%-40s size differs" % file_name)
			continue
		a.convert(Image.FORMAT_RGB8)
		b.convert(Image.FORMAT_RGB8)
		var da := a.get_data()
		var db := b.get_data()
		var changed := 0
		var max_delta := 0
		var total_delta := 0
		for i in range(0, da.size(), 3):
			var delta := maxi(absi(da[i] - db[i]), maxi(absi(da[i + 1] - db[i + 1]), absi(da[i + 2] - db[i + 2])))
			total_delta += delta
			max_delta = maxi(max_delta, delta)
			if delta > 8:
				changed += 1
		var pixels := da.size() / 3
		print("%-40s pixels changed(>8/255): %6.3f%%  mean delta: %.3f/255  max: %d" % [file_name, 100.0 * changed / pixels, float(total_delta) / pixels, max_delta])
	quit()
