// Wind for grass tufts (MaterialFactory.detail_material("grass")): same as
// detail_wind.gdshader, but drawn from both sides, so each blade is ONE
// triangle (DetailMeshes.builtin(index, true)) instead of two back to back:
// half the triangles for the densest layers. Shared code: detail_wind.gdshaderinc.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_disabled, diffuse_lambert, specular_disabled;

#define TWO_SIDED
#include "detail_wind.gdshaderinc"
