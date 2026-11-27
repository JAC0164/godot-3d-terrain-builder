extends SceneTree
## Heightmap files (generation/heightmap_io.gd, Advanced > Terrain Size >
## Import / Export Heightmap):
## - export writes .exr, .png (16-bit, readable by Godot's own loader) and
##   .json;
## - EXR back in: the same heights exactly; 16-bit PNG back in (with its
##   .json, and without: the current range): within one 16-bit step;
## - .r16 and 8-bit PNG read; a smaller image is resized (a ramp stays a
##   ramp); heights past the limits are cut and counted;
## - missing / malformed files give an error and change nothing.
## Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_heightmap_io.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const HeightmapIO = preload(ADDON + "generation/heightmap_io.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _initialize() -> void:
	_run.call_deferred()

static func _worst(a: PackedFloat32Array, b: PackedFloat32Array) -> float:
	if a.size() != b.size():
		return INF
	var worst := 0.0
	for i in a.size():
		worst = maxf(worst, absf(a[i] - b[i]))
	return worst

func _flat(t: Node3D) -> void:
	var heights: PackedFloat32Array = t.get_meta(Meta.HEIGHTS)
	heights.fill(0.0)
	t.set_meta(Meta.HEIGHTS, heights)

func _run() -> void:
	var root3d := Node3D.new()
	root3d.name = "Root"
	root.add_child(root3d)
	var t := TestTerrain.savanna(root3d)
	var resolution: int = t.get_meta(Meta.RESOLUTION)
	var original: PackedFloat32Array = (t.get_meta(Meta.HEIGHTS) as PackedFloat32Array).duplicate()
	var low := INF
	var high := -INF
	for h in original:
		low = minf(low, h)
		high = maxf(high, h)
	var step := (high - low) / 65535.0
	var folder := ProjectSettings.globalize_path("user://heightmap_check")
	DirAccess.make_dir_recursive_absolute(folder)
	var base := folder.path_join("savanna")

	var start := Time.get_ticks_msec()
	var error := HeightmapIO.export_files(t, base + ".exr")
	var export_ms := Time.get_ticks_msec() - start
	check("export %d x %d in %d ms: %s" % [resolution, resolution, export_ms, error if not error.is_empty() else "exr, png, json"], error.is_empty() and FileAccess.file_exists(base + ".exr") and FileAccess.file_exists(base + ".png") and FileAccess.file_exists(base + ".json"))
	var godot_png := Image.load_from_file(base + ".png")
	check("the 16-bit PNG opens in Godot's own loader (%s)" % (godot_png.get_size() if godot_png else "null"), godot_png != null and godot_png.get_width() == resolution and godot_png.get_height() == resolution)

	_flat(t)
	var stats := HeightmapIO.import_file(t, base + ".exr")
	check("EXR back in: same heights (worst %.7f m)" % _worst(original, t.get_meta(Meta.HEIGHTS)), not stats.has("error") and _worst(original, t.get_meta(Meta.HEIGHTS)) < 0.000001)

	_flat(t)
	start = Time.get_ticks_msec()
	stats = HeightmapIO.import_file(t, base + ".png")
	var import_ms := Time.get_ticks_msec() - start
	var worst := _worst(original, t.get_meta(Meta.HEIGHTS))
	check("16-bit PNG + .json back in, %d ms: worst %.5f m (one step %.5f m)" % [import_ms, worst, step], not stats.has("error") and worst <= step * 0.51 + 0.000001)

	# No .json: the range of the current heights (= the original ones here).
	DirAccess.copy_absolute(base + ".png", folder.path_join("alone.png"))
	stats = HeightmapIO.import_file(t, folder.path_join("alone.png"))
	worst = _worst(original, t.get_meta(Meta.HEIGHTS))
	check("16-bit PNG without .json: current range %s (worst %.5f m)" % [stats.get("range"), worst], not stats.has("error") and worst <= step * 0.51 + 0.00001)

	# r16 beside the .json.
	var raw := PackedByteArray()
	raw.resize(original.size() * 2)
	for i in original.size():
		raw.encode_u16(i * 2, clampi(roundi((original[i] - low) / (high - low) * 65535.0), 0, 65535))
	var file := FileAccess.open(base + ".r16", FileAccess.WRITE)
	file.store_buffer(raw)
	file.close()
	_flat(t)
	stats = HeightmapIO.import_file(t, base + ".r16")
	worst = _worst(original, t.get_meta(Meta.HEIGHTS))
	check(".r16 + .json: worst %.5f m" % worst, not stats.has("error") and worst <= step * 0.51 + 0.000001)

	# 8-bit PNG.
	var image := Image.create(resolution, resolution, false, Image.FORMAT_L8)
	for z in resolution:
		for x in resolution:
			image.set_pixel(x, z, Color.from_hsv(0.0, 0.0, (original[z * resolution + x] - low) / (high - low)))
	image.save_png(base + ".png")
	stats = HeightmapIO.import_file(t, base + ".png")
	worst = _worst(original, t.get_meta(Meta.HEIGHTS))
	check("8-bit PNG + .json: worst %.3f m (one step %.3f m)" % [worst, (high - low) / 255.0], not stats.has("error") and worst <= (high - low) / 255.0)

	# A 16-bit RGB PNG as other tools write it: every row filter (0-4).
	var side := 1025
	var expected := PackedFloat32Array()
	expected.resize(side * side)
	var pixel := 6
	var row_bytes := side * pixel
	var plain := PackedByteArray()
	plain.resize(row_bytes * side)
	for y in side:
		for x in side:
			var value := (x * 37 + y * 101 + (x * y) % 977) % 65536
			expected[y * side + x] = float(value) / 65535.0
			for channel in 3:
				plain[y * row_bytes + x * pixel + channel * 2] = (value >> 8) & 0xFF
				plain[y * row_bytes + x * pixel + channel * 2 + 1] = value & 0xFF
	var filtered := PackedByteArray()
	for y in side:
		var kind := y % 5
		filtered.append(kind)
		for i in row_bytes:
			var current := plain[y * row_bytes + i]
			var a := plain[y * row_bytes + i - pixel] if i >= pixel else 0
			var b := plain[(y - 1) * row_bytes + i] if y > 0 else 0
			var c := plain[(y - 1) * row_bytes + i - pixel] if y > 0 and i >= pixel else 0
			var predictor := 0
			match kind:
				1:
					predictor = a
				2:
					predictor = b
				3:
					predictor = (a + b) >> 1
				4:
					var p := a + b - c
					predictor = a if absi(p - a) <= absi(p - b) and absi(p - a) <= absi(p - c) else (b if absi(p - b) <= absi(p - c) else c)
			filtered.append((current - predictor) & 0xFF)
	var header := PackedByteArray()
	header.resize(13)
	header.encode_u32(0, HeightmapIO._swap32(side))
	header.encode_u32(4, HeightmapIO._swap32(side))
	header[8] = 16
	header[9] = 2
	var png := PackedByteArray(HeightmapIO.PNG_SIGNATURE)
	png.append_array(HeightmapIO._chunk("IHDR", header))
	png.append_array(HeightmapIO._chunk("IDAT", filtered.compress(FileAccess.COMPRESSION_DEFLATE)))
	png.append_array(HeightmapIO._chunk("IEND", PackedByteArray()))
	start = Time.get_ticks_msec()
	var decoded := HeightmapIO.decode_png16(png)
	var decode_ms := Time.get_ticks_msec() - start
	var decoded_values: PackedFloat32Array = decoded.get("values", PackedFloat32Array())
	check("16-bit RGB PNG with filters 0-4 (%d x %d) decoded in %d ms: worst %.7f" % [side, side, decode_ms, _worst(expected, decoded_values)], _worst(expected, decoded_values) < 0.0000001)

	# A smaller ramp, resized.
	var ramp := Image.create(33, 17, false, Image.FORMAT_RF)
	for y in 17:
		for x in 33:
			ramp.set_pixel(x, y, Color(float(x) / 32.0, 0.0, 0.0))
	ramp.save_exr(folder.path_join("ramp.exr"), true)
	stats = HeightmapIO.import_file(t, folder.path_join("ramp.exr"))
	var heights: PackedFloat32Array = t.get_meta(Meta.HEIGHTS)
	var ramp_worst := 0.0
	for z in resolution:
		for x in resolution:
			ramp_worst = maxf(ramp_worst, absf(heights[z * resolution + x] - float(x) / float(resolution - 1)))
	check("33 x 17 ramp resized to %d x %d: still a ramp (worst %.5f m)" % [resolution, resolution, ramp_worst], not stats.has("error") and ramp_worst < 0.0001)

	# Too high: cut to the limit.
	var tall := Image.create(8, 8, false, Image.FORMAT_RF)
	tall.fill(Color(1000.0, 0.0, 0.0))
	tall.save_exr(folder.path_join("tall.exr"), true)
	stats = HeightmapIO.import_file(t, folder.path_join("tall.exr"))
	heights = t.get_meta(Meta.HEIGHTS)
	check("1000 m: %d points cut to Highest Ground %.1f m" % [stats.get("clamped", 0), TerrainData.height_max(t)], stats.get("clamped", 0) == resolution * resolution and is_equal_approx(heights[0], TerrainData.height_max(t)))

	# Bad files.
	t.set_meta(Meta.HEIGHTS, original.duplicate())
	file = FileAccess.open(folder.path_join("odd.r16"), FileAccess.WRITE)
	file.store_buffer(PackedByteArray([1, 2, 3]))
	file.close()
	var missing := HeightmapIO.import_file(t, folder.path_join("nothing.exr"))
	var odd := HeightmapIO.import_file(t, folder.path_join("odd.r16"))
	var wrong := HeightmapIO.import_file(t, folder.path_join("savanna.json"))
	check("errors: %s / %s / %s; heights untouched" % [missing.get("error"), odd.get("error"), wrong.get("error")], missing.has("error") and odd.has("error") and wrong.has("error") and _worst(original, t.get_meta(Meta.HEIGHTS)) == 0.0)

	print("RESULT: %s" % ("PASS" if _failures == 0 else "FAIL (%d)" % _failures))
	quit(1 if _failures > 0 else 0)
