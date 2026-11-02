extends SceneTree
## FINAL-06 Task 9 forensics for horseback_skeleton.glb skin binds.
##
## FINAL-05 switched GrannyActor3D._apply_skin_and_materials to name-resolved
## binds KEEPING the GLTF importer's inverse-bind poses (fixed spear/shield
## displacement) but QA reports the whole horseman renders UPSIDE DOWN, while
## the OLD rest-inverse rebuild (tools/render_units.gd:249, the baker) is
## reported to have kept the body upright with displaced gear. This tool:
##   1. dumps every skin bind vs the rest-derived inverse (determinant,
##      rotation angle, origin delta) so the mismatch is measured, and which
##      binds the Plane01 (spear) / bone_shield (shield) meshes use;
##   2. renders the model in four bind policies so the fix is picked by
##      pixels: importer (live path), restfix (old/baker path), hybrid
##      (per-bone validation), rootfix (importer binds + rest-inverse root).
##
## Run WINDOWED (3D SubViewport needs a real renderer):
##   Godot_v4.7.2-stable_win64.exe --path rebuild --script tools/diag_horseback_bind.gd
## env: GLB=<stem> (default horseback_skeleton), OUT_DIR=<abs dir>

const PX_PER_WORLD := 2.0

var glb := "horseback_skeleton"
var out_dir := ""
var inst: Node
var skel: Skeleton3D
var meshes: Array = []
var vp: SubViewport
var cam: Camera3D
var aabb := AABB()
var _f := 0
var _phase := -1  # index into _plan, -1 = not started
var _settle := 0  # frames to wait before the next capture
var _plan: Array = []  # [{mode, pose}] pose: "bind" | clip name
var _shots: Array = []  # [{key, image}]

func _find(n: Node, t: String) -> Node:
	if n.get_class() == t:
		return n
	for c in n.get_children():
		var r: Node = _find(c, t)
		if r != null:
			return r
	return null

