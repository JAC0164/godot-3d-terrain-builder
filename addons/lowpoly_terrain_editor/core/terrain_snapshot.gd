@tool
extends RefCounted
## Undo/redo snapshots of the editable terrain data.
##
## A snapshot is a deep copy of the metadata a stroke can change. Restoring one
## only writes metadata; the caller is responsible for regenerating meshes.
## The Undo history keeps delta_pair()s: what changed only.

const Meta = preload("terrain_meta.gd")
const StylePalette = preload("../styles/style_palette.gd")

static func capture(terrain: Node3D) -> Dictionary:
	StylePalette.ensure_material_data(terrain)
	var mask: PackedFloat32Array = terrain.get_meta(Meta.MASK)
	var heights: PackedFloat32Array = terrain.get_meta(Meta.HEIGHTS)
	var roads: Array = terrain.get_meta(Meta.ROADS, [])
	var rivers: Array = terrain.get_meta(Meta.RIVERS, [])
	var waterholes: Array = terrain.get_meta(Meta.WATERHOLES, [])
	var cell_styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES)
	var cell_active: PackedByteArray = terrain.get_meta(Meta.CELL_ACTIVE, PackedByteArray())
	var style_palette: Array = terrain.get_meta(Meta.STYLE_PALETTE, [])
	return {
		"resolution": Meta.get_int(terrain, Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION),
		"world_size": Meta.get_float(terrain, Meta.WORLD_SIZE, Meta.DEFAULT_WORLD_SIZE),
		"mask": mask.duplicate(),
		"heights": heights.duplicate(),
		"roads": roads.duplicate(true),
		"rivers": rivers.duplicate(true),
		"waterholes": waterholes.duplicate(true),
		"cell_styles": cell_styles.duplicate(),
		"cell_active": cell_active.duplicate(),
		"cell_vegetation": Meta.vegetation_paint(terrain).duplicate(true),
		"style_palette": style_palette.duplicate(true),
	}

## Grid arrays: vertex arrays (resolution^2) and cell arrays ((resolution-1)^2).
const VERTEX_KEYS: Array[String] = ["mask", "heights"]
const CELL_KEYS: Array[String] = ["cell_styles", "cell_active"]
## The rest: copied whole into a delta, only when they changed.
const OTHER_KEYS: Array[String] = ["roads", "rivers", "waterholes", "cell_vegetation", "style_palette"]

## The Undo / Redo pair of an edit, small: [before, after] deltas holding
## only the rectangle of the grids that changed (one for the vertex arrays,
## one for the cell arrays, as raw bytes) and the other entries that changed.
## [] when the grid size changed (use the full snapshots then).
## A stroke on a 1025 x 1025 map keeps a few KB instead of ~2 x 13 MB.
static func delta_pair(before: Dictionary, after: Dictionary) -> Array[Dictionary]:
	var resolution: int = before.get("resolution", -1)
	var after_resolution: int = after.get("resolution", -2)
	var world_size: float = before.get("world_size", -1.0)
	var after_world_size: float = after.get("world_size", -2.0)
	if resolution < 2 or after_resolution != resolution or not is_equal_approx(world_size, after_world_size):
		return []
	var old := {"delta": true, "resolution": resolution, "world_size": world_size}
	var new := old.duplicate()
	for keys: Array[String] in [VERTEX_KEYS, CELL_KEYS]:
		var width := resolution if keys == VERTEX_KEYS else resolution - 1
		var rect := Rect2i()
		var grids := {}
		for key in keys:
			var a := _bytes(before.get(key))
			var b := _bytes(after.get(key))
			var element := _element_size(before.get(key))
			if element == 0 or element != _element_size(after.get(key)) or a.size() != b.size() or (a.size() != 0 and a.size() != width * width * element):
				return []
			grids[key] = [a, b, element]
			var changed := _changed_rect(a, b, width, element)
			if changed.has_area():
				rect = changed if not rect.has_area() else rect.merge(changed)
		if not rect.has_area():
			continue
		var rect_key := "vertex_rect" if keys == VERTEX_KEYS else "cell_rect"
		old[rect_key] = rect
		new[rect_key] = rect
		for key in keys:
			var entry: Array = grids[key]
			var a: PackedByteArray = entry[0]
			var b: PackedByteArray = entry[1]
			var element: int = entry[2]
			if not a.is_empty():
				old[key] = _block(a, width, element, rect)
				new[key] = _block(b, width, element, rect)
	for key in OTHER_KEYS:
		if before.get(key) != after.get(key):
			old[key] = before.get(key)
			new[key] = after.get(key)
	return [old, new]

