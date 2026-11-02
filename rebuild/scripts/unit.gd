class_name Unit
extends Node2D

signal died(unit: Unit)
signal damaged(unit: Unit, amount: int)

enum Team { ALLY, ENEMY }

enum State { WALK_IN, COMBAT, DEAD }

const MELEE := "melee"

const CORPSE_HOLD := 0.7
const CORPSE_FADE := 0.5

# "strike" text-track timestamps per [glb_stem][clip_name]; missing entries keep the instant hit (delay 0)
const STRIKE_TIMES := {
	"ash": {"attack_a": 0.333, "attack_b": 0.300, "attack_c": 0.333, "cast": 0.433},
	"smithy": {"attack_a": 0.600, "hammertime": 0.333},
	"catapults": {"attack_a": 0.133},
	"arthur": {"attack_a": 0.467, "attack_b": 0.433},
	"henry": {"attack_a": 0.467, "attack_b": 0.533},
	"evil_ash": {"attack_a": 0.700, "attack_b": 0.433},
	"evil_sheila": {"attack_a": 0.467, "attack_b": 0.733},
	"flying_book": {"attack_a": 0.333, "attack_b": 0.067},
	"armored_guard": {"attack_a": 0.700, "attack_b": 0.433},
	"horseman": {"attack_a": 0.500, "attack_b": 0.533},
	"horseback_skeleton": {"attack_a": 0.500, "attack_b": 0.533},
	"mini_ash": {"attack_a": 0.500, "attack_b": 0.467},
	"peasant": {"attack_a": 0.167, "attack_b": 0.433},
	"pit_monster": {"attack_a": 0.500, "attack_b": 0.500},
	"crossbow_skeleton": {"attack_a": 0.033},
	"spear_skeleton": {"attack_a": 0.367, "attack_b": 0.433},
	"sword_skeleton": {"attack_a": 0.400, "attack_b": 0.367},
	"spearman": {"attack_a": 0.467, "attack_b": 0.567},
	"swordsman": {"attack_a": 0.233, "attack_b": 0.300},
	"dryad": {"attack_a": 0.567, "attack_b": 0.567},
	"wiseman": {"attack_a": 0.567, "attack_ab": 0.567, "attack_b": 0.567},
	"witch": {"attack_a": 0.367, "attack_b": 0.367},
	"archer": {"attack_a": 1.367},
	"vortex_book": {"idle": 0.667},
}

var main: Node2D
var unit_type := ""
var debris_key := ""  # bake key for T38 debris lookup (data/debris.json)
var shed_parts: Array[String] = []  # T43: parts already knocked off this body
var damaged_head := false  # T42: swapped to the __nohead bake
var level := 1
var team := Team.ALLY
var is_hero := false
var is_gate := false
var is_wall_archer := false
var is_catapult := false
var is_prop := false  # background NPC (blacksmith): no health bar

var max_health := 1.0
var health := 1.0
var speed := 50.0
var body_scale := 1.0
var height := 60.0
var regen_rate := 0.0
var can_be_knocked_back := true

# KnockbackOrder ballistic hop (gravity 500, solved to land on dest at T); distance 0 is a stun-only hold (pit / vortex / magic words)
var stumble_time := 0.0    # order time remaining (stun OR knockback flight)
var knock_flying := false  # signedDist != 0: the per-frame arc integration runs
var knock_vx := 0.0        # X velocity = signedDist / T (C++ order +0x24)
var knock_vy := 0.0        # Y-down launch velocity (dest - y)/T - 250*T (+0x28)
var knock_dest_x := 0.0    # clamped landing x (C++ order +0x10)
var knock_dest_y := 0.0    # landing ground line y (C++ order +0x14)

var weapon_name := ""
var weapon_range := 0.0
var weapon_min_range := 0.0
var splash_range := 0.0
var attack_damage := 0
var attack_interval := 1.0
var attack_cooldown := 0.0
var is_ranged := false
var ammo_name := ""

# Ash's melee slot: the gun/melee switch threshold is the melee weapon's own range -- the engine compare is unrecoverable
var melee_weapon_name := ""
var melee_range := 0.0
var melee_splash := 0.0
var melee_damage := 0
var melee_interval := 1.0
var melee_knockback := 0.0
var _active_melee := false  # which weapon the pending/current attack uses

var walk_in_x := 0.0
var lane_offset := 0.0  # depth lane applied on top of the terrain line
var last_hit_by: Unit = null  # attacker of the final damage packet (kill credit)
var state := State.WALK_IN
var target: Unit = null
var _retarget_t := 0.0  # allyunit/enemyunit getClosestObjectToAttack re-poll (0.2 s)
var facing := 1.0
var ai_enabled := true  # --sandbox: false -> pose only; never think, move, or attack
var anim_lock := ""     # --sandbox: pinned clip name (state machine stands down)

var anim: AnimatedSprite2D  # baked paper-doll sprites (null -> stick figure)
var actor3d: GrannyActor3D  # live .glb paper doll (ARCH-01; null -> sprite path)
var _body_atlas_key := ""   # atlas key feeding the current body (baked-item check)
var _anim_ground := Vector2.ZERO  # baked AABB center: anchors model y=0 to the unit origin
var _authored_facing := 1.0  # direction the baked art faces (data/model_facing.json)
var _attack_anim_pending := 0.0
# pending swings land when the clip reaches its "strike" key -- cleared by death or knockback (either clears the unit's orders)
var _strikes_pending: Array = []  # [{t, melee, ranged, target}]

var equipped_slots: Dictionary = {}  # slot -> {name, tex, obj} (GP-02 pop-off data)
var is_healer := false               # wiseman.lua: never damages; heals via negative damage
var helper_kind := ""                # torch_sword_boy.lua: sword/torch/flute
var _previous_patients: Dictionary = {}  # wiseman.lua m_previous_patients (heal dedup)
var _previous_victims: Dictionary = {}   # torch_sword_boy.lua m_previous_victims
var _scan_t := 0.0                   # the 0.2 s process cadence of torch_sword_boy.lua
var _note_t := 5.0                   # flute/drummer note loop (LoopAction 5.0)
var is_moving := false               # movement this frame (wiseman.lua orders:isMoving)
var _walk_paused := false            # evil_ash.lua scheduled stops
var _stop_timer := 0.0
var _stops_left := 0
var _buff_factor := 1.0              # PartWeapon damage buff (spec Q2)
var _buff_source: Unit = null
var _buff_sprite: Sprite2D = null

static func _anim_meta(type_name: String) -> Dictionary:
	return DB.load_json("res://data/unit_anims.json").get(type_name, {})

func _variant_type() -> String:
	var table: Dictionary = DB.load_json("res://data/unit_variants.json").get(unit_type, {})
	if not table.is_empty():
		var lvls: Dictionary = table.get("levels", {})
		var key: Variant = lvls.get(str(level), lvls.get(str(clampi(level, 1, max(1, lvls.size())))))
		if key != null and DB.load_json("res://data/unit_anims.json").has(str(key)):
			return str(key)
	var uri := str(DB.get_stat("units", unit_type, "texture", level))
	if uri.begins_with("texture/"):
		var cand := unit_type + "__" + uri.rsplit("/", 1)[-1]
		if DB.load_json("res://data/unit_anims.json").has(cand):
			return cand
	return unit_type

static func _facing_meta(type_name: String) -> float:
	var table: Variant = DB.load_json("res://data/model_facing.json").get("authored", {})
	var v: Variant = table.get(type_name, 1)
	return float(v) if v != null else 1.0