func _all_mi(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_all_mi(c, out)

func _initialize() -> void:
	var e := OS.get_environment("GLB")
	if e != "":
		glb = e
	out_dir = OS.get_environment("OUT_DIR")
	if out_dir == "":
		out_dir = ProjectSettings.globalize_path("res://../work/tmp_final06")
	DirAccess.make_dir_recursive_absolute(out_dir)
	var scene: PackedScene = load("res://assets/models/%s.glb" % glb)
	inst = scene.instantiate()
	# NOT added to root here — _setup_viewport reparents it into the
	# SubViewport (a node can only have one parent)

func _det(b: Basis) -> float:
	return b.determinant()

func _angle_deg(a: Basis, b: Basis) -> float:
	## rotation angle between two orthonormal bases (trace formula)
	var rel := a * b.inverse()
	var tr := clampf((rel.x.x + rel.y.y + rel.z.z - 1.0) * 0.5, -1.0, 1.0)
	return rad_to_deg(acos(tr))

func _dump_binds() -> void:
	print("=== bone count: ", skel.get_bone_count())
	var ap := _find(inst, "AnimationPlayer") as AnimationPlayer
	print("=== clips: ", ap.get_animation_list() if ap != null else [])
	print("=== mesh nodes:")
	for m: MeshInstance3D in meshes:
		var used := {}
		if m.mesh != null:
			for s in m.mesh.get_surface_count():
				var arrays: Array = m.mesh.surface_get_arrays(s)
				if arrays[Mesh.ARRAY_BONES] != null:
					for bi in arrays[Mesh.ARRAY_BONES]:
						used[bi] = true
		var used_names: Array = []
		if m.skin != null:
			for bi: int in used.keys():
				if bi < m.skin.get_bind_count():
					used_names.append("%d:%s" % [bi, m.skin.get_bind_name(bi)])
		print("  node=", m.name, " surfaces=", m.mesh.get_surface_count() if m.mesh != null else 0,
			" binds=", m.skin.get_bind_count() if m.skin != null else 0,
			" surface_bones=", used_names)
	var src := _ref_skin()
	if src == null:
		print("!!! no skinned mesh — nothing to dump")
		return
	print("=== bind table: bindidx name | importer pose (det, origin) vs rest-inverse (det, origin) | delta")
	for i in src.get_bind_count():
		var bname := src.get_bind_name(i)
		var bone := skel.find_bone(bname)
		var bp: Transform3D = src.get_bind_pose(i)
		if bone < 0:
			print("  %2d %-22s NO BONE BY NAME (fallback idx)" % [i, bname])
			continue
		var rp: Transform3D = skel.get_bone_global_rest(bone).affine_inverse()
		var db := _det(bp.basis)
		var dr := _det(rp.basis)
		var ang := _angle_deg(bp.basis, rp.basis)
		var dov: float = (bp.origin - rp.origin).length()
		var tag := ""
		if absf(db - dr) > 0.01:
			tag = " DET-MISMATCH"
		elif ang > 90.0:
			tag = " FLIP"
		elif dov > 1.0:
			tag = " OFFSET"
		print("  %2d %-22s bone=%2d imp(det=%+.0f o=%7.1f,%7.1f,%7.1f) rest(det=%+.0f o=%7.1f,%7.1f,%7.1f) ang=%6.1f do=%6.1f%s" % [
			i, bname, bone, db, bp.origin.x, bp.origin.y, bp.origin.z,
			dr, rp.origin.x, rp.origin.y, rp.origin.z, ang, dov, tag])
	print("=== E_b = importer_bind * rest_global (the per-bone shear the node TRS dropped)")
	for i in src.get_bind_count():
		var bname := src.get_bind_name(i)
		var bone := skel.find_bone(bname)
		if bone < 0:
			continue
		var bp: Transform3D = src.get_bind_pose(i)
		var rest: Transform3D = skel.get_bone_global_rest(bone)
		var eb: Transform3D = bp * rest
		print("  %2d %-22s E.o=(%6.1f,%6.1f,%6.1f) E.xx=%5.2f E.xy=%5.2f E.xz=%5.2f | E.yx=%5.2f E.yy=%5.2f E.yz=%5.2f | E.zx=%5.2f E.zy=%5.2f E.zz=%5.2f" % [
			i, bname, eb.origin.x, eb.origin.y, eb.origin.z,
			eb.basis.x.x, eb.basis.x.y, eb.basis.x.z,
			eb.basis.y.x, eb.basis.y.y, eb.basis.y.z,
			eb.basis.z.x, eb.basis.z.y, eb.basis.z.z])

var _orig_names := PackedStringArray()
var _orig_poses: Array = []  # Transform3D per bind, snapshotted from the import
var _w_corr: Array = []      # per-bone W = S * inv(T) (engine-equation correction)
var _w_on := false           # engineq mode: rewrite bone global poses on update

func _ref_skin() -> Skin:
	for m: MeshInstance3D in meshes:
		if m.skin != null:
			return m.skin
	return null

func _snapshot_binds() -> void:
	var src := _ref_skin()
	if src == null:
		push_error("no skinned mesh found")
		return
	for i in src.get_bind_count():
		_orig_names.append(src.get_bind_name(i))
		_orig_poses.append(src.get_bind_pose(i))

func _compute_w() -> void:
	## W_b = S_b * inv(T_b): S_b = the authentic Granny bind world (inverse of
	## the importer's inverse-bind pose), T_b = Godot's rest global pose (node
	## TRS, shear dropped).  Left-multiplying the animated global poses by W
	## and skinning with the AUTHENTIC binds reproduces the engine composite
	## v = S * A * inv(S) * v (see _correct_poses).
	_w_corr.clear()
	for i in _orig_names.size():
		var bone := skel.find_bone(_orig_names[i])
		if bone < 0:
			_w_corr.append(Transform3D.IDENTITY)
			continue
		var s: Transform3D = _orig_poses[i].affine_inverse()
		var t: Transform3D = skel.get_bone_global_rest(bone)
		_w_corr.append(s * t.affine_inverse())
	if not skel.skeleton_updated.is_connected(_correct_poses):
		skel.skeleton_updated.connect(_correct_poses)

func _correct_poses() -> void:
	if not _w_on:
		return
	# pass 1: snapshot the ORIGINAL (uncorrected) global poses — children
	# must be corrected by W against their own original pose, not against an
	# already-corrected parent
	var orig: Array = []
	for i in skel.get_bone_count():
		orig.append(skel.get_bone_global_pose(i))
	# pass 2: write back parent-first (bone order is depth-first);
	# set_bone_global_pose derives the local pose from the parent's
	# ALREADY-corrected global, and the written value is exact
	for i in skel.get_bone_count():
		skel.set_bone_global_pose(i, _w_corr[i] * orig[i])

func _apply_skin(mode: String) -> void:
	## Rebuild every mesh's skin with the chosen bind policy (bone resolution
	## by NAME in all modes — that part is settled).
	for m: MeshInstance3D in meshes:
		if m.skin == null:
			continue
		var skin := Skin.new()
		if mode == "restfix":
			# old path / baker path (render_units.gd:249)
			for i in skel.get_bone_count():
				skin.add_bind(i, skel.get_bone_global_rest(i).affine_inverse())
				skin.set_bind_name(i, skel.get_bone_name(i))
				skin.set_bind_bone(i, i)
		else:
			for i in _orig_names.size():
				var bname := _orig_names[i]
				var bone := skel.find_bone(bname)
				if bone < 0:
					bone = i
				var pose: Transform3D = _orig_poses[i]
				if mode == "hybrid":
					# per-bone validation: importer pose where it agrees with
					# the rest-derived inverse (same det, < 90 deg), else rest
					var rp: Transform3D = skel.get_bone_global_rest(bone).affine_inverse()
					if absf(_det(pose.basis) - _det(rp.basis)) > 0.01 \
							or _angle_deg(pose.basis, rp.basis) > 90.0:
						pose = rp
				elif mode == "rootfix" and i == 0:
					pose = skel.get_bone_global_rest(bone).affine_inverse()
				skin.add_bind(bone, pose)
				skin.set_bind_name(i, bname)
		m.skin = skin
	print("[diag] skin mode -> ", mode)

func _setup_viewport() -> void:
	var side: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://assets/models/%s.aabb.json" % glb))
	var mn: Array = side["min"]
	var mx: Array = side["max"]
	aabb = AABB(Vector3(float(mn[0]), float(mn[1]), float(mn[2])),
		Vector3(float(mx[0]) - float(mn[0]), float(mx[1]) - float(mn[1]),
			float(mx[2]) - float(mn[2])))
	vp = SubViewport.new()
	vp.transparent_bg = true
	vp.own_world_3d = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	var w := int(ceil(aabb.size.x * PX_PER_WORLD)) + 8
	var h := int(ceil(aabb.size.y * PX_PER_WORLD)) + 8
	vp.size = Vector2i(w, h)
	root.add_child(vp)
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.size = aabb.size.y + 4.0 / PX_PER_WORLD
	cam.position = Vector3(aabb.get_center().x, aabb.get_center().y, aabb.end.z + 5.0)
	vp.add_child(cam)
	var sun := DirectionalLight3D.new()  # no-op on unshaded materials
	sun.rotation_degrees = Vector3(-45, 30, 0)
	vp.add_child(sun)
	vp.add_child(inst)
	var tex: Texture2D = load("res://assets/units/%s.png" % glb)
	for m: MeshInstance3D in meshes:
		if m.mesh == null:
			continue
		for s in m.mesh.get_surface_count():
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_texture = tex
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			mat.alpha_scissor_threshold = 0.5
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.set_surface_override_material(s, mat)
	_snapshot_binds()

func _skinned_report(tag: String) -> void:
	## Numerically skin every surface with the CURRENT skin + bone poses and
	## print the AABB plus the hoof/head/lance landmarks (seat evidence).
	var mn := Vector3(INF, INF, INF)
	var mx := Vector3(-INF, -INF, -INF)
	var lance_mn := Vector3(INF, INF, INF)
	var lance_mx := Vector3(-INF, -INF, -INF)
	for m: MeshInstance3D in meshes:
		if m.skin == null or m.mesh == null:
			continue
		var skin := m.skin
		for s in m.mesh.get_surface_count():
			var arrays: Array = m.mesh.surface_get_arrays(s)
			var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			if verts.is_empty() or arrays[Mesh.ARRAY_BONES] == null:
				continue
			var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
			var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
			var smn := Vector3(INF, INF, INF)
			var smx := Vector3(-INF, -INF, -INF)
			var is_lance := false
			for v in verts.size():
				var pos := Vector3.ZERO
				for k in 4:
					if weights.size() <= v * 4 + k or weights[v * 4 + k] <= 0.0:
						continue
					var bi := bones[v * 4 + k]
					if bi >= skin.get_bind_count():
						continue
					var bone := skin.get_bind_bone(bi)
					if bone < 0:
						bone = bi
					var g: Transform3D = skel.get_bone_global_pose(bone)
					pos += (g * skin.get_bind_pose(bi)) * verts[v] * weights[v * 4 + k]
					if skin.get_bind_name(bi) == "Plane01":
						is_lance = true
				smn = smn.min(pos)
				smx = smx.max(pos)
			mn = mn.min(smn)
			mx = mx.max(smx)
			if is_lance:
				lance_mn = lance_mn.min(smn)
				lance_mx = lance_mx.max(smx)
	print("[diag] AABB %-14s %-8s all=(%.0f..%.0f, %.0f..%.0f) lance=(%.0f..%.0f, %.0f..%.0f)" % [
		tag, str(_plan[_phase]["pose"]) if _phase < _plan.size() else "?",
		mn.x, mx.x, mn.y, mx.y, lance_mn.x, lance_mx.x, lance_mn.y, lance_mx.y])

func _compose(key: String, img: Image) -> void:
	_shots.append({"key": key, "img": img})
	print("[diag] rendered ", key, " ", img.get_size())

func _save_all() -> void:
	# vertical stack of every shot, labelled by order in the log
	if _shots.is_empty():
		return
	var w := 0
	var h := 0
	for s: Dictionary in _shots:
		var im: Image = s["img"]
		w = maxi(w, im.get_width())
		h += im.get_height() + 4
	var canvas := Image.create(w, h, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0.16, 0.16, 0.22, 1.0))
	var y := 0
	for s: Dictionary in _shots:
		var im2: Image = s["img"]
		canvas.blit_rect(im2, Rect2i(Vector2i.ZERO, im2.get_size()), Vector2i(0, y))
		y += im2.get_height() + 4
	var path := "%s/%s_bind_politics.png" % [out_dir, glb]
	canvas.save_png(path)
	print("[diag] saved ", path, " ", canvas.get_size())

