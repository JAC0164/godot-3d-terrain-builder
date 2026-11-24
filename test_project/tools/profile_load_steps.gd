extends SceneTree
## Times every build step of LowpolyTerrainRuntime on the audit's savanna map
## (generated in game + one river, ground collision on), one step at a time,
## and prints the slowest ones and the total per kind of step.
##   godot --path . --position -3000,-3000 --script res://tools/profile_load_steps.gd
## (a real window: mesh uploads cost as in a game).

const ADDON := "res://addons/lowpoly_terrain_editor/"
const Meta = preload(ADDON + "core/terrain_meta.gd")
const TerrainData = preload(ADDON + "core/terrain_data.gd")
const MapGenerator = preload(ADDON + "generation/map_generator.gd")
const TerrainRuntime = preload(ADDON + "runtime/terrain_runtime.gd")
const FeatureStyle = preload(ADDON + "styles/feature_style.gd")
const RECIPE := ADDON + "generation/presets/senegal_savanna_map.tres"

func _initialize() -> void:
	var root := Node3D.new()
	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	root.add_child(terrain)
	TerrainData.initialize(terrain)
	MapGenerator.generate(terrain, load(RECIPE), 7)
	var size: float = float(terrain.get_meta(Meta.WORLD_SIZE))
	var points: Array[Vector2] = []
	for i in 9:
		var t := float(i) / 8.0
		points.append(Vector2(lerpf(-0.42, 0.42, t) * size, sin(t * 5.0) * 0.12 * size + 0.18 * size))
	FeatureStyle.commit(terrain, FeatureStyle.RIVER, points)
	terrain.set_meta(Meta.RUNTIME_BUILD, Meta.RUNTIME_BUILD_ALL)
	terrain.set_meta(Meta.COLLISION_ENABLED, true)
	var runtime := TerrainRuntime.new()
	# Every detail at load (as the earlier measures; on by default since 2026-11-24).
	runtime.stream_details = false
	runtime.name = String(Meta.RUNTIME_NODE_NAME)
	runtime.build_on_ready = false
	terrain.add_child(runtime)
	get_root().add_child(root)
	await process_frame
	var times: Array[float] = []
	var kinds: Array[String] = []
	var slices: Array[int] = []
	# Default slice budget (sliced steps), but one step per _run(0) call below.
	runtime.frame_budget_ms = 6.0
	runtime.build()
	runtime.set_process(false)
	# build() ran the first steps already.
	for i in runtime._done:
		times.append(-1.0)
		kinds.append(_kind(runtime, i))
		slices.append(0)
	while not runtime.is_finished:
		var index: int = runtime._done
		var kind := _kind(runtime, index)
		var t0 := Time.get_ticks_usec()
		runtime._run(0.0)
		var ms := (Time.get_ticks_usec() - t0) / 1000.0
		if index < times.size():
			# A sliced step called again: keep its slowest slice.
			times[index] = maxf(times[index], ms)
			slices[index] += 1
		else:
			times.append(ms)
			kinds.append(kind)
			slices.append(1)
		await process_frame
	var per_kind := {}
	var order: Array = []
	for i in times.size():
		if times[i] < 0.0:
			continue
		if not per_kind.has(kinds[i]):
			per_kind[kinds[i]] = [0, 0.0, 0.0]
			order.append(kinds[i])
		per_kind[kinds[i]][0] += 1
		per_kind[kinds[i]][1] += times[i]
		per_kind[kinds[i]][2] = maxf(per_kind[kinds[i]][2], times[i])
	print("steps %d" % times.size())
	for kind in order:
		var k: Array = per_kind[kind]
		print("  %-26s x%3d  total %7.1f ms  worst %6.1f ms" % [kind, k[0], k[1], k[2]])
	var slow: Array = []
	for i in times.size():
		slow.append([times[i], i])
	slow.sort_custom(func(a, b): return a[0] > b[0])
	for s in slow.slice(0, 12):
		var bound: Array = (runtime._steps[s[1]] as Callable).get_bound_arguments() if s[1] < runtime._steps.size() else []
		print("  step %3d %-26s %6.1f ms%s %s" % [s[1], kinds[s[1]], s[0], " (slowest of %d slices)" % slices[s[1]] if slices[s[1]] > 1 else "", bound.slice(1) if not bound.is_empty() else ""])
	quit()

## Kind of build step `index` (same order as TerrainRuntime.build()).
func _kind(runtime: Node, index: int) -> String:
	var step: Callable = runtime._steps[index] if index < runtime._steps.size() else Callable()
	if not step.is_valid():
		return "?"
	var method := String(step.get_method())
	if method == "" or method.begins_with("<anonymous"):
		return "lambda #%d" % index if index < 3 or index >= runtime._ground_steps - 1 else "lambda"
	return method
