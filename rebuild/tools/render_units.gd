extends SceneTree
## Bakes every converted unit model into 2D animation strips.
##
## Run WINDOWED (3D SubViewports need a real GPU context):
##   Godot_console.exe --path rebuild --script tools/render_units.gd
##
## For each assets/models/<unit>.glb: instantiates the model in an offscreen
## SubViewport, binds assets/units/<unit>.png as the albedo for every surface,
## then renders the bind pose + every AnimationPlayer clip frame-by-frame into
## horizontal strip PNGs (assets/unit_frames/<unit>/<clip>.png, 2x world scale,
## feet at bottom-center) and writes data/unit_anims.json for the game.

const FPS := 18.0
const SS := 2.0          # supersample: strip pixels per world unit
const MAX_FRAMES := 48   # cap per clip (walk loops only need one cycle)
const MARGIN := 6.0      # px of headroom around the union AABB
const MAX_STRIP_W := 16384  # GPU texture cap — clips wider wrap into rows

var tasks: Array = []    # [{unit, clip(null=bind), frames, t}]
var current := -1
var vp: SubViewport
var cam: Camera3D
var model: Node3D
var model_unit := ""
var canvas: Image
var out_meta := {}
# merge into the existing meta so partial re-bakes (ONLY=...) never drop
# units baked in earlier runs
var _prev_meta_path := ProjectSettings.globalize_path("res://data/unit_anims.json")
var _need_redraw := false
var _root: Node
# item attachment tables (work/tools/extract_attachments.py)
var _attach: Dictionary = {}
var _item_meshes: Dictionary = {}   # obj name -> ArrayMesh (parsed lazily)

func _initialize() -> void:
	_root = root
	if FileAccess.file_exists("res://data/unit_anims.json"):
		var prev: Variant = JSON.parse_string(
			FileAccess.get_file_as_string("res://data/unit_anims.json"))
		if prev is Dictionary:
			out_meta = prev
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://assets/unit_frames"))
	var dir := DirAccess.open("res://assets/models")
	if dir == null:
		push_error("no assets/models — run stage_units.py first")
		quit(1)
		return
	var units: Array = []
	for f in dir.get_files():
		if f.ends_with(".glb"):
			units.append(f.get_basename())
	units.sort()
	# ONLY=<unit> bakes one GLB; ONLY=<unit>__<suffix> bakes that GLB's stem
	# plus exactly one virtual variant (T35: ONLY=ash__saw -> ash + ash__saw)
	var only := OS.get_environment("ONLY")
	var only_vkey := ""
	if only.contains("__"):
		only_vkey = only
		only = only.split("__")[0]
	if only != "":
		units = units.filter(func(u): return u.contains(only))
	# item attachments (data/attachments.json) + level->variant table
	var att: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/attachments.json"))
	if att is Dictionary:
		_attach = att
	# bake list: glb-backed keys first, then item-only variants (same glb,
	# different attached props, e.g. spear_skeleton__he1..he4)
	var bake_list: Array = []
	for u in units:
		bake_list.append({"key": u, "glb": u})
	if FileAccess.file_exists("res://data/unit_variants.json"):
		var variants: Variant = JSON.parse_string(
			FileAccess.get_file_as_string("res://data/unit_variants.json"))
		if variants is Dictionary:
			for uname: String in variants:
				var vkeys: Dictionary = variants[uname].get("variants", {})
				for vkey: String in vkeys:
					# T42: ONLY=<unit>__<variant>__nohead bakes the helmet-less
					# twin of exactly that variant
					var nh_key := vkey + "__nohead"
					var only_plain := only_vkey == "" or only_vkey == vkey
					var only_nohead := only_vkey == "" or only_vkey == nh_key
					if not only_plain and not only_nohead:
						continue
					if vkey == uname or units.has(vkey):
						continue
					if not _attach.has(vkey):
						continue  # nothing attached -> no new bake needed
					var src := vkey if units.has(vkey) else uname
					if not units.has(src):
						continue
					if only_plain:
						bake_list.append({"key": vkey, "glb": src})
						print("virtual variant ", vkey, " from glb ", src)
					if only_nohead and _attach_has_slot(vkey, "helmet"):
						bake_list.append({"key": nh_key, "glb": src, "nohead": true})
						print("virtual variant ", nh_key, " from glb ", src)
	for b: Dictionary in bake_list:
		var u: String = b["key"]
		var tex_path := "res://assets/units/%s.png" % u
		if not FileAccess.file_exists(tex_path):
			tex_path = "res://assets/units/%s.png" % b["glb"]
		if not FileAccess.file_exists(tex_path):
			print("skip (no atlas): ", u)
			continue
		var scene: PackedScene = load("res://assets/models/%s.glb" % b["glb"])
		if scene == null:
			print("skip (glb load failed): ", u)
			continue
		var inst: Node3D = scene.instantiate()
		var ap: AnimationPlayer = _find_anim_player(inst)
		var clips: Array = []
		if ap != null:
			for c in ap.get_animation_list():
				if not c.begins_with("RESET"):
					clips.append(c)
		var aabb := _merged_aabb(inst)
		out_meta[u] = {"atlas": tex_path, "clips": {}}
		tasks.append({"unit": u, "glb": b["glb"], "inst": inst, "clips": clips, "aabb": aabb})
		print("queued ", u, " clips=", clips, " aabb=", aabb)
	print("total units: ", tasks.size())

	vp = SubViewport.new()
	vp.size = Vector2i(64, 64)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.own_world_3d = true
	_root.add_child(vp)
	cam = Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.current = true
	vp.add_child(cam)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, 30, 0)
	vp.add_child(sun)

