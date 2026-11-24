@tool
extends RefCounted
## Per-cell paint styles (top/side colour, texture and tile size).
##
## Every terrain keeps a palette of unique style dictionaries in metadata and a
## PackedInt32Array that maps each cell to a palette index (-1 = unassigned).
## A style is captured into the palette when a cell becomes painted, so later
## brush changes never restyle existing cells.

const Meta = preload("../core/terrain_meta.gd")
const GridMath = preload("../core/grid_math.gd")

static func make_default_style() -> Dictionary:
	return {
		"top_color": Meta.DEFAULT_TOP_COLOR,
		"cliff_color": Meta.DEFAULT_CLIFF_COLOR,
		"top_texture": null,
		"cliff_texture": null,
		"top_tile_size": Meta.DEFAULT_TILE_SIZE,
		"cliff_tile_size": Meta.DEFAULT_TILE_SIZE,
		"signature": style_signature(Meta.DEFAULT_TOP_COLOR, Meta.DEFAULT_CLIFF_COLOR, null, null, Meta.DEFAULT_TILE_SIZE, Meta.DEFAULT_TILE_SIZE),
	}

static func style_signature(top_color: Color, cliff_color: Color, top_texture: Texture2D, cliff_texture: Texture2D, top_tile_size: float, cliff_tile_size: float) -> String:
	return "%s|%s|%s|%s|%.4f|%.4f" % [
		top_color.to_html(true),
		cliff_color.to_html(true),
		resource_identity(top_texture),
		resource_identity(cliff_texture),
		top_tile_size,
		cliff_tile_size,
	]

## `value` as a Texture2D: null when it is none or anything else (optional
## texture settings and old style fields may hold any value).
static func as_texture(value: Variant) -> Texture2D:
	if value is Texture2D:
		var texture: Texture2D = value
		return texture
	return null

## Albedo texture of a Material stored by an earlier build; null when the
## value is not a BaseMaterial3D (or has no texture).
static func _old_material_texture(value: Variant) -> Texture2D:
	if value is BaseMaterial3D:
		var material: BaseMaterial3D = value
		return material.albedo_texture
	return null

static func resource_identity(resource: Resource) -> String:
	if resource == null:
		return "none"
	if not resource.resource_path.is_empty():
		return resource.resource_path
	return "instance:%s" % resource.get_instance_id()

## Compatibility with an earlier build, which stored whole Materials. If a
## StandardMaterial3D had an albedo texture, preserve that texture automatically.
static func migrate_style_texture_fields(style: Dictionary) -> Dictionary:
	if not style.has("top_texture"):
		style["top_texture"] = _old_material_texture(style.get("top_material", null))
	if not style.has("cliff_texture"):
		style["cliff_texture"] = _old_material_texture(style.get("cliff_material", null))
	if not style.has("top_tile_size"):
		style["top_tile_size"] = Meta.DEFAULT_TILE_SIZE
	if not style.has("cliff_tile_size"):
		style["cliff_tile_size"] = Meta.DEFAULT_TILE_SIZE
	style.erase("top_material")
	style.erase("cliff_material")
	var top_color: Color = style.get("top_color", Meta.DEFAULT_TOP_COLOR)
	var cliff_color: Color = style.get("cliff_color", Meta.DEFAULT_CLIFF_COLOR)
	var top_tile_size: float = style.get("top_tile_size", Meta.DEFAULT_TILE_SIZE)
	var cliff_tile_size: float = style.get("cliff_tile_size", Meta.DEFAULT_TILE_SIZE)
	style["signature"] = style_signature(
		top_color,
		cliff_color,
		as_texture(style.get("top_texture", null)),
		as_texture(style.get("cliff_texture", null)),
		top_tile_size,
		cliff_tile_size
	)
	return style

