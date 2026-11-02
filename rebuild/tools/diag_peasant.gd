extends SceneTree
## Diagnostic: render peasant GLB (untouched rest) and OBJ bind mesh.

var vp: SubViewport
var cam: Camera3D
var step := 0
var models: Array = []

func _initialize() -> void:
	vp = SubViewport.new()
	vp.size = Vector2i(320, 480)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = true
	root.add_child(vp)
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.size = 70.0
	vp.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	vp.add_child(sun)

	var tex: Texture2D = load("res://assets/units/peasant.png")
	# A: unshaded white, no texture
	var a: Node3D = (load("res://assets/models/peasant.glb") as PackedScene).instantiate()
	a.position = Vector3(-45, 0, 0)
	vp.add_child(a)
	_bind_all(a, tex, false)
	# B: unshaded + atlas texture
	var b: Node3D = (load("res://assets/models/peasant.glb") as PackedScene).instantiate()
	b.position = Vector3(0, 0, 0)
	vp.add_child(b)
	_bind_all(b, tex, true)
	# C: imported material, albedo_texture set on it
	var c: Node3D = (load("res://assets/models/peasant.glb") as PackedScene).instantiate()
	c.position = Vector3(45, 0, 0)
	vp.add_child(c)
	var mc: Array = []
	_find(c, mc)
	for m: MeshInstance3D in mc:
		for i in m.mesh.get_surface_count():
			var mat := m.get_active_material(i) as BaseMaterial3D
			if mat == null:
				mat = StandardMaterial3D.new()
			mat = mat.duplicate()
			mat.albedo_texture = tex
			m.set_surface_override_material(i, mat)
	models.append(a)
	models.append(b)
	models.append(c)
	var meshes: Array = []
	_find(b, meshes)
	print("GLB meshes: ", meshes.size())
	var sk := _find_skel(b)
	if sk != null:
		print("bones=", sk.get_bone_count())
		for i in mini(sk.get_bone_count(), 6):
			print("  bone %d '%s' rest_pos=%s rest_rot=%s" % [i, sk.get_bone_name(i),
				sk.get_bone_rest(i).origin, sk.get_bone_rest(i).basis.get_rotation_quaternion()])
	pass

func _bind_all(n: Node, tex: Texture2D, textured: bool) -> void:
	var meshes: Array = []
	_find(n, meshes)
	for m: MeshInstance3D in meshes:
		for i in m.mesh.get_surface_count():
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			if textured:
				mat.albedo_texture = tex
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.set_surface_override_material(i, mat)

func _find(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_find(c, out)

func _find_anim(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim(c)
		if r != null:
			return r
	return null

func _find_skel(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r := _find_skel(c)
		if r != null:
			return r
	return null

func _process(_d: float) -> bool:
	step += 1
	if step == 2:
		var sk2 := _find_skel(models[0])
		var ap2: AnimationPlayer = _find_anim(models[0])
		print("anims: ", ap2.get_animation_list())
		ap2.play("idle")
		ap2.seek(0.5, true)
		print("torso pose@0.5: pos=", sk2.get_bone_global_pose(1).origin, " rot=", sk2.get_bone_global_pose(1).basis.get_rotation_quaternion())
		print("torso rest:      pos=", sk2.get_bone_global_rest(1).origin, " rot=", sk2.get_bone_global_rest(1).basis.get_rotation_quaternion())
	if step == 4:
		var img := vp.get_texture().get_image()
		img.save_png(ProjectSettings.globalize_path("res://assets/unit_frames/diag_glb_rest.png"))
		print("saved diag_glb_rest.png")
		quit(0)
	return false
