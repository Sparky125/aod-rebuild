class_name GrannyActor3D
extends Node2D
## Live 3D paper-doll from a staged .glb: skin-bind rebuild by name, per-mesh z bias, ortho SubViewport mapped to 2D as (p.x, -p.y) * 1/PX_PER_WORLD, feet on the node origin.

const PX_PER_WORLD := 2.0   # the engine's texture convention: 2 px per world unit
const Z_SQUASH := 0.001     # util.lua:877 render_actor.scale z (paper-doll flatten)

const MODEL_RENAMES := {
	"skeleton_warrior": "sword_skeleton",
	"skeleton_spearman": "spear_skeleton",
	"skeleton_archer": "crossbow_skeleton",
	"skeleton_knight": "horseback_skeleton",
	"skeleton_siege_shield": "shield_skeleton",
	"duke_henry": "henry",
	"wise_man": "wiseman",
	"blacksmith": "smithy",
	"mini_ashes": "mini_ash",
	"heavy_swordsman": "armored_guard",
	"catapult": "catapults",
	"evil_book": "flying_book",
	"knight": "horseman",
	"sword_boy": "swordboy",
	"torch_boy": "torchboy",
}

const SLOT_DEFAULTS := {
	"weapon": {"bone": "bone_weapon", "z": 4.0},
	"secondary_weapon": {"bone": "bone_secondary_weapon", "z": 4.0},
	"helmet": {"bone": "bone_head", "z": 5.0},
	"shield": {"bone": "bone_shield", "z": 6.0},
	"tie": {"bone": "bone_tie", "z": 2.0},
}

# staged glbs whose bones carry Granny Y-mirror ScaleShears (audited across all 38) — they render upside down without the global model-root Y-mirror; prefix match covers the per-level variant twins.
const Y_MIRROR_MODELS := ["horseback_skeleton", "dryad", "evil_ash"]

# soft-alpha smoke fx: the baker's ALPHA_SCISSOR @ 0.5 discards their feathering (poof renders EMPTY) — these use alpha-blend materials instead (see _make_item_material).
const SPELL_FX_MODELS := ["vortex_book", "magic_words", "poof"]

static var _scene_cache: Dictionary = {}   # glb stem -> PackedScene
static var _mesh_cache: Dictionary = {}    # obj name -> ArrayMesh

var glb_stem := ""
var _model: Node3D
var _skeleton: Skeleton3D
var _anim: AnimationPlayer
var _root: Node2D                # facing mirror wrapper
var _container: SubViewportContainer
var _vp: SubViewport
var _slots: Dictionary = {}      # slot -> {bone, obj, tex, node}
var _frame_aabb := AABB()

static func clear_caches() -> void:
	_scene_cache.clear()
	_mesh_cache.clear()

static func glb_stem_for_model(model_uri: String) -> String:
	var leaf := model_uri.get_file()
	if leaf.ends_with(".gr2"):
		leaf = leaf.trim_suffix(".gr2")
	if MODEL_RENAMES.has(leaf):
		leaf = MODEL_RENAMES[leaf]
	return leaf

static func _is_y_mirror_model(stem: String) -> bool:
	## prefix-matched so per-level variant twins ("<stem>__<variant>") get the same correction.
	for m: String in Y_MIRROR_MODELS:
		if stem == m or stem.begins_with(m + "__"):
			return true
	return false

static func _is_spell_fx_model(stem: String) -> bool:
	for m: String in SPELL_FX_MODELS:
		if stem == m or stem.begins_with(m + "__"):
			return true
	return false

static func supports_model(model_uri: String) -> bool:
	## true only for staged .glb models on a real renderer — headless falls back to sprites.
	if DisplayServer.get_name() == "headless":
		return false
	if not model_uri.ends_with(".gr2"):
		return false
	# evil_book is a billboard quad — the sprite animator must render it.
	if model_uri.ends_with("evil_book.gr2"):
		return false
	return ResourceLoader.exists("res://assets/models/%s.glb" % glb_stem_for_model(model_uri))

static func variant_glb_exists(variant_key: String) -> bool:
	## true when a per-level variant key has its own staged .glb + frame AABB — the 3D body swaps model AND part atlas.
	return variant_key != "" \
		and ResourceLoader.exists("res://assets/models/%s.glb" % variant_key) \
		and FileAccess.file_exists("res://assets/models/%s.aabb.json" % variant_key)