## Raw bytes of a grid array (empty for anything else).
static func _bytes(grid: Variant) -> PackedByteArray:
	if grid is PackedFloat32Array:
		var floats: PackedFloat32Array = grid
		return floats.to_byte_array()
	if grid is PackedInt32Array:
		var ints: PackedInt32Array = grid
		return ints.to_byte_array()
	if grid is PackedByteArray:
		return grid
	return PackedByteArray()

## Bytes per entry of a grid array, 0 for anything else.
static func _element_size(grid: Variant) -> int:
	if grid is PackedFloat32Array or grid is PackedInt32Array:
		return 4
	return 1 if grid is PackedByteArray else 0

## `bytes` back into the array type of `like`.
static func _from_bytes(bytes: PackedByteArray, like: Variant) -> Variant:
	if like is PackedFloat32Array:
		return bytes.to_float32_array()
	if like is PackedInt32Array:
		return bytes.to_int32_array()
	return bytes

## Bounding rectangle (grid x / z, size in entries) of the entries that differ
## between two grids `width` entries wide; empty when equal. Rows compare
## natively; only changed rows are scanned for their first / last difference.
static func _changed_rect(a: PackedByteArray, b: PackedByteArray, width: int, element: int) -> Rect2i:
	if a == b:
		return Rect2i()
	var row_bytes := width * element
	var min_x := row_bytes
	var max_x := -1
	var min_z := -1
	var max_z := -1
	for z in width:
		var start := z * row_bytes
		if a.slice(start, start + row_bytes) == b.slice(start, start + row_bytes):
			continue
		if min_z < 0:
			min_z = z
		max_z = z
		var left := 0
		while left < min_x and a[start + left] == b[start + left]:
			left += 1
		min_x = mini(min_x, left)
		var right := row_bytes - 1
		while right > max_x and a[start + right] == b[start + right]:
			right -= 1
		max_x = maxi(max_x, right)
	return Rect2i(min_x / element, min_z, max_x / element - min_x / element + 1, max_z - min_z + 1)

## The rows of `rect` of a grid, one after the other (bytes).
static func _block(grid: PackedByteArray, width: int, element: int, rect: Rect2i) -> PackedByteArray:
	var block := PackedByteArray()
	for z in range(rect.position.y, rect.end.y):
		var start := (z * width + rect.position.x) * element
		block.append_array(grid.slice(start, start + rect.size.x * element))
	return block

## Writes a delta's block back into the terrain's grid `meta_key`.
static func _write_block(terrain: Node3D, meta_key: StringName, block: PackedByteArray, width: int, rect: Rect2i) -> void:
	var grid: Variant = terrain.get_meta(meta_key)
	var element := _element_size(grid)
	var bytes := _bytes(grid)
	if element == 0 or bytes.size() != width * width * element:
		return
	var row_bytes := rect.size.x * element
	var result := PackedByteArray()
	var cursor := 0
	var read := 0
	for z in range(rect.position.y, rect.end.y):
		var start := (z * width + rect.position.x) * element
		result.append_array(bytes.slice(cursor, start))
		result.append_array(block.slice(read, read + row_bytes))
		read += row_bytes
		cursor = start + row_bytes
	result.append_array(bytes.slice(cursor))
	terrain.set_meta(meta_key, _from_bytes(result, grid))

const META_KEYS := {
	"mask": Meta.MASK, "heights": Meta.HEIGHTS, "cell_styles": Meta.CELL_STYLES, "cell_active": Meta.CELL_ACTIVE,
	"roads": Meta.ROADS, "rivers": Meta.RIVERS, "waterholes": Meta.WATERHOLES, "style_palette": Meta.STYLE_PALETTE,
}

