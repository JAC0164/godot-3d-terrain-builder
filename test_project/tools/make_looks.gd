extends SceneTree
## Writes the example Custom Materials of world/looks/ (terrain Inspector >
## Look > Ground Material / Detail Material). Game-side examples, not
## part of the plugin:
##   godot --headless --path . --script res://tools/make_looks.gd

const DIR := "res://world/looks/"

func _vertex_color_material(name: String) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.resource_name = name
	# The terrain colours are vertex colours picked in sRGB.
	material.vertex_color_use_as_albedo = true
	material.vertex_color_is_srgb = true
	material.roughness = 1.0
	material.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	return material

func _save(resource: Resource, file: String) -> void:
	var error := ResourceSaver.save(resource, DIR + file)
	print("%s %s" % ["wrote" if error == OK else "FAILED", DIR + file])

func _initialize() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	# Toon: light in two hard steps instead of a smooth falloff.
	for target in ["ground", "detail"]:
		var toon := _vertex_color_material("%s toon" % target)
		toon.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
		_save(toon, "%s_toon.tres" % target)
		# Unshaded: the colours as painted (baked shading kept), no sun, no shadows.
		var unshaded := _vertex_color_material("%s unshaded" % target)
		unshaded.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		_save(unshaded, "%s_unshaded.tres" % target)
	# Toon + wind, written as a shader (see detail_toon_wind.gdshader).
	var wind := ShaderMaterial.new()
	wind.resource_name = "detail toon wind"
	wind.shader = load(DIR + "detail_toon_wind.gdshader")
	_save(wind, "detail_toon_wind.tres")
	# Soil grain on the ground colours (see ground_detail.gdshader).
	var grain := ShaderMaterial.new()
	grain.resource_name = "ground detail"
	grain.shader = load(DIR + "ground_detail.gdshader")
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.035
	noise.fractal_octaves = 4
	var noise_tex := NoiseTexture2D.new()
	noise_tex.width = 256
	noise_tex.height = 256
	noise_tex.seamless = true
	noise_tex.noise = noise
	var normal_tex := NoiseTexture2D.new()
	normal_tex.width = 256
	normal_tex.height = 256
	normal_tex.seamless = true
	normal_tex.as_normal_map = true
	normal_tex.bump_strength = 6.0
	normal_tex.noise = noise
	grain.set_shader_parameter("noise_tex", noise_tex)
	grain.set_shader_parameter("noise_normal", normal_tex)
	_save(grain, "ground_detail.tres")
	# Outline post-effect: a full-screen quad to put under the Camera3D.
	var outline_material := ShaderMaterial.new()
	outline_material.shader = load(DIR + "outline.gdshader")
	var quad := QuadMesh.new()
	quad.size = Vector2(2, 2)
	var overlay := MeshInstance3D.new()
	overlay.name = "Outline"
	overlay.mesh = quad
	overlay.material_override = outline_material
	# Never culled (the vertex shader puts it over the whole screen).
	overlay.extra_cull_margin = 16384.0
	overlay.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	overlay.position = Vector3(0, 0, -1)
	var scene := PackedScene.new()
	scene.pack(overlay)
	_save(scene, "outline.tscn")
	overlay.free()
	quit(0)
