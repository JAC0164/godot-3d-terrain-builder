@tool
class_name LowpolyDetailLayer
extends Resource
## One kind of scattered detail in a biome (grass tufts, rocks, shrubs,
## skulls, trees...): which mesh, how many, where, and how it looks.
##
## Every chunk draws each layer with ONE MultiMesh (one draw call per visible
## chunk). Placement only depends on global cell coordinates, the layer name
## and its seed, so it is stable across rebuilds.

const _ModelMesh = preload("../mesh/model_mesh.gd")
const _DetailMeshes = preload("../mesh/detail_meshes.gd")

enum GroundFilter {
	ANY,       ## Every untextured ground.
	GREENISH,  ## Ground whose colour is green-dominant (grass).
	COLOR,     ## Ground close to `filter_color`.
	STYLES,    ## Cells painted with one of `filter_styles` (palette indices).
}
## Where the layer may grow relative to dried waterholes (see
## styles/waterhole_style.gd): the basin is the depression, the rim the ring
## of trampled clay around it.
enum WaterholeZone {
	ANYWHERE,
	OUTSIDE_BASIN,  ## Everywhere except inside the basins (default).
	RIM_ONLY,       ## Only on the rims: skulls, dead trees, reeds...
	BASIN_ONLY,     ## Only inside the basins, on the cracked mud.
	AWAY,           ## Neither in a basin nor on a rim.
}

## Whether the Vegetation brush (more / fewer / none, painted on the terrain)
## changes this layer's density.
enum VegetationBrush {
	AUTO,    ## Plants follow it (grass, shrubs, trees, custom meshes); rocks, pebbles, mounds and bones do not.
	FOLLOW,  ## Always follows it.
	IGNORE,  ## Never: the brush does not change this layer.
}

enum ColorMode {
	GROUND,  ## Baked ground colour under the instance x tint.
	SIDE,    ## The ground style's side colour (rocks), x tint.
	FIXED,   ## `tint` only.
}

@export var name := "Detail":
	set(value):
		name = value
		emit_changed()
@export var enabled := true:
	set(value):
		enabled = value
		emit_changed()
## Changes the random placement without changing the rules.
@export var placement_seed := 0:
	set(value):
		placement_seed = value
		emit_changed()

@export_group("Mesh")
## Your own 3D model: drag a .glb, .gltf, .blend, .fbx or .tscn here. Its size
## is in metres, it stands on its bottom (see Keep Model Origin) and keeps its
## own materials and textures. Takes over Mesh and Builtin Mesh.
@export var model: PackedScene:
	set(value):
		model = value
		emit_changed()
## Place the model by its own origin instead of standing it on the bottom
## centre of its bounding box (e.g. roots modelled below the origin).
@export var model_keep_origin := false:
	set(value):
		model_keep_origin = value
		emit_changed()
## Built-in low-poly mesh used when `mesh` is empty (see DetailMeshes).
@export_enum("None", "Grass Tuft", "Rock", "Dry Grass Tuft", "Pebbles", "Shrub", "Acacia", "Baobab", "Termite Mound", "Zebu Skull", "Dead Tree") var builtin_mesh := 1:
	set(value):
		builtin_mesh = value
		emit_changed()
## Your own mesh (a Mesh resource). Its size is in cell units (1 = one
## terrain cell). For a .glb / .blend / .fbx file, use Model instead.
@export var mesh: Mesh:
	set(value):
		mesh = value
		emit_changed()
## Keep the materials of `mesh` instead of the plugin's vertex-colour material
## (instance colours then only apply if your material uses vertex colour).
@export var use_mesh_materials := false:
	set(value):
		use_mesh_materials = value
		emit_changed()

@export_group("Amount")
## Average instances per cell where every rule fully passes.
@export_range(0.0, 8.0, 0.01) var density := 0.5:
	set(value):
		density = value
		emit_changed()
