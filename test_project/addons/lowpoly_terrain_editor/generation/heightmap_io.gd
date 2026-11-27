@tool
extends RefCounted
## Heightmap files in and out (Inspector > Advanced > Terrain Size > Import /
## Export Heightmap), to shape a map in another tool and back.
##
## Export writes three files side by side:
##   <name>.exr   the heights in metres (32-bit float, one channel);
##   <name>.png   the same, 16-bit grey, from the lowest (black) to the
##                highest (white) height;
##   <name>.json  that range and the map size, for the PNG.
## Import reads an EXR (metres), a PNG (8 or 16 bit, grey or colour: its red
## channel) or a .r16 / .raw (16-bit little-endian, square). A PNG / raw has
## no unit: its black-to-white range comes from the .json next to it when
## there is one, else from the terrain's current lowest and highest ground.
## The image is resized to the terrain's grid; heights stay within its
## Lowest / Highest Ground (Advanced > Heights & Offsets). Only the heights
## change: the painted cells and styles stay.

const Meta = preload("../core/terrain_meta.gd")
const TerrainData = preload("../core/terrain_data.gd")

const EXTENSIONS: Array[String] = ["exr", "png", "r16", "raw"]
const FORMAT_NAME := "lowpoly_terrain_heightmap"
const PNG_SIGNATURE := [137, 80, 78, 71, 13, 10, 26, 10]
## Biggest image side read (a 16 384 x 16 384 PNG is ~512 MB unpacked).
const MAX_SIDE := 8192

static var _crc_table := PackedInt64Array()

## Writes <base>.exr, <base>.png and <base>.json (`path`'s extension is
## replaced). Returns "" or what went wrong.
static func export_files(terrain: Node3D, path: String) -> String:
	var resolution := Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS, PackedFloat32Array())
	if resolution < 2 or heights.size() != resolution * resolution:
		return "the terrain has no heights to export."
	var base := path.get_basename()
	var image := Image.create_from_data(resolution, resolution, false, Image.FORMAT_RF, heights.to_byte_array())
	var error := image.save_exr(base + ".exr", true)
	if error != OK:
		return "could not write %s.exr (%s)." % [base, error_string(error)]
	var low := INF
	var high := -INF
	for h in heights:
		low = minf(low, h)
		high = maxf(high, h)
	var span := maxf(high - low, 0.000001)
	var values := PackedInt32Array()
	values.resize(heights.size())
	for i in heights.size():
		values[i] = clampi(roundi((heights[i] - low) / span * 65535.0), 0, 65535)
	error = _write_file(base + ".png", encode_png16(values, resolution, resolution))
	if error != OK:
		return "could not write %s.png (%s)." % [base, error_string(error)]
	var info := {
		"format": FORMAT_NAME,
		"min": low,
		"max": high,
		"resolution": resolution,
		"world_size": Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE),
	}
	error = _write_file(base + ".json", JSON.stringify(info, "\t").to_utf8_buffer())
	if error != OK:
		return "could not write %s.json (%s)." % [base, error_string(error)]
	return ""

## Reads a heightmap file: {"values": PackedFloat32Array (row by row),
## "width", "height", "metres": bool (EXR) or false (0..1, needs a range)},
## or {"error": text}.
static func read(path: String) -> Dictionary:
	var extension := path.get_extension().to_lower()
	if not FileAccess.file_exists(path):
		return {"error": "%s not found." % path}
	if extension == "r16" or extension == "raw":
		var bytes := FileAccess.get_file_as_bytes(path)
		var side := roundi(sqrt(bytes.size() / 2.0))
		if side < 2 or side > MAX_SIDE or side * side * 2 != bytes.size():
			return {"error": "%s is not a square 16-bit raw heightmap (%d bytes)." % [path.get_file(), bytes.size()]}
		var values := PackedFloat32Array()
		values.resize(side * side)
		for i in values.size():
			values[i] = float(bytes.decode_u16(i * 2)) / 65535.0
		return {"values": values, "width": side, "height": side, "metres": false}
	if extension == "png":
		var bytes := FileAccess.get_file_as_bytes(path)
		var decoded := decode_png16(bytes)
		if not decoded.is_empty():
			return decoded
	if not extension in EXTENSIONS:
		return {"error": "%s: use an .exr, .png, .r16 or .raw file." % path.get_file()}
	var image := Image.load_from_file(path)
	if image == null or image.is_empty():
		return {"error": "could not read %s." % path.get_file()}
	if image.get_width() > MAX_SIDE or image.get_height() > MAX_SIDE:
		return {"error": "%s is bigger than %d pixels a side." % [path.get_file(), MAX_SIDE]}
	if image.is_compressed():
		image.decompress()
	image.convert(Image.FORMAT_RF)
	return {"values": image.get_data().to_float32_array(), "width": image.get_width(), "height": image.get_height(), "metres": extension == "exr"}