static func load_item_mesh(obj_name: String) -> ArrayMesh:
	if _mesh_cache.has(obj_name):
		return _mesh_cache[obj_name]
	var txt := FileAccess.get_file_as_string("res://assets/items/%s.obj.txt" % obj_name)
	if txt.is_empty():
		return null
	var vpos := PackedVector3Array()
	var vuv := PackedVector2Array()
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	var uniq := {}
	for line: String in txt.split("\n"):
		var p := line.strip_edges().split(" ", false)
		if p.is_empty():
			continue
		if p[0] == "v" and p.size() >= 4:
			vpos.append(Vector3(p[1].to_float(), p[2].to_float(), p[3].to_float()))
		elif p[0] == "vt" and p.size() >= 3:
			vuv.append(Vector2(p[1].to_float(), 1.0 - p[2].to_float()))  # V flip
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
		return null
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = idx
	var am := ArrayMesh.new()
	am.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	_mesh_cache[obj_name] = am
	return am

static func _make_item_material(tex: Texture2D, spell_fx := false) -> StandardMaterial3D:
	## spell_fx swaps ALPHA_SCISSOR for true alpha-blend (the fx atlases carry wide soft-alpha skirts scissor shreds — poof renders empty); DEPTH_DRAW_OPAQUE_ONLY keeps the paper-doll planes depth-sorting while blended.
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = tex
	if spell_fx:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_OPAQUE_ONLY
	else:
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.5
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	return mat

func _find_skeleton(n: Node) -> Skeleton3D:
	if n is Skeleton3D:
		return n
	for c in n.get_children():
		var r := _find_skeleton(c)
		if r != null:
			return r
	return null

func _find_anim_player(n: Node) -> AnimationPlayer:
	if n is AnimationPlayer:
		return n
	for c in n.get_children():
		var r := _find_anim_player(c)
		if r != null:
			return r
	return null

func _find_meshes(n: Node, out: Array) -> void:
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		_find_meshes(c, out)

func setup(model_uri: String, tex: Texture2D, stem_override := "") -> bool:
	## returns false when the model/aabb is unavailable so the caller can fall back to sprites; stem_override swaps to a per-level variant glb stem.
	glb_stem = glb_stem_for_model(model_uri)
	if stem_override != "" and variant_glb_exists(stem_override):
		glb_stem = stem_override
	var scene_path := "res://assets/models/%s.glb" % glb_stem
	if not ResourceLoader.exists(scene_path) or tex == null:
		return false
	var packed: PackedScene = _scene_cache.get_or_add(glb_stem, load(scene_path))
	var aabb_path := "res://assets/models/%s.aabb.json" % glb_stem
	if not FileAccess.file_exists(aabb_path):
		return false
	var side: Variant = JSON.parse_string(FileAccess.get_file_as_string(aabb_path))
	if not (side is Dictionary) or not (side as Dictionary).has("min"):
		return false
	var mn: Array = side["min"]
	var mx: Array = side["max"]
	_frame_aabb = AABB(Vector3(float(mn[0]), float(mn[1]), float(mn[2])),
		Vector3(float(mx[0]) - float(mn[0]), float(mx[1]) - float(mn[1]),
			float(mx[2]) - float(mn[2])))
	# grow the frame by the baker's item-radius margin (attachments.json "grow") so equipped items stay in frame.
	var grow := 0.0
	var attach: Variant = JSON.parse_string(
		FileAccess.get_file_as_string("res://data/attachments.json"))
	if attach is Dictionary:
		for k: String in (attach as Dictionary):
			if k == glb_stem or k.begins_with(glb_stem + "__"):
				grow = maxf(grow, float((attach as Dictionary)[k].get("grow", 0.0)))
	if grow > 0.0:
		_frame_aabb = _frame_aabb.grow(grow)

	_model = (packed as PackedScene).instantiate()
	_skeleton = _find_skeleton(_model)
	_anim = _find_anim_player(_model)
	_apply_skin_and_materials(tex)

	_root = Node2D.new()
	add_child(_root)
	_vp = SubViewport.new()
	_vp.transparent_bg = true
	_vp.own_world_3d = true
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.size = Vector2i(maxi(1, ceili(_frame_aabb.size.x * PX_PER_WORLD)),
		maxi(1, ceili(_frame_aabb.size.y * PX_PER_WORLD)))
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	cam.keep_aspect = Camera3D.KEEP_HEIGHT
	cam.size = _frame_aabb.size.y
	# camera looks down -Z; the container at (x_min, -y_max) scale 1/PX_PER_WORLD maps model point p to local (p.x, -p.y).
	cam.position = Vector3(_frame_aabb.get_center().x, _frame_aabb.get_center().y,
		_frame_aabb.end.z + 5.0)
	_vp.add_child(cam)
	var sun := DirectionalLight3D.new()  # no-op on unshaded materials; kept for parity
	sun.rotation_degrees = Vector3(-45, 30, 0)
	_vp.add_child(sun)
	_vp.add_child(_model)
	_container = SubViewportContainer.new()
	_container.position = Vector2(_frame_aabb.position.x, -_frame_aabb.end.y)
	_container.scale = Vector2.ONE / PX_PER_WORLD
	_container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_container.add_child(_vp)
	_root.add_child(_container)
	return true

