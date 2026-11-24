#!/bin/bash
# Screenshots of the plugin in the Godot editor, for the documentation site.
#   bash tools/editor_shots/run_editor_shots.sh      (from test_project/)
# Builds a scratch project in $TMPDIR/lte_shots (the plugin, the test project's
# savanna light in world/, and the lte_shots EditorPlugin), opens the real editor
# off screen (3 min max) and copies the images to ../docs/editor/.
G=/c/Users/Jaco/Programmes/Godot_v4_7_2/Godot_v4.7.2-stable_win64_console.exe
S=${TMPDIR:-/tmp}/lte_shots
ADDON=../addons/lowpoly_terrain_editor
OUT=../docs/editor
rm -rf $S && mkdir -p $S/addons $OUT
cp tools/editor_smoke/project.godot.txt $S/project.godot
sed -i 's|^config/name=.*|config/name="Savanna"|' $S/project.godot
cp -r $ADDON $S/addons/lowpoly_terrain_editor
cp -r tools/editor_shots/lte_shots $S/addons/
cp -r world $S/world
sed -i 's|^enabled=PackedStringArray(.*)|enabled=PackedStringArray()|' $S/project.godot
timeout 90 "$G" --headless --path "$S" --import >/dev/null 2>&1
sed -i 's|^enabled=PackedStringArray(.*)|enabled=PackedStringArray("res://addons/lowpoly_terrain_editor/plugin.cfg", "res://addons/lte_shots/plugin.cfg")|' $S/project.godot
timeout 180 "$G" --editor --path "$S" --position -3000,-3000 --resolution 1920x1080 > $S/shots.txt 2>&1
echo "shots: exit $? images $(grep -c '^SHOT ' $S/shots.txt)"
grep -h "SCRIPT ERROR\|ERROR:\|SHOTS DONE" $S/shots.txt | head -12
cp $S/shots/*.webp $OUT/ 2>/dev/null
ls $OUT