var _flash_time := 0.0
var burn_dps := 0.0
var burn_left := 0.0
var _burn_acc := 0.0
var burn_source: Unit
var _flame: AnimatedSprite2D  # enflamed effect: engulfing fire while burning

func ignite(dps: float, src: Unit) -> void:
	if state == State.DEAD or dps <= 0.0:
		return
	if DB.entry("units", unit_type).get("flammable", true) == false:
		return
	burn_dps = maxf(burn_dps, dps)
	burn_left = 3.0
	burn_source = src

func _spawn_flame() -> void:
	var tex: Texture2D = load("res://assets/map/fire_sprite.webp")
	if tex == null:
		return
	var frames := SpriteFrames.new()
	frames.set_animation_speed("default", 15.0)
	frames.set_animation_loop("default", true)
		# frame 0 is the TOP-left cell -- bottom-row-first order played the loop mirrored vertically
	for i in range(8):
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(float(i % 4) * 32.0, (0.0 if i < 4 else 64.0), 32.0, 64.0)
		frames.add_frame("default", at)
	_flame = AnimatedSprite2D.new()
	_flame.sprite_frames = frames
	var h := height * body_scale
	var base_pos := Vector2(0.0, -h * 0.45)
	var base_scale := Vector2.ONE * clampf(h / 36.0, 1.2, 3.5)
	_flame.position = base_pos
	_flame.scale = Vector2.ZERO  # LuaBaseUnit:95 m_enflamed_effect.scale = (0,0,1)
	_flame.z_index = 1  # over the body: flames engulf it
	_flame.modulate.a = 0.85
	_flame.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(_flame)
	_flame.play("default")
	var peak_scale := Vector2(base_scale.x * 1.25, base_scale.y * 1.75)
	var tw := _flame.create_tween()
	tw.set_loops()
	tw.set_parallel(true)
	tw.tween_property(_flame, "scale", peak_scale, 0.5) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)  # Ramp
	tw.tween_property(_flame, "position:y", base_pos.y - 20.0, 0.25) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)  # MoveOffset +20 up
	tw.chain().set_parallel(true)
	tw.tween_property(_flame, "scale", base_scale, 0.5) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)  # Fall
	tw.tween_property(_flame, "position:y", base_pos.y, 0.5) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)  # MoveOffset -20
var _attack_anim_time := 0.0

static func create(game: Node2D, type_name: String, lvl: int, team_: Team) -> Unit:
	var u := Unit.new()
	u.main = game
	u.unit_type = type_name
	u.level = lvl
	u.team = team_
	u._load_stats()
	return u

# GDScript `or` yields a bool: null-check Variants explicitly, never `v or default`
func _stat_f(cat: String, stat: String, lvl: int, def: float, type_name := "") -> float:
	var v: Variant = DB.get_stat(cat, type_name if type_name != "" else unit_type, stat, lvl)
	return float(v) if v != null else def

func _stat_s(cat: String, stat: String, lvl: int, type_name := "") -> String:
	var v: Variant = DB.get_stat(cat, type_name if type_name != "" else unit_type, stat, lvl)
	return str(v) if v != null else ""

func _load_stats() -> void:
	max_health = _stat_f("units", "health", level, 1.0)
	health = max_health
	speed = _stat_f("units", "speed", level, 0.0)
	body_scale = _stat_f("units", "scale", level, 1.0)
	height = _stat_f("units", "height", level, 60.0)
	regen_rate = _stat_f("units", "regen_rate", level, 0.0)
	var kb: Variant = DB.entry("units", unit_type).get("can_be_knocked_back")
	can_be_knocked_back = true if kb == null else bool(kb)
	_load_weapon(str(DB.entry("units", unit_type).get("weapon", "")))
	var script := str(DB.entry("units", unit_type).get("script", ""))
	if script == "torch_sword_boy":
		if unit_type.contains("torch"):
			helper_kind = "torch"
		elif unit_type.contains("sword"):
			helper_kind = "sword"
		elif unit_type.contains("flute") or unit_type.contains("drummer"):
			helper_kind = "flute"
	var target_ally: bool = DB.get_stat("weapons", weapon_name, "target_ally", level) == true
	var ammo_dmg := 0.0
	if ammo_name != "":
		ammo_dmg = _stat_f("ammo", "damage", level, 0.0, ammo_name)
	is_healer = script == "wiseman" or (target_ally and ammo_dmg < 0.0)

func _load_weapon(wname: String) -> void:
	weapon_name = wname
	weapon_range = _stat_f("weapons", "range", level, 0.0, weapon_name)
	weapon_min_range = _stat_f("weapons", "min_range", level, 0.0, weapon_name)
	splash_range = _stat_f("weapons", "splash_range", level, 0.0, weapon_name)
	attack_interval = _stat_f("weapons", "reload_delay", level, 1.0, weapon_name)
	ammo_name = _stat_s("weapons", "ammo", level, weapon_name)
	if ammo_name != "":
		is_ranged = true
		attack_damage = int(_stat_f("ammo", "damage", level, 0.0, ammo_name))
	else:
		is_ranged = weapon_range > 0.0  # hitscan guns (boomstick) have no ammo actor
		attack_damage = int(_stat_f("weapons", "damage", level, 0.0, weapon_name))

func equip_weapon(wname: String) -> void:
	_load_weapon(wname)

func equip_melee(wname: String) -> void:
	melee_weapon_name = wname
	melee_range = _stat_f("weapons", "range", level, 0.0, wname)
	melee_splash = _stat_f("weapons", "splash_range", level, 0.0, wname)
	melee_damage = int(_stat_f("weapons", "damage", level, 0.0, wname))
	melee_interval = _stat_f("weapons", "reload_delay", level, 1.0, wname)
	melee_knockback = _stat_f("weapons", "knockback_multiplier", level, 0.0, wname)
	if actor3d != null:
		_load_equipment()
		return
	if anim != null:
		var old := anim
		anim = null
		remove_child(old)
		old.queue_free()
		_setup_body()

func _ready() -> void:
	add_to_group("units")
	if team == Team.ENEMY:
		facing = -1.0
	if unit_type == "evil_ash":
		_stop_timer = 5.0
		_stops_left = 5
	_setup_body()

func _swap_to_headless() -> void:
	## head-off swap to the variant's __nohead twin bake (same frame size/aabb); the die clip stays WHOLE so the corpse collapses intact
	if anim == null or damaged_head or debris_key == "":
		return
	var meta := _anim_meta(debris_key + "__nohead")
	if meta.is_empty() or not ResourceLoader.exists(str(meta.get("atlas", ""))):
		return
	var nf := SpriteFrames.new()
	var fw := maxi(int(meta.get("frame_w", 1)), 1)
	var fh := maxi(int(meta.get("frame_h", 1)), 1)
	var ss: float = float(meta.get("ss", 2.0))
	for clip: String in meta.get("clips", {}).keys():
		_add_clip_frames(nf, clip, meta["clips"][clip], fw, fh)
	# die stays whole: copy the original variant's die clip (its own frame size)
	var whole := _anim_meta(debris_key)
	var dinfo: Dictionary = whole.get("clips", {}).get("die", {})
	if not dinfo.is_empty():
		_add_clip_frames(nf, "die", dinfo,
			maxi(int(whole.get("frame_w", 1)), 1), maxi(int(whole.get("frame_h", 1)), 1))
	if nf.get_animation_names().is_empty():
		return
	var cur := anim.animation
	var fr := anim.frame
	anim.sprite_frames = nf
	if nf.has_animation(cur):
		anim.play(cur)
		anim.frame = clampi(fr, 0, nf.get_frame_count(cur) - 1)
	else:
		anim.play(_idle_clip_name())
	damaged_head = true
	if main != null and main.has_method("_debris_log") and main._debris_log():
		var t0: Texture2D = anim.sprite_frames.get_frame_texture(anim.animation, 0)
		var t0info := "?"
		if t0 is AtlasTexture and (t0 as AtlasTexture).atlas != null:
			t0info = (t0 as AtlasTexture).atlas.resource_path
		elif t0 != null:
			t0info = str(t0.get_size())
		print("[t42] head shed -> %s__nohead (clip=%s->%s frame=%d/%d tex0=%s clips=%s)" % [
			debris_key, cur, anim.animation, anim.frame, anim.sprite_frames.get_frame_count(anim.animation),
			t0info, anim.sprite_frames.get_animation_names()])

