@tool
extends RefCounted
## Undo/redo snapshots of the editable terrain data.
##
## A snapshot is a deep copy of the metadata a stroke can change. Restoring one
## only writes metadata; the caller is responsible for regenerating meshes.

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

static func apply(terrain: Node3D, snapshot: Dictionary) -> void:
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