func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r: AnimationPlayer = _find_anim_player(c)
		if r != null:
			return r
	return null

func _find_meshes(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_find_meshes(c, out)

func _merged_aabb(n: Node3D) -> AABB:
	var meshes: Array = []
	_find_meshes(n, meshes)
	var total := AABB()
	var first := true
	for m: MeshInstance3D in meshes:
		var xf := m.global_transform if m.is_inside_tree() else _rel_xform(n, m)
		var ab := xf * m.get_aabb()
		if first:
			total = ab
			first = false
		else:
			total = total.merge(ab)
	return total

func _rel_xform(root: Node, n: Node3D) -> Transform3D:
	var xf := Transform3D.IDENTITY
	var chain: Array = []
	var walk: Node = n
	while walk != null and walk != root:
		chain.push_front(walk)
		walk = walk.get_parent()
	for step in chain:
		if step is Node3D:
			xf = xf * (step as Node3D).transform
	return xf

func _bind_textures(n: Node, tex: Texture2D) -> void:
	var meshes: Array = []
	_find_meshes(n, meshes)
	var skel: Skeleton3D = _find_skeleton(n)
	var mi: MeshInstance3D = null
	for m: MeshInstance3D in meshes:
		mi = m
	for m: MeshInstance3D in meshes:
		for i in m.mesh.get_surface_count():
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_texture = tex
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
			mat.alpha_scissor_threshold = 0.5
			mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
			mat.cull_mode = BaseMaterial3D.CULL_DISABLED
			m.set_surface_override_material(i, mat)
	# Godot's GLTF importer leaves every skin bind with bone=-1 and the
	# renderer then falls back to bind index == bone index; models whose
	# Granny bone order is not depth-first get inverse binds from the WRONG
	# bones and the paper doll explodes.  Rebuild the binds from the
	# skeleton's own global rests so bind i provably belongs to bone i.
	# Godot's GLTF importer leaves every skin bind with bone=-1 and the
	# renderer then falls back to bind index == bone index; models whose
	# Granny bone order is not depth-first get inverse binds from the WRONG
	# bones and the paper doll explodes.  Rebuild the binds from the
	# skeleton's own global rests so bind i provably belongs to bone i.
	if OS.get_environment("SKINSTRIP") != "" and mi != null:
		# static render of the raw vertex soup: strip bones/weights so no
		# skinning transform applies at all
		var am := ArrayMesh.new()
		var src_mi: MeshInstance3D = null
		for m: MeshInstance3D in meshes:
			src_mi = m
			for i in m.mesh.get_surface_count():
				var arrays: Array = m.mesh.surface_get_arrays(i)
				arrays[Mesh.ARRAY_BONES] = null
				arrays[Mesh.ARRAY_WEIGHTS] = null
				am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
				var mat2 := StandardMaterial3D.new()
				mat2.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
				mat2.albedo_texture = tex
				mat2.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				mat2.alpha_scissor_threshold = 0.5
				mat2.cull_mode = BaseMaterial3D.CULL_DISABLED
				am.surface_set_material(i, mat2)
		var parent := src_mi.get_parent()
		for m: MeshInstance3D in meshes:
			m.get_parent().remove_child(m)
		mi = null
		var mi2 := MeshInstance3D.new()
		mi2.name = "StaticSoup"
		mi2.mesh = am
		parent.add_child(mi2)
		print("  skinstrip: static soup with ", am.get_surface_count(), " surfaces")
		var src_arrays: Array = src_mi.mesh.surface_get_arrays(0)
		var sv: PackedVector3Array = src_arrays[Mesh.ARRAY_VERTEX]
		var si: PackedInt32Array = src_arrays[Mesh.ARRAY_INDEX]
		print("  surface0 verts=", sv.size())
		for vi in sv.size():
			print("    v", vi, "=", sv[vi])
		print("  surface0 indices=", si)
		print("  mesh aabb=", src_mi.get_aabb())
		return
	if OS.get_environment("SKINFIX") != "" and skel != null and mi != null:
		var skin := Skin.new()
		for i in skel.get_bone_count():
			skin.add_bind(i, skel.get_bone_global_rest(i).affine_inverse())
			skin.set_bind_name(i, skel.get_bone_name(i))
			skin.set_bind_bone(i, i)
		mi.skin = skin
		print("  skinfix: rebound ", skel.get_bone_count(), " binds")

func _attach_has_slot(key: String, slot: String) -> bool:
	for a: Dictionary in _attach[key].get("attach", []):
		if str(a.get("slot")) == slot:
			return true
	return false

func _attach_items(model: Node3D, key: String, skip_helmet := false) -> float:
	## Pin equipped item quads to the skeleton (util.lua):
	##   weapon->bone_weapon z+4, secondary->bone_secondary_weapon z+4,
	##   helmet->bone_head z+5, shield->bone_shield z+6, scale (s,s,1).
	## OBJ vertices are authored in the attach bone's local frame (same Y-up
	## Max space as the gr2 — no remap). Returns the max item radius so the
	## caller can grow the frame AABB.
	## skip_helmet (T42 __nohead): the head slot is the unit's skull — skip it
	## so the twin bakes read headless.
	var spec: Dictionary = _attach[key]
	var skel := _find_skeleton(model)
	if skel == null:
		print("  ! no skeleton for items: ", key)
		return 0.0
	var grow := float(spec.get("grow", 0.0))
	for a: Dictionary in spec.get("attach", []):
		if skip_helmet and str(a.get("slot")) == "helmet":
			print("  nohead: skipping helmet ", a["obj"], " (", a.get("tex"), ")")
			continue
		var bone: String = str(a["bone"])
		if skel.find_bone(bone) < 0:
			print("  ! ", key, ": bone missing: ", bone)
			continue
		var mesh := _load_item_mesh(str(a["obj"]))
		if mesh == null:
			continue
		var ba := BoneAttachment3D.new()
		ba.bone_name = bone
		skel.add_child(ba)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		var s: float = float(a.get("scale", 1.0))
		mi.scale = Vector3(s, s, 1.0)
		mi.position = Vector3(0.0, 0.0, float(a.get("z", 4.0)))
		var mat := StandardMaterial3D.new()
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mat.albedo_texture = load("res://assets/items/%s.png" % str(a["tex"]))
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.5
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
		mi.material_override = mat
		ba.add_child(mi)
		print("  attach ", key, ": ", a["obj"], " on ", bone, " z+", a.get("z", 4.0))
	return grow

func _load_item_mesh(obj_name: String) -> ArrayMesh:
	## Minimal OBJ (v/vt/f) parser — the game's item props are 1-3 quads.
	## 3ds Max UVs are V-up like the body atlases -> flip V unless
	## NOVFLIP is set (verified flag for experiments).
	if _item_meshes.has(obj_name):
		return _item_meshes[obj_name]
	var path := "res://assets/items/%s.obj" % obj_name
	var txt := FileAccess.get_file_as_string(path)
	if txt.is_empty():
		print("  ! item obj missing: ", path)
		return null
	var flip := OS.get_environment("NOVFLIP") == ""
	var vpos := PackedVector3Array()
	var vuv := PackedVector2Array()
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var uniq := {}
	for line: String in txt.split("\n"):
		var p := line.strip_edges().split(" ", false)
		if p.size() == 0:
			continue
		if p[0] == "v" and p.size() >= 4:
			vpos.append(Vector3(p[1].to_float(), p[2].to_float(), p[3].to_float()))
		elif p[0] == "vt" and p.size() >= 3:
			var v := p[2].to_float()
			vuv.append(Vector2(p[1].to_float(), 1.0 - v if flip else v))
		elif p[0] == "f" and p.size() >= 4:
			var fi := PackedInt32Array()
			for tok: String in p.slice(1):
				var c := tok.split("/")
				if c[0].is_empty():
					continue
				var vi := int(c[0]) - 1
				var ti := vi
				if c.size() > 1 and not c[1].is_empty():
					ti = int(c[1]) - 1
				var k := vi * 1000000 + ti
				if not uniq.has(k):
					uniq[k] = verts.size()
					verts.append(vpos[vi])
					uvs.append(vuv[ti] if ti >= 0 and ti < vuv.size() else Vector2.ZERO)
				fi.append(int(uniq[k]))
			for k2 in range(1, fi.size() - 1):
				idx.append(fi[0])
				idx.append(fi[k2])
				idx.append(fi[k2 + 1])
	if idx.is_empty():
		print("  ! item obj parsed empty: ", path)
		return null
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_item_meshes[obj_name] = am
	return am

func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null

func _start_task(t: Dictionary) -> void:
	model_unit = t.unit
	model = t.inst
	# The converted GLBs are already Y-up (height on +Y, paper-doll layers on
	# -Z); ROTX/ROTY env vars exist only for one-off axis experiments.
	var rot := Vector3(deg_to_rad(float(OS.get_environment("ROTX"))), 		deg_to_rad(float(OS.get_environment("ROTY"))), 0.0)
	model.rotation = rot
	vp.add_child(model)
	_bind_textures(model, load(out_meta[t.unit]["atlas"]))
	# attach equipped items (weapons/helmets/shields) to the skeleton bones —
	# AFTER _bind_textures so the unit atlas only touches body meshes.
	# __nohead keys attach the SOURCE variant's items minus the helmet (T42).
	# Derived from the key (not the task dict — _initialize rebuilds tasks and
	# would drop a flag field).
	var nohead: bool = str(t.unit).ends_with("__nohead")
	var src_key := str(t.unit).trim_suffix("__nohead")
	var grow := 0.0
	if _attach.has(t.unit):
		grow = _attach_items(model, t.unit)
	elif _attach.has(src_key):
		grow = _attach_items(model, src_key, nohead)
	# Frame size: prefer the converter's union AABB (bind + every sampled
	# clip frame, so attack swings / death falls never clip) over the static
	# bind AABB.
	var src: AABB = t.aabb
	var side_path := "res://assets/models/%s.aabb.json" % str(t.get("glb", t.unit))
	if FileAccess.file_exists(side_path):
		var side: Variant = JSON.parse_string(FileAccess.get_file_as_string(side_path))
		if side is Dictionary and side.has("min"):
			var mn: Array = side["min"]
			var mx: Array = side["max"]
			src = AABB(Vector3(float(mn[0]), float(mn[1]), float(mn[2])),
					Vector3(float(mx[0]) - float(mn[0]), float(mx[1]) - float(mn[1]),
						float(mx[2]) - float(mn[2])))
			print("  using union aabb ", src)
	# attached items extend past the body AABB by their max bone-local radius
	# (symmetric grow keeps the baked anchor center unchanged)
	if grow > 0.0:
		src = src.grow(grow)
		print("  item grow ", grow, " -> ", src)
	# T42: the __nohead twin REUSES the whole variant's aabb/frame exactly so
	# the in-game anchor (AABB center) and scale are identical — swapping the
	# bake mid-fight never rescales or shifts the body
	if nohead and out_meta.has(src_key) and out_meta[src_key].has("aabb"):
		var na: Dictionary = out_meta[src_key]["aabb"]
		var napos: Array = na["pos"]
		var nasize: Array = na["size"]
		src = AABB(Vector3(float(napos[0]), float(napos[1]), float(napos[2])),
			Vector3(float(nasize[0]), float(nasize[1]), float(nasize[2])))
		print("  nohead: reusing ", src_key, " aabb ", src)
	# transform the AABB corners by the same rotation
	var basis := Basis.from_euler(rot)
	var a := AABB(basis * src.position, Vector3.ZERO)
	for cx in 2:
		for cy in 2:
			for cz in 2:
				var corner := src.position + Vector3(
					src.size.x * float(cx), src.size.y * float(cy), src.size.z * float(cz))
				a = a.expand(basis * corner)
	t.raabb = a
	var h := (a.size.y * SS) + MARGIN * 2.0
	var w := maxf(a.size.x * SS + MARGIN * 2.0, 8.0)
	w = ceilf(w)
	h = ceilf(h)
	vp.size = Vector2i(int(w), int(h))
	# SS pixels per world unit: the viewport covers h/SS world units.
	cam.size = h / SS
	# center the AABB in frame; camera looks down -Z
	cam.position = Vector3(a.get_center().x, a.get_center().y, a.size.z + 5.0)
	out_meta[t.unit]["frame_w"] = int(w)
	out_meta[t.unit]["frame_h"] = int(h)
	out_meta[t.unit]["fps"] = FPS
	out_meta[t.unit]["ss"] = SS
	out_meta[t.unit]["aabb"] = {"pos": [a.position.x, a.position.y, a.position.z],
		"size": [a.size.x, a.size.y, a.size.z]}
	var plan: Array = [{"clip": "" if OS.get_environment("SKIP_ANIMS") != "" else ("idle" if "idle" in t.clips else ""), "frames": 1}]
	if OS.get_environment("SKIP_ANIMS") != "":
		t["plan"] = plan
		t["pi"] = -1
		_next_clip(t)
		return
	for c: String in t.clips:
		if nohead and c == "die":
			# T42: the die clip stays WHOLE — unit.gd binds the original
			# variant's die frames onto the headless set, so don't bake one
			continue
		var ap := _find_anim_player(model)
		var length: float = ap.get_animation(c).length
		var n := clampi(int(ceil(length * FPS)), 2, MAX_FRAMES)
		plan.append({"clip": c, "frames": n})
	t["plan"] = plan
	t["pi"] = -1
	_next_clip(t)

func _next_clip(t: Dictionary) -> void:
	t.pi += 1
	if t.pi >= t.plan.size():
		_finish_task(t)
		return
	var p: Dictionary = t.plan[t.pi]
	t.frame = 0
	t.frames = p.frames
	var ap := _find_anim_player(model)
	if p.clip == "":
		pass  # untouched rest pose renders the bind correctly
	else:
		ap.play(p.clip)
		ap.seek(0.0, true)
	var dir := ProjectSettings.globalize_path("res://assets/unit_frames/%s" % model_unit)
	DirAccess.make_dir_recursive_absolute(dir)
	var cname2: String = str(p.clip)
	var fname: String = ((cname2 if cname2 != "" else "bind") + ".png")
	# clips longer than the GPU texture cap wrap into a grid of rows
	t.cols = mini(t.frames, maxi(1, int(MAX_STRIP_W / int(vp.size.x))))
	t.rows = int(ceil(float(t.frames) / float(t.cols)))
	canvas = Image.create(int(vp.size.x) * t.cols, int(vp.size.y) * t.rows, false, Image.FORMAT_RGBA8)
	t.img_path = dir + "/" + fname
	t.clip_name = p.clip
	_need_redraw = true

func _capture(t: Dictionary) -> void:
	var img := vp.get_texture().get_image()
	if img != null and img.is_invisible():
		# silent blank captures have burned two sessions (stale GLB import,
		# viewport that never drew the resized frame) — make them loud
		print("  WARNING: ", model_unit, "/", t.clip_name, " frame ", t.frame, " captured fully transparent")
	canvas.blit_rect(img, Rect2i(Vector2i.ZERO, img.get_size()),
		Vector2i((t.frame % t.cols) * int(vp.size.x),
			(t.frame / t.cols) * int(vp.size.y)))
	t.frame += 1
	if t.frame >= t.frames:
		canvas.save_png(t.img_path)
		var cname: String = t.clip_name if t.clip_name != "" else "bind"
		out_meta[model_unit]["clips"][cname] = {
			"file": "res://assets/unit_frames/%s/%s" % [model_unit, cname + ".png"],
			"frames": t.frames, "fps": FPS, "cols": t.cols}
		print("  baked ", model_unit, "/", cname, " x", t.frames)
		_next_clip(t)
	else:
		var ap := _find_anim_player(model)
		var p: Dictionary = t.plan[t.pi]
		if p.clip != "":
			ap.seek(float(t.frame) / FPS, true)
		_need_redraw = true

func _finish_task(t: Dictionary) -> void:
	if model.is_inside_tree():
		vp.remove_child(model)
	model.queue_free()
	current += 1
	if current >= tasks.size():
		var path := ProjectSettings.globalize_path("res://data/unit_anims.json")
		var f := FileAccess.open(path, FileAccess.WRITE)
		f.store_string(JSON.stringify(out_meta, "  "))
		f.close()
		print("done -> ", path)
		quit(0)
		return
	_start_task(tasks[current])

func _process(_delta: float) -> bool:
	if current >= tasks.size():
		if tasks.size() == 0:
			return true
		return false
	if current == -1:
		current = 0
		_start_task(tasks[0])
		return false
	var t: Dictionary = tasks[current]
	if _need_redraw:
		_need_redraw = false
		return false  # give the viewport a frame to draw the new pose
	_capture(t)
	return false
