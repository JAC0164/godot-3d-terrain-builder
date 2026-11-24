@tool
extends RefCounted
## Runs the generator's loops in parallel (WorkerThreadPool): over bands of
## rows of a grid (run), or over a list of jobs (each).
##
## The work runs on any thread and must only read shared data: a write to a
## Packed array captured by a task copies it (copy on write). So each band
## returns its own arrays and the caller joins them in row order (join_*):
## the result is the same as one loop over the whole grid.

## Rows per task: 16 tasks on a 1 024-cell map.
const BAND_ROWS := 64

## The results of `work.call(index)` for index 0..count-1, in that order.
static func each(count: int, work: Callable) -> Array:
	var holders: Array = []
	for index in count:
		holders.append([])
	if count == 1:
		_run_one(0, work, holders)
	elif count > 1:
		# High priority: low priority tasks only get a share of the threads
		# (low_priority_thread_ratio).
		var task := WorkerThreadPool.add_group_task(_run_one.bind(work, holders), count, -1, true)
		WorkerThreadPool.wait_for_group_task_completion(task)
	var results: Array = []
	for holder: Array in holders:
		results.append(holder[0])
	return results

## The results of `work.call(from_row, to_row)` for each band of `rows`, in
## row order.
static func run(rows: int, work: Callable) -> Array:
	return each(maxi(ceili(float(rows) / float(BAND_ROWS)), 1), _band.bind(work, rows))

static func _run_one(index: int, work: Callable, holders: Array) -> void:
	var holder: Array = holders[index]
	holder.append(work.call(index))

static func _band(band: int, work: Callable, rows: int) -> Variant:
	var from := band * BAND_ROWS
	return work.call(from, mini(from + BAND_ROWS, rows))

## The bands' arrays end to end.
static func join_floats(parts: Array) -> PackedFloat32Array:
	var joined := PackedFloat32Array()
	for part: PackedFloat32Array in parts:
		joined.append_array(part)
	return joined

static func join_ints(parts: Array) -> PackedInt32Array:
	var joined := PackedInt32Array()
	for part: PackedInt32Array in parts:
		joined.append_array(part)
	return joined

static func join_bytes(parts: Array) -> PackedByteArray:
	var joined := PackedByteArray()
	for part: PackedByteArray in parts:
		joined.append_array(part)
	return joined
