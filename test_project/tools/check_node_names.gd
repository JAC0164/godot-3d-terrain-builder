extends SceneTree
## Nodes the plugin adds to a scene keep a readable name: their own, else
## Name2, Name3... (core/node_names.gd), never Godot's @Node3D@123.
##   godot --headless --path . --script res://tools/check_node_names.gd

const NodeNames = preload("res://addons/lowpoly_terrain_editor/core/node_names.gd")

var _ok := true

func _check(label: String, condition: bool) -> void:
	print("%s %s" % ["PASS" if condition else "FAIL", label])
	_ok = _ok and condition

func _named(name: String) -> Node3D:
	var node := Node3D.new()
	node.name = name
	return node

func _initialize() -> void:
	var parent := Node3D.new()
	var first := _named("LowpolyTerrain")
	NodeNames.add(parent, first)
	_check("free name kept (%s)" % first.name, first.name == "LowpolyTerrain")
	var second := _named("LowpolyTerrain")
	NodeNames.add(parent, second)
	_check("taken name -> LowpolyTerrain2 (%s)" % second.name, second.name == "LowpolyTerrain2")
	var third := _named("LowpolyTerrain")
	NodeNames.add(parent, third)
	_check("next -> LowpolyTerrain3 (%s)" % third.name, third.name == "LowpolyTerrain3")
	# A freed number is reused first.
	parent.remove_child(second)
	second.free()
	var fourth := _named("LowpolyTerrain")
	NodeNames.add(parent, fourth)
	_check("first free number reused -> LowpolyTerrain2 (%s)" % fourth.name, fourth.name == "LowpolyTerrain2")
	# A name ending with a digit gets "_2", not a longer number.
	NodeNames.add(parent, _named("Far_1_2"))
	var far := _named("Far_1_2")
	NodeNames.add(parent, far)
	_check("Far_1_2 taken -> Far_1_2_2 (%s)" % far.name, far.name == "Far_1_2_2")
	# No name: the class name.
	var unnamed := MeshInstance3D.new()
	NodeNames.add(parent, unnamed)
	_check("no name -> class name (%s)" % unnamed.name, unnamed.name == "MeshInstance3D")
	var readable := true
	for child in parent.get_children():
		readable = readable and not String(child.name).begins_with("@")
	_check("no @ name among %d children" % parent.get_child_count(), readable)
	parent.free()
	print("CHECK %s: node names" % ("PASS" if _ok else "FAIL"))
	quit(0 if _ok else 1)