func _add_clip_frames(frames: SpriteFrames, clip: String, info: Dictionary, fw: int, fh: int) -> void:
	var tex: Texture2D = load(str(info["file"]))
	if tex == null:
		return
	frames.add_animation(clip)
	frames.set_animation_speed(clip, float(info.get("fps", 18)))
	frames.set_animation_loop(clip, clip in ["idle", "walk", "win", "bind"])
	var n := maxi(int(info.get("frames", 1)), 1)
	var cols := maxi(int(info.get("cols", n)), 1)
	for i in n:
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2((i % cols) * fw, (i / cols) * fh, fw, fh)
		frames.add_frame(clip, at)

func on_part_shed(part_name: String) -> void:
	## a living body never sheds the same part twice; the head swaps to the headless bake
	if part_name == "":
		return
	if not shed_parts.has(part_name):
		shed_parts.append(part_name)
	if part_name == "head":
		_swap_to_headless()

func _setup_body() -> void:
	## body pick order: sprite-animated table, live .glb actor, baked-strip fallback; equipment slots recorded on every path
	var model_uri := str(DB.entry("units", unit_type).get("model", ""))
	var vtype := _variant_type()
	# checked BEFORE the 3D path -- the billboard quad would win and render the whole sheet
	var sa: Dictionary = DB.load_json("res://data/sprite_anims.json").get(unit_type, {})
	if not sa.is_empty():
		if _setup_sprite_body(vtype, sa):
			return
	if GrannyActor3D.supports_model(model_uri) and _setup_body_3d(model_uri):
		_load_equipment()
		return
	if is_hero and melee_weapon_name != "":
		var wvar := "ash__saw" if melee_weapon_name == "chainsaw" else "ash__fist"
		if DB.load_json("res://data/unit_anims.json").has(wvar):
			vtype = wvar
	var meta := _anim_meta(vtype)
	if meta.is_empty() or not ResourceLoader.exists(str(meta.get("atlas", ""))):
		meta = _anim_meta(unit_type)
		if meta.is_empty() or not ResourceLoader.exists(str(meta.get("atlas", ""))):
			return
		vtype = unit_type
	debris_key = vtype  # resolved bake key — T38 debris uses the same table
	_authored_facing = _facing_meta(unit_type)
	var frames := SpriteFrames.new()
	var fw := maxi(int(meta.get("frame_w", 1)), 1)
	var fh := maxi(int(meta.get("frame_h", 1)), 1)
	var ss: float = float(meta.get("ss", 2.0))
	var clips: Dictionary = meta.get("clips", {})
	for clip: String in clips.keys():
		var info: Dictionary = clips[clip]
		var tex: Texture2D = load(str(info["file"]))
		if tex == null:
			continue
		frames.add_animation(clip)
		frames.set_animation_speed(clip, float(info.get("fps", 18)))
		frames.set_animation_loop(clip, clip in ["idle", "walk", "win", "bind"])
		# defaulting cols to 1 sent every frame past 0 out of bounds below the strip -- the combat sprite-flicker root cause
		var n := int(info.get("frames", 1))
		var cols := maxi(int(info.get("cols", n)), 1)
		for i in n:
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2((i % cols) * fw, (i / cols) * fh, fw, fh)
			frames.add_frame(clip, at)
	if frames.get_animation_names().is_empty():
		return
	anim = AnimatedSprite2D.new()
	anim.sprite_frames = frames
	anim.scale = Vector2(1.0 / ss, 1.0 / ss)
	# scale around the baked AABB center so body_scale stays visual only
	var ab0: Dictionary = meta.get("aabb", {})
	var anchor := Vector2(0, -fh / (2.0 * ss) + 2.0)
	if ab0.has("pos") and ab0.has("size"):
		var cx0: float = float(ab0["pos"][0]) + float(ab0["size"][0]) * 0.5
		var cy0: float = float(ab0["pos"][1]) + float(ab0["size"][1]) * 0.5
		_anim_ground = Vector2(cx0, cy0)
		anchor = Vector2(cx0, -cy0)
	else:
		_anim_ground = Vector2(0, fh / (2.0 * ss))
	anim.scale *= body_scale
	anim.position = anchor * body_scale
	anim.set_meta("base_anim_scale", anim.scale)
	# strips from UN-mirrored glbs -- flip_v matches the corrected live 3D actor; the AABB-center anchor above still holds
	anim.flip_v = GrannyActor3D._is_y_mirror_model(
		GrannyActor3D.glb_stem_for_model(model_uri))
	add_child(anim)
	_play_clip(_idle_clip_name())
	_load_equipment()  # record weapon/helmet/shield slots on the sprite path too

func _resolve_body_atlas() -> String:
	## 3D body texture = the unit's bake atlas; baked item art is unreferenced by body UVs, so live equipment never doubles against it
	var key := GrannyActor3D.glb_stem_for_model(str(DB.entry("units", unit_type).get("model", "")))
	if is_hero and melee_weapon_name != "":
		var wvar := "ash__saw" if melee_weapon_name == "chainsaw" else "ash__fist"
		if DB.load_json("res://data/unit_anims.json").has(wvar):
			key = wvar
	return key

func _setup_body_3d(model_uri: String) -> bool:
	## a variant with its own staged .glb + atlas swaps BOTH model and texture (same routing as _variant_type)
	_body_atlas_key = _resolve_body_atlas()
	var tex_path := "res://assets/units/%s.webp" % _body_atlas_key
	var use_stem := ""
	var vtype := _variant_type()
	if vtype != unit_type and GrannyActor3D.variant_glb_exists(vtype) \
			and ResourceLoader.exists("res://assets/units/%s.webp" % vtype):
		use_stem = vtype
		_body_atlas_key = vtype
		tex_path = "res://assets/units/%s.webp" % vtype
	if not ResourceLoader.exists(tex_path):
		_body_atlas_key = GrannyActor3D.glb_stem_for_model(model_uri)
		tex_path = "res://assets/units/%s.webp" % _body_atlas_key
		if not ResourceLoader.exists(tex_path):
			return false
	var tex: Texture2D = load(tex_path)
	var a := GrannyActor3D.new()
	if not a.setup(model_uri, tex, use_stem):
		return false
	actor3d = a
	a.scale = Vector2.ONE * body_scale  # units.lua model-uniform scale
	_authored_facing = _facing_meta(unit_type)
	add_child(a)
	a.set_facing_flip(facing * _authored_facing < 0.0)
	a.play_clip(_idle_clip_name(), true)
	return true

func _stat_pick(stat: Variant) -> String:
	var s := str(stat) if stat != null else ""
	if s == "" or s == "<null>":
		return ""
	var parts := s.split(";")
	return parts[randi() % parts.size()]

