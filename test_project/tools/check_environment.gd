extends SceneTree
## Checks the game's Environment files (world/savanna_environment.tres, and
## world/open_world_environment.tres of the open world).
##   godot --headless --path . --script res://tools/check_environment.gd
## Godot 4.7.2 only applies a depth fog loaded from a file when fog_mode comes
## AFTER fog_depth_begin / fog_depth_end / fog_depth_curve in the file. The
## editor saves fog_mode first: after saving this file from the editor, move
## the "fog_mode = 1" line below "fog_depth_end" again (otherwise the depth
## settings are ignored and the fog no longer hides the far horizon).

const PATHS: Array[String] = ["res://world/savanna_environment.tres", "res://world/open_world_environment.tres"]

func _initialize() -> void:
	var ok := true
	for path in PATHS:
		ok = _check(path) and ok
	print("CHECK %s: environment fog file order" % ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)

func _check(path: String) -> bool:
	var lines := FileAccess.get_file_as_string(path).split("\n")
	var mode := -1
	var depth := -1
	for i in lines.size():
		if lines[i].begins_with("fog_mode = 1"):
			mode = i
		elif lines[i].begins_with("fog_depth_"):
			depth = maxi(depth, i)
	var env: Environment = load(path)
	if env.fog_mode == Environment.FOG_MODE_DEPTH and (mode < depth):
		push_error("%s: fog_mode must come after the fog_depth_* lines (Godot ignores the depth settings otherwise)" % path)
		return false
	return true
