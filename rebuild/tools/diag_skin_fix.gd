extends SceneTree
## Try fixing an exploded model by rebuilding its Skin binds in Godot:
## bind i = inverse of Skeleton3D's own global rest for bone i. Bakes the bind
## pose to work/analysis/<unit>_skinfix.png for visual confirmation.

var _frames := 0
var inst: Node
var unit := ""

func _find(n: Node, t: String) -> Node:
	if n.get_class() == t:
		return n
	for c in n.get_children():
		var r: Node = _find(c, t)
		if r != null:
			return r
	return null

func _initialize() -> void:
	unit = OS.get_environment("GLB")
	if unit == "":
		unit = "sword_skeleton"
	var scene: PackedScene = load("res://assets/models/%s.glb" % unit)
	inst = scene.instantiate()
	root.add_child(inst)

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames != 2:
		return false
	var skel: Skeleton3D = _find(inst, "Skeleton3D") as Skeleton3D
	var mi := _find(inst, "MeshInstance3D") as MeshInstance3D
	var skin := Skin.new()
	for i in skel.get_bone_count():
		skin.add_bind(i, skel.get_bone_global_rest(i).affine_inverse())
		skin.set_bind_name(i, skel.get_bone_name(i))
		skin.set_bind_bone(i, i)
	mi.skin = skin
	print("rebound ", skel.get_bone_count(), " bones")
	# render into an offscreen viewport
	var vp := SubViewport.new()
	vp.size = Vector2i(200, 200)
	vp.transparent_bg = true
	vp.own_world_3d = true
	root.add_child(vp)
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	vp.add_child(cam)
	var aabb: AABB = _find(inst, "MeshInstance3D").get_aabb()
	print("aabb=", aabb)
	cam.size = maxf(aabb.size.y, aabb.size.x) * 1.2
	cam.position = Vector3(aabb.get_center().x, aabb.get_center().y, 50)
	var sun := DirectionalLight3D.new()
	vp.add_child(sun)
	await root.get_tree().process_frame
	await root.get_tree().process_frame
	var img := vp.get_texture().get_image()
	var out1: String = ProjectSettings.globalize_path("res://..") + "/work/analysis/%s_skinfix.png" % unit
	img.save_png(out1)
	print("saved ", out1, " err")
	var big: Image = img.duplicate()
	big.resize(400, 400, Image.INTERPOLATE_NEAREST)
	var out2: String = ProjectSettings.globalize_path("res://..") + "/work/analysis/%s_skinfix_big.png" % unit
	big.save_png(out2)
	print("saved ", out2)
	print("saved work/analysis/%s_skinfix.png" % unit)
	quit(0)
	return true