func _item_file(leaf: String, folder := "items") -> String:
	var leaf_only := leaf.get_file()
	var path := "res://assets/%s/%s.webp" % [folder, leaf_only]
	return path if ResourceLoader.exists(path) else ""

func _load_equipment() -> void:
	## weapon/helmet/shield resolved to model .obj + texture (semicolon lists pick one); recorded for pop-off, attached live
	equipped_slots.clear()
	var weapon_spec: String
	if is_hero and melee_weapon_name != "":
		weapon_spec = melee_weapon_name
	else:
		weapon_spec = _stat_pick(DB.get_stat("units", unit_type, "weapon", level))
	var specs := [
		["weapon", "weapons", weapon_spec, "bone_weapon", 4.0],
		["helmet", "items", _stat_pick(DB.get_stat("units", unit_type, "helmet", level)), "bone_head", 5.0],
		["shield", "items", _stat_pick(DB.get_stat("units", unit_type, "shield", level)), "bone_shield", 6.0],
	]
	for spec: Array in specs:
		var slot := str(spec[0])
		var table := str(spec[1])
		var item_name := str(spec[2])
		if item_name == "" or item_name == "<null>":
			continue
		var entry: Dictionary = DB.entry(table, item_name)
		if entry.is_empty():
			continue
		var obj_uri := str(entry.get("model", ""))
		if not obj_uri.ends_with(".obj"):
			# texture-only items still attach: torchboy_fire_shield is a textured prop riding bone_shield
			if item_name == "torchboy_fire_shield":
				_attach_fire_shield(entry, float(spec[4]))
			continue
		var obj_name := obj_uri.get_file().trim_suffix(".obj")
			# level-resolved texture: weapons swap art per level; items keep type-level art
		var tex_leaf := _stat_pick(DB.get_stat(table, item_name, "texture", level))
		var tex_file := _item_file(tex_leaf)
		if tex_file == "":
			tex_leaf = _stat_pick(str(entry.get("texture", "")))
			tex_file = _item_file(tex_leaf)
			if tex_file == "":
				continue
		equipped_slots[slot] = {"name": item_name, "tex": tex_leaf.get_file(), "obj": obj_name}
		if actor3d != null:
			var scale_v: Variant = entry.get("scale", 1.0)
			actor3d.equip_slot(slot, str(spec[3]), obj_name, tex_leaf.get_file(),
				float(spec[4]), float(scale_v) if scale_v != null else 1.0)

var _fire_shield: Node = null  # torchboy's animated fire_sprite shield prop

func _attach_fire_shield(entry: Dictionary, z_offset: float) -> void:
	## texture-only shield: the torch flipbook animates on bone_shield
	var tex: Texture2D = load("res://assets/items/fire_sprite.webp")
	if tex == null:
		return
	equipped_slots["shield"] = {"name": "torchboy_fire_shield",
		"tex": "fire_sprite.webp", "obj": ""}
	if actor3d == null:
		return  # sprite path: slot recorded, no bone prop (like other slots)
	var skel: Skeleton3D = actor3d._skeleton
	if skel == null or skel.find_bone("bone_shield") < 0:
		return
	var scale_v: Variant = entry.get("scale", 1.0)
	var s := float(scale_v) if scale_v != null else 1.0
	var frames := SpriteFrames.new()
	frames.set_animation_speed("default", 15.0)
	frames.set_animation_loop("default", true)
	for i in range(8):
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(float(i % 4) * 32.0, (0.0 if i < 4 else 64.0), 32.0, 64.0)
		frames.add_frame("default", at)
	var ba := BoneAttachment3D.new()
	ba.bone_name = "bone_shield"
	skel.add_child(ba)
	var spr := AnimatedSprite3D.new()
	spr.sprite_frames = frames
	spr.pixel_size = (480.0 / 1024.0) * s  # assets.lua ratio x item scale
	spr.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	spr.shaded = false
		# a raw +6 z-offset lands BEHIND the ortho camera on torchboy -- clamp to the frame AABB
	spr.position = Vector3(0.0, 0.0,
		minf(z_offset, actor3d._frame_aabb.end.z))
	ba.add_child(spr)
	spr.play("default")
	_fire_shield = ba

func on_weapon_swapped(wname: String) -> void:
	## re-equip swaps the weapon's data AND its item art -- re-record the slot, re-attach the mesh
	var entry: Dictionary = DB.entry("weapons", wname)
	if entry.is_empty():
		return
	var obj_uri := str(entry.get("model", ""))
	var tex_leaf := _stat_pick(entry.get("texture"))
	if obj_uri.ends_with(".obj") and tex_leaf != "":
		equipped_slots["weapon"] = {"name": wname, "tex": tex_leaf.get_file(),
			"obj": obj_uri.get_file().trim_suffix(".obj")}
		if actor3d != null:
			actor3d.equip_slot("weapon", "bone_weapon",
				obj_uri.get_file().trim_suffix(".obj"), tex_leaf.get_file(), 4.0)

func _setup_sprite_body(vtype: String, sa: Dictionary) -> bool:
	var tex: Texture2D = null
	for cand: String in [vtype, unit_type]:
		var path := "res://assets/units/%s.webp" % cand
		if ResourceLoader.exists(path):
			tex = load(path)
			break
	if tex == null:
		return false
	var rects: Array = sa.get("rects", [])
	var keys: Array = sa.get("keys", [])
	if rects.is_empty() or keys.is_empty():
		return false
	var s: float = 1.0 / float(sa.get("px_per_world", 1.0))
	var fps: float = float(sa.get("fps", 30.0))
	var frames := SpriteFrames.new()
	for clip: String in ["idle", "walk", "win", "attack_a", "attack_b", "attack_c", "damage"]:
		frames.add_animation(clip)
		frames.set_animation_speed(clip, fps)
		frames.set_animation_loop(clip, true)
		for k: int in keys:
			var at := AtlasTexture.new()
			at.atlas = tex
			var r: Array = rects[k]
			at.region = Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))
			frames.add_frame(clip, at)
	frames.add_animation("die")
	frames.set_animation_speed("die", 4.0)
	frames.set_animation_loop("die", false)
	var d0: Array = rects[0]
	var dat := AtlasTexture.new()
	dat.atlas = tex
	dat.region = Rect2(float(d0[0]), float(d0[1]), float(d0[2]), float(d0[3]))
	frames.add_frame("die", dat)
	anim = AnimatedSprite2D.new()
	anim.sprite_frames = frames
	anim.scale = Vector2(s, s) * body_scale
	var ab: Dictionary = sa.get("aabb", {})
	if ab.has("pos") and ab.has("size"):
		var cx: float = float(ab["pos"][0]) + float(ab["size"][0]) * 0.5
		var cy: float = float(ab["pos"][1]) + float(ab["size"][1]) * 0.5
		_anim_ground = Vector2(cx, cy)
		anim.position = Vector2(cx, -cy) * body_scale
	_authored_facing = _facing_meta(unit_type)
	add_child(anim)
	_play_clip(_idle_clip_name())
	return true

func _clip_or_fallback(names: Array) -> StringName:
	for n: String in names:
		if _has_clip(n):
			return StringName(n)
	return _idle_clip_name()

func _has_clip(n: String) -> bool:
	if actor3d != null:
		return actor3d.has_clip(n)
	if anim == null:
		return false
	return anim.sprite_frames.has_animation(n)

func _clip_len(n: String) -> float:
	if actor3d != null:
		return actor3d.get_clip_length(n)
	if anim == null or not anim.sprite_frames.has_animation(n):
		return 0.0
	return anim.sprite_frames.get_frame_count(n) \
		/ maxf(anim.sprite_frames.get_animation_speed(n), 1.0)