## Size, in cells, of the patches the layer groups into (0 = even spread).
@export_range(0.0, 256.0, 0.5) var clump_size := 0.0:
	set(value):
		clump_size = value
		emit_changed()
## Share of the ground covered by patches when clumping (0..1).
@export_range(0.0, 1.0, 0.01) var clump_coverage := 0.5:
	set(value):
		clump_coverage = value
		emit_changed()

@export_group("Placement Rules")
@export_range(0.0, 90.0, 0.5) var slope_min := 0.0:
	set(value):
		slope_min = value
		emit_changed()
@export_range(0.0, 90.0, 0.5) var slope_max := 90.0:
	set(value):
		slope_max = value
		emit_changed()
## Degrees over which the layer fades in after slope_min / out before slope_max.
@export_range(0.0, 45.0, 0.5) var slope_fade := 5.0:
	set(value):
		slope_fade = value
		emit_changed()
## Terrain height range (local units) where the layer grows.
@export var height_min := -1000.0:
	set(value):
		height_min = value
		emit_changed()
@export var height_max := 1000.0:
	set(value):
		height_max = value
		emit_changed()
@export var ground_filter := GroundFilter.ANY:
	set(value):
		ground_filter = value
		emit_changed()
@export var filter_color := Color(0.44, 0.69, 0.20):
	set(value):
		filter_color = value
		emit_changed()
## Colour distance (0..1.7) still accepted by the COLOR filter.
@export_range(0.0, 1.0, 0.01) var filter_tolerance := 0.2:
	set(value):
		filter_tolerance = value
		emit_changed()
## Style palette indices accepted by the STYLES filter.
@export var filter_styles := PackedInt32Array():
	set(value):
		filter_styles = value
		emit_changed()
## Skip cells whose top style is textured (their colour is unknown).
@export var skip_textured := true:
	set(value):
		skip_textured = value
		emit_changed()
@export var avoid_roads := true:
	set(value):
		avoid_roads = value
		emit_changed()
@export var avoid_rivers := true:
	set(value):
		avoid_rivers = value
		emit_changed()
@export var waterhole_zone := WaterholeZone.OUTSIDE_BASIN:
	set(value):
		waterhole_zone = value
		emit_changed()

@export_group("Shape")
## Uniform size range, in cells.
@export_range(0.01, 20.0, 0.01) var scale_min := 0.75:
	set(value):
		scale_min = value
		emit_changed()
@export_range(0.01, 20.0, 0.01) var scale_max := 1.25:
	set(value):
		scale_max = value
		emit_changed()
## Vertical stretch range applied on top of the size.
@export_range(0.05, 4.0, 0.01) var height_scale_min := 0.8:
	set(value):
		height_scale_min = value
		emit_changed()
@export_range(0.05, 4.0, 0.01) var height_scale_max := 1.2:
	set(value):
		height_scale_max = value
		emit_changed()
## Random extra width along one axis (1 = none).
@export_range(1.0, 3.0, 0.01) var stretch_max := 1.0:
	set(value):
		stretch_max = value
		emit_changed()
@export_range(0.0, 45.0, 0.5) var max_tilt := 0.0:
	set(value):
		max_tilt = value
		emit_changed()

@export_group("Color")
@export var color_mode := ColorMode.GROUND:
	set(value):
		color_mode = value
		emit_changed()
@export var tint := Color.WHITE:
	set(value):
		tint = value
		emit_changed()
@export_range(0.0, 3.0, 0.01) var brightness := 1.0:
	set(value):
		brightness = value
		emit_changed()
## Random brightness change per instance (+/-).
@export_range(0.0, 0.5, 0.01) var brightness_jitter := 0.08:
	set(value):
		brightness_jitter = value
		emit_changed()
## Moves the colour toward grey (0..1) before tinting.
@export_range(0.0, 1.0, 0.01) var desaturate := 0.0:
	set(value):
		desaturate = value
		emit_changed()
## Moves the colour toward white (0..1) after desaturating.
@export_range(0.0, 1.0, 0.01) var lighten := 0.0:
	set(value):
		lighten = value
		emit_changed()

