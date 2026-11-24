@tool
extends RefCounted
## Compact storage of the big terrain arrays in scene files.
##
## In memory the heights / mask / cell styles / active cells / vegetation paint stay plain
## metadata arrays (every module reads them directly). Only while a scene is
## saved, LowpolyTerrainRuntime (child of the terrain) packs them into one
## Zstandard block (PACKED_DATA) and empties the arrays; right after the save
## it puts them back. When a scene is loaded, the same node unpacks the block
## before anything reads the terrain (editor and game).
##
## A .tscn written as numbers in text was ~1 MB for a 256 map (Godot warns
## about large text scenes); packed it is a few tens of KB. Scenes saved
## before this (plain arrays, no block) still load as they are.

const Meta = preload("terrain_meta.gd")

## Metadata holding the packed block: {"format", "size", "zstd"}; an empty
## Dictionary in memory once unpacked.
const PACKED_DATA := "_lte_packed_data"
const FORMAT := 1
## Arrays moved into the block, in this order (keeps the bytes deterministic:
## the same terrain always gives the same block, so instanced terrain scenes
## are not seen as overridden by the scenes that use them).
const PACKED_KEYS: Array[String] = [Meta.MASK, Meta.HEIGHTS, Meta.CELL_STYLES, Meta.CELL_ACTIVE, Meta.CELL_VEGETATION]

static func is_packed(terrain: Object) -> bool:
	if not terrain.has_meta(PACKED_DATA):
		return false
	var packed: Variant = terrain.get_meta(PACKED_DATA)
	if not (packed is Dictionary):
		return false
	var packed_dict: Dictionary = packed
	return not packed_dict.is_empty()

## Moves the arrays into the packed block. Returns the arrays it replaced (to
## put back after the save without decoding), or {} when nothing was packed.
static func pack(terrain: Object) -> Dictionary:
	if not is_instance_valid(terrain) or not Meta.is_terrain(terrain) or is_packed(terrain):
		return {}
	var originals: Dictionary = {}
	for key in PACKED_KEYS:
		if terrain.has_meta(key) and _empty_like(terrain.get_meta(key)) != null:
			originals[key] = terrain.get_meta(key)
	if originals.is_empty():
		return {}
	var raw := var_to_bytes(originals)
	terrain.set_meta(PACKED_DATA, {
		"format": FORMAT,
		"size": raw.size(),
		"zstd": raw.compress(FileAccess.COMPRESSION_ZSTD),
	})
	for key: String in originals:
		var value: Variant = originals[key]
		# Same type, empty: replacing an existing value does not make the
		# Inspector rebuild its property list.
		terrain.set_meta(key, _empty_like(value))
	return originals

## Puts back the arrays `pack` returned (after the save).
static func restore(terrain: Object, originals: Dictionary) -> void:
	if not is_instance_valid(terrain) or originals.is_empty():
		return
	for key: String in originals:
		terrain.set_meta(key, originals[key])
	terrain.set_meta(PACKED_DATA, {})

## Decodes the packed block of a loaded scene into the arrays. No-op when the
## terrain is not packed. Returns false when the block is unreadable.
static func unpack(terrain: Object) -> bool:
	if not is_instance_valid(terrain) or not is_packed(terrain):
		return true
	var packed: Dictionary = terrain.get_meta(PACKED_DATA)
	var format: int = packed.get("format", 0)
	if format != FORMAT or not (packed.get("zstd") is PackedByteArray):
		push_error("Lowpoly Terrain: unknown packed terrain data format on %s (saved by a newer plugin?)." % terrain)
		return false
	var zstd: PackedByteArray = packed["zstd"]
	var size: int = packed.get("size", 0)
	var raw: PackedByteArray = zstd.decompress(size, FileAccess.COMPRESSION_ZSTD)
	var values: Variant = bytes_to_var(raw)
	if not (values is Dictionary):
		push_error("Lowpoly Terrain: packed terrain data of %s is damaged." % terrain)
		return false
	var values_dict: Dictionary = values
	for key: String in values_dict:
		terrain.set_meta(key, values_dict[key])
	terrain.set_meta(PACKED_DATA, {})
	return true

static func _empty_like(value: Variant) -> Variant:
	match typeof(value):
		TYPE_PACKED_FLOAT32_ARRAY: return PackedFloat32Array()
		TYPE_PACKED_INT32_ARRAY: return PackedInt32Array()
		TYPE_PACKED_BYTE_ARRAY: return PackedByteArray()
		TYPE_PACKED_FLOAT64_ARRAY: return PackedFloat64Array()
		TYPE_PACKED_INT64_ARRAY: return PackedInt64Array()
		TYPE_ARRAY: return []
		TYPE_DICTIONARY: return {}
	return null
