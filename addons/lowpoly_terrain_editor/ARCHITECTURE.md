# Lowpoly Terrain Editor — architecture

The terrain is a plain `Node3D` whose editable data lives in **metadata**
(`core/terrain_meta.gd` lists every key). Generated meshes and collision are
disposable children rebuilt from that data.

```
plugin.gd                 EditorPlugin: lifecycle, toolbar/inspector wiring,
                          viewport input, Undo/Redo,
                          "empty terrain" hint over the 3D view, editor
                          toasts when an action cannot run
core/
  terrain_meta.gd         metadata keys, node names, default values
  grid_math.gd            pure grid + 2D geometry helpers
  terrain_data.gd         create / migrate terrain data, cell queries
  terrain_sampler.gd      height sampling (base, uncarved, carved)
  terrain_snapshot.gd     undo snapshots: capture / apply / equal
  ground_bumps.gd         small bumps written in the heights (Look >
                          Ground Bumps): fixed noise x amount
  terrain_storage.gd      heights / mask / styles packed in one Zstandard
                          block while a scene is saved, unpacked on load
                          (plain arrays in memory)
biomes/                   user-facing Resources (the only class_name scripts)
  terrain_biome.gd        LowpolyTerrainBiome: ground styles, baked shading,
                          waterhole colors, detail layers; built-in
                          "Temperate" default; TerrainBiome.of(terrain)
  detail_layer.gd         LowpolyDetailLayer: mesh, density, placement rules,
                          shape, colour, draw distance of one detail kind
  ground_style.gd         LowpolyGroundStyle: one-click brush preset
  presets/*.tres          ready-made biomes (duplicate to customise)
styles/
  style_palette.gd        per-cell paint styles and generator styles
  feature_style.gd        road / river dictionaries (defaults, commit, preview)
  waterhole_style.gd      dried waterhole dictionaries + Shape (irregular
                          outline, carve profile, basin / rim zones)
editing/
  tool_mode.gd            tool enum, Ctrl / Shift variants, status hints
  brush.gd                paint / erase / sculpt / smooth on the data
  canvas.gd               grid expansion
  feature_eraser.gd       road / river hit-test and erase
  surface_ray.gd          mouse ray vs heightfield (march + bisection): the
                          brush lands on the relief under the cursor
  stroke_controller.gd    mouse stroke -> edits; chunk meshes refreshed once
                          per frame (flush), neighbours / collision after the
                          stroke (TerrainBuilder deferred jobs), Undo rebuilds
                          the stroke area only. Paint / Relief / Flatten /
                          Smooth shape the ground ONLY: the details stay as
                          they are (defer_chunk / rebuild_area "details":
                          false, rebuild_all_chunks(terrain, false) when the
                          canvas grows); Inspector > Look > Replace Details
                          (plugin.replace_details) re-scatters them on the
                          new ground. Erase still updates the details of the
                          chunks it touched (removed ground loses them;
                          placement is fixed per cell, nothing new appears),
                          Vegetation re-scatters live. Detail nodes are in
                          terrain space, so they stay put when chunk keys
                          change.
mesh/
  mesh_utils.gd           triangle winding, surfaces, UVs
  terrain_mesher.gd       ground chunk mesh (tops + cliffs)
  terrain_shading.gd      baked vertex-colour shading (style blend, slope, AO, lip);
                          per vertex with Smooth Ground (default), per face
                          otherwise (faceted look)
  detail_scatter.gd       biome detail layers as per-chunk MultiMeshes
  detail_collision.gd     trunk / mound cylinders read back from the detail
                          MultiMeshes (game only, shape owners, shared shapes)
  detail_meshes.gd        built-in low-poly detail meshes: tufts, stones and props
  model_mesh.gd           a layer's Model (.glb / .blend / .fbx / .tscn scene)
                          merged into one ArrayMesh (node transforms, one
                          surface per material, bottom centre at the origin),
                          cached per file; drawn with its own materials, size
                          in metres (`_compile` divides out the cell size)
                          (shrub, acacia, baobab, termite mound, zebu skull, dead
                          tree), flat-shaded ArrayMeshes built from:
  detail_mesh_data.gd     the prop shapes as plain data (vertices, triangles,
                          palette). Generated: modelled in Blender by
                          tools/blender/lte_props.py, converted by
                          tools/blender/glb_to_gdscript.py; do not edit by hand
  road_mesher.gd          road union surface (signed distance on the terrain's
                          own grid, each cell split along the terrain diagonal,
                          marching-triangles edges, heights from
                          TerrainSampler.surface_height_in: every road
                          triangle lies in one ground triangle, so the ground
                          never pokes through; tools/check_road_fit.gd)
  river_mesher.gd         river carve + water union
  feature_ribbon.gd       live stroke preview ribbon
  feature_mesher.gd       all roads + rivers in one mesh
  waterhole_mesher.gd     waterhole carve + cracked mud plates (Voronoi)
  terrain_builder.gd      writes meshes/collision into child nodes, caches
materials/
  material_factory.gd     terrain / road / water materials (terrain ones cached)
  river_water.gdshader    water shader (screen-space refraction)
  river_water_mobile.gdshader  same without refraction ("Mobile Water"; phones always, MaterialFactory.phone_water)
  detail_wind.gdshader    detail material + wind sway (shrub / tree profiles, back faces culled)
  detail_wind_two_sided.gdshader  same for grass, drawn from both sides
  detail_wind.gdshaderinc shared code of both (back faces keep the upward normal)
generation/
  image_generator.gd      pixel map -> terrain data
  map_recipe.gd           LowpolyMapRecipe: how to generate a whole map
  map_patch.gd            LowpolyMapPatch: ground patches of one style
  map_generator.gd        recipe + seed -> terrain data (outline, plateaus,
                          lowlands, relief, patches, tracks, waterholes)
  row_bands.gd            runs the generator's per-cell loops in parallel
                          bands of rows (WorkerThreadPool)
  map_paths.gd            AStarGrid2D paths on a coarse grid of the map
                          (rivers, track network), smoothing, meanders
  presets/*.tres          ready-made map recipes (savanna, temperate island)
  map_presets.gd          the presets list (Inspector "Map Preset") and the
                          default recipe of Generate Map (never a no-op)
runtime/
  terrain_runtime.gd      LowpolyTerrainRuntime: in-game build (generated map,
                          unsaved meshes / details, tree + ground collision),
                          spread over frames, nearest chunks first; optional
                          detail streaming around the camera; also
                          packs / unpacks the terrain data on save / load
                          (every terrain of the edited scene gets one)
ui/
  terrain_toolbar.gd      3D editor toolbar (signals only; "New Terrain"
                          with its name, then one row of 7 tool buttons with
                          tooltips, shown only with a terrain selected:
                          Ground + ground style list (biome styles + Custom),
                          Relief, Flatten, Road, River, Waterhole,
                          Vegetation + plant list; Erase / Lower / Smooth
                          stay ToolModes, reached by Ctrl / Shift
                          (button_mode() maps them to their button); Size
                          = road / river width for those tools, Strength off
                          when unused; Undo / Redo = Godot's Ctrl+Z)
  tool_icons.gd           toolbar icons (inline SVG, editor scale + theme)
  editor_camera_framer.gd frames the editor camera on a new map (no Godot
                          API: Focus Selection on a temporary marker + wheel
                          zoom steps; does nothing if the layout differs)
  brush_overlay.gd        brush ring drawn over the 3D viewport (per tool
                          colour / symbol / size; nothing added to the scene)
  terrain_inspector_plugin.gd  "LowPoly Terrain" Inspector panel: Map / Look /
                          Roads, Rivers & Waterholes / Game, then a closed
                          Advanced; explanations in tooltips, no paragraphs
```

