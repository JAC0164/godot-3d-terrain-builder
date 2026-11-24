#!/bin/bash
# Typing audit of the addon: every GDScript typing warning (untyped
# declaration, unsafe property / method access, unsafe cast, unsafe call
# argument, inference on Variant), reported as errors by --check-only.
#   bash tools/typecheck.sh [work_name] [filter_regex]     (from test_project/)
# work_name: scratch project folder (one per parallel run), default "main".
# filter_regex: only check files whose path matches (e.g. "^mesh/").
# Prints "<message>\t<file>:<line>" lines to results/typecheck_<work_name>.txt
# and the count. Warnings of other scripts that fail to compile are not shown.
G=/c/Users/Jaco/Programmes/Godot_v4_7_2/Godot_v4.7.2-stable_win64_console.exe
HERE=$(cd "$(dirname "$0")/.." && pwd)
WORK_NAME=${1:-main}
FILTER=${2:-.}
T=${TMPDIR:-/tmp}/lte_typecheck_$WORK_NAME
OUT=$HERE/results/typecheck_$WORK_NAME.txt
mkdir -p $T/addons
cp $HERE/tools/typecheck/project.godot.txt $T/project.godot
rm -rf $T/addons/lowpoly_terrain_editor
cp -r $HERE/../addons/lowpoly_terrain_editor $T/addons/
[ -d $T/.godot ] || timeout 90 $G --headless --path $T --import >/dev/null 2>&1
: > $OUT
cd $T/addons/lowpoly_terrain_editor
for f in $(find . -name "*.gd" | sed 's|^\./||' | grep -E "$FILTER" | sort); do
	timeout 30 $G --headless --path $T --check-only --script res://addons/lowpoly_terrain_editor/$f 2>&1 \
		| grep -A1 "SCRIPT ERROR" | paste - - | grep "lowpoly_terrain_editor/$f:" \
		| sed -E 's/SCRIPT ERROR: (Parse|Compile) Error: //; s/ \(Warning treated as error.\)//; s/\s+at: GDScript::reload \(res:\/\/addons\/lowpoly_terrain_editor\//\t/; s/\)$//' >> $OUT
done
echo "$(wc -l < $OUT) typing issue(s) -> $OUT"