## Ensures the palette exists and the cell style array matches the grid size.
static func ensure_material_data(terrain: Node3D) -> void:
	var resolution: int = terrain.get_meta(Meta.RESOLUTION, Meta.DEFAULT_RESOLUTION)
	var cell_count := (resolution - 1) * (resolution - 1)

	var palette: Array = terrain.get_meta(Meta.STYLE_PALETTE, [])
	if palette.is_empty():
		palette = [make_default_style()]
	else:
		for i in range(palette.size()):
			var style: Dictionary = palette[i]
			palette[i] = migrate_style_texture_fields(style)
	terrain.set_meta(Meta.STYLE_PALETTE, palette)

	var cell_styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES, PackedInt32Array())
	if cell_styles.size() != cell_count:
		cell_styles = PackedInt32Array()
		cell_styles.resize(cell_count)
		cell_styles.fill(-1)
		var mask: PackedFloat32Array = terrain.get_meta(Meta.MASK, PackedFloat32Array())
		if mask.size() == resolution * resolution:
			for z in range(resolution - 1):
				for x in range(resolution - 1):
					if GridMath.cell_active_for_mask(mask, x, z, resolution):
						cell_styles[GridMath.cell_index(x, z, resolution)] = 0
		terrain.set_meta(Meta.CELL_STYLES, cell_styles)

## Returns the palette index of an equivalent style, appending it if needed.
static func capture_style_definition(
	terrain: Node3D,
	top_color: Color,
	cliff_color: Color,
	top_texture: Texture2D,
	cliff_texture: Texture2D,
	top_tile_size: float,
	cliff_tile_size: float
) -> int:
	var signature := style_signature(top_color, cliff_color, top_texture, cliff_texture, top_tile_size, cliff_tile_size)
	var palette: Array = terrain.get_meta(Meta.STYLE_PALETTE, [])

	for i in range(palette.size()):
		var existing: Dictionary = palette[i]
		var existing_signature: String = existing.get("signature", "")
		if existing_signature == signature:
			return i

	var style := {
		"top_color": top_color,
		"cliff_color": cliff_color,
		"top_texture": top_texture,
		"cliff_texture": cliff_texture,
		"top_tile_size": top_tile_size,
		"cliff_tile_size": cliff_tile_size,
		"signature": signature,
	}
	palette.append(style)
	terrain.set_meta(Meta.STYLE_PALETTE, palette)
	return palette.size() - 1

## Captures the Custom Ground Style (brush settings) as a palette style.
static func capture_current_paint_style(terrain: Node3D) -> int:
	var top_color: Color = terrain.get_meta(Meta.BRUSH_TOP_COLOR, Meta.DEFAULT_TOP_COLOR)
	var cliff_color: Color = terrain.get_meta(Meta.BRUSH_CLIFF_COLOR, Meta.DEFAULT_CLIFF_COLOR)
	return capture_style_definition(
		terrain,
		top_color,
		cliff_color,
		as_texture(Meta.get_optional(terrain, Meta.BRUSH_TOP_TEXTURE)),
		as_texture(Meta.get_optional(terrain, Meta.BRUSH_CLIFF_TEXTURE)),
		maxf(Meta.get_float(terrain, Meta.BRUSH_TOP_TILE_SIZE, Meta.DEFAULT_TILE_SIZE), 0.001),
		maxf(Meta.get_float(terrain, Meta.BRUSH_CLIFF_TILE_SIZE, Meta.DEFAULT_TILE_SIZE), 0.001)
	)

## Assigns the current paint style to the given cells.
static func assign_paint_style_to_cells(terrain: Node3D, indices: PackedInt32Array) -> void:
	if indices.is_empty():
		return

	ensure_material_data(terrain)
	var cell_styles: PackedInt32Array = terrain.get_meta(Meta.CELL_STYLES, PackedInt32Array())
	if cell_styles.is_empty():
		return

	var style_id: int = capture_current_paint_style(terrain)
	for index in indices:
		if index >= 0 and index < cell_styles.size():
			cell_styles[index] = style_id
	terrain.set_meta(Meta.CELL_STYLES, cell_styles)

# -----------------------------------------------------------------------------
# Pixel-map generator styles (one per GREEN / RED / BLUE class)
# -----------------------------------------------------------------------------

static func generator_style_keys(prefix: String) -> Dictionary[String, String]:
	return {
		"top_color": Meta.generator_style_key(prefix, "top_color"),
		"cliff_color": Meta.generator_style_key(prefix, "cliff_color"),
		"top_texture": Meta.generator_style_key(prefix, "top_texture"),
		"cliff_texture": Meta.generator_style_key(prefix, "cliff_texture"),
		"top_tile_size": Meta.generator_style_key(prefix, "top_tile_size"),
		"cliff_tile_size": Meta.generator_style_key(prefix, "cliff_tile_size"),
	}