## Rules of thumb

- Modules are loaded with `preload()` (no `class_name`, so nothing leaks into
  the user's global class list). Exceptions, the user-facing types: the
  `biomes/` Resources, `LowpolyMapRecipe` / `LowpolyMapPatch` and the
  `LowpolyTerrainRuntime` node carry a `Lowpoly*` `class_name` so users can
  create them from the Inspector; the plugin's own code still preloads them. Everything
  below `ui/` and `plugin.gd` is `static` and works on a bare `Node3D`,
  without the editor — that is what unit tests should target.
- Data modules (`core/`, `styles/`, `editing/` except the stroke controller,
  `generation/`) only read/write metadata. Meshers return `ArrayMesh` /
  dictionaries without touching the scene tree. Only `TerrainBuilder` creates
  child nodes.
- Draw calls: each chunk puts all untextured faces in one vertex-coloured
  surface with a shared material; only textured styles get extra surfaces.
  Terrain materials are shared through `MaterialFactory`'s cache, never
  duplicated per surface.
- Custom Materials (`Meta.GROUND_MATERIAL`, `Meta.DETAIL_MATERIAL`) are the
  one style hook: `MaterialFactory.terrain_vertex_color_material()` and
  `DetailScatter.layer_material(layer, terrain)` return them when set, and
  `TerrainBuilder.refresh_materials()` swaps them into built meshes without a
  rebuild (vertex-coloured surfaces = surfaces with `ARRAY_FORMAT_COLOR`; also
  run by the runtime node when a scene loads). The contract is the vertex
  colour (sRGB style colour x baked shading), so any look works without new
  mesh data. Look-specific materials stay in the game (examples in
  `test_project/world/looks/`).
- Visual detail on untextured styles is baked on the CPU into vertex colours
  by `TerrainShading` (zero runtime cost). Its colours must only depend on
  global grid data (checked by `test_project/tools/check_shading_seams.gd`);
  partial rebuilds widen their area by `TerrainShading.influence_margin()`.
  With every shading setting at 0 the mesher output is unchanged.
- Biomes are data, not code: the terrain stores a `LowpolyTerrainBiome` in
  `_lte_biome` (none = `TerrainBiome.default_biome()`). The biome is the
  only source of the look: `TerrainShading.settings()` reads its baked
  shading and `WaterholeStyle.shapes()` its waterhole colors (the terrain
  keeps only Smooth Ground, Flat Top Lighting and Double-Sided). A biome
  file is shared by every terrain using it; `copy_biome_to_terrain()`
  (Inspector "Copy Biome to This Terrain", undoable) stores a deep copy in
  the scene. Every biome property setter calls `emit_changed()` and the
  biome re-emits its layers' `changed`; the plugin watches the biome of the
  last selected terrain (even while the biome is open in the Inspector) and,
  250 ms after the last edit, calls `TerrainBuilder.rebuild_all()` when
  `look_signature()` changed (shading / waterhole colors) or
  `rebuild_all_details()` otherwise.
- Old scenes stored a copy of the biome's shading (`_lte_shade_*` except
  smooth), the waterhole colors (`_lte_waterhole_clay/crack_color`) and
  colors in each waterhole. `TerrainData.migrate_look()` (from
  `ensure_defaults`, editor and runtime) removes them; when they differ
  from the biome, the terrain first gets its own biome copy holding them
  (named "<biome> (<terrain>)"), so it looks the same. Smoke-tested.