func _apply_skin_and_materials(tex: Texture2D) -> void:
	var meshes: Array = []
	_find_meshes(_model, meshes)
	for m: MeshInstance3D in meshes:
		if m.mesh == null:
			continue
		var fx_mat := _make_item_material(tex, _is_spell_fx_model(glb_stem))
		for i in m.mesh.get_surface_count():
			m.set_surface_override_material(i, fx_mat)
		# engine z-bias: translate the mesh along its own local Z by half its bbox depth, through the engine's z-squash.
		var ab := m.get_aabb()
		m.position.z += (ab.position.z + ab.end.z) * 0.5 * Z_SQUASH
	# the staged binds carry Y-mirror shears the glTF quaternions dropped — the assembled doll renders upside down; the measured fix is one GLOBAL model-root Y-mirror (frame AABB mirrored to match).
	if _is_y_mirror_model(glb_stem):
		_model.scale = Vector3(1.0, -1.0, 1.0)
		_frame_aabb.position.y = -_frame_aabb.end.y
	# Godot's GLTF importer leaves every skin bind bone=-1 (the index fallback reads wrong bones and the doll explodes) — rebuild binds by NAME but KEEP the original inverse-bind poses; substituting rest inverses displaced baked quads.
	if _skeleton != null:
		for m: MeshInstance3D in meshes:
			if m.skin == null:
				continue
			var src := m.skin
			var skin := Skin.new()
			for i in src.get_bind_count():
				var bname := src.get_bind_name(i)
				var bone := _skeleton.find_bone(bname)
				if bone < 0:
					bone = i  # unnamed bind: keep the index==bind fallback
				skin.add_bind(bone, src.get_bind_pose(i))
				skin.set_bind_name(i, bname)
			m.skin = skin

func set_facing_flip(flip: bool) -> void:
	if _root != null:
		_root.scale.x = -1.0 if flip else 1.0

# ------------------------------------------------------------- animation API

func has_clip(clip_name: String) -> bool:
	return _anim != null and _anim.has_animation(clip_name)

func get_clip_length(clip_name: String) -> float:
	if _anim == null or not _anim.has_animation(clip_name):
		return 0.0
	return _anim.get_animation(clip_name).length

func play_clip(clip_name: String, loop := false, blend := 0.15) -> bool:
	## gr2 clips import without a loop flag — `loop` forces LOOP_LINEAR; returns false when the clip is missing.
	if _anim == null or not _anim.has_animation(clip_name):
		return false
	var anim_res := _anim.get_animation(clip_name)
	anim_res.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	if _anim.current_animation == clip_name and _anim.is_playing():
		return true
	_anim.play(clip_name, blend)
	return true

func current_clip() -> String:
	return _anim.current_animation if _anim != null else ""

func anim_clock() -> float:
	## -1.0 when nothing plays: the LOOP_NONE gap before a finished clip's re-play must read as a distinct state, never 0.
	return _anim.current_animation_position \
		if _anim != null and _anim.is_playing() else -1.0

var _dbg_once := false

func _process(_dt: float) -> void:
	if not _dbg_once and _anim != null:
		_dbg_once = true
		print("[g3d] %s anim=%s playing=%s pos=%.2f len=%.2f bones=%d" % [
			glb_stem, _anim.current_animation, _anim.is_playing(),
			_anim.current_animation_position,
			get_clip_length(_anim.current_animation),
			_skeleton.get_bone_count() if _skeleton != null else -1])