## The black-to-white range of a PNG / raw: its .json (export_files), else
## the terrain's current lowest and highest heights (its height limits when
## it is flat).
static func range_for(terrain: Node3D, path: String) -> Vector2:
	var info_path := path.get_basename() + ".json"
	if FileAccess.file_exists(info_path):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(info_path))
		if parsed is Dictionary:
			var info: Dictionary = parsed
			# JSON numbers are floats.
			var low_value: Variant = info.get("min")
			var high_value: Variant = info.get("max")
			if low_value is float and high_value is float:
				var saved_low: float = low_value
				var saved_high: float = high_value
				return Vector2(saved_low, saved_high)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS, PackedFloat32Array())
	var low := INF
	var high := -INF
	for h in heights:
		low = minf(low, h)
		high = maxf(high, h)
	if heights.is_empty() or high - low < 0.01:
		return Vector2(0.0, TerrainData.height_max(terrain))
	return Vector2(low, high)

## Puts a heightmap file on the terrain's heights (resized to its grid).
## Returns {"width", "height", "range": Vector2, "clamped": vertices cut to
## the height limits} or {"error": text}.
static func import_file(terrain: Node3D, path: String) -> Dictionary:
	var data := read(path)
	if data.has("error"):
		return data
	var resolution := Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS, PackedFloat32Array())
	if resolution < 2 or heights.size() != resolution * resolution:
		return {"error": "the terrain has no grid yet."}
	var values: PackedFloat32Array = data["values"]
	var width: int = data["width"]
	var height: int = data["height"]
	var metres: bool = data["metres"]
	var source_range := Vector2(0.0, 1.0) if metres else range_for(terrain, path)
	var scale := 1.0 if metres else source_range.y - source_range.x
	var offset := 0.0 if metres else source_range.x
	var low := TerrainData.height_min(terrain)
	var high := TerrainData.height_max(terrain)
	var clamped := 0
	var result := PackedFloat32Array()
	result.resize(resolution * resolution)
	for z in resolution:
		var v := float(z) / float(resolution - 1) * float(height - 1)
		var z0 := mini(int(v), height - 1)
		var z1 := mini(z0 + 1, height - 1)
		var fz := v - float(z0)
		for x in resolution:
			var u := float(x) / float(resolution - 1) * float(width - 1)
			var x0 := mini(int(u), width - 1)
			var x1 := mini(x0 + 1, width - 1)
			var fx := u - float(x0)
			var top := lerpf(values[z0 * width + x0], values[z0 * width + x1], fx)
			var bottom := lerpf(values[z1 * width + x0], values[z1 * width + x1], fx)
			var h := offset + lerpf(top, bottom, fz) * scale
			if h < low or h > high:
				clamped += 1
				h = clampf(h, low, high)
			result[z * resolution + x] = h
	terrain.set_meta(Meta.HEIGHTS, result)
	return {"width": width, "height": height, "range": source_range if not metres else Vector2(low, high), "clamped": clamped, "metres": metres}

# -----------------------------------------------------------------------------
# 16-bit grey PNG (Godot writes 8-bit PNGs only, and reads 16-bit ones as 8)
# -----------------------------------------------------------------------------

## A 16-bit grey PNG of `values` (0..65535, row by row).
static func encode_png16(values: PackedInt32Array, width: int, height: int) -> PackedByteArray:
	var row_bytes := 1 + width * 2
	var raw := PackedByteArray()
	raw.resize(row_bytes * height)
	for y in height:
		var start := y * row_bytes
		# Filter 0 (none) on every row.
		raw[start] = 0
		for x in width:
			var value := values[y * width + x]
			raw[start + 1 + x * 2] = (value >> 8) & 0xFF
			raw[start + 2 + x * 2] = value & 0xFF
	var header := PackedByteArray()
	header.resize(13)
	header.encode_u32(0, _swap32(width))
	header.encode_u32(4, _swap32(height))
	header[8] = 16
	header[9] = 0
	header[10] = 0
	header[11] = 0
	header[12] = 0
	var png := PackedByteArray(PNG_SIGNATURE)
	png.append_array(_chunk("IHDR", header))
	# Godot's DEFLATE is a zlib stream, what IDAT holds.
	png.append_array(_chunk("IDAT", raw.compress(FileAccess.COMPRESSION_DEFLATE)))
	png.append_array(_chunk("IEND", PackedByteArray()))
	return png