- Out of scope, left to each game: lighting (sky, fog, sun) and what lies
  past the map border. They depend on the camera (FPS / top-down); the test
  project shows one way (`world/savanna_sky.tscn`, `world/map_horizon.gd`).
- Details (`DetailScatter`) are MultiMeshInstance3D children of each chunk,
  one per enabled biome layer (`_Details_<index>_<name>`; stale ones are
  removed): one draw call per layer and visible chunk, no cast shadows by
  default, culled by `visibility_range_end`. Built-in grass tufts are drawn with
  the two-sided grass material and one triangle per blade
  (`DetailMeshes.builtin(i, true)`, chosen in `DetailScatter._mesh_for`):
  half the triangles of the densest layers. With any other material (the
  terrain's Detail Material) they keep both windings. The road / river mesh
  and the waterhole plates cast no shadow (flat on the ground). The ground
  chunks cast shadows unless Game > Ground Casts Shadows is off
  (`Meta.GROUND_SHADOWS`): set on new chunks, and on existing ones by
  `TerrainBuilder.apply_ground_shadows()` (toggle, scene load) without a
  rebuild. Measured cost of the ground's shadows: ~0.75 ms GPU per frame at
  1080p on an Iris Xe with front faces (the mounds' self-shadow), ~0.15 ms
  with the back-face casters below; a game short of GPU time can still
  turn it off there.
  The ground's shadow comes from back faces: each chunk casts none and
  holds a shadow-only child `_GroundShadow` (`Meta.GROUND_SHADOW_NAME`,
  `TerrainBuilder._update_ground_caster`) whose mesh is the chunk's
  triangles with reversed winding, positions only, welded and indexed,
  10 cm under the ground (`MeshUtils.back_face_caster`). Only slopes turned
  away from the sun reach the shadow map, so the lit ground (most of the
  map) is no longer drawn there; mounds keep the same shadow, and the drop
  avoids speckles on faces edge-on to the sun. No sun direction is needed.
  A separate node, not `ArrayMesh.shadow_mesh`: Forward+ also uses the
  shadow mesh for its depth prepass, where reversed faces would vanish.
  Measured at 1080p on an Iris Xe: ~0.6 ms of the ~0.75 ms the ground's
  shadow cost (`tools/profile_terrain_gpu.gd --ab="front face shadows"`);
  ~1.3 ms per chunk to build. Scenes saved before get their casters in
  `apply_ground_shadows` (scene load). Checked by
  `test_project/tools/check_ground_shadow.gd`.
  Ground, road and detail materials are matte (`MaterialFactory._matte`, and
  `diffuse_lambert, specular_disabled` in the wind shaders): at roughness 1
  the specular term is invisible and Lambert looks the same as Burley, for
  less work on every pixel of the ground. Layers are flattened into typed
  `Rule` objects once per chunk; placement is a hash of global cell
  coordinates + layer name + seed, so rebuilding a chunk never moves the
  details of another. Checked by `test_project/tools/check_biomes.gd`.
- The scatter's per-cell x per-layer loop is the hot path. Keep it free of
  GDScript function calls: the cell's random draw comes first (sparse layers
  reject most cells before reading slope / colour / noise), clumping uses a
  native `FastNoiseLite`, and the per-instance code is inlined (one 64-bit
  hash remixed for extra bits).
- The Vegetation brush paints `_lte_cell_vegetation`, a Dictionary
  {target: PackedByteArray} (one byte per cell, 64 = biome density, 0 =
  none, 255 = x4 .. x25, see below; a target back to all 64 is removed). Target "" = "All
  plants", read by the layers whose `vegetation_brush` resolves to follow
  (Auto = plants and custom meshes); a layer name = that layer only (the
  toolbar list). Below 64 the expected count is scaled linearly; above, a
  boost 0..1 (both targets added) raises it to `Rule.max_paint`
  (`PAINTED_DENSITY / density`, clamped x4..x25: sparse layers get a real
  forest, grass stays x4), fills the gaps between clumps and, unless
  `paint_relaxes_rules` is off, relaxes the rules progressively: ground
  filter weight towards 1, slope limit up to +12 degrees (capped at 50),
  height range ignored, rim / basin-only zones lifted when that layer is the
  target. Roads, rivers, basins and textured ground stay excluded. Unpainted
  cells take none of these branches (placement identical). Checked by
  `test_project/tools/check_vegetation_paint.gd`. A stroke re-scatters the
  touched chunks' details only (no mesh, no collision); it is in the undo
  snapshot, the packed storage and `Canvas.expand`.
- Ground Bumps (`_lte_ground_bumps`, m, 0 = none for older scenes; 0.3 on
  new terrains). The ground's texture is left to the game (Ground Material;
  example: test_project/world/looks/ground_detail.gdshader, soil grain). The bumps are data: amount x a fixed
  FastNoiseLite of the local vertex position, added to `_lte_heights`, so
  collision, details, roads, rivers and waterholes follow with no special
  case. Changing the amount adds (new - old) x shape (painted relief stays,
  0 = the ground without bumps); `plugin.set_ground_bumps` is undoable
  (snapshot + meta, merged while dragging). `Canvas.expand` gives the new
  vertices the same bumps, Generate Map / Generate from Image add them to the
  new heights. Not in the tuning signature: the heights change, not a look.