func _idle_clip_name() -> StringName:
	for n in ["idle", "bind", "idel", "walk"]:
		if _has_clip(str(n)):
			return StringName(n)
	return &""

func _play_clip(clip: StringName) -> void:
	if clip == &"":
		return
	if actor3d != null:
		actor3d.play_clip(str(clip), clip in [&"idle", &"walk"])
		return
	if anim != null and anim.animation != clip:
		anim.play(clip)

func _play_clip_len(clip: StringName) -> float:
	if clip == &"" or not _has_clip(str(clip)):
		return 0.0
	_play_clip(clip)
	return _clip_len(str(clip))

func _process(dt: float) -> void:
	if state == State.DEAD:
		return
	if _flash_time > 0.0:
		_flash_time -= dt
		modulate = Color(1, 0.35, 0.35) if int(_flash_time * 20.0) % 2 == 0 else Color.WHITE
		if _flash_time <= 0.0:
			modulate = Color.WHITE
	if burn_left > 0.0:
		burn_left -= dt
		_burn_acc += burn_dps * dt
		_flash_time = maxf(_flash_time, 0.08)
		modulate = Color(1.0, 0.55, 0.2) if int(_flash_time * 20.0) % 2 == 0 else Color.WHITE
		if _burn_acc >= 1.0:
			var d := int(_burn_acc)
			_burn_acc -= float(d)
			take_damage(d, burn_source, 0.0, false)
		if _flame == null:
			_spawn_flame()
		if burn_left <= 0.0:
			burn_dps = 0.0
			modulate = Color.WHITE
			if _flame != null:
				_flame.queue_free()
				_flame = null
	if _attack_anim_time > 0.0:
		_attack_anim_time -= dt
	if regen_rate > 0.0 and health < max_health:
		health = minf(health + regen_rate * dt, max_health)
		queue_redraw()

	attack_cooldown = maxf(attack_cooldown - dt, 0.0)
	if _attack_anim_pending > 0.0:
		_attack_anim_pending -= dt
		if _attack_anim_pending <= 0.0:
			_play_clip(_clip_or_fallback(["idle"]))

	if not _strikes_pending.is_empty():
		for i in range(_strikes_pending.size() - 1, -1, -1):
			_strikes_pending[i]["t"] -= dt
			if float(_strikes_pending[i]["t"]) <= 0.0:
				var strike: Dictionary = _strikes_pending[i]
				_strikes_pending.remove_at(i)
				_deliver_strike(strike)

	# while the order runs the unit cannot act; y-down mirrors the C++ y-up -- the step adds +250*dt^2 and vy grows by +500*dt
	if stumble_time > 0.0:
		stumble_time -= dt
		if knock_flying:
			position.x += knock_vx * dt
			position.y += knock_vy * dt + 250.0 * dt * dt
			knock_vy += 500.0 * dt
			main.try_pit_scoop(self)
		_play_clip(_clip_or_fallback(["damage"]))
		if stumble_time <= 0.0 and knock_flying:
			knock_flying = false
			position.x = knock_dest_x
			position.y = knock_dest_y
		return  # no combat action while stumbling

	# ground_y is y-up (negate for Godot); catapults stand on mapdata posts -- snapping them onto the road dragged the machines up
	if not is_gate and not is_wall_archer and not is_catapult:
		position.y = -main.ground_y(position.x) + lane_offset

	# set by the advance branches below, read by the clip machine and the healer's is_moving gate
	is_moving = false
	# wave_over survivors pose only: orders cleared so no pending swing lands and _tick_special stops; the clip machine still plays out a "win"
	var wave_done: bool = main != null and main.wave_over
	if wave_done:
		_strikes_pending.clear()
	else:
		match state:
			State.WALK_IN:
				var dx := walk_in_x - position.x
				if absf(dx) < 2.0:
					position.x = walk_in_x
					state = State.COMBAT
				elif not _walk_paused:
					position.x += signf(dx) * speed * dt
					facing = signf(dx)
					is_moving = true
			State.COMBAT:
				_combat_tick(dt)

	# clip state machine (runs after the advance so is_moving is this frame's)
	if anim != null or actor3d != null:
		var flip := facing * _authored_facing < 0.0
		if anim != null:
			anim.flip_h = flip
		else:
			actor3d.set_facing_flip(flip)
		if anim_lock != "":
			_play_clip(StringName(anim_lock))
		elif state == State.WALK_IN and is_moving:
			# walking overrides a still-playing attack clip -- feet must move; the strike itself stays timer-driven and lands on schedule
			_attack_anim_pending = 0.0
			_play_clip(_clip_or_fallback(["walk"]))
		elif _attack_anim_pending <= 0.0:
			match state:
				State.WALK_IN:
					_play_clip(_clip_or_fallback(["walk"]))
				State.COMBAT:
					_play_clip(_clip_or_fallback(["walk", "idle"]) if is_moving \
						else _clip_or_fallback(["idle"]))
				State.DEAD:
					pass

	if not wave_done:
		_tick_special(dt)

func _tick_special(dt: float) -> void:
	if unit_type == "evil_ash":
		_tick_scheduled_stops(dt)
	if is_healer:
		_tick_healer(dt)
	if helper_kind != "":
		_tick_helper(dt)

func _tick_scheduled_stops(dt: float) -> void:
	## paused = speed 0 + orders cleared (in-range combat still runs); all stop/resume pairs are queued up front
	if _stops_left <= 0 and not _walk_paused:
		return
	_stop_timer -= dt
	if _stop_timer > 0.0:
		return
	_walk_paused = not _walk_paused
	if _walk_paused:
		_stops_left -= 1
		_stop_timer = 18.0
	else:
		_stop_timer = 5.0

func _combat_tick(dt: float) -> void:
	if not ai_enabled or is_gate or is_prop:
		return
	if is_healer:
		# the staff's heal_magic ammo carries negative damage; the combat "target" is the heal patient
		_combat_tick_healer(dt)
		return
	if is_hero:
		# re-poll every cycle -- a stale target let a skeleton saw at Ash's back
		target = main.get_closest_opposing(self)
		if target == null:
			return  # nothing to fight; hold position until enemies arrive
	else:
		# NO sticky target: re-ask every 0.2 s so aggro follows whoever is nearest; a dead/freed target re-polls immediately
		if target != null and (not is_instance_valid(target) or target.state == State.DEAD):
			target = null
		_retarget_t -= dt
		if target == null or _retarget_t <= 0.0:
			_retarget_t = 0.2
			target = main.get_closest_opposing(self)
		if target == null:
			return  # nothing to fight; hold position (allies) until enemies arrive

	var dx: float = target.position.x - position.x
	var adx := absf(dx)
	facing = signf(dx) if dx != 0.0 else facing

	if is_wall_archer or is_catapult:
		if adx <= weapon_range and adx >= weapon_min_range and attack_cooldown <= 0.0:
			_attack()
			attack_cooldown = attack_interval
		return

	if is_hero:
		# Ash holds position (the player kites); the melee slot swings inside ITS reach, the gun covers the rest
		_active_melee = melee_weapon_name != "" and adx <= melee_range
		if not _active_melee and adx > weapon_range:
			return
	elif adx > weapon_range:
		# Evil Ash's scheduled stop zeroes movement while in-range combat keeps running
		if not _walk_paused:
			position.x += signf(dx) * speed * dt
			is_moving = true
		return

	if attack_cooldown <= 0.0:
		_check_damage_buff_expired()  # FUN_00114220 lazy buff clear on attack
		_attack()
		attack_cooldown = melee_interval if _active_melee else attack_interval

