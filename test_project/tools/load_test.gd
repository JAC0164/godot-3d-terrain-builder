extends SceneTree
## Scene file size and load time: text .tscn (what the plugin produces) vs
## binary .scn, and how much of it is editor-only terrain metadata.
##
##   godot --headless --path . --script res://tools/load_test.gd

const SIZES := [64, 128, 256]

func _initialize() -> void:
	var report := []
	for size in SIZES:
		var tscn := "res://scenes/terrain_%d.tscn" % size
		var scn := "user://terrain_%d.scn" % size
		var stripped_scn := "user://terrain_%d_nometa.scn" % size

		var packed := ResourceLoader.load(tscn, "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
		ResourceSaver.save(packed, scn, ResourceSaver.FLAG_COMPRESS)

		# Same scene without the _lte_* metadata (heights, masks, palette...).
		var root := packed.instantiate()
		var terrain := root.get_node("LowpolyTerrain")
		for key in terrain.get_meta_list():
			terrain.remove_meta(key)
		var stripped := PackedScene.new()
		stripped.pack(root)
		ResourceSaver.save(stripped, stripped_scn, ResourceSaver.FLAG_COMPRESS)
		root.free()

		var entry := {"size": size}
		for item in [["tscn", tscn], ["scn_compressed", scn], ["scn_no_metadata", stripped_scn]]:
			entry[item[0] + "_kb"] = int(FileAccess.get_file_as_bytes(item[1]).size() / 1024)
			var t := Time.get_ticks_usec()
			var loaded := ResourceLoader.load(item[1], "", ResourceLoader.CACHE_MODE_IGNORE) as PackedScene
			var instance := loaded.instantiate()
			entry[item[0] + "_load_ms"] = snappedf(float(Time.get_ticks_usec() - t) / 1000.0, 0.1)
			instance.free()
		report.append(entry)
		print(entry)

	var file := FileAccess.open("res://results/load_report.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "  "))
	quit()