- Details Everywhere (`_lte_details_everywhere`, Inspector > Advanced >
  Details). On (default, so scenes made before it are unchanged): the biome
  grows on every ground cell. Off (set by "New Terrain"): it grows only on
  the cells of target `#grow` (1 = grows), which Generate Map and Generate
  from Image write as their active cells (`Meta.generated_vegetation`;
  `Canvas.expand` fills new cells with 0). Every other cell is bare: the
  scatter skips it before any rule unless a brush target is above 64 there,
  and then the boost alone (`boost x max_paint`) makes the layer grow. Ground
  painted by hand therefore costs no detail work (savanna_128: 0.26 ms per
  chunk instead of 20, `test_project/tools/profile_bare_ground.gd`), and a
  generated map with it off is identical to it on.
- Sparse layers (painted density `density x max_paint` < 0.5 per cell:
  trees, props, rocks) are painted in blocks of `Rule.block` cells
  (round(1 / sqrt(painted density)), 2..8, aligned on the terrain grid):
  where the layer's boost is > 0, its biome instances stay (scaled as
  before, none on bare ground) and the block gets one more instance, on its
  most painted cell not too steep for the layer's full painted slope limit
  (`_block_candidate`, cached per build), with a chance from the block's top
  paint `b_all x 3 + b_layer x 18` (one click with the layer picked = sure,
  also at a cliff edge). That instance ignores the slope / ground fade and the
  patches once the rules allow the cell at all. Per-cell draws could only use
  1 cell in 40 for a baobab, so most clicks grew nothing
  (`test_project/tools/check_click_props.gd`: first click 1/30 -> 30/30,
  never 23/30 -> 0/30). Unpainted cells keep the per-cell draw (placement
  identical). One instance per block: a click next to an existing one (same
  block) adds none.
- Painted spacing: `Rule.min_gap` = `DetailLayer.paint_spacing` (0.85 by
  default) x the layer's width (mesh AABB x+z / 2 x mean scale, widened by
  half the stretch). The block is at least `min_gap` wide (up to 16 cells),
  so only the 8 neighbouring blocks can be too close: a block that grows its
  instance drops it if a neighbour of a higher fixed rank (`_block_rank`)
  grows one closer than `min_gap` (`_crowded`; same draws as the scatter loop,
  `_instance_spot`, `_block_grows`, so every chunk agrees). With a gap, the
  layer's biome instances in a painted area stay exactly as unpainted (rules
  not relaxed, no patch fill): relaxed ones were unspaced and landed next to
  the block instance. A block instance can still stand near a biome tree of
  the generated map (those are not spaced, as before). Savanna acacias:
  block 3 -> 6 cells, gap 5.9 m; the audit's painted forest 209 -> 128
  acacias, no crossed crowns; full-map detail rebuild +3..14 % (A/B
  medians 860 -> 894 ms, `test_project/tools/print_paint_blocks.gd`). Unpainted placement is
  unchanged.
- Dried waterholes are data only (`_lte_waterholes`): their depression is
  added to the carve array, their clay / crack colours (the biome's, shared
  by all waterholes of the terrain) are baked by TerrainShading (also when
  shading is off), their mud plates are one mesh
  per waterhole under `_GeneratedWaterholes`, and detail layers target them
  with `waterhole_zone`. Heights and cell styles are never written, so
  erasing a waterhole restores the terrain exactly. Checked by
  `test_project/tools/check_waterholes.gd`.
