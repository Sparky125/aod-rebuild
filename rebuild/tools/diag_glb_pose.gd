extends SceneTree
## Play a clip at t=0 on a staged GLB and dump Skeleton3D bone global poses,
## to diff Godot's interpretation against Python/Granny runtime composition.
## Run: Godot_console --path rebuild --script tools/diag_glb_pose.gd  (env: GLB=<unit>, CLIP=<clip>)

func _find(n: Node, t: String) -> Node:
	if n.get_class() == t:
		return n
	for c in n.get_children():
		var r: Node = _find(c, t)
		if r != null:
			return r
	return null

var inst: Node
var _f := 0

func _initialize() -> void:
	var unit := OS.get_environment("GLB")
	if unit == "":
		unit = "spear_skeleton"
	var clip := OS.get_environment("CLIP")
	if clip == "":
		clip = "idle"
	var scene: PackedScene = load("res://assets/models/%s.glb" % unit)
	inst = scene.instantiate()
	root.add_child(inst)
	var ap := _find(inst, "AnimationPlayer") as AnimationPlayer
	print("clips: ", ap.get_animation_list())
	ap.play(clip)
	ap.seek(0.0, true)
	print("playing '", ap.current_animation, "' pos=", ap.current_animation_position)

func _process(_dt: float) -> bool:
	_f += 1
	if _f < 3:
		return false
	var skel := _find(inst, "Skeleton3D") as Skeleton3D
	print("bones=", skel.get_bone_count())
	for i in skel.get_bone_count():
		var gp: Transform3D = skel.get_bone_global_pose(i)
		var b: Transform3D = skel.get_bone_pose(i)
		print("bone %2d %-20s global=(%7.2f,%7.2f,%6.2f) local_t=(%6.2f,%6.2f,%6.2f)" % [
			i, skel.get_bone_name(i), gp.origin.x, gp.origin.y, gp.origin.z,
			b.origin.x, b.origin.y, b.origin.z])
	quit(0)
	return true