## Restores a delta_pair() entry: only its rectangles and entries.
static func _apply_delta(terrain: Node3D, delta: Dictionary) -> void:
	var resolution: int = delta["resolution"]
	for rect_key: String in ["vertex_rect", "cell_rect"]:
		if not delta.has(rect_key):
			continue
		var rect: Rect2i = delta[rect_key]
		var width := resolution if rect_key == "vertex_rect" else resolution - 1
		for key in VERTEX_KEYS if rect_key == "vertex_rect" else CELL_KEYS:
			if delta.has(key):
				var meta_key: StringName = META_KEYS[key]
				var block: PackedByteArray = delta[key]
				_write_block(terrain, meta_key, block, width, rect)
	for key: String in ["roads", "rivers", "waterholes"]:
		if delta.has(key):
			var list: Array = delta[key]
			var meta_key: StringName = META_KEYS[key]
			terrain.set_meta(meta_key, list.duplicate(true))
	if delta.has("cell_vegetation"):
		var cell_vegetation: Dictionary = delta["cell_vegetation"]
		Meta.set_optional(terrain, Meta.CELL_VEGETATION, cell_vegetation.duplicate(true) if not cell_vegetation.is_empty() else null)
	if delta.has("style_palette"):
		var style_palette: Array = delta["style_palette"]
		terrain.set_meta(Meta.STYLE_PALETTE, style_palette.duplicate(true))
		StylePalette.sync_with_biome(terrain)

## Restores a snapshot: a full capture() or a delta_pair() entry.
static func apply(terrain: Node3D, snapshot: Dictionary) -> void:
	if snapshot.get("delta", false):
		_apply_delta(terrain, snapshot)
		return
	if snapshot.has("resolution"):
		var resolution: int = snapshot["resolution"]
		terrain.set_meta(Meta.RESOLUTION, resolution)
	if snapshot.has("world_size"):
		var world_size: float = snapshot["world_size"]
		terrain.set_meta(Meta.WORLD_SIZE, world_size)
	var mask: PackedFloat32Array = snapshot["mask"]
	terrain.set_meta(Meta.MASK, mask.duplicate())
	var heights: PackedFloat32Array = snapshot["heights"]
	terrain.set_meta(Meta.HEIGHTS, heights.duplicate())
	var roads: Array = snapshot["roads"]
	terrain.set_meta(Meta.ROADS, roads.duplicate(true))
	var rivers: Array = snapshot["rivers"]
	terrain.set_meta(Meta.RIVERS, rivers.duplicate(true))
	if snapshot.has("waterholes"):
		var waterholes: Array = snapshot["waterholes"]
		terrain.set_meta(Meta.WATERHOLES, waterholes.duplicate(true))
	if snapshot.has("cell_styles"):
		var cell_styles: PackedInt32Array = snapshot["cell_styles"]
		terrain.set_meta(Meta.CELL_STYLES, cell_styles.duplicate())
	if snapshot.has("cell_active"):
		var cell_active: PackedByteArray = snapshot["cell_active"]
		terrain.set_meta(Meta.CELL_ACTIVE, cell_active.duplicate())
	if snapshot.has("cell_vegetation"):
		var cell_vegetation: Dictionary = snapshot["cell_vegetation"]
		Meta.set_optional(terrain, Meta.CELL_VEGETATION, cell_vegetation.duplicate(true) if not cell_vegetation.is_empty() else null)
	if snapshot.has("style_palette"):
		var style_palette: Array = snapshot["style_palette"]
		terrain.set_meta(Meta.STYLE_PALETTE, style_palette.duplicate(true))
		# Styles edited in the biome since the snapshot: keep the biome's look.
		StylePalette.sync_with_biome(terrain)

static func equal(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return false
	return (
		a.get("resolution", Meta.DEFAULT_RESOLUTION) == b.get("resolution", Meta.DEFAULT_RESOLUTION)
		and a.get("world_size", Meta.DEFAULT_WORLD_SIZE) == b.get("world_size", Meta.DEFAULT_WORLD_SIZE)
		and a["mask"] == b["mask"]
		and a["heights"] == b["heights"]
		and a["roads"] == b["roads"]
		and a["rivers"] == b["rivers"]
		and a.get("waterholes", []) == b.get("waterholes", [])
		and a.get("cell_styles", PackedInt32Array()) == b.get("cell_styles", PackedInt32Array())
		and a.get("cell_active", PackedByteArray()) == b.get("cell_active", PackedByteArray())
		and a.get("cell_vegetation", {}) == b.get("cell_vegetation", {})
		and a.get("style_palette", []) == b.get("style_palette", [])
	)