# -------------------------------------------------------------- equipment

func equip_slot(slot: String, bone_name: String, obj_name: String, tex_name: String,
		z_offset: float, item_scale := 1.0) -> bool:
	unequip_slot(slot)
	if _skeleton == null or _model == null:
		return false
	var bone_idx := _skeleton.find_bone(bone_name)
	if bone_idx < 0:
		print("[attach] FAIL no bone %s on %s" % [bone_name, glb_stem])
		return false
	var mesh := load_item_mesh(obj_name)
	if mesh == null:
		print("[attach] FAIL no mesh %s" % obj_name)
		return false
	var tex_path := "res://assets/items/%s.webp" % tex_name
	if not ResourceLoader.exists(tex_path):
		print("[attach] FAIL no tex %s" % tex_path)
		return false
	var ba := BoneAttachment3D.new()
	ba.bone_name = bone_name
	_skeleton.add_child(ba)
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	# the model-root Y-flip does NOT reach BoneAttachment3D children (bone poses carry no mirror sign) — flip the item quad's Y; re-seat off-center art so the flip pivots on its own center (mirroring about y=0 maps [y0,y1] to [-y1,-y0]; adding scale*(y0+y1) restores it).
	var flip_item := _is_y_mirror_model(glb_stem)
	mi.scale = Vector3(item_scale, -item_scale if flip_item else item_scale, 1.0)
	mi.position = Vector3(0.0, 0.0, z_offset)
	var ab := mesh.get_aabb()
	if flip_item and absf(ab.position.y + ab.end.y) > 0.001:
		mi.position.y = item_scale * (ab.position.y + ab.end.y)
	# horseback bone_shield mounts at the rider's NECK — drop 15 glb units so the shield clears his head.
	if slot == "shield" and glb_stem.begins_with("horseback_skeleton"):
		mi.position.y += 15.0
	# probe: --shieldy=<glb units> nudges the shield further (screenshot aid)
	if slot == "shield" and Dbg.args.has("shieldy"):
		mi.position.y += float(str(Dbg.args["shieldy"]))
	mi.material_override = _make_item_material(load(tex_path))
	ba.add_child(mi)
	_slots[slot] = {"bone": bone_name, "obj": obj_name, "tex": tex_name, "node": mi}
	print("[attach] %s slot=%s obj=%s tex=%s bone=%s idx=%d" % [
		glb_stem, slot, obj_name, tex_name, bone_name, bone_idx])
	return true

func unequip_slot(slot: String) -> Dictionary:
	var info: Dictionary = _slots.get(slot, {})
	if info.has("node") and is_instance_valid(info["node"]):
		(info["node"].get_parent() as Node).queue_free()
	_slots.erase(slot)
	return info

func attach_sprite_to_bone(bone_name: String, tex: Texture2D, z_offset: float,
		world_per_px := 1.0 / PX_PER_WORLD) -> Sprite3D:
	## Sprite3D riding the bone's live pose inside the SubViewport; null when the model has no such bone (caller falls back to a flat sprite).
	if _skeleton == null or tex == null or _skeleton.find_bone(bone_name) < 0:
		return null
	var ba := BoneAttachment3D.new()
	ba.bone_name = bone_name
	_skeleton.add_child(ba)
	var spr := Sprite3D.new()
	spr.texture = tex
	spr.pixel_size = world_per_px
	spr.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	spr.shaded = false
	# the tie hangs by its TOP: its center sits half a height below the bone.
	spr.position = Vector3(0.0, -tex.get_height() * world_per_px * 0.5, z_offset)
	ba.add_child(spr)
	return spr

func has_slot(slot: String) -> bool:
	return _slots.has(slot)

func slot_world_pos(slot: String) -> Vector2:
	if not _slots.has(slot):
		return Vector2.INF
	var mi: MeshInstance3D = _slots[slot]["node"]
	if mi == null or not is_instance_valid(mi):
		return Vector2.INF
	var p := mi.global_transform.origin
	var local := Vector2(p.x, -p.y)
	if _root != null and _root.scale.x < 0.0:
		local.x = -local.x
	return to_global(local)

func slot_texture(slot: String) -> String:
	return str(_slots.get(slot, {}).get("tex", ""))
