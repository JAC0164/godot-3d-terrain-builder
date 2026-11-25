@tool
extends RefCounted
## Names of the nodes the plugin adds to a scene. When a child name is already
## taken, Godot gives the new node an unreadable one (@Node3D@20604). So every
## node the plugin puts in a scene goes through add(): it keeps its name when
## that name is free, else it gets the next free number as a suffix
## (LowpolyTerrain2, LowpolyTerrain3...), like the editor's own duplicates.

## `base` if `parent` has no child of that name, else `base` + the first free
## number from 2 (a "_" in between when `base` already ends with a digit, so
## "Far_1_2" gives "Far_1_2_2", not "Far_1_22").
static func unique(parent: Node, base: String) -> String:
	if not parent.has_node(NodePath(base)):
		return base
	var separator := "_" if base.right(1).is_valid_int() else ""
	var number := 2
	while parent.has_node(NodePath("%s%s%d" % [base, separator, number])):
		number += 1
	return "%s%s%d" % [base, separator, number]

## Adds `child` to `parent` under its own name, made unique (see unique()). A
## child without a name is named after its class.
static func add(parent: Node, child: Node) -> void:
	var base := String(child.name)
	if base.is_empty():
		base = child.get_class()
	child.name = unique(parent, base)
	parent.add_child(child)