- Map generation (`MapGenerator.generate`) only writes terrain data, never
  nodes; the same recipe + seed gives the same data (checked by
  `test_project/tools/check_maps.gd`). Noise fields come from one native
  `FastNoiseLite.get_image()` call each and are thresholded by percentile so
  a coverage setting is the real share of cells. The fields are made in
  parallel, and every per-cell loop runs in bands of 64 rows on
  WorkerThreadPool (`RowBands`, high priority: low priority tasks only get a
  share of the threads); each band returns its own arrays, joined in row
  order, so the data is the same to the bit (smoothing: a band reads
  ceil(smoothness) rows more on each side, where the factor reaches 1).
  1 024 x 1 024 cells: 4.6 s -> 0.8 s on 8 cores
  (`test_project/tools/profile_generator.gd`; fingerprints of 12 maps in
  `tools/hash_generator.gd` / `results/big_world/generator_baseline.txt`).
  `MapGenerator.start()` / `step()` make the map in 6 steps: the plugin runs
  one a frame with a progress bar in the toolbar (no stroke meanwhile), and
  shows the loading of a streamed big terrain the same way.
- Open-world recipe options (all off by default: the older presets give the
  same data to the bit): `border` (hills or two-step cliffs over
  `border_width` cells at the square edge, added to the cell heights, its
  own style; an obstacle for waterholes), `river_count` (the first river
  crosses the map, the others are tributaries joining it; planned before
  the border, which opens a valley where they leave the map; committed as
  ordinary rivers, so the usual carve applies) and `track_network` (waterholes
  first, then tracks joining `track_count` map exits and the
  `track_network_stops` most spread out waterholes as a minimum spanning
  tree). Paths: AStarGrid2D on ~256 x 256 nodes (`MapPaths.step_for`), node
  weights from height (rivers) or slope + plateaus + rivers + waterholes
  (tracks), a large noise and a fixed per-node jitter (else paths follow the
  grid's axes), then Chaikin smoothing, sine meanders (`MapPaths.wobble`)
  and points every 2 cells. Rivers and tracks have their own random
  sequences. Checked by `check_maps.gd` (open-world section); look at a
  recipe with `tools/render_map_overview.gd` (top view) and
  `tools/render_open_world.gd` (3D). It also sets
  `_lte_detail_seed`, which is added to every layer's placement seed (0 =
  placement unchanged).