# ------------------------------------------------- wiseman heal support

func _tick_healer(dt: float) -> void:
	## while MOVING: scan for damaged team peers in range not yet healed; stationary clears the patient memory
	if is_moving:
		if attack_cooldown <= 0.0:
			var patient := _find_patient()
			if patient != null:
				attack_cooldown = attack_interval
				_previous_patients[patient.get_instance_id()] = true
				_fire_heal(patient)
	else:
		_previous_patients.clear()

func _find_patient() -> Unit:
	for u: Unit in main._team_objects(team):
		if u.state == State.DEAD or u.is_gate or u.is_prop:
			continue
		if _previous_patients.has(u.get_instance_id()):
			continue
		if u.health >= u.max_health:
			continue
		if absf(u.position.x - position.x) > weapon_range:
			continue
		return u
	return null

func _fire_heal(t: Unit) -> void:
	var clip := _clip_or_fallback(["attack_a", "attack_b"])
	_attack_anim_pending = _play_clip_len(clip)
	var strike := {"t": _strike_delay(clip), "melee": false, "ranged": true, "target": t,
		"target_pos": t.position}
	if float(strike["t"]) <= 0.0:
		_deliver_strike(strike)
	else:
		_strikes_pending.append(strike)

func _combat_tick_healer(dt: float) -> void:
	## heal Ash below the scaled pct, else the first damaged peer; with nobody hurt, march on the closest enemy but NEVER swing the staff at one
	var t := _heal_target()
	if t != null:
		var dx: float = t.position.x - position.x
		if dx != 0.0:
			facing = signf(dx)
		if absf(dx) > weapon_range:
			position.x += facing * speed * dt
			is_moving = true
			return
		if attack_cooldown <= 0.0:
			attack_cooldown = attack_interval
			if t != main.ash:
				_previous_patients[t.get_instance_id()] = true
			_fire_heal(t)
		return
	var enemy: Unit = main.get_closest_opposing(self)
	if enemy == null:
		return
	var dx2: float = enemy.position.x - position.x
	if dx2 != 0.0:
		facing = signf(dx2)
	if absf(dx2) <= weapon_range:
		return  # AttackOrder satisfied: hold — never swing the staff at an enemy
	position.x += facing * speed * dt
	is_moving = true

func _heal_target() -> Unit:
	## Ash first (no patient-memory gate), then an in-range damaged peer; fallback = the front-most damaged peer anywhere on the field
	var fallback: Unit = null
	var front := 1.0 if team == Team.ALLY else -1.0  # toward the opposing team
	if team == Team.ALLY:
		var pct: float = float(DB.table("globals").get("ash_health_bar_show_percentage", 0.75))
		pct = (1.0 - pct) * (1.0 - 0.5) + 0.5
		var ash: Unit = main.ash
		if ash != null and is_instance_valid(ash) and ash.state != State.DEAD \
				and absf(ash.position.x - position.x) <= weapon_range \
				and ash.max_health > 0.0 and ash.health / ash.max_health < pct:
			return ash
	for u: Unit in main._team_objects(team):
		if u == self or u.state == State.DEAD or u.is_gate or u.is_prop:
			continue
		if u.health >= u.max_health:
			continue
		if absf(u.position.x - position.x) <= weapon_range \
				and not _previous_patients.has(u.get_instance_id()):
			return u
		if fallback == null or u.position.x * front > fallback.position.x * front:
			fallback = u
	return fallback

func heal(amount: int) -> void:
	if state == State.DEAD or amount <= 0:
		return
	health = minf(health + float(amount), max_health)
	queue_redraw()

func _tick_helper(dt: float) -> void:
	## every 0.2 s scan team peers in range not yet in m_previous_victims and apply this unit's help
	_scan_t -= dt
	if _scan_t <= 0.0:
		_scan_t = 0.2
		for u: Unit in main._team_objects(team):
			if u == self or u.state == State.DEAD or u.is_gate or u.is_prop:
				continue
			if _previous_victims.has(u.get_instance_id()):
				continue
			if absf(u.position.x - position.x) > weapon_range:
				continue
			_previous_victims[u.get_instance_id()] = true
			match helper_kind:
				"sword":
					_helper_swordboy(u)
				"torch":
					_helper_torchboy(u)
				"flute":
					_helper_flute(u)
	if helper_kind == "flute":
		_note_t -= dt
		if _note_t <= 0.0:
			_note_t = 5.0
			main.spawn_sign(self, "res://assets/fx/note.webp", 4.0)

func _helper_swordboy(target: Unit) -> void:
	var new_weapon: Variant = DB.get_stat("units", target.unit_type, "sword_boy_weapon", target.level)
	if new_weapon == null or str(new_weapon) == "":
		return
	target.equip_weapon(str(new_weapon))
	target.on_weapon_swapped(str(new_weapon))
	print("[helper] swordboy gives %s to %s" % [str(new_weapon), target.unit_type])
	main.spawn_bubble(target, "res://assets/fx/buff_sword_good.webp", 60.0)

func _helper_torchboy(target: Unit) -> void:
	var old := target.weapon_name
	if old == "":
		return
	var new_weapon := "flaming_" + old
	if DB.entry("weapons", new_weapon).is_empty():
		return
	target.equip_weapon(new_weapon)
	target.on_weapon_swapped(new_weapon)
	print("[helper] torchboy enflames %s's %s" % [target.unit_type, new_weapon])
	main.spawn_bubble(target, "res://assets/items/fire_sprite.webp", 80.0, 0.4)

func _helper_flute(target: Unit) -> void:
	if target.weapon_name == "":
		return
	var factor: Variant = DB.get_stat("units", unit_type, "damage_buff_factor", level)
	if factor == null or float(factor) == 1.0:
		return
	target.apply_damage_buff(float(factor), self)

func apply_damage_buff(factor: float, source: Unit) -> void:
	if state == State.DEAD or factor <= 0.0 or factor == 1.0:
		return
	attack_damage = int(round(float(attack_damage) * factor))
	_buff_factor *= factor
	_buff_source = source
	print("[buff] %s buffs %s x%.2f -> dmg %d" % [
		source.unit_type if source != null and is_instance_valid(source) else "?",
		unit_type, _buff_factor, attack_damage])
	_spawn_buff_sprite()

func _expire_damage_buff() -> void:
	print("[buff] %s loses its damage buff (dmg back to %d)" % [
		unit_type, maxi(int(round(float(attack_damage) / _buff_factor)), 0)])
	attack_damage = maxi(int(round(float(attack_damage) / _buff_factor)), 0)
	_buff_factor = 1.0
	_buff_source = null
	if _buff_sprite != null and is_instance_valid(_buff_sprite):
		var s := _buff_sprite
		_buff_sprite = null
		var tw := s.create_tween()
		tw.tween_property(s, "scale", Vector2.ZERO, 0.4)
		tw.tween_callback(s.queue_free)

func _check_damage_buff_expired() -> void:
	## lazy clear: a dead flute/drummer no longer resolves and the buff divides back out
	if _buff_factor == 1.0:
		return
	if _buff_source != null and is_instance_valid(_buff_source) \
			and _buff_source.state != State.DEAD:
		return
	_expire_damage_buff()

func clear_damage_buff_from(source: Unit) -> void:
	if _buff_source == source and _buff_factor != 1.0:
		_expire_damage_buff()