## A 16-bit PNG's first channel as 0..1 values ({"values", "width", "height",
## "metres": false}); {} for anything else (8-bit PNGs go through Image).
static func decode_png16(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 33 or bytes.slice(0, 8) != PackedByteArray(PNG_SIGNATURE):
		return {}
	var width := 0
	var height := 0
	var channels := 0
	var data := PackedByteArray()
	var cursor := 8
	while cursor + 8 <= bytes.size():
		var length := _swap32(bytes.decode_u32(cursor))
		var type := bytes.slice(cursor + 4, cursor + 8).get_string_from_ascii()
		if length < 0 or cursor + 12 + length > bytes.size():
			return {}
		var body := bytes.slice(cursor + 8, cursor + 8 + length)
		cursor += 12 + length
		if type == "IHDR":
			width = _swap32(body.decode_u32(0))
			height = _swap32(body.decode_u32(4))
			var depth := body[8]
			var color := body[9]
			if depth != 16 or body[12] != 0:
				return {}
			match color:
				0:
					channels = 1
				2:
					channels = 3
				4:
					channels = 2
				6:
					channels = 4
			if channels == 0 or width < 2 or height < 2 or width > MAX_SIDE or height > MAX_SIDE:
				return {}
		elif type == "IDAT":
			data.append_array(body)
		elif type == "IEND":
			break
	if channels == 0 or data.is_empty():
		return {}
	var pixel := channels * 2
	var row_bytes := width * pixel
	var raw := data.decompress_dynamic((row_bytes + 1) * height, FileAccess.COMPRESSION_DEFLATE)
	if raw.size() != (row_bytes + 1) * height:
		return {}
	var values := PackedFloat32Array()
	values.resize(width * height)
	var previous := PackedByteArray()
	previous.resize(row_bytes)
	for y in height:
		var start := y * (row_bytes + 1)
		var filter := raw[start]
		var row := raw.slice(start + 1, start + 1 + row_bytes)
		match filter:
			1:
				for i in range(pixel, row_bytes):
					row[i] = (row[i] + row[i - pixel]) & 0xFF
			2:
				for i in row_bytes:
					row[i] = (row[i] + previous[i]) & 0xFF
			3:
				for i in row_bytes:
					var left := row[i - pixel] if i >= pixel else 0
					row[i] = (row[i] + ((left + previous[i]) >> 1)) & 0xFF
			4:
				for i in row_bytes:
					var a := row[i - pixel] if i >= pixel else 0
					var b := previous[i]
					var c := previous[i - pixel] if i >= pixel else 0
					var p := a + b - c
					var pa := absi(p - a)
					var pb := absi(p - b)
					var pc := absi(p - c)
					var predictor := a if pa <= pb and pa <= pc else (b if pb <= pc else c)
					row[i] = (row[i] + predictor) & 0xFF
		for x in width:
			values[y * width + x] = float((row[x * pixel] << 8) | row[x * pixel + 1]) / 65535.0
		previous = row
	return {"values": values, "width": width, "height": height, "metres": false}

static func _chunk(type: String, body: PackedByteArray) -> PackedByteArray:
	var typed := type.to_ascii_buffer()
	typed.append_array(body)
	var chunk := PackedByteArray()
	chunk.resize(4)
	chunk.encode_u32(0, _swap32(body.size()))
	chunk.append_array(typed)
	var crc := PackedByteArray()
	crc.resize(4)
	crc.encode_u32(0, _swap32(_crc32(typed)))
	chunk.append_array(crc)
	return chunk

static func _crc32(bytes: PackedByteArray) -> int:
	if _crc_table.is_empty():
		_crc_table.resize(256)
		for n in 256:
			var c := n
			for k in 8:
				c = (0xEDB88320 ^ (c >> 1)) if (c & 1) != 0 else (c >> 1)
			_crc_table[n] = c
	var crc := 0xFFFFFFFF
	for byte in bytes:
		crc = _crc_table[(crc ^ byte) & 0xFF] ^ (crc >> 8)
	return crc ^ 0xFFFFFFFF

## Big-endian <-> little-endian 32-bit (PNG numbers are big-endian).
static func _swap32(value: int) -> int:
	return ((value & 0xFF) << 24) | ((value & 0xFF00) << 8) | ((value >> 8) & 0xFF00) | ((value >> 24) & 0xFF)

static func _write_file(path: String, bytes: PackedByteArray) -> Error:
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return FileAccess.get_open_error()
	file.store_buffer(bytes)
	file.close()
	return OK
