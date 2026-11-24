#!/bin/bash
# Full regression check after a plugin change, every step time-boxed.
#   bash tools/run_checks.sh          (from test_project/)
# 1. syncs the plugin copies, 2. fingerprints vs results/refactor/baseline_*,
# 3. headless checks + static typing (tools/typecheck.sh), 4. the editor smoke harness (one pass, 3 min max).
# The smoke harness (tools/editor_smoke/lte_harness, an EditorPlugin) runs in a
# scratch project rebuilt each time in $TMPDIR/lte_smoke: the plugin + it.
G=/c/Users/Jaco/Programmes/Godot_v4_7_2/Godot_v4.7.2-stable_win64_console.exe
S=${TMPDIR:-/tmp}/lte_smoke
ADDON=../addons/lowpoly_terrain_editor
mkdir -p $S/addons
cp tools/editor_smoke/project.godot.txt $S/project.godot
rm -rf $S/addons/lowpoly_terrain_editor $S/addons/lte_harness
cp -r tools/editor_smoke/lte_harness $S/addons/
cp -r $ADDON/. addons/lowpoly_terrain_editor/ && cp -r $ADDON $S/addons/lowpoly_terrain_editor
diff -rq --exclude="*.uid" --exclude="*.import" $ADDON addons/lowpoly_terrain_editor/ >/dev/null && diff -rq --exclude="*.uid" --exclude="*.import" $ADDON $S/addons/lowpoly_terrain_editor/ >/dev/null && echo "synced" || echo "SYNC MISMATCH"
fail=0
timeout 120 "$G" --headless --path . --script res://tools/hash_everything.gd 2>&1 | grep " data " | sed 's/ (.*//' > /tmp/lte_everything.txt
diff -q results/refactor/baseline_everything.txt /tmp/lte_everything.txt >/dev/null && echo "OK   fingerprint everything" || { echo "FAIL fingerprint everything"; diff results/refactor/baseline_everything.txt /tmp/lte_everything.txt; fail=1; }
timeout 120 "$G" --headless --path . --script res://tools/hash_details.gd 2>&1 | grep "instances" | grep -v savanna_128 | sed 's/ (.*//' > /tmp/lte_details.txt
diff -q results/refactor/baseline_details.txt /tmp/lte_details.txt >/dev/null && echo "OK   fingerprint details" || { echo "FAIL fingerprint details"; fail=1; }
timeout 120 "$G" --headless --path . --script res://tools/hash_details.gd -- --sliced 2>&1 | grep "instances" | grep -v savanna_128 | sed 's/ (.*//' > /tmp/lte_details_sliced.txt
diff -q results/refactor/baseline_details.txt /tmp/lte_details_sliced.txt >/dev/null && echo "OK   fingerprint details sliced" || { echo "FAIL fingerprint details sliced"; fail=1; }
for t in check_ground_shadow check_maps check_biomes check_shading_seams check_optimizations check_waterholes check_road_fit check_river_level check_vegetation_paint check_click_props check_custom_model check_streaming check_threaded_chunks check_ground_streaming check_feature_cache check_feature_split check_texture_blend check_environment; do
	# The ground streaming builds a 768 m map twice (~2 min).
	limit=120; [ $t = check_ground_streaming ] && limit=360
	out=$(timeout $limit "$G" --headless --path . --script res://tools/$t.gd 2>&1)
	code=$?
	if [ $code -ne 0 ] || echo "$out" | grep -qE "SCRIPT ERROR|Parse Error|RESULT: FAIL|RESULT FAIL|[1-9][0-9]* failure|FAIL "; then
		echo "FAIL $t (exit $code)"; echo "$out" | grep -E "SCRIPT ERROR|Parse Error|FAIL|failure" | head -5; fail=1
	else
		echo "OK   $t"
	fi
done
# Static typing: every GDScript typing warning of the addon must stay at 0.
typing=$(timeout 300 bash tools/typecheck.sh checks | grep -o "^[0-9]*")
[ "$typing" = "0" ] && echo "OK   typecheck" || { echo "FAIL typecheck ($typing issue(s), results/typecheck_checks.txt)"; fail=1; }
sed -i 's|^enabled=PackedStringArray(.*)|enabled=PackedStringArray()|' $S/project.godot
timeout 60 "$G" --headless --path "$S" --import >/dev/null 2>&1
sed -i 's|^enabled=PackedStringArray(.*)|enabled=PackedStringArray("res://addons/lte_harness/plugin.cfg")|' $S/project.godot
timeout 180 "$G" --editor --path "$S" --position -3000,-3000 > $S/smoke_1.txt 2>&1
echo "smoke: exit $? pass $(grep -c 'PASS ' $S/smoke_1.txt) fail $(grep -c 'FAIL ' $S/smoke_1.txt)"
grep -h "SMOKE FAIL\|SCRIPT ERROR" $S/smoke_1.txt | head -8
exit $fail
