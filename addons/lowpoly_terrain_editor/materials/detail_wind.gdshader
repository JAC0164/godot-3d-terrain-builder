// Wind for scattered details (grass, shrubs, trees): MaterialFactory.detail_material(profile).
// Same look as the plain detail material (vertex colour x MultiMesh instance
// colour, picked in sRGB, fully rough, no specular); only the vertices move.
// The bend grows with the height in the mesh (the base stays planted): slow
// gusts travel across the map along the wind, each plant sways at its own
// phase, and a quick small shiver plays on top. No texture, a few sin() per
// vertex: fine on mobile.
// Closed meshes (shrubs, trees): back faces culled. Grass uses
// detail_wind_two_sided.gdshader. Shared code: detail_wind.gdshaderinc.
shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_lambert, specular_disabled;

#include "detail_wind.gdshaderinc"
