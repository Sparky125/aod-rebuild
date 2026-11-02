extends SceneTree
## Render a staged GLB at a chosen clip/frame through a SubViewport (the
## baker's exact path) and save the PNG — the ground-truth acceptance check
## for "what does Godot actually draw".
## Run: Godot_console --path rebuild --script tools/diag_glb_render.gd
## env: GLB=<unit> CLIP=<clip> T=<seconds> OUT=<abs path.png>

func _find(n: Node, t: String) -> Node:
	if n.get_class() == t:
		return n
	for c in n.get_children():
		var r: Node = _find(c, t)
		if r != null:
			return r
	return null

var vp: SubViewport
var inst: Node
var _f := 0
var _out := ""
var _clip := "idle"
var _t := 0.0
var _ready_done := false

func _initialize() -> void:
	var unit := OS.get_environment("GLB")
	if unit == "":
		unit = "spear_skeleton"
	_clip = OS.get_environment("CLIP")
	if _clip == "":
		_clip = "idle"
	var t := OS.get_environment("T")
	_t = float(t) if t != "" else 0.0
	_out = OS.get_environment("OUT")
	if _out == "":
		_out = ProjectSettings.globalize_path("res://../work/analysis/glb_render.png")

	var scene: PackedScene = load("res://assets/models/%s.glb" % unit)
	inst = scene.instantiate()
	vp = SubViewport.new()
	vp.size = Vector2i(480, 480)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(vp)
	vp.add_child(inst)

func _setup_cam() -> void:
	var light := DirectionalLight3D.new()
	light.rotation = Vector3(-0.6, 0.3, 0.0)
	light.light_energy = 1.2
	vp.add_child(light)
	var cam := Camera3D.new()
	vp.add_child(cam)
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	var bounds := _mesh_bounds(inst)
	var c := bounds.get_center()
	cam.position = c + Vector3(0, 0, maxf(bounds.size.x, bounds.size.y) * 1.6 + 40.0)
	cam.look_at(c, Vector3.UP)
	cam.size = maxf(bounds.size.x, bounds.size.y) * 1.2 + 10.0
	var tex_path := OS.get_environment("TEX")
	if tex_path != "":
		var tex: Texture2D = load(tex_path)
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = tex
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		for mi: MeshInstance3D in _all_mi(inst):
			for s in mi.mesh.get_surface_count():
				mi.set_surface_override_material(s, mat)
	if _clip != "bind":
		var ap := _find(inst, "AnimationPlayer") as AnimationPlayer
		ap.play(_clip)
		ap.seek(_t, true)

func _mesh_bounds(n: Node) -> AABB:
	var out := AABB()
	var first := true
	for mi: MeshInstance3D in _all_mi(n):
		var b := mi.global_transform * mi.get_aabb()
		out = b if first else out.merge(b)
		first = false
	return out

func _all_mi(n: Node) -> Array:
	var out: Array = []
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_all_mi(c))
	return out

func _process(_dt: float) -> bool:
	_f += 1
	if _f == 2 and not _ready_done:
		_ready_done = true
		_setup_cam()
		return false
	if _f < 5:
		return false
	var img := vp.get_texture().get_image()
	img.save_png(_out)
	print("saved ", _out, " ", img.get_size())
	quit(0)
	return true
