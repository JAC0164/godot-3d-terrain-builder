extends SceneTree
## The biome is the terrain's theme: painted cells follow the biome ground
## style they were painted with (StylePalette.sync_with_biome), Custom styles
## stay as painted. Exit code 1 if a check fails.
##   godot --headless --path . --script res://tools/check_theme_live.gd

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const StylePalette = preload(ADDON + "styles/style_palette.gd")
const TerrainBiome = preload(ADDON + "biomes/terrain_biome.gd")
const TerrainBuilder = preload(ADDON + "mesh/terrain_builder.gd")
const TerrainSnapshot = preload(ADDON + "core/terrain_snapshot.gd")
const TestTerrain = preload("res://tools/test_terrain.gd")

var _failures := 0

func check(label: String, ok: bool) -> void:
	if not ok:
		_failures += 1
	print("%s  %s" % ["OK  " if ok else "FAIL", label])

func _entry(t: Node3D, linked: String) -> Dictionary:
	for style: Dictionary in t.get_meta(Meta.STYLE_PALETTE):
		if style.get("biome_style", "") == linked:
			return style
	return {}

func _initialize() -> void:
	var root := Node3D.new()
	get_root().add_child(root)
	var t := TestTerrain.savanna(root)
	var palette: Array = t.get_meta(Meta.STYLE_PALETTE)
	var linked := palette.filter(func(s: Dictionary) -> bool: return s.has("biome_style"))
	check("generated map: its styles are linked to the biome (%d of %d)" % [linked.size(), palette.size()], linked.size() > 0)
	check("Laterite linked", not _entry(t, "Laterite").is_empty())

	# A Custom style (not in the biome) stays as painted.
	var custom_color := Color(0.1, 0.9, 0.9)
	var custom_id := StylePalette.capture_style_definition(t, custom_color, Color.BLACK, null, null, 4.0, 4.0)
	var custom: Dictionary = t.get_meta(Meta.STYLE_PALETTE)[custom_id]
	check("custom style not linked", not custom.has("biome_style"))

	# Edit Laterite in the terrain's own biome: its cells follow.
	var own: TerrainBiome = TerrainBiome.of(t).duplicate(true)
	t.set_meta(Meta.BIOME, own)
	var new_color := Color(0.2, 0.3, 0.9)
	for style in own.ground_styles:
		if style.name == "Laterite":
			style.top_color = new_color
	check("sync reports a change", StylePalette.sync_with_biome(t))
	var laterite := _entry(t, "Laterite")
	var laterite_color: Color = laterite.get("top_color", Color.BLACK)
	check("Laterite cells follow the biome color", laterite_color.is_equal_approx(new_color))
	var custom_after: Dictionary = t.get_meta(Meta.STYLE_PALETTE)[custom_id]
	var custom_after_color: Color = custom_after["top_color"]
	check("custom style unchanged", custom_after_color.is_equal_approx(custom_color))
	check("second sync: nothing to do", not StylePalette.sync_with_biome(t))

	# Undo to a palette from before the edit keeps the biome's look.
	var snapshot := TerrainSnapshot.capture(t)
	var old_palette: Array = snapshot["style_palette"]
	for style: Dictionary in old_palette:
		if style.get("biome_style", "") == "Laterite":
			style["top_color"] = Color.RED
	TerrainSnapshot.apply(t, snapshot)
	var undone: Color = _entry(t, "Laterite").get("top_color", Color.BLACK)
	check("restored snapshot re-synced", undone.is_equal_approx(new_color))

	# Another biome with a style of the same name takes over (theme swap).
	t.set_meta(Meta.BIOME, TerrainBiome.make_temperate())
	StylePalette.sync_with_biome(t)
	var sand: Color = _entry(t, "Sand").get("top_color", Color.BLACK)
	check("biome swap: Sand takes the new biome's Sand", sand.is_equal_approx(Color(0.83, 0.74, 0.52)))
	var kept: Color = _entry(t, "Laterite").get("top_color", Color.BLACK)
	check("biome swap: a name the new biome lacks keeps its look", kept.is_equal_approx(new_color))

	# Live in the editor: the biome look signature sees a style edit.
	var before := own.look_signature()
	own.ground_styles[0].side_color = Color(0.5, 0.5, 0.5)
	check("look signature follows ground styles", own.look_signature() != before)
	var macro_before := own.look_signature()
	own.macro_variation = 0.33
	check("look signature follows macro variation", own.look_signature() != macro_before)

	print("RESULT: %s (%d failure(s))" % ["OK" if _failures == 0 else "FAIL", _failures])
	quit(1 if _failures > 0 else 0)