## Seeds missing generator styles from the current brush settings.
static func ensure_generator_style_defaults(terrain: Node3D) -> void:
	var current_top_color: Color = terrain.get_meta(Meta.BRUSH_TOP_COLOR, Meta.DEFAULT_TOP_COLOR)
	var current_cliff_color: Color = terrain.get_meta(Meta.BRUSH_CLIFF_COLOR, Meta.DEFAULT_CLIFF_COLOR)
	var current_top_texture := as_texture(Meta.get_optional(terrain, Meta.BRUSH_TOP_TEXTURE))
	var current_cliff_texture := as_texture(Meta.get_optional(terrain, Meta.BRUSH_CLIFF_TEXTURE))
	var current_top_tile: float = Meta.get_float(terrain, Meta.BRUSH_TOP_TILE_SIZE, Meta.DEFAULT_TILE_SIZE)
	var current_cliff_tile: float = Meta.get_float(terrain, Meta.BRUSH_CLIFF_TILE_SIZE, Meta.DEFAULT_TILE_SIZE)

	for prefix: String in Meta.GENERATOR_PREFIXES:
		var keys := generator_style_keys(prefix)
		if not terrain.has_meta(keys["top_color"]): terrain.set_meta(keys["top_color"], current_top_color)
		if not terrain.has_meta(keys["cliff_color"]): terrain.set_meta(keys["cliff_color"], current_cliff_color)
		if not terrain.has_meta(keys["top_texture"]) and current_top_texture != null: terrain.set_meta(keys["top_texture"], current_top_texture)
		if not terrain.has_meta(keys["cliff_texture"]) and current_cliff_texture != null: terrain.set_meta(keys["cliff_texture"], current_cliff_texture)
		if not terrain.has_meta(keys["top_tile_size"]): terrain.set_meta(keys["top_tile_size"], current_top_tile)
		if not terrain.has_meta(keys["cliff_tile_size"]): terrain.set_meta(keys["cliff_tile_size"], current_cliff_tile)

## Overwrites every generator style with the current brush settings.
static func copy_current_paint_to_generator_styles(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return

	var top_color: Color = terrain.get_meta(Meta.BRUSH_TOP_COLOR, Meta.DEFAULT_TOP_COLOR)
	var cliff_color: Color = terrain.get_meta(Meta.BRUSH_CLIFF_COLOR, Meta.DEFAULT_CLIFF_COLOR)
	var top_texture := as_texture(Meta.get_optional(terrain, Meta.BRUSH_TOP_TEXTURE))
	var cliff_texture := as_texture(Meta.get_optional(terrain, Meta.BRUSH_CLIFF_TEXTURE))
	var top_tile: float = Meta.get_float(terrain, Meta.BRUSH_TOP_TILE_SIZE, Meta.DEFAULT_TILE_SIZE)
	var cliff_tile: float = Meta.get_float(terrain, Meta.BRUSH_CLIFF_TILE_SIZE, Meta.DEFAULT_TILE_SIZE)

	for prefix: String in Meta.GENERATOR_PREFIXES:
		var keys := generator_style_keys(prefix)
		terrain.set_meta(keys["top_color"], top_color)
		terrain.set_meta(keys["cliff_color"], cliff_color)
		Meta.set_optional(terrain, keys["top_texture"], top_texture)
		Meta.set_optional(terrain, keys["cliff_texture"], cliff_texture)
		terrain.set_meta(keys["top_tile_size"], top_tile)
		terrain.set_meta(keys["cliff_tile_size"], cliff_tile)

	terrain.notify_property_list_changed()

static func capture_generator_style(terrain: Node3D, prefix: String) -> int:
	var keys := generator_style_keys(prefix)
	var top_color: Color = terrain.get_meta(keys["top_color"], Meta.DEFAULT_TOP_COLOR)
	var cliff_color: Color = terrain.get_meta(keys["cliff_color"], Meta.DEFAULT_CLIFF_COLOR)
	return capture_style_definition(
		terrain,
		top_color,
		cliff_color,
		as_texture(Meta.get_optional(terrain, keys["top_texture"])),
		as_texture(Meta.get_optional(terrain, keys["cliff_texture"])),
		maxf(Meta.get_float(terrain, keys["top_tile_size"], Meta.DEFAULT_TILE_SIZE), 0.001),
		maxf(Meta.get_float(terrain, keys["cliff_tile_size"], Meta.DEFAULT_TILE_SIZE), 0.001)
	)