- What a scene file stores is decided by `_lte_runtime_build`
  (`Meta.RUNTIME_BUILD_*`): generated nodes are always added through
  `TerrainBuilder._add_generated_child()`, which only gives them an owner when
  that kind of node is saved; `apply_ownership()` fixes owners after the
  setting changes. `LowpolyTerrainRuntime` (child `_LowpolyTerrainRuntime`,
  auto-added by the plugin when needed) rebuilds the rest: in the editor
  synchronously when the scene opens, in game as a queue of small steps
  (one chunk / one waterhole / one ground collision shape per step) run
  within `frame_budget_ms` per frame (`ready_budget_ms`, 25 ms, until
  `terrain_ready`: the player is not in yet), emitting `terrain_ready` once
  ground and ground collision exist, then `finished`. A step returning `false` is not
  finished and runs again next frame: the road / river mesh is built that way
  in slices of the frame budget (`FeatureMesher.start / step / finish`, over
  `RoadMesher.union_begin / union_step` and `RiverMesher.water_begin /
  water_step`; `build()` is the same code in one go, so the mesh is identical
  however it is sliced, `test_project/tools/hash_feature_mesh.gd [--sliced]`).
  With stream_ground (big maps) each road / river group is computed on a
  worker thread instead, all at once, once the ground near the start is
  built (`FeatureMesher.start_threaded`, on `TerrainMesher.thread_snapshot`s;
  the geometry turned into packed arrays on the worker too); `step` then
  adds the finished groups' surfaces in order, so the mesh is the same
  (`hash_feature_mesh.gd --threaded --open-world`). 1.5 km open world on a
  laptop: 680 ms instead of 1.05-1.27 s; each big surface still costs
  100-165 ms on the main thread (its upload).
  In game (not the editor's camera streaming) the job is `split`: each
  group's triangles are also cut on the worker by the ground chunk under
  their centre, so there is no single mesh: each built chunk gets a child
  `_Roads` (TerrainRuntime.ROADS_NAME, no shadow) with its pieces, one
  upload per step within the budget, freed with its chunk; the road / river
  collision faces join that chunk's own shape (chunks built before the job
  finished get their shape made again). Same triangles, same collision
  (`test_project/tools/check_feature_split.gd`). 1.5 km open world: 222
  pieces in 213 chunks; walking draws 220 k triangles instead of 350 k
  (GPU 3.2 ms instead of 4.4 ms on the laptop), no 100-165 ms upload.
  Each chunk's details are sliced the same way (`TerrainBuilder.start /
  step / finish_chunk_details` over `DetailScatter.build_begin / build_step /
  build_result`, row by row; same placement however it is sliced,
  `test_project/tools/hash_details.gd [--sliced]`).
  One-time work gets steps of its own before what first needs it: a shader
  compiles once (~25 ms each on a laptop; a wind ShaderMaterial when made, a
  StandardMaterial3D on first use, `MaterialFactory.compile`), so the ground
  material (`TerrainBuilder.warm_ground_material`), each road / river material
  and the generated wave texture (`feature_material_warmups`), each detail
  material and layer mesh (`DetailScatter.warmups`). Road materials are cached
  per look: Godot frees a StandardMaterial3D's shader with its last material.
  Savanna 192 m: worst step 199 -> 36-45 ms (one shader compile), worst
  details slice ~7-10 ms (`tools/profile_load_steps.gd`,
  `tools/profile_load_frames.gd`). The ground colours each chunk mesh is
  built with (`rebuild_chunk()`'s `shading`) are kept for that chunk's
  details (`TerrainShading.top_faces()`, the top-face colours only), not
  made twice (~6 ms a chunk on a laptop).
- Detail streaming (`LowpolyTerrainRuntime.stream_details`, on by default):
  each detail layer is only built on the chunks within its draw distance
  (`DetailScatter.layer_radii()`: the layer's Draw Distance, else the
  terrain's; 0 = always) + `stream_margin` of the focus (`stream_focus`, else
  the current camera), measured to the chunk's nearest point (the visibility
  range is measured to the AABB centre, further away: built before it can
  show), and freed past draw distance + `unload_margin` (hysteresis: walking
  along a border does not build / free over and over). Per layer, not per
  chunk: the trees are drawn across a whole small map while grass is not.
  Placement is a pure function of cell, layer name and seed, so a chunk's
  layers are built in any order and any grouping with the same instances
  (`build_begin / start_chunk_details(layer_mask)`; `apply(layer_mask)`
  leaves the other layers' nodes alone; `tools/check_streaming.gd` compares
  every streamed node with a full build). `finished` fires once the layers
  around the start position are built; then `_stream()` runs in
  `stream_budget_ms` a frame: every 0.25 s or when the focus moved a quarter
  chunk (teleport) it frees what is past the unload distance and queues the
  missing layers nearest chunk first (with the layers about to be wanted: one
  job per chunk, not one per layer), drops the job being built when it is no
  longer wanted, finishes at most one chunk a frame. The ground colours of
  every chunk are kept (~32 KB a chunk) when the ground is built at runtime,
  else the last 12. Trunk collision only within `collision_distance`, rebuilt
  when a chunk's collision layers change. Only when the runtime builds the
  details (not with details saved in the scene); the public `rebuild_*`
  calls bypass it. Single-threaded on purpose: MultiMesh / RenderingServer
  work must stay on the main thread.
- Ground streaming (`LowpolyTerrainRuntime.stream_ground`, off by default,
  for big maps such as 1024 cells): one big terrain, its data all in memory
  (~14 MB for 1024 cells), only the geometry streamed. Ground chunks within
  `ground_distance` + `stream_margin` of the focus are built, freed past
  `ground_distance` + `unload_margin` (with their details, collision and
  ground colours); waterholes the same, by their bounds. It turns detail
  streaming on, with the layer radii capped at `ground_distance`. Ground
  collision: one `_GroundCollision` StaticBody3D per chunk under the chunk,
  within `ground_collision_distance`, filled before it enters the tree
  (Jolt rebuilds a body in the tree on each shape added); the roads keep
  their single shape on `_RuntimeGroundCollision`. The ground colours of
  every built chunk are kept: each detail layer comes at its own distance and
  would make them again (20-100 ms). Checked by
  `test_project/tools/check_ground_streaming.gd` (768 m map: chunks and
  waterholes in range only and bit-identical to a main-thread build,
  collision in range, never a hole under the feet at 10 m/s; worst streaming
  frame 25 ms, 99 % under 6.5 ms on a laptop). `terrain_ready` waits only
  for the chunks within `ready_distance` (96 m) and their collision; the
  rest of the ring and the far blocks keep coming while the detail steps
  run (`_run` pumps the ground with half of the frame budget once the
  ground is ready). On the Tecno phone, waiting for the whole 250 m ring
  took 13-19 s.
- Worker threads (stream_ground): a chunk's faces take 15-30 ms, so they are
  computed on `WorkerThreadPool`. The mesher is split in two:
  `TerrainMesher.build_chunk_arrays()` / `WaterholeMesher.build_arrays()`
  only read metadata and run on a worker, on a `TerrainMesher.thread_snapshot()`
  (a detached Node3D with the terrain's metadata: packed arrays shared copy
  on write, style palette deep-copied because reading a style writes its
  migrated fields); `assemble_chunk()` / `assemble()` make the ArrayMesh and
  its materials on the main thread (shared material cache). Lazy statics
  (default biome, border noise) are made first on the main thread
  (`prepare_threads()`). Same output bit for bit
  (`test_project/tools/check_threaded_chunks.gd`). While loading, one task
  per core but one (terrain_ready 5.0 s -> 1.2-1.7 s on 768 m); in game,
  `STREAM_TASKS` (1): more workers took the CPU from the main thread and
  made the frame slower, not the ground faster. Tasks still running when the
  runtime is freed are waited for (their snapshots freed).
- Main-thread spikes while walking (`test_project/tools/profile_stream_frames.gd`
  times the runtime per frame on the open world; a phone CPU is ~3x a
  laptop's, so 5 ms there = a missed 60 fps frame). The worker also does
  `TerrainMesher.pack_chunk()` (final packed arrays, the shadow caster's
  welded positions `MeshUtils.back_face_arrays()`, the collision faces = the
  mesh's triangles, exact where `get_faces()` read the mesh back from the
  GPU and snapped it to 0.1 mm), with `chunk_looks()` read before on the main
  thread; `assemble_packed()` only uploads (`check_threaded_chunks.gd`
  compares it all). A chunk's collision shape comes in a frame of its own
  (`_shape_queue`, first in the pump), the trunk collision is sliced
  (`DetailCollision.begin_chunk / step_chunk / finish_chunk`, body filled out
  of the tree), detail slices check their budget every 8 cells. Laptop,
  10 m/s: frames over 4 ms 123 -> ~80, over 8 ms 17 -> ~6, p99 6.7 -> 4.5 ms
  (ground finish 8 -> ~4 ms, shape 6-8 -> 2-4 ms, trunk collision 16 ms ->
  slices). Left: a detail job's start (`DetailScatter.build_begin`, 3-5 ms),
  `_retarget` ~2 ms every 0.25 s, rare ~17 ms stalls (render sync).
- Far ground (stream_ground, `far_distance` > 0, `mesh/lod_mesher.gd`):
  past `ground_distance`, blocks of 4 x 4 chunks (`_FarGround/Far_x_z`)
  keep one vertex in `far_step` (2/4/8), vertex colours taken from the
  baked colour at each kept vertex (one draw call, no collision, details or
  shadows). Each block mesh leaves out its detailed chunks (16-bit mask), so
  nothing is drawn twice: a new detailed chunk stays hidden while its block
  still covers it; a chunk going far is freed only once its block is rebuilt
  to cover it; a block mesh and the visibility of its chunks change in the
  same frame. Skirts (one `step` deep, normals up so they light as the
  ground) hang under the block borders, around the left-out chunks and,
  merged in the vertex-colour surface, under the detailed chunks' borders:
  the coarse edge leaves a T-junction gap on whichever side is lower. Block
  data (corners, colours: ~100 ms on a worker, mostly shading) is kept, so
  a new mask only redoes `block_arrays()` (~7 ms). Far blocks are built
  after the chunks: `terrain_ready` does not wait for them, `finished`
  does. Past the game's fog end they cost GPU for nothing: the game sets
  `far_distance` to its fog end (test_project open world: 600 m). 768 m map, centre: 120 detailed draws / 245 k tris, far
  12 draws / 20 k tris. `check_ground_streaming.gd` also checks that each
  chunk within `far_distance` is shown exactly once on every frame of the
  run.
- Editor at scale (`TerrainBuilder.streams_in_editor`: more than
  `EDITOR_STREAM_CHUNKS` = 16 chunks a side): the editor no longer builds
  the whole map (1024 cells: ~40 s, 2 M triangles). The terrain's
  LowpolyTerrainRuntime node streams it around the 3D editor camera
  (`start_editor_stream`, same code as stream_ground: threads, far blocks;
  no trunk collision, no map generation). Nothing generated is saved:
  Runtime Build is set to Everything and the node's `stream_ground` on, with
  a line in the Output log. The plugin's TerrainBuilder routes every edit
  to it (`editor_stream()`): `rebuild_chunk` rebuilds a detailed chunk at
  once (with its skirt) and tells the runtime the chunk changed
  (`editor_chunks_changed`: tasks started from the old data are dropped,
  far blocks made again, the shading cache cleared); details, waterholes,
  collision and the river carve go through `editor_*` calls; `rebuild_all`
  restarts the streaming. The runtime and the plugin share one builder
  (`share_builder`), so they read the same river carve. Selecting a 1024-cell
  map: 0.2 s, ground around the camera in ~4 s, everything in ~11 s (119
  of 1024 chunks). Checked by the editor smoke harness (stroke, Undo, far
  block redone after its data changed, waterhole, back to a small map).
- Road cache (editor, `TerrainBuilder.feature_cache_enabled`):
  `rebuild_feature_mesh(terrain, ground_changed)` keeps each connected
  group (FeatureMesher.build_cached). A road group keeps its union state,
  triangulated in bands of 32 cell rows (RoadMesher.bands_*): a ground edit
  in a rect samples again only the corners and edge crossings there and
  redoes the bands of those rows; a river group crossing the rect is made
  again; an unchanged group is reused. A changed river carve, or
  `ground_changed` = true, empties the cache. Same mesh bit for bit
  (`test_project/tools/check_feature_cache.gd`): a stroke on a road of a
  768 m map 300 ms -> 30 ms.
- Detail collision is never saved and never built in the editor:
  `DetailCollision` reads the instance transforms back from each chunk's
  detail MultiMeshes and adds one cylinder shape owner per instance of the
  layers with `collision_radius > 0` to a `_DetailCollision` StaticBody3D in
  the chunk. Sizes are rounded so instances share `CylinderShape3D`s. The
  body is filled out of the tree and added once complete: with Jolt, a shape
  added to a body in the tree rebuilds the whole body each time.
- The river carve is derived data: `TerrainBuilder.get_river_carve()` caches it
  per terrain and passes it to the samplers and meshers.
- Rivers never climb: `RiverMesher.water_levels()` resamples a river's
  centre line and gives each point a water level = max(running minimum of
  the ground from the start, from the end). On ground that only goes down it
  is the ground (same channel as before); over a hill it stays at the lower
  side's height and `compute_carve()` cuts the channel through it (banks at
  `BANK_SLOPE`, at most `MAX_BANK_REACH` m wide); the water surface is
  min(ground, level) - Surface Drop. The carve therefore depends on the
  heights along the river: a sculpt stroke near one (`any_river_near`)
  re-carves at its end, and `rebuild_river_carve()` returns the chunks whose
  carve changed (rebuilt too, also by `rebuild_area` for Undo). Checked by
  `test_project/tools/check_river_level.gd` and the smoke test.

## Shared helpers (look here before writing it again)

- Brush and road / river width limits: `ToolMode.BRUSH_RADIUS_*`,
  `BRUSH_STRENGTH_*`, `FEATURE_WIDTH_*` (toolbar, Inspector and the `[ ]`
  keys all read them); the width of the active road / river tool:
  `ToolMode.feature_width(terrain, mode)` / `feature_width_key(mode)`.
- Default value of every terrain setting: `TerrainData.SETTING_DEFAULTS`
  (one table, used by `initialize()` and `ensure_defaults()`).
- A chunk node from its grid key: `TerrainMesher.find_chunk(terrain, x, z)`.
- Generated child nodes: `TerrainBuilder._ensure_container()` /
  `_ensure_mesh_child()` (created when missing, reused otherwise).
- Writing a height / style grid into the metadata:
  `ImageGenerator.write_grid()` (used by both generators).
- Grouping roads / rivers that touch: `GridMath.connected_groups(bounds,
  touch)` with `GridMath.polyline_bounds()` boxes as a cheap prefilter.
- A detail entry (`DetailScatter.apply`): `ENTRY_NODE_NAME`, `ENTRY_COUNT`,
  `ENTRY_BUFFER`, `ENTRY_LAYER`, `ENTRY_MESH` instead of `entry[0..4]`.
- The biome of a terrain (with the built-in default): `TerrainBiome.of()`.
- Waterhole and road heights: `TerrainSampler.surface_height_in()` (the drawn
  triangles), not a local copy.

## Checking that a refactor changes nothing

From `test_project/`: `bash tools/run_checks.sh` (~4 min, each step under a
time limit). It syncs the addon, compares `tools/hash_everything.gd` (data,
ground, details, roads / rivers / waterholes, collision of 3 terrains) and
`tools/hash_details.gd` (whole and sliced) to the saved baselines, runs the
`check_*` tools and the editor smoke test. A hash of metadata must not
depend on object ids or on the order StringNames were created in: the tool
replaces objects by their path and sorts the keys as text.

## Static typing

The addon is fully statically typed: `test_project/tools/typecheck.sh` (also
a step of `run_checks.sh`) checks every file with all GDScript typing
warnings as errors (untyped declaration, inference on Variant, unsafe
property / method access, unsafe cast, unsafe call argument) and must report
0. Godot skips these warnings in `addons/` by default, so the editor alone
does not show them. How to keep it at 0:
- metadata: `Meta.get_float / get_int / get_bool(object, key, default)`,
  not `float(object.get_meta(...))`;
- dictionary / untyped-array values: read into a typed local
  (`var width: float = road["width"]`) or a typed `for` iterator;
- biomes, layers, recipes: the preload consts as types (`TerrainBiome`,
  `DetailLayer`, `MapRecipe`...), not `Resource`;
- `clampf / mini / lerpf...` rather than the Variant `clamp / min / lerp`;
- never turn a parameter `Array` into `Array[T]` when a caller passes a
  plain array (rejected at run time);
- a value that may hold anything (optional metadata, old fields): test it
  with `is`, then assign it to a typed variable (null otherwise), as in
  `DetailScatter.custom_material()`; no `as` on a Variant and no
  `@warning_ignore` (there are none).