func _enter_phase(i: int) -> void:
	_phase = i
	_settle = 3  # frames for the skin rebuild + viewport redraw to land
	var step: Dictionary = _plan[i]
	_apply_skin(str(step["mode"]))
	_w_on = str(step["mode"]) == "engineq"
	if _w_on:
		_compute_w()
	# global-mirror candidates: importer binds with the MODEL ROOT flipped
	# (yflip: scale (1,-1,1); zrot: rotated 180 deg about Z)
	inst.scale = Vector3(1, -1, 1) if str(step["mode"]) == "yflip" \
		else Vector3.ONE
	inst.rotation = Vector3(0, 0, PI) if str(step["mode"]) == "zrot" \
		else Vector3.ZERO
	var ap := _find(inst, "AnimationPlayer") as AnimationPlayer
	if str(step["pose"]) == "bind":
		ap.stop()
		if ap.has_animation("RESET"):
			ap.play("RESET")
			ap.seek(0.0, true)
	else:
		ap.play(str(step["pose"]))
		ap.seek(0.0, true)
	if str(step["pose"]) == "attack_a":
		ap.seek(0.45, true)  # mid-thrust

func _process(_dt: float) -> bool:
	_f += 1
	if _f == 2:
		skel = _find(inst, "Skeleton3D") as Skeleton3D
		_all_mi(inst, meshes)
		_dump_binds()
		_setup_viewport()
		var ap := _find(inst, "AnimationPlayer") as AnimationPlayer
		var walk := "walk" if ap != null and ap.has_animation("walk") else ""
		var atk := "attack_a" if ap != null and ap.has_animation("attack_a") else ""
		for mode in ["importer", "restfix", "yflip", "zrot"]:
			_plan.append({"mode": mode, "pose": "bind"})
			if walk != "":
				_plan.append({"mode": mode, "pose": "walk"})
		# the thrust is the art-verification pose for the winning candidate
		if atk != "":
			_plan.append({"mode": "yflip", "pose": "attack_a"})
			_plan.append({"mode": "restfix", "pose": "attack_a"})
		_enter_phase(0)
		return false
	if _phase < 0:
		return false
	_settle -= 1
	if _settle > 0:
		return false
	var step: Dictionary = _plan[_phase]
	_skinned_report(str(step["mode"]))
	var img := vp.get_texture().get_image()
	_compose("%s_%s" % [step["mode"], step["pose"]], img)
	if _phase + 1 >= _plan.size():
		_save_all()
		quit(0)
		return true
	_enter_phase(_phase + 1)
	return false
