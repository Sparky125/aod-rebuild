extends SceneTree
## Probe Godot's import of a GLB: compare bone global rests vs skin binds and
## evaluate mesh vertices the way Godot skinning does.
## Run: Godot_console --path rebuild --script tools/diag_glb_skin.gd  (env: GLB=<name>)

func _find(n: Node, t: String) -> Node:
	if n.get_class() == t:
		return n
	for c in n.get_children():
		var r: Node = _find(c, t)
		if r != null:
			return r
	return null

func _spread(verts: PackedVector3Array) -> Vector3:
	var mn: Vector3 = verts[0]
	var mx: Vector3 = verts[0]
	for v in verts:
		mn = mn.min(v)
		mx = mx.max(v)
	return mx - mn

var _frames := 0
var inst: Node

func _initialize() -> void:
	var unit := OS.get_environment("GLB")
	if unit == "":
		unit = "sword_skeleton"
	var scene: PackedScene = load("res://assets/models/%s.glb" % unit)
	inst = scene.instantiate()
	root.add_child(inst)

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	var skel: Skeleton3D = _find(inst, "Skeleton3D") as Skeleton3D
	var mi := _find(inst, "MeshInstance3D") as MeshInstance3D
	print("skeleton bones=", skel.get_bone_count())
	for i in skel.get_bone_count():
		var gp: Transform3D = skel.get_bone_global_pose(i)
		print("  bone %2d %-18s parent=%2d global_pos=(%.2f, %.2f, %.2f)" % [
			i, skel.get_bone_name(i), skel.get_bone_parent(i),
			gp.origin.x, gp.origin.y, gp.origin.z])
	print("mesh_instance.skeleton=", mi.skeleton, " skin=", mi.skin)
	if mi.skin != null:
		for b in mini(mi.skin.get_bind_count(), 20):
			var pb: Transform3D = mi.skin.get_bind_pose(b)
			print("  skin bind %2d bone=%d name=%s ibm_origin=(%.2f,%.2f,%.2f)" % [
				b, mi.skin.get_bind_bone(b), mi.skin.get_bind_name(b), pb.origin.x, pb.origin.y, pb.origin.z])
	var mesh: Mesh = mi.mesh
	for s in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var bones: PackedInt32Array = PackedInt32Array()
		var weights: PackedFloat32Array = PackedFloat32Array()
		if arrays[Mesh.ARRAY_BONES] != null:
			bones = arrays[Mesh.ARRAY_BONES]
		if arrays[Mesh.ARRAY_WEIGHTS] != null:
			weights = arrays[Mesh.ARRAY_WEIGHTS]
		var mn := Vector3(INF, INF, INF)
		var mx := Vector3(-INF, -INF, -INF)
		for v in verts.size():
			var pos := Vector3.ZERO
			for k in 4:
				var w := 0.0
				if weights.size() > v * 4 + k:
					w = weights[v * 4 + k]
				if w <= 0.0:
					continue
				var bone := bones[v * 4 + k]
				var bind_xf: Transform3D = mi.skin.get_bind_pose(bone)
				var sk: Transform3D = skel.get_bone_global_pose(bone)
				pos += (sk * bind_xf) * verts[v] * w
			mn = mn.min(pos)
			mx = mx.max(pos)
		print("surface %d: raw spread=%s skinned spread=%s" % [s, _spread(verts), str(mx - mn)])
	quit(0)
	return true
