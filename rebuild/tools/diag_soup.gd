extends SceneTree
## Dump ALL surface vertex data of the imported archer GLB.

func _find(n: Node, t: String) -> Node:
	if n.get_class() == t:
		return n
	for c in n.get_children():
		var r: Node = _find(c, t)
		if r != null:
			return r
	return null

var _frames := 0
var inst: Node

func _initialize() -> void:
	var scene: PackedScene = load("res://assets/models/archer.glb")
	inst = scene.instantiate()
	root.add_child(inst)

func _process(_dt: float) -> bool:
	_frames += 1
	if _frames < 2:
		return false
	var mi := _find(inst, "MeshInstance3D") as MeshInstance3D
	var mesh: Mesh = mi.mesh
	for s in mesh.get_surface_count():
		var arrays: Array = mesh.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var mn := Vector3(INF, INF, INF)
		var mx := Vector3(-INF, -INF, -INF)
		for v in verts:
			mn = mn.min(v)
			mx = mx.max(v)
		print("surface %d verts=%d min=%s max=%s" % [s, verts.size(), mn, mx])
		var bones: PackedInt32Array = PackedInt32Array()
		if arrays[Mesh.ARRAY_BONES] != null:
			bones = arrays[Mesh.ARRAY_BONES]
		var bset := {}
		for b in bones:
			bset[b] = true
		print("   bones=", bset.keys())
	quit(0)
	return true