func _spawn_buff_sprite() -> void:
	if _buff_sprite != null and is_instance_valid(_buff_sprite):
		return
	var tex: Texture2D = load("res://assets/fx/buff_sword_evil.webp")
	if tex == null:
		return
	_buff_sprite = Sprite2D.new()
	_buff_sprite.texture = tex
	_buff_sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_buff_sprite.scale = Vector2.ONE * 0.5  # engine draws textures at half px size
	_buff_sprite.position = Vector2(0.0, -tex.get_height() * 0.25)
	add_child(_buff_sprite)
	var top := -(height * body_scale + 10.0)
	var tw := _buff_sprite.create_tween()
	tw.tween_property(_buff_sprite, "position:y", top, 0.65) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)  # InterpAction.Fall
	tw.parallel().tween_property(_buff_sprite, "scale", Vector2.ONE, 0.325) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(_buff_sprite, "scale", Vector2.ONE * 0.5, 0.325) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var pulse := _buff_sprite.create_tween()
	pulse.set_loops()
	pulse.tween_property(_buff_sprite, "scale", Vector2.ONE * 0.625, 0.325) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	pulse.tween_property(_buff_sprite, "scale", Vector2.ONE * 0.375, 0.325) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

func _attack() -> void:
	var clip := &"attack_a"
	if _active_melee:
		clip = &"attack_b" if melee_weapon_name == "chainsaw" else &"attack_c"
	elif not is_hero:
		if _has_clip("attack_a") and _has_clip("attack_b"):
			clip = &"attack_b" if randi() % 2 == 0 else &"attack_a"
	_attack_anim_pending = _play_clip_len(clip)
	var ssnd: Variant = DB.get_stat("weapons",
		melee_weapon_name if _active_melee else weapon_name, "on_animation_start_sound", level)
	if ssnd != null and str(ssnd) != "":
		main.play_uri_list(str(ssnd))
	var strike := {"t": _strike_delay(clip), "melee": _active_melee,
		"ranged": not _active_melee and ammo_name != "", "target": target,
		# where the enemy stood at swing start -- a late release still flies to this spot
		"target_pos": target.position if target != null else Vector2.ZERO}
	if float(strike["t"]) <= 0.0:
		_deliver_strike(strike)
	else:
		_strikes_pending.append(strike)

func _deliver_strike(s: Dictionary) -> void:
	## the target can be corpse-freed mid-swing: resolve through a Variant first -- binding a freed instance to a typed Unit var is a runtime error
	var tv: Variant = s["target"]
	var t: Unit = tv if is_instance_valid(tv) and tv is Unit else null
	if t == null:
		return  # target gone mid-swing: a dead ref fizzles the attack
	if s["melee"]:
		t.take_damage(melee_damage, self, melee_knockback)
		if melee_splash > 0.0:
			main.splash_damage(t.position.x, melee_splash, melee_damage, self, t)
		# the invented keys below stay as fallback for weapons with no data field
		var dsnd: Variant = DB.get_stat("weapons", melee_weapon_name,
			"on_deal_damage_sound", level)
		if dsnd != null and str(dsnd) != "":
			main.play_uri_list(str(dsnd))
		elif melee_weapon_name == "chainsaw":
			main.play_sfx("chainsaw_hit_%d" % (randi() % 8), -3.0)
		else:
			main.play_sfx("fx_generic_hit_%d" % (1 + randi() % 4), -3.0)
		return
	if s["ranged"]:
		# the projectile aims at the CAPTURED strike position (fixed at spawn); a vanished patient takes the heal shot with him
		var tp: Vector2 = s.get("target_pos", Vector2.ZERO)
		if t != null:
			main.spawn_projectile(self, t, tp)
		elif tp != Vector2.ZERO and not is_healer:
			main.spawn_projectile(self, null, tp)
		if is_hero:
			var rsnd: Variant = DB.get_stat("weapons", weapon_name,
				"on_deal_damage_sound", level)
			if rsnd != null and str(rsnd) != "":
				main.play_uri_list(str(rsnd))
			else:
				main.play_sfx("boomstick_hit", -3.0)
		return
	t.take_damage(attack_damage, self)
	if splash_range > 0.0:
		main.splash_damage(t.position.x, splash_range, attack_damage, self, t)
	if is_hero:
		var mp: Vector2 = main._muzzle_pos(self)
		main._spawn_muzzle_flash(mp)
		main._spawn_smoke_puff(mp)

func _cancel_strike() -> void:
	_strikes_pending.clear()

func _glb_stem() -> String:
	if actor3d != null:
		return actor3d.glb_stem
	return GrannyActor3D.glb_stem_for_model(str(DB.entry("units", unit_type).get("model", "")))

func _strike_delay(clip: StringName) -> float:
	var per_model: Dictionary = STRIKE_TIMES.get(_glb_stem(), {})
	var v: Variant = per_model.get(str(clip))
	return float(v) if v != null else 0.0

func apply_knockback(distance: float, time := 0.0) -> void:
	## ballistic hop landing on dest at T (default T = |D|/100); distance 0 = stun-only hold
	if state == State.DEAD or not can_be_knocked_back or is_gate \
			or is_wall_archer or is_catapult:
		return
	_cancel_strike()
	var t := time
	if t <= 0.0:
		t = absf(distance) / 100.0
	stumble_time = maxf(stumble_time, t)
	if distance == 0.0:
		return
	var dest_x := clampf(position.x + distance, main.ally_spawn_x, main.enemy_spawn_x)
	knock_dest_x = dest_x
	knock_dest_y = -main.ground_y(dest_x) + lane_offset
	knock_vx = (dest_x - position.x) / t
	knock_vy = (knock_dest_y - position.y) / t - 250.0 * t  # Godot y-down launch
	knock_flying = true

func play_cast_anim() -> void:
	_attack_anim_pending = _play_clip_len(_clip_or_fallback(["cast", "attack_a"]))

func play_attack_anim() -> void:
	_attack_anim_pending = _play_clip_len(&"attack_a")

var _necktie: Node = null  # the live tie prop (Sprite3D on bone_tie / 2D fallback)

func show_necktie() -> void:
	_drop_necktie()
	var tex: Texture2D = load("res://assets/items/necktie.webp")
	if tex == null:
		return
	if actor3d != null:
		# the tie art draws at HALF ratio world-per-px, not the raw 2px/world scale
		_necktie = actor3d.attach_sprite_to_bone("bone_tie", tex, 2.0,
			0.5 * (480.0 / 1024.0))
	if _necktie == null:
		var spr := Sprite2D.new()
		spr.texture = tex
		spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		spr.scale = Vector2.ONE * 0.5 * (480.0 / 1024.0) * body_scale
		spr.position = Vector2(0.0, -height * body_scale * 0.62)
		add_child(spr)
		_necktie = spr
	_necktie.modulate.a = 0.0
	var tw := _necktie.create_tween()
	tw.tween_property(_necktie, "modulate:a", 1.0, 0.25)
	tw.tween_interval(2.25)
	tw.tween_property(_necktie, "modulate:a", 0.0, 0.5)
	tw.tween_callback(_drop_necktie)

func _drop_necktie() -> void:
	if _necktie == null or not is_instance_valid(_necktie):
		_necktie = null
		return
	# a 3D tie rides its own BoneAttachment3D — free the attachment with it
	var parent := _necktie.get_parent()
	_necktie.queue_free()
	_necktie = null
	if parent is BoneAttachment3D:
		parent.queue_free()