@export_group("Rendering")
## Hide this layer beyond this camera distance. -1 = terrain Draw Distance,
## 0 = always drawn.
@export var draw_distance := -1.0:
	set(value):
		draw_distance = value
		emit_changed()
@export var cast_shadows := false:
	set(value):
		cast_shadows = value
		emit_changed()

@export_group("Collision")
## Radius of a cylinder blocking the player (trunk, mound), as a fraction of
## the instance width. 0 = no collision. Built when the game starts
## (LowpolyTerrainRuntime), not in the editor.
@export_range(0.0, 1.0, 0.005) var collision_radius := 0.0:
	set(value):
		collision_radius = value
		emit_changed()
## Height of that cylinder, as a fraction of the instance height.
@export_range(0.0, 2.0, 0.01) var collision_height := 0.6:
	set(value):
		collision_height = value
		emit_changed()

@export_group("Advanced")
# Rarely changed: density boosts, brush behaviour, fine placement and shape.
## Extra density on steep ground (x (1 + bonus x steepness)).
@export_range(0.0, 20.0, 0.1) var steep_bonus := 0.0:
	set(value):
		steep_bonus = value
		emit_changed()
## Extra density on cells along a cliff edge.
@export_range(0.0, 20.0, 0.1) var edge_bonus := 0.0:
	set(value):
		edge_bonus = value
		emit_changed()
## Whether the Vegetation brush, painting "All plants", changes this layer:
## Auto = plants (grass, shrubs, trees, custom meshes) follow it, rocks and
## bones do not. Picking this layer in the brush list always paints it.
## Painted cells go from none (Ctrl) to x4 (dense layers like grass) .. x25
## (sparse layers like trees), with clumps filled in.
@export var vegetation_brush := VegetationBrush.AUTO:
	set(value):
		vegetation_brush = value
		emit_changed()
## Painted thicker with the Vegetation brush, this layer may also grow on
## other ground, on slopes up to 12 degrees steeper and at any height (rim /
## basin-only layers anywhere when this layer is picked in the brush list).
## Roads, rivers, waterhole basins and cliffs stay free. Off = only denser
## where it already grows.
@export var paint_relaxes_rules := true:
	set(value):
		paint_relaxes_rules = value
		emit_changed()
## Painted thicker with the Vegetation brush, instances of this layer stay
## this far apart, in widths of the instance (its mesh at its mean size):
## 0.85 = crowns of a painted forest barely touch, 0 = they may overlap.
## Only for sparse layers (trees, props); the biome's own placement is
## not changed.
@export_range(0.0, 2.0, 0.05) var paint_spacing := 0.85:
	set(value):
		paint_spacing = value
		emit_changed()
## Keeps instances away from the cell border (0..0.45), e.g. for big props.
@export_range(0.0, 0.45, 0.01) var cell_margin := 0.0:
	set(value):
		cell_margin = value
		emit_changed()
## > 1 makes small instances more common than big ones.
@export_range(0.25, 4.0, 0.05) var small_bias := 1.0:
	set(value):
		small_bias = value
		emit_changed()
## Pushes instances into the ground by this fraction of their size.
@export_range(0.0, 1.0, 0.01) var sink := 0.0:
	set(value):
		sink = value
		emit_changed()

## Mesh this layer scatters: Model, else Mesh, else the built-in one.
func resolved_mesh() -> Mesh:
	if model != null:
		var merged: Mesh = _ModelMesh.mesh_of(model, model_keep_origin)
		if merged != null:
			return merged
	if mesh != null:
		return mesh
	return _DetailMeshes.builtin(builtin_mesh)

## Your own model or mesh (not a built-in one).
func is_custom() -> bool:
	return model != null or mesh != null

## Drawn with its own materials (a Model always, a Mesh if asked).
func keeps_own_materials() -> bool:
	return model != null or (mesh != null and use_mesh_materials)