func take_damage(amount: int, source, knockback_mult := 0.0, fx := true,
		flame_dps := 0.0) -> void:
	## `source` deliberately untyped: a corpse-freed igniter bound to a typed Unit param is itself a runtime error; flame_dps rides every packet
	if state == State.DEAD:
		return
	# wall defenses and props carry health=nil -- untargetable/undamageable
	if is_wall_archer or is_catapult or is_prop:
		return
	last_hit_by = source if source != null and is_instance_valid(source) else null
	var tds: Variant = DB.get_stat("units", unit_type, "on_take_damage_sound", level)
	if tds != null and str(tds) != "":
		main.play_uri_list(str(tds))
	health -= float(amount)
	_flash_time = 0.25
	if flame_dps > 0.0:
		ignite(flame_dps, source if source != null and is_instance_valid(source) else null)
	# the multiplier->distance mapping is engine-side and unrecovered -- invented proportional scale, floor 8 / cap 40
	if knockback_mult > 0.0 and can_be_knocked_back and not is_gate \
			and not is_wall_archer and not is_catapult and not is_hero:
		var dir := signf(position.x - (source.position.x if source != null and is_instance_valid(source) else position.x - 1.0))
		if dir == 0.0:
			dir = -facing
		apply_knockback(dir * clampf(knockback_mult * 1.8, 8.0, 40.0), 0.0)
	damaged.emit(self, amount)
	# enemies only, unconditionally -- the killing blow pops too; allies never pop
	if team == Team.ENEMY:
		_try_pop_off_equipment()
	queue_redraw()
	if health <= 0.0:
		health = 0.0
		state = State.DEAD
		_cancel_strike()  # the dying unit's orders clear — no pending strike lands
		modulate = Color.WHITE  # clear any hit-flash tint before the fade
		_play_clip(_clip_or_fallback(["die"]))
		if _flame != null:
			_flame.queue_free()  # onDeath destroys the enflamed effect
			_flame = null
		died.emit(self)
		_start_corpse_fade()

func _start_corpse_fade() -> void:
	## the gate and Ash never fade -- their deaths ARE the defeat screen
	if is_gate or is_hero or is_prop:
		return
	var die_dur := _clip_len("die")
	var tw := create_tween()
	tw.tween_interval(die_dur + CORPSE_HOLD)
	tw.tween_property(self, "modulate:a", 0.0, CORPSE_FADE)
	tw.tween_callback(queue_free)

# ------------------------------------------------ shield/helmet pop-off

func _try_pop_off_equipment() -> void:
	if equipped_slots.is_empty() or max_health <= 0.0:
		return
	var damage_percent := health / max_health
	if damage_percent < 0.666667 and equipped_slots.has("shield"):
		_pop_equipment("shield")
	if damage_percent < 0.333333 and equipped_slots.has("helmet"):
		_pop_equipment("helmet")

func _pop_equipment(slot: String) -> void:
	var info: Dictionary = equipped_slots.get(slot, {})
	equipped_slots.erase(slot)
	if slot == "shield" and _fire_shield != null:
		_fire_shield.queue_free()  # the animated fire-shield prop dies with the slot
		_fire_shield = null
	# read the bone world position BEFORE unequip_slot tears it down -- after, slot_world_pos always returns INF
	var pop_pos := position + Vector2(0.0, -height * body_scale * 0.6)
	if actor3d != null:
		var p := actor3d.slot_world_pos(slot)
		if p != Vector2.INF:
			pop_pos = p
		actor3d.unequip_slot(slot)
	elif slot == "helmet" and anim != null:
		_swap_to_headless()  # T42 twin bake — the popped skull leaves the body art
	print("[pop] %s L%d loses its %s at %.0f%% health" % [
		unit_type, level, slot, 100.0 * health / max_health])
	var tex: String = str(info.get("tex", ""))
	if tex == "" or not ResourceLoader.exists("res://assets/items/%s.webp" % tex):
		return  # nothing staged to draw — the slot is still spent
	main.spawn_popped_item(pop_pos, position.y, "res://assets/items/%s.webp" % tex,
		str(info.get("obj", "")))

# ------------------------------------------------------------------ drawing

# the HUD's occupied top-left corner (canvas px); the gate bar skips drawing when its screen rect lands inside
const HUD_TOPLEFT_RECT := Rect2(0, 0, 255, 150)

# gate HP bar: 3 layered lifebar textures (opaque recess body, fill stripe, steel bevel) drawn left-anchored, centred on the cage
const GATE_BAR := Rect2(-50.0, -118.3, 46.0, 6.6)
const GATE_BAR_FILL_COLOR := Color(0.0, 0.47, 0.02)
var _gate_bar_tex: Texture2D
var _gate_bar_frame_tex: Texture2D

func _gate_bar_under_hud() -> bool:
	var xform := get_global_transform_with_canvas()
	var tl: Vector2 = xform * GATE_BAR.position
	var br: Vector2 = xform * (GATE_BAR.position + GATE_BAR.size)
	return Rect2(tl, br - tl).intersects(HUD_TOPLEFT_RECT)

func _draw() -> void:
	if is_gate:
		if health > 0.0 and not _gate_bar_under_hud():
			var fw := 41.0 * clampf(health / max_health, 0.0, 1.0)
			# dark recess body -> green fill stripe -> steel bevel frame
			if _gate_bar_tex == null:
				_gate_bar_tex = load("res://assets/ui/hud/ash_lifebar_back.webp")
				_gate_bar_frame_tex = load("res://assets/ui/hud/ash_lifebar.webp")
			if _gate_bar_tex != null:
				draw_texture_rect(_gate_bar_tex, GATE_BAR, false)
			draw_rect(Rect2(GATE_BAR.position.x + 2.5, GATE_BAR.position.y + 1.7,
				fw, 3.2), GATE_BAR_FILL_COLOR)
			if _gate_bar_frame_tex != null:
				draw_texture_rect(_gate_bar_frame_tex, GATE_BAR, false)
		return  # gate uses a Sprite2D child, no procedural body

	# enemies and non-full allies draw a bar (the original hides Ash's); wall units are never damageable
	if not is_prop and not is_wall_archer and not is_catapult \
			and (team == Team.ENEMY or (team == Team.ALLY and not is_hero) or (is_hero and health < max_health)):
		var bw := 26.0
		var frac := health / max_health
		var top := -height * body_scale
		var by := top - 3.0
		draw_rect(Rect2(-bw * 0.5, by, bw, 3.5), Color(0, 0, 0, 0.65))
		var col := Color(0.15, 0.85, 0.2) if team == Team.ALLY else Color(0.9, 0.2, 0.15)
		draw_rect(Rect2(-bw * 0.5, by, bw * frac, 3.5), col)

	if anim != null or actor3d != null:
		return  # real paper-doll body renders the figure

	var h := height * body_scale
	var w := h * 0.38
	var body := Color(0.35, 0.28, 0.2)
	var head := Color(0.82, 0.76, 0.65)
	if team == Team.ENEMY:
		body = Color(0.62, 0.66, 0.55)  # bone
		head = Color(0.9, 0.9, 0.8)
	if is_hero:
		body = Color(0.2, 0.3, 0.45)
		head = Color(0.8, 0.68, 0.55)

	var reach := w * (2.2 if _attack_anim_time > 0.0 else 0.9) * facing
	draw_line(Vector2(0, -h * 0.62), Vector2(reach, -h * 0.62), Color(0.25, 0.22, 0.18), 3.0)
	draw_rect(Rect2(-w * 0.5, -h * 0.62, w, h * 0.62), body)
	draw_rect(Rect2(-w * 0.42, -h * 0.28, w * 0.3, h * 0.28), body.darkened(0.25))
	draw_rect(Rect2(w * 0.12, -h * 0.28, w * 0.3, h * 0.28), body.darkened(0.25))
	draw_circle(Vector2(0, -h * 0.78), h * 0.16, head)
