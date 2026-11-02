extends Node2D
## Main game controller. Map space is y-up — _g() flips to Godot coords: Vector2(x, -y).

const CAMERA_HALF := 240.0  # half the 480x320 base viewport
const DEFAULT_ZOOM := 1.78

const IRON_BASE_RATE := 1.15
const COIN_PICKUP_RANGE := 37.5  # ash.lua checkForCoins vacuum range
const COIN_DROP_TIME := 0.5
const COIN_PULSE_TIME := 5.0
const COIN_FADE_TIME := 0.5
const COIN_DROP_HEIGHT := 50.0
const IRON_PER_BAR := 2  # ash.lua checkForCoins: incrementIron(2) per bar
const NON_USER_TARGETED_SPELL_OFFSET := 120.0  # globals.non_user_targeted_spell_offset
const EFFECT_TEXEL := 480.0 / 1024.0  # assets.lua ratio: texture px -> world units for effect sprites

# World draw widths: authored px * EFFECT_TEXEL for every entry except "arrow" (already world units).
const AMMO_WORLD_WIDTH := {
	"arrow": 52.5,
	"flaming_arrow": 128.0 * EFFECT_TEXEL,
	"bolt": 128.0 * EFFECT_TEXEL,
	"rock": 64.0 * EFFECT_TEXEL,
	"flaming_rock": 64.0 * EFFECT_TEXEL,
	"heal_shot": 128.0 * EFFECT_TEXEL,
	"blur_flaming_arrow": 512.0 * EFFECT_TEXEL,
	"blur_rock": 182.0 * EFFECT_TEXEL,
	"blur_flaming_rock": 182.0 * EFFECT_TEXEL,
}


# original-camera z ordering, roughly: bg -450, gate -400, units 0, fg +400
const Z_BG := -20
const Z_FG := 10

# Authored centers, already in _g() output space (Godot coords: mapdata (x, y) -> (x, -y)).
const BACKWALL_MASK_CENTERS := {
	"backwall_mask_01": Vector2(431.50, -364.75),
	"backwall_mask_02": Vector2(806.75, -252.00),
	"backwall_mask_03": Vector2(1013.75, -272.50),
}

# Matched (displaced from raw mapdata) centers, in _g() output space; keys are the tex.get_file() leaves.
const FG_MASK_CENTERS := {
	# These five RIDE bg_part1_bottom — a seat change must move them by the same delta or the stairs tear.
	"wall_mask_01": Vector2(858.50, -104.25),
	"wall_mask_02": Vector2(760.43, -143.00),
	"wall_mask_03": Vector2(614.68, -160.00),
	"wall_mask_04": Vector2(459.68, -178.75),
	"wall_mask_05": Vector2(162.43, -204.00),
	"front_gate_mask": Vector2(1896.10, -120.50),
}

# ENGINE FALLBACK for data/torch_overrides.json — ranks are the x-sorted 1-16 numbering; edit the JSON, never this.
const _TORCH_SHIPPED := {
	1: {"enabled": false, "offset": Vector2(-26.83, 1.16), "scale": 1.6},   # gate sconce L
	2: {"enabled": false, "offset": Vector2(-22.77, 3.84), "scale": 1.5},   # gate sconce R
	3: {"enabled": false, "offset": Vector2(0.28, 0.45), "scale": 1.0},
	4: {"enabled": false, "offset": Vector2(6.55, -2.15), "scale": 1.0},    # deliberate +4 down (R11-04 §D)
	5: {"enabled": false, "offset": Vector2(25.67, 4.42), "scale": 1.4},    # bigger + lower
	6: {"enabled": false, "offset": Vector2(-10.0, 3.0), "scale": 1.25},    # user-directed, footage-neutral (§E)
	7: {"enabled": true, "offset": Vector2(-0.85, 0.27), "scale": 1.0},
	8: {"enabled": true, "offset": Vector2(3.35, 0.56), "scale": 1.0},
	9: {"enabled": true, "offset": Vector2(4.25, -1.73), "scale": 1.0},
	10: {"enabled": true, "offset": Vector2(9.88, -6.27), "scale": 1.0},
	11: {"enabled": true, "offset": Vector2(10.90, -1.70), "scale": 1.0},
	12: {"enabled": true, "offset": Vector2(12.54, -8.56), "scale": 1.0},
	13: {"enabled": true, "offset": Vector2(17.44, -7.14), "scale": 1.0},
	14: {"enabled": true, "offset": Vector2(19.85, -4.16), "scale": 1.0},
	15: {"enabled": false, "offset": Vector2(21.34, 4.54), "scale": 1.0},   # slide left, z unchanged (§F)
	16: {"enabled": false, "offset": Vector2(27.41, 8.61), "scale": 1.0},   # FOREGROUND torch (z Z_FG)
}

# Measured per post; the seat includes our glb's render-anchor offset — do NOT edit map.json.
const CATAPULT_RENDER := {
	1: {"scale": 0.95, "seat": Vector2(12.8, 67.4)},
	2: {"scale": 0.79, "seat": Vector2(22.7, 59.7)},
	3: {"scale": 1.05, "seat": Vector2(0.0, 72.5)},
}

var units_layer: Node2D
var fx_layer: Node2D
var camera: Camera2D
var hud: CanvasLayer
var menus: CanvasLayer
var pause_menu: PauseMenu

var ash: Unit
var _field_hold := false  # a play-field hold is steering Ash (slides over the HUD)
var gate: Unit
var spawner: WaveSpawner
var tutorial: TutorialController  # TUT-01 waves 1-3 + smithy prompt (nil in sandbox)

# --- map data (from map.json) ---
var map_data := {}
var human_path: Array = []   # [x, y] in original coords, x ascending
var deadite_path: Array = []
var cam_path: Array = []
var cam_min_x := 0.0
var cam_max_x := 0.0
var ally_spawn_x := 62.0
var enemy_spawn_x := 1818.0
var world_rect := Rect2(-400, -800, 3400, 1000)
var wall_archer_posts: Array = []      # godot-space positions of the 6 wall posts
var wall_archer_post_z: Array = []     # compressed Lua z_index per post (same order)
var catapult_post_meta: Array = []     # {idx, pos, scale, z, zi} per catapult post (spawn_index order)
var smithy_post := Vector2.ZERO
var pit_x := 1394.37
var pit_overlay_sprite: Sprite2D = null
var pit_closed_sprite: Sprite2D = null
var pit_open_sprite: Sprite2D = null
var pit_bodies := 0                    # >0 while a victim is in flight (pit open)
var fixture_positions := {}            # type -> [godot positions] (click-to-buy)
var wall_archers: Array = []
var catapults: Array = []

var iron := 0.0
var iron_cap := 50
var iron_rate := IRON_BASE_RATE
# Per-wave only: start_wave re-derives it from the Castle Smithy level, so the purchase never persists.
var iron_level := 1
var enemies_spawned_alive := 0
var enemies_killed := 0
var wave_gold_collected := 0  # in-wave coin pickups (victory tally)
var wave_over := false
var wave_won := false
var wave_push_count := 0

# waves.json wave_51 IS the endless entry; start_wave re-pins saves parked past 51 to it.
const ENDLESS_WAVE := 51
var endless_mode := false
var endless: EndlessDirector = null

# unit_type -> remaining cooldown seconds on its summon button
var button_cooldowns := {}
# spell_id -> remaining cooldown (the HUD shows up to two equipped spells)
var spell_cooldowns := {}
# Alive copies per "unique" ally type: the button stays locked while one lives and re-arms on death.
var _unique_alive := {}

# ids MUST match the spells.json keys — a silent mismatch never equips or casts
const SPELL_PRIORITY := ["arrow_volley", "super_boomstick_blast", "vortex",
	"magic_words", "catapults_spell", "deathcoaster_spell"]

# --- Ash's voice (ash.lua / maingame.lua) -----------------------------------
const ASH_KILL_LINES := [
	"objects_skills_ash_bye_bye", "objects_skills_ash_come_get_some",
	"objects_skills_ash_come_to_papa", "objects_skills_ash_groovy",
	"objects_skills_ash_howd_you_like_the_taste_of_that",
	"objects_skills_ash_shoelace", "objects_skills_ash_that_will_teach_you",
	"objects_skills_ash_thats_gotta_hurt",
	"objects_skills_ash_whats_that_you_got_on_your_face",
	"objects_skills_ash_who_wants_some", "objects_skills_ash_whos_next",
]
const ASH_KILL_COOLDOWN_MS := 3000  # ash.lua time_between_ash_sounds
const ASH_GRUNT_COOLDOWN_MS := 750  # ash.lua time_between_grunt_sounds
const ASH_WIN_LINES := [
	"objects_level_outros_ash_boomstick", "objects_level_outros_ash_buckle_up_bonehead",
	"objects_level_outros_ash_cry_to_mama", "objects_level_outros_ash_give_me_some_sugar_baby",
	"objects_level_outros_ash_guy_with_the_gun", "objects_level_outros_ash_hail_to_the_king_baby",
	"objects_level_outros_ash_names_ash_housewares",
	"objects_level_outros_ash_next_one_of_you_primates",
	"objects_level_outros_ash_pillow_talk", "objects_level_outros_ash_shop_s_mart",
	"objects_level_outros_ash_hello_mr_fancy_pants", "objects_level_outros_ash_london_bridge",
]
var _ash_next_grunt_ms := 0
var _ash_next_kill_ms := 0

var _coins: Array = []
var _projectiles: Array = []
var _sfx_pool: Array = []
var _sfx_meta := {}
var _sfx_streams := {}
var music_player: AudioStreamPlayer
var _spawn_slots: Array = []
var _slot_i := 0
var _kb_running := false
var _shake := 0.0

# --- sandbox mode (--sandbox): art-comparison stage, no waves
var sandbox := false
var sandbox_types: Array = []
var sandbox_i := 0
var sandbox_level := 1
var sandbox_flip := 1.0
var sandbox_clip := ""        # "" -> natural state clips
var sandbox_clip_i := -1
var sandbox_units: Array = []
var _sandbox_label: Label

# --- graphical bg-piece editor (--bgeditor, sandbox boots only) ---
# bg_pieces entry: {leaf, spr, authored, kind, follow} — authored is the pre-override seat; follow shares a parent's offset.
var bg_pieces: Array = []
var _bg_overrides := {}
var _bg_clones: Array = []
var bg_editor: Node = null
# gameplay_anchors_overrides.json rows applied to the PATH ENDS in _load_map; missing file = the mapdata ends.
var _anchor_overrides := {}
# the RAW mapdata ends (original coords, y up) the anchor gizmos measure from
var _anchor_data_ends := {}

const SANDBOX_CLIPS := ["idle", "walk", "attack_a", "attack_b", "attack_c", "damage", "die", "win"]

func _ready() -> void:
	PauseMenu.apply_saved_audio()  # before any hint/flash reads the bus state
	_load_map()

	# Mouse filter IGNORE — with the default STOP this backdrop swallowed every field tap above the castle art.
	var sky := ColorRect.new()
	sky.color = Color(0.02, 0.02, 0.03)
	sky.position = world_rect.position
	sky.size = world_rect.size
	sky.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sky.z_index = Z_BG - 10
	add_child(sky)

	camera = Camera2D.new()
	camera.zoom = Vector2(DEFAULT_ZOOM, DEFAULT_ZOOM)
	camera.position = Vector2(cam_min_x + CAMERA_HALF, _cam_y(cam_min_x + CAMERA_HALF))
	add_child(camera)

	_build_background()
	_build_fixtures()
	_build_lighting()

	units_layer = Node2D.new()
	units_layer.y_sort_enabled = true
	add_child(units_layer)

	fx_layer = Node2D.new()
	add_child(fx_layer)

	_sfx_meta = DB.load_json("res://data/audio_manifest.json")
	if not _sfx_meta.is_empty():
		# dedicated Music/SFX buses so the pause menu's toggles mute them independently of Master
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, "Music")
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, "SFX")
		for i in 10:
			var pl := AudioStreamPlayer.new()
			pl.bus = "SFX"
			add_child(pl)
			_sfx_pool.append(pl)
		music_player = AudioStreamPlayer.new()
		music_player.bus = "Music"
		music_player.volume_db = -10.0
		add_child(music_player)
	_flash_hint("Muted — press M for sound" if AudioServer.is_bus_mute(0) else "Sound on")

	spawner = WaveSpawner.new()
	spawner.main = self
	spawner.all_spawned.connect(_on_all_spawned)
	add_child(spawner)

	hud = load("res://scripts/hud.gd").new()
	hud.main = self
	add_child(hud)

	menus = load("res://scripts/menus.gd").new()
	menus.main = self
	add_child(menus)

	# ESC pause menu
	pause_menu = PauseMenu.new()
	pause_menu.main = self  # restart/quit click sounds route through play_sfx
	add_child(pause_menu)

	# Skipped in sandbox; the smoke harness skips wave 1 too — its hurt modal pauses the tree awaiting a hover no bot can give.
	if not Dbg.args.has("sandbox") and not \
			(Dbg.args.has("smoke-test") and GameState.current_wave == 1):
		tutorial = TutorialController.new()
		tutorial.main = self
		add_child(tutorial)

	_shuffle_slots()
	sandbox = Dbg.args.has("sandbox")
	if sandbox:
		_start_sandbox()
	elif menus.open_main_menu_on_boot():
		pass  # UI-01: the title screen owns the boot; PLAY starts the wave
	else:
		start_wave(GameState.current_wave)

# ------------------------------------------------------------------ map data

func _load_map() -> void:
	map_data = DB.load_json("res://data/map.json")
	human_path = _path_points(map_data.get("paths", {}).get("human_path", []))
	deadite_path = _path_points(map_data.get("paths", {}).get("deadite_path", []))
	cam_path = _path_points(map_data.get("camera_path", []))
	if human_path.is_empty():
		push_error("map.json missing human_path")
		human_path = [Vector2(62, 235), Vector2(1782, 114)]
	if cam_path.is_empty():
		cam_path = [Vector2(257, 282), Vector2(1755, 182)]
	cam_min_x = cam_path[0].x
	cam_max_x = cam_path[-1].x
	_apply_gameplay_anchor_overrides()
	ally_spawn_x = human_path[0].x
	enemy_spawn_x = deadite_path[-1].x if not deadite_path.is_empty() else 1818.0
	# deadite_path is stored left-to-right for interpolation; spawn from its right end
	deadite_path.sort_custom(func(a, b): return a.x < b.x)

func _apply_gameplay_anchor_overrides() -> void:
	## dx moves the path END itself so every reader follows; dy is NOT applied (walk/spawn y interpolates along the path).
	_anchor_data_ends = {}
	if not human_path.is_empty():
		_anchor_data_ends["ally_walk_end"] = Vector2(human_path[-1].x, human_path[-1].y)
		_anchor_data_ends["ally_spawn"] = Vector2(human_path[0].x, human_path[0].y)
	if not deadite_path.is_empty():
		_anchor_data_ends["enemy_spawn"] = Vector2(deadite_path[-1].x, deadite_path[-1].y)
	_anchor_overrides = {}
	var text := FileAccess.get_file_as_string("res://data/gameplay_anchors_overrides.json")
	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if parsed is Dictionary:
		_anchor_overrides = parsed
	elif not text.is_empty():
		push_warning("[anchors] gameplay_anchors_overrides.json unparsable — using the mapdata ends")
	var moved := {}
	if _anchor_overrides.has("ally_spawn") and not human_path.is_empty():
		# Applied before ally_spawn_x derives; keep the dragged end left of the next path point or interpolation degrades.
		human_path[0].x += float((_anchor_overrides["ally_spawn"] as Dictionary).get("dx", 0.0))
		moved["ally_spawn"] = human_path[0].x
	if _anchor_overrides.has("ally_walk_end") and not human_path.is_empty():
		human_path[-1].x += float((_anchor_overrides["ally_walk_end"] as Dictionary).get("dx", 0.0))
		moved["ally_walk_end"] = human_path[-1].x
	if _anchor_overrides.has("enemy_spawn") and not deadite_path.is_empty():
		deadite_path[-1].x += float((_anchor_overrides["enemy_spawn"] as Dictionary).get("dx", 0.0))
		moved["enemy_spawn"] = deadite_path[-1].x
	print("[anchors] walk/spawn ends: ally_spawn x=%.2f, ally_walk_end x=%.2f, enemy_spawn x=%.2f (%d override row(s) applied)" % [
		human_path[0].x, human_path[-1].x,
		deadite_path[-1].x if not deadite_path.is_empty() else 0.0, moved.size()])

func _register_anchor_gizmos() -> void:
	## Registered LAST so the handles grab on top of the door paint they sit on.
	for leaf: String in ["ally_walk_end", "enemy_spawn", "ally_spawn"]:
		var endv: Vector2 = _anchor_data_ends[leaf]
		var m := Node2D.new()
		m.position = _g(endv.x, endv.y)
		if _anchor_overrides.has(leaf):
			m.position.x += float((_anchor_overrides[leaf] as Dictionary).get("dx", 0.0))
		add_child(m)
		bg_pieces.append({"leaf": leaf, "spr": m, "authored": _g(endv.x, endv.y),
			"kind": "anchor", "follow": "", "size": Vector2(46.0, 46.0)})

func _path_points(raw: Array) -> Array:
	## [[x,y,z], ...] -> sorted Vector2 list (original coords, x ascending)
	var out: Array = []
	for p: Variant in raw:
		out.append(Vector2(float(p[0]), float(p[1])))
	out.sort_custom(func(a, b): return a.x < b.x)
	return out

func _g(x: float, y: float) -> Vector2:
	## original map space (y up) -> Godot space (y down)
	return Vector2(x, -y)

func _interp_path(path: Array, x: float) -> float:
	## piecewise-linear y(x) along a path in original coords
	if path.is_empty():
		return 0.0
	if x <= path[0].x:
		return path[0].y
	for i in range(1, path.size()):
		if x <= path[i].x:
			var t: float = (x - path[i - 1].x) / maxf(path[i].x - path[i - 1].x, 0.001)
			return lerpf(path[i - 1].y, path[i].y, t)
	return path[-1].y

func ground_y(x: float) -> float:
	## walkable ground line (original coords) — the human path IS the ground
	return _interp_path(human_path, x)

func _cam_y(x: float) -> float:
	return _interp_path(cam_path, clampf(x, cam_min_x, cam_max_x))

# ---------------------------------------------------------------- background

func _sprite(tex_name: String, center: Vector2, scale_v: Vector2, z: int, pixel := true) -> Sprite2D:
	var s := Sprite2D.new()
	s.texture = load("res://assets/map/%s" % tex_name)
	s.position = center
	s.scale = scale_v
	s.z_index = z
	if pixel:
		s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	add_child(s)
	return s

func _piece(tex_name: String, center: Vector2, world_size: Vector2, z: int) -> Sprite2D:
	## sgx piece: texture is drawn at half its pixel size (world_size is pre-halved)
	var s := _sprite(tex_name, center, Vector2(1, 1), z)
	var ts: Vector2 = s.texture.get_size()
	if ts != Vector2.ZERO:
		s.scale = world_size / ts
	return _register_piece(s, tex_name.get_basename(), "bg")

func _build_background() -> void:
	## Bg parts 1+2 decompose into piece sprites (sizes pre-halved, offsets relative to the part location).
	_apply_bg_overrides()
	_piece("bg_part1_bottom.jpg", Vector2(413.25, -112.36), Vector2(1024, 256), Z_BG)
	var sl := _sprite("bg_part1_bottom.jpg", Vector2(926.75, -112.36), Vector2(0.5, 0.5), Z_BG)
	sl.region_enabled = true
	sl.region_rect = Rect2(2043, 0, 5, 512)
		# The seam strip has no key of its own — it always shares bg_part1_bottom's offset.
	_register_piece(sl, "bg_part1_bottom_seam", "bg", "bg_part1_bottom")
	for part in [["bg_part1", 479.82, 240.36, ""],
			["bg_part2", 1439.5, 240.0, "bg_part2_bottom.jpg"]]:
		var loc := _g(part[1], part[2])
		if part[3] != "":
			_piece(part[3], loc + Vector2(0, 128.0), Vector2(1024, 256), Z_BG)
		_piece(part[0] + "_middle.webp", loc + Vector2(0, -32.0), Vector2(1024, 64), Z_BG)
		_piece(part[0] + "_middle_alpha.webp", loc + Vector2(0, -80.0), Vector2(1024, 32), Z_BG)
	var p1 := _g(479.82, 240.36)
	_piece("bg_part1_topleft.webp", p1 + Vector2(-415.25, -176.0), Vector2(193.5, 160.0), Z_BG)
	_piece("bg_part1_topright_left.webp", p1 + Vector2(-80.0, -176.0), Vector2(69.0, 160.0), Z_BG)
	_piece("bg_part1_topright_middle.webp", p1 + Vector2(18.5, -176.0), Vector2(128.0, 160.0), Z_BG)
	_piece("bg_part1_topright_right.webp", p1 + Vector2(116.25, -176.0), Vector2(67.5, 160.0), Z_BG)
	var p2 := _g(1439.5, 240.0)
	_piece("bg_part2_top_left.webp", p2 + Vector2(-137.75, -113.0), Vector2(284.5, 34.0), Z_BG)
	_piece("bg_part2_top_middle.webp", p2 + Vector2(212.0, -104.0), Vector2(128.0, 16.0), Z_BG)
	_piece("bg_part2_top_right.webp", p2 + Vector2(394.0, -154.0), Vector2(208.0, 116.0), Z_BG)
	if map_data.has("textures"):
		var t3: Dictionary = map_data["textures"].get("texture://objects/world/bg_part3", {})
		if not t3.is_empty():
			_piece(str(t3["file"]), _g(2010.0, 240.0), Vector2(195.5, 512.0), Z_BG + 1)

func _apply_bg_overrides() -> void:
	## Missing/unparsable file = the shipped seats exactly (a typo can never break the map).
	_bg_overrides = {}
	_bg_clones = []
	var text := FileAccess.get_file_as_string("res://data/bg_piece_overrides.json")
	var parsed: Variant = JSON.parse_string(text)
	if parsed is Dictionary and parsed.get("pieces") is Dictionary:
		_bg_overrides = parsed["pieces"]
		var cl: Variant = parsed.get("clones")
		if cl == null:
			pass  # optional key absent
		elif cl is Array:
			_bg_clones = cl
		else:
			push_warning("[bgeditor] bg_piece_overrides.json: \"clones\" must be an array — ignored")
	elif not text.is_empty():
		push_warning("[bgeditor] bg_piece_overrides.json unparsable — using zero offsets")
	print("[bgeditor] %d overrides applied" % _bg_overrides.size())

func _register_piece(spr: Sprite2D, leaf: String, kind: String, follow := "") -> Sprite2D:
	## Follower offsets are ADDITIVE: the parent's offset plus the piece's own residual.
	var off := Vector2.ZERO
	if follow != "" and _bg_overrides.has(follow):
		off += Vector2(float(_bg_overrides[follow].get("dx", 0.0)),
			float(_bg_overrides[follow].get("dy", 0.0)))
	if _bg_overrides.has(leaf):
		off += Vector2(float(_bg_overrides[leaf].get("dx", 0.0)),
			float(_bg_overrides[leaf].get("dy", 0.0)))
	var authored := spr.position
	spr.position += off
	var entry := {"leaf": leaf, "spr": spr, "authored": authored,
		"kind": kind, "follow": follow}
		# Riders hide later in _finish_bg_overrides — they register after this piece, so the flag alone cannot reach them.
	if _bg_overrides.has(leaf) \
			and bool((_bg_overrides[leaf] as Dictionary).get("deleted", false)):
		spr.visible = false
		entry["deleted"] = true
	bg_pieces.append(entry)
	return spr

func _register_clone(spr: Sprite2D, leaf: String, kind: String,
		source_leaf: String, authored: Vector2) -> void:
	## authored = the source's seat, so dx/dy is already baked into position — clones never re-apply overrides.
	bg_pieces.append({"leaf": leaf, "spr": spr, "authored": authored,
		"kind": kind, "follow": "", "clone": true, "source": source_leaf})

func _register_torch_clone(flame: AnimatedSprite2D, leaf: String, rank: int,
		anchor: Vector2) -> void:
	## authored = the source rank's anchor (the dx/dy is anchor-relative).
	bg_pieces.append({"leaf": leaf, "spr": flame, "authored": anchor,
		"kind": "torch", "follow": "", "anchor": anchor,
		"size": Vector2(32.0, 64.0), "glows": [], "clone": true,
		"source": rank})

func _finish_bg_overrides() -> void:
	## Runs only once EVERY registry entry exists — hides deleted pieces' riders, then spawns the piece clones.
	var deleted_n := 0
	var rider_n := 0
	for e: Dictionary in bg_pieces:
		if not bool(e.get("deleted", false)):
			continue
		deleted_n += 1
		var leaf: String = e["leaf"]
		for r: Dictionary in bg_pieces:
			if str(r["follow"]) == leaf \
					and not bool(r.get("deleted", false)) \
					and (r["spr"] as CanvasItem).visible:
				(r["spr"] as CanvasItem).visible = false
				rider_n += 1
	print("[bgeditor] deleted pieces hidden: %d (+%d rider(s) with them)" % [
		deleted_n, rider_n])
	var spawned := 0
	for i in range(_bg_clones.size()):
		var c: Variant = _bg_clones[i]
		if not (c is Dictionary):
			push_warning("[bgeditor] bg_piece_overrides.json: clones[%d] is not an object — skipped" % i)
			continue
		var cd: Dictionary = c
		if bool(cd.get("deleted", false)):
			continue  # a deleted clone: accepted, not spawned
		var src_leaf := str(cd.get("source", ""))
		var src_i := -1
		for j in range(bg_pieces.size()):
			if str(bg_pieces[j]["leaf"]) == src_leaf:
				src_i = j
				break
		if src_i < 0:
			push_warning("[bgeditor] bg_piece_overrides.json: clone source \"%s\" is not a known piece — skipped" % src_leaf)
			continue
		var src: Dictionary = bg_pieces[src_i]
		if str(src["kind"]) == "torch":
			push_warning("[bgeditor] bg_piece_overrides.json: clone source \"%s\" is a torch — torch clones live in torch_overrides.json — skipped" % src_leaf)
			continue
		var dxv: Variant = cd.get("dx", 0.0)
		var dyv: Variant = cd.get("dy", 0.0)
		if not (dxv is float or dxv is int) or not (dyv is float or dyv is int):
			push_warning("[bgeditor] bg_piece_overrides.json: clone \"%s\" dx/dy must be numbers — skipped" % src_leaf)
			continue
		var src_spr := src["spr"] as Sprite2D
		var dup := Sprite2D.new()
		dup.texture = src_spr.texture
		dup.region_enabled = src_spr.region_enabled
		dup.region_rect = src_spr.region_rect
		dup.scale = src_spr.scale
		dup.z_index = src_spr.z_index
		dup.texture_filter = src_spr.texture_filter
		dup.position = (src["authored"] as Vector2) \
			+ Vector2(float(dxv), float(dyv))
		# the moon is a CAMERA child (camera-space seat) — its clone must be one too
		if src_spr.get_parent() == camera:
			camera.add_child(dup)
		else:
			add_child(dup)
		_register_clone(dup, "%s_clone%d" % [src_leaf, i + 1],
			str(src["kind"]), src_leaf, src["authored"])
		spawned += 1
	print("[bgeditor] piece clones spawned: %d/%d" % [spawned, _bg_clones.size()])

func _register_torch(flame: AnimatedSprite2D, rank: int, anchor: Vector2) -> void:
	## Editor fields: "anchor" (mapdata fire point; the JSON offset is FULL), "size" (one 32x64 frame px), "glows" (pool sprites attached by _add_glow).
	bg_pieces.append({"leaf": "torch_%d" % rank, "spr": flame,
		"authored": flame.position, "kind": "torch", "follow": "",
		"anchor": anchor, "size": Vector2(32.0, 64.0), "glows": []})

func _build_fixtures() -> void:
	## Textures are 2px/world, so fixture sprites draw at HALF pixel size.
	var objs: Array = map_data.get("objects", [])

	# moon is a CAMERA child — its seat is a camera-space offset (pinned on screen), not a world position.
	for o: Dictionary in objs:
		if str(o.get("attrs", {}).get("type", "")) == "moon":
			var s := _fix_sprite(o, Z_BG - 5, 1.0, 0.63)
			if s != null:
				s.get_parent().remove_child(s)
				s.position = Vector2(-172.0, -223.0)  # frame2: crescent peeks from behind the gate tower
				camera.add_child(s)
				# Its seat is CAMERA-space, so bg_editor resolves its rect through global_position.
				_register_piece(s, "moon", "fixture")
	# gate is spawned as a Unit in start_wave; skip here

	# upgrade posts — click targets for buying (icons behind units)
	var archer_objs: Array = []   # {idx, pos, z} — spawn order comes from spawn_index
	var catapult_objs: Array = [] # {idx, pos, scale, z} — same spawn_index ordering
	for o: Dictionary in objs:
		var attrs: Dictionary = o.get("attrs", {})
		var otype := str(attrs.get("type", ""))
		if otype == "inner_wall_archer":
			var loc: Array = o.get("location", [0, 0, 0])
			# The mapdata array order is NOT the buy order — attrs.spawn_index is.
			archer_objs.append({
				"idx": int(float(attrs.get("spawn_index", 0.0))),
				"pos": _g(float(loc[0]), float(loc[1])),
				"z": float(loc[2]),
			})
		elif otype == "catapults":
			# Array order is idx2/idx1/idx3, NOT sorted; render constants come from CATAPULT_RENDER, not raw mapdata.
			var loc2: Array = o.get("location", [0, 0, 0])
			var size2: Array = o.get("size", [1.0, 1.0, 1.0])
			catapult_objs.append({
				"idx": int(float(attrs.get("spawn_index", 0.0))),
				"pos": _g(float(loc2[0]), float(loc2[1])),
				"scale": float(size2[0]),
				"size_y": float(size2[1]),
				"z": float(loc2[2]),
			})
		elif otype == "smithy":
			var loc3: Array = o.get("location", [0, 0, 0])
			smithy_post = _g(float(loc3[0]), float(loc3[1]))
			fixture_positions["smithy"] = [smithy_post]
	# buy order: post #1 first, so level N seats archers on posts #1..N
	archer_objs.sort_custom(func(a, b): return int(a["idx"]) < int(b["idx"]))
	catapult_objs.sort_custom(func(a, b): return int(a["idx"]) < int(b["idx"]))
	for cm: Dictionary in catapult_objs:
		catapult_post_meta.append(cm)
		fixture_positions["catapults"] = fixture_positions.get("catapults", []) + [cm["pos"]]
	# Raw Lua z's compress into Godot slots just above Z_BG — a raw-z pass-through would sink the wall fixtures behind the bg.
	var wall_zs: Array = []
	for ao: Dictionary in archer_objs:
		wall_zs.append(float(ao["z"]))
	for o: Dictionary in objs:
		if str(o.get("texture", "")).contains("backwall_mask"):
			var locz: Array = o.get("location", [0, 0, 0])
			wall_zs.append(float(locz[2]))
	# idx2 (raw z -409) sorts into the backwall band; the courtyard posts keep their field depth at spawn.
	for cm: Dictionary in catapult_objs:
		if float(cm["z"]) < 0.0:
			wall_zs.append(float(cm["z"]))
	wall_zs.sort()
	wall_zs.reverse()  # descending: closest (least negative raw z) first
	for ao: Dictionary in archer_objs:
		wall_archer_posts.append(ao["pos"])
		wall_archer_post_z.append(-11 - wall_zs.find(float(ao["z"])))
		fixture_positions["inner_wall_archer"] = fixture_positions.get("inner_wall_archer", []) + [ao["pos"]]
	for cm: Dictionary in catapult_post_meta:
		# Z_FG exactly — Z_FG+1 is the glow-halo slot; the equal-z tie resolves machine-first (units_layer added after _build_fixtures).
		cm["zi"] = Z_FG if float(cm["z"]) > 0.0 \
			else -11 - wall_zs.find(float(cm["z"]))

	# pit_open boots hidden — the editor skips invisible sprites, so it can never be grabbed instead of pit_closed beneath it.
	for o: Dictionary in objs:
		var tex2 := str(o.get("texture", ""))
		if tex2.ends_with("pit_overlay"):
			pit_overlay_sprite = _fix_sprite(o, Z_BG + 2, 1.0)
			if pit_overlay_sprite != null:
				_register_piece(pit_overlay_sprite, "pit_overlay", "fixture")
		elif tex2.ends_with("pit_closed"):
			pit_closed_sprite = _fix_sprite(o, Z_BG + 2, 1.0)
			if pit_closed_sprite != null:
				_register_piece(pit_closed_sprite, "pit_closed", "fixture")
			var loc4: Array = o.get("location", [0, 0, 0])
			pit_x = float(loc4[0])
		elif tex2.ends_with("pit_open"):
			pit_open_sprite = _fix_sprite(o, Z_BG + 2, 1.0)
			if pit_open_sprite != null:
				pit_open_sprite.visible = false
				_register_piece(pit_open_sprite, "pit_open", "fixture")
	# The torch flame pass runs after the mask loop below, so equal-z ties resolve flame-over-mask.
	# Foreground masks render IN FRONT of units; backwall masks take the compressed slots computed above.
	var fg_masks := 0
	var fg_seated := 0
	for o: Dictionary in objs:
		var tex3 := str(o.get("texture", ""))
		if tex3.contains("_mask"):
			var loc5: Array = o.get("location", [0, 0, 0])
			if tex3.contains("backwall_mask"):
				# Pixel-exact tower paint copies at HALF-pixel scale 0.5, displaced per BACKWALL_MASK_CENTERS.
				var spr := _fix_sprite(o, -11 - wall_zs.find(float(loc5[2])),
					1.0, 0.5)
				var leaf := tex3.get_file()
				if spr != null and BACKWALL_MASK_CENTERS.has(leaf):
					spr.position = BACKWALL_MASK_CENTERS[leaf]
				if spr != null:
					# masks are editor-movable (--bgmasks toggle)
					_register_piece(spr, leaf, "mask")
			elif float(loc5[2]) > 0.0:
				fg_masks += 1
				var fg := _fix_sprite(o, Z_FG, 1.0)
				# Matched centers align the paint 1:1 with the bg beneath (raw mapdata centers cut a seam).
				var fgleaf := tex3.get_file()
				if fg != null and FG_MASK_CENTERS.has(fgleaf):
					fg.position = FG_MASK_CENTERS[fgleaf]
					fg_seated += 1
				if fg != null:
					# These ride bg_part1_bottom: an editor drag of the strip moves the flights instead of tearing them off.
					_register_piece(fg, fgleaf, "mask",
						"bg_part1_bottom" if fgleaf.begins_with("wall_mask_") else "")
	# Boot check: a key mismatch here means masks draw at raw mapdata centers.
	print("[r14] fg mask seats: %d/%d applied" % [fg_seated, fg_masks])

	# The mapdata fire_sprite objects ARE battle scenery: the live flipbook draws on top of the baked flame paint.
	var fire_tex: Texture2D = load("res://assets/map/fire_sprite.webp")
	if fire_tex != null:
		# Frame 0 is the TOP-left cell of the 4x2 grid.
		var fire_frames := SpriteFrames.new()
		fire_frames.set_animation_speed("default", 15.0)
		fire_frames.set_animation_loop("default", true)
		for i in range(8):
			var fat := AtlasTexture.new()
			fat.atlas = fire_tex
			fat.region = Rect2(float(i % 4) * 32.0, 0.0 if i < 4 else 64.0,
				32.0, 64.0)
			fire_frames.add_frame("default", fat)
		# distinct raw z's of the wall band (computed above, no fires in it)
		var band_zs: Array = []
		for wz: Variant in wall_zs:
			if not band_zs.has(wz):
				band_zs.append(wz)
		# Each flame's MIDDLE EMBER centers on the baked ember-core color #fdfd77.
		var tcfg := _torch_config(objs)
		var ranks := _fire_point_ranks(objs)
		# Spawn live flames ONLY at config-enabled ranks — disabled anchors revert to baked-paint-only.
		var flames_spawned := 0
		for o: Dictionary in objs:
			if not str(o.get("texture", "")).contains("fire_sprite"):
				continue
			var floc: Array = o.get("location", [0, 0, 0])
			var fz := float(floc[2])
			var fkey := "%.2f,%.2f" % [float(floc[0]), float(floc[1])]
			if not (tcfg["flames"] as Dictionary).has(fkey):
				continue
			var tw: Dictionary = tcfg["tweaks"][fkey]
			var flame := AnimatedSprite2D.new()
			flame.sprite_frames = fire_frames
			# The JSON "offset" seats the art's middle ember on the baked #fdfd77 core.
			flame.position = _g(float(floc[0]), float(floc[1])) \
				+ (tw["offset"] as Vector2)
			# The JSON "scale" multiplies about the sprite center so the ember seating scales with the art.
			flame.scale = Vector2.ONE * (EFFECT_TEXEL * float(tw["scale"]))
			flame.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			if fz > 0.0:
				# Rank 16 (culled today): units walk BEHIND it in the +400 band.
				flame.z_index = Z_FG
			else:
				# Clamp at -19 so no flame sinks behind the bg paint at Z_BG.
				var closer := 0
				for bz: Variant in band_zs:
					if float(bz) > fz:
						closer += 1
				flame.z_index = maxi(-11 - closer, -19)
			add_child(flame)
			flame.play("default")
			flames_spawned += 1
			_register_torch(flame, int(ranks[fkey]),
				_g(float(floc[0]), float(floc[1])))

		print("[r14] torch flames spawned: %d/16 mapdata points (config: %s)" % [
			flames_spawned,
			"torch_overrides.json" if tcfg["json"] \
				else "engine fallback (_TORCH_SHIPPED)"])

		# Per-rank facts for the clone pass; a disabled rank carries no "z" and its clone re-derives the slot.
		var flame_meta := {}
		for o: Dictionary in objs:
			if not str(o.get("texture", "")).contains("fire_sprite"):
				continue
			var mloc: Array = o.get("location", [0, 0, 0])
			var mkey := "%.2f,%.2f" % [float(mloc[0]), float(mloc[1])]
			if not ranks.has(mkey):
				continue
			var mrank := int(ranks[mkey])
			var mtw: Dictionary = (tcfg["tweaks"] as Dictionary)[mkey]
			var meta := {"anchor": _g(float(mloc[0]), float(mloc[1])),
				"fz": float(mloc[2]), "scale": float(mtw["scale"])}
			for e: Dictionary in bg_pieces:
				if str(e["kind"]) == "torch" and not bool(e.get("clone", false)) \
						and str(e["leaf"]) == "torch_%d" % mrank:
					meta["z"] = (e["spr"] as Node2D).z_index
					break
			flame_meta[mrank] = meta

		# A clone of a disabled rank spawns standalone — the rank needs no live flame.
		var clone_spawned := 0
		var clone_i := 0
		for c: Dictionary in (tcfg["clones"] as Array):
			clone_i += 1
			var crank: int = c["rank"]
			var cmeta: Dictionary = flame_meta.get(crank, {})
			if cmeta.is_empty():
				push_warning("[r14] torch_overrides.json: clones[%d] source rank %d is not a mapdata fire point — skipped" % [clone_i - 1, crank])
				continue
			var cflame := AnimatedSprite2D.new()
			cflame.sprite_frames = fire_frames
			cflame.position = (cmeta["anchor"] as Vector2) + (c["delta"] as Vector2)
			cflame.scale = Vector2.ONE * (EFFECT_TEXEL * float(cmeta["scale"]))
			cflame.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			if cmeta.has("z"):
				cflame.z_index = int(cmeta["z"])  # the source flame's resolved slot
			else:
				# source rank disabled (no live flame): recompute the band rule
				var ccloser := 0
				for cbz: Variant in band_zs:
					if float(cbz) > float(cmeta["fz"]):
						ccloser += 1
				cflame.z_index = maxi(-11 - ccloser, -19)
			add_child(cflame)
			cflame.play("default")
			clone_spawned += 1
			_register_torch_clone(cflame, "torch_%d_clone%d" % [crank, clone_i],
				crank, cmeta["anchor"])
		if clone_spawned > 0:
			print("[r14] torch clones spawned: %d" % clone_spawned)

	# rider hiding + piece clones — the whole registry must exist by now
	_finish_bg_overrides()
	_register_anchor_gizmos()

	_spawn_blacksmith()

## User #N = x-sorted rank N (map.json array order is NOT x-sorted).
func _fire_point_ranks(objs: Array) -> Dictionary:
	var entries: Array = []  # { "key": String, "x": float }
	for o: Dictionary in objs:
		if str(o.get("texture", "")).contains("fire_sprite"):
			var fl: Array = o.get("location", [0, 0, 0])
			entries.append({
				"key": "%.2f,%.2f" % [float(fl[0]), float(fl[1])],
				"x": float(fl[0]),
			})
	entries.sort_custom(func(a, b) -> bool: return a["x"] < b["x"])
	var ranks := {}
	for i in entries.size():
		ranks[entries[i]["key"]] = i + 1
	return ranks

# torch_overrides.json resolved once and cached — {"flames", "tweaks", "json", "clones"}; shared by flame + glow passes so they cull together.
var _torch_cfg := {}
var _torch_cfg_loaded := false
const TORCH_CFG_PATH := "res://data/torch_overrides.json"

func _torch_config(objs: Array) -> Dictionary:
	if _torch_cfg_loaded:
		return _torch_cfg
	_torch_cfg_loaded = true
	var by_rank := {}
	for r in range(1, 17):
		# a fresh row per rank: _TORCH_SHIPPED's rows are const (read-only)
		var shipped: Dictionary = _TORCH_SHIPPED[r]
		by_rank[r] = {"enabled": shipped["enabled"], "offset": shipped["offset"],
			"scale": shipped["scale"], "glow_offset": Vector2.ZERO}
	var from_json := false
	var fallback_warn := "[r14] %s missing/invalid — falling back to shipped torch placement (ranks 7-14); see work/tmp_final14/TORCH_HOWTO.md" % TORCH_CFG_PATH
	var parsed: Variant = null  # the raw JSON root (also read by the R14-20 clones block)
	if FileAccess.file_exists(TORCH_CFG_PATH):
		parsed = JSON.parse_string(
			FileAccess.get_file_as_string(TORCH_CFG_PATH))
		if parsed is Dictionary \
				and (parsed as Dictionary).get("torches") is Dictionary:
			# Ranks the JSON omits default to disabled + identity, not to the fallback.
			by_rank = {}
			for r in range(1, 17):
				by_rank[r] = {"enabled": false, "offset": Vector2.ZERO,
					"scale": 1.0, "glow_offset": Vector2.ZERO}
			var torches: Dictionary = (parsed as Dictionary)["torches"]
			for rank_s: String in torches:
				var rank := rank_s.to_int()
				if rank < 1 or rank > 16:
					push_warning("[r14] torch_overrides.json: ignoring unknown rank \"%s\" (valid: 1-16)" % rank_s)
					continue
				var row: Variant = torches[rank_s]
				if not (row is Dictionary):
					push_warning("[r14] torch_overrides.json: rank %d is not an object — ignored" % rank)
					continue
				var rd: Dictionary = row
				var tw := {"enabled": bool(rd.get("enabled", false)),
					"offset": Vector2.ZERO, "scale": 1.0,
					"glow_offset": Vector2.ZERO}
				var off: Variant = rd.get("offset", [0.0, 0.0])
				if off is Array and (off as Array).size() == 2:
					tw["offset"] = Vector2(float((off as Array)[0]),
						float((off as Array)[1]))
				else:
					push_warning("[r14] torch_overrides.json: rank %d offset must be [x, y] — using [0, 0]" % rank)
				var goff: Variant = rd.get("glow_offset", [0.0, 0.0])
				if goff is Array and (goff as Array).size() == 2:
					tw["glow_offset"] = Vector2(float((goff as Array)[0]),
						float((goff as Array)[1]))
				else:
					push_warning("[r14] torch_overrides.json: rank %d glow_offset must be [x, y] — using [0, 0]" % rank)
				var sc: Variant = rd.get("scale", 1.0)
				if (sc is float or sc is int) and float(sc) > 0.0:
					tw["scale"] = float(sc)
				else:
					push_warning("[r14] torch_overrides.json: rank %d scale must be a positive number — using 1.0" % rank)
				by_rank[rank] = tw
			from_json = true
		else:
			push_warning(fallback_warn)
	else:
		push_warning(fallback_warn)
	# Clones resolve to {rank, delta, glow_offset} — the source rank's glow seat rides along.
	var torch_clones: Array = []
	if from_json:
		var cl: Variant = parsed.get("clones")
		if cl == null:
			pass  # optional key absent
		elif cl is Array:
			var ci := -1
			for cv: Variant in cl:
				ci += 1
				if not (cv is Dictionary):
					push_warning("[r14] torch_overrides.json: clones[%d] is not an object — skipped" % ci)
					continue
				var cd: Dictionary = cv
				if bool(cd.get("deleted", false)):
					continue
				var crank := int(cd.get("source", 0))
				if crank < 1 or crank > 16:
					push_warning("[r14] torch_overrides.json: clones[%d] source must be a rank 1-16 — skipped" % ci)
					continue
				var cdx: Variant = cd.get("dx", 0.0)
				var cdy: Variant = cd.get("dy", 0.0)
				if not (cdx is float or cdx is int) \
						or not (cdy is float or cdy is int):
					push_warning("[r14] torch_overrides.json: clones[%d] dx/dy must be numbers — skipped" % ci)
					continue
				torch_clones.append({"rank": crank,
					"delta": Vector2(float(cdx), float(cdy)),
					"glow_offset": by_rank[crank]["glow_offset"]})
		else:
			push_warning("[r14] torch_overrides.json: \"clones\" must be an array — ignored")
	# resolve the per-rank decisions onto the x-sorted mapdata keys
	var ranks := _fire_point_ranks(objs)
	var flames := {}
	var tweaks := {}
	for fkey: String in ranks:
		var rank := int(ranks[fkey])
		var tw: Dictionary = by_rank[rank]
		tweaks[fkey] = {"offset": tw["offset"], "scale": tw["scale"],
			"glow_offset": tw["glow_offset"]}
		if tw["enabled"]:
			flames[fkey] = true
	_torch_cfg = {"flames": flames, "tweaks": tweaks, "json": from_json,
		"clones": torch_clones}
	return _torch_cfg

# ------------------------------------------------------------------ lighting

var _glows: Array = []
# anvil-spark phase-lock watchers, ticked every frame against the smithy's animation clock
var _anvil_watchers: Array = []

func _build_lighting() -> void:
	## The flame sprites/modulate must NOT be tinted — only the glow constants below move.
	var pool_a := 0.13  # R11-05: was 0.28 (T34 round 8)
	var core_a := 0.06  # R11-05: was 0.18 (T34 round 8)
	var pool_r := 90.0
	var tex := GradientTexture2D.new()
	tex.width = 256
	tex.height = 256
	tex.fill = GradientTexture2D.FILL_RADIAL
	tex.fill_from = Vector2(0.5, 0.5)
	tex.fill_to = Vector2(0.5, 0.0)
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.62, 0.28, pool_a))
		# NB: no mid-stop — Gradient.add_point() renders this GradientTexture2D as broken flat quads in Godot 4.7.2.
	grad.set_color(1, Color(1.0, 0.45, 0.12, 0.0))
	tex.gradient = grad
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	# hot inner core — the original's pools read bright right at the flame
	var core := GradientTexture2D.new()
	core.width = 128
	core.height = 128
	core.fill = GradientTexture2D.FILL_RADIAL
	core.fill_from = Vector2(0.5, 0.5)
	core.fill_to = Vector2(0.5, 0.0)
	var cgrad := Gradient.new()
	cgrad.set_color(0, Color(1.0, 0.72, 0.34, core_a))
	cgrad.set_color(1, Color(1.0, 0.5, 0.16, 0.0))
	core.gradient = cgrad

	# These pools ARE per-torch and must cull with the flames or they'd halo empty baked-paint-only sconces.
	var objs: Array = map_data.get("objects", [])
	var tcfg := _torch_config(objs)
	var ranks := _fire_point_ranks(objs)
	var anchors: Array[Vector2] = []
	var anchor_ranks: Array[int] = []   # parallel: the torch rank (0 = forge)
	var anchor_tweaks: Array[Dictionary] = []  # parallel: the rank's cfg row
	for o: Dictionary in objs:
		if str(o.get("texture", "")).contains("fire_sprite"):
			var loc: Array = o.get("location", [0, 0, 0])
			var lk := "%.2f,%.2f" % [float(loc[0]), float(loc[1])]
			if not (tcfg["flames"] as Dictionary).has(lk):
				continue
			anchors.append(_g(float(loc[0]), float(loc[1])))
			anchor_ranks.append(int(ranks[lk]))
			anchor_tweaks.append((tcfg["tweaks"] as Dictionary)[lk])
	anchors.append(_g(1290.0, 250.0))
	anchor_ranks.append(0)  # the forge — not a torch, follows nothing
	anchor_tweaks.append({})
	if not Dbg.args.is_empty():
		print("[r12] glow pools: %d anchors (%d kept torches + 1 forge)" % [
			anchors.size(), anchors.size() - 1])
	# Overlap diminishing keeps clusters from merging into one wash.
	var dims: Array[float] = []
	for i in anchors.size():
		var w := 0.0
		for j in anchors.size():
			if j != i:
				w += clampf(1.0 - anchors[i].distance_to(anchors[j]) \
					/ (pool_r * 2.0), 0.0, 1.0)
		dims.append(1.0 / (1.0 + 0.9 * w))
	for i in anchors.size():
		var is_forge := anchor_ranks[i] == 0
		# The forge fire is a touch wider to light the shop front.
		var glow_off: Vector2 = anchor_tweaks[i].get("glow_offset", Vector2.ZERO)
		_add_glow(anchors[i] + glow_off, tex, mat,
			105.0 if is_forge else pool_r, dims[i], anchor_ranks[i])
		# A wider additive core bloomed the painted flame white — keep the core tight.
		_add_glow(anchors[i] + glow_off, core, mat,
			36.0 if is_forge else 15.0, dims[i], anchor_ranks[i])

	# Clone halos attach to the clone's registry entry so the editor drag moves them too.
	for c: Dictionary in (tcfg["clones"] as Array):
		var cleaf := "torch_%d_clone%d" % [int(c["rank"]),
			(tcfg["clones"] as Array).find(c) + 1]
		var centry: Dictionary
		var found := false
		for e: Dictionary in bg_pieces:
			if str(e["leaf"]) == cleaf:
				centry = e
				found = true
				break
		if not found:
			continue  # the fire pass warned and skipped this entry
		var cseat: Vector2 = (centry["spr"] as Node2D).position \
			+ (c["glow_offset"] as Vector2)
		var cw := 0.0
		for a: Vector2 in anchors:
			cw += clampf(1.0 - cseat.distance_to(a) / (pool_r * 2.0), 0.0, 1.0)
		var cdim := 1.0 / (1.0 + 0.9 * cw)
		_add_glow(cseat, tex, mat, pool_r, cdim, 0, cleaf)
		_add_glow(cseat, core, mat, 15.0, cdim, 0, cleaf)

	# soft vignette over the world, under the HUD
	var layer := CanvasLayer.new()
	layer.layer = 5
	add_child(layer)
	var rect := ColorRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	rect.material = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = """
shader_type canvas_item;
uniform float strength : hint_range(0.0, 1.0) = 0.30;
void fragment() {
	float d = distance(SCREEN_UV, vec2(0.5, 0.48));
	float v = smoothstep(0.32, 0.78, d) * strength;
	COLOR = vec4(0.0, 0.0, 0.02, v);
}
"""
	(rect.material as ShaderMaterial).shader = sh
	layer.add_child(rect)

func _add_glow(pos: Vector2, tex: Texture2D, mat: Material, radius := 90.0,
		dim := 1.0, rank := 0, leaf := "") -> void:
	var s := Sprite2D.new()
	s.texture = tex
	s.material = mat
	s.position = pos
	s.scale = Vector2.ONE * (radius * 2.0 / 256.0)
	# NOT Z_BG+3 — the mask_03 tower patch tree-order draws over the halo there and slices it.
	s.z_index = Z_FG + 1
	add_child(s)
	_glows.append({"spr": s, "dim": dim, "phase": randf() * TAU, "speed": randf_range(5.0, 8.0)})
	# `leaf` routes a torch CLONE's pools to the clone's own entry; the forge (rank 0) follows nothing.
	if rank > 0 or leaf != "":
		var want := leaf if leaf != "" else "torch_%d" % rank
		for e: Dictionary in bg_pieces:
			if str(e["kind"]) == "torch" and str(e["leaf"]) == want:
				if not e.has("glow_base"):
					e["glow_base"] = s.position  # both pools share the seat
				(e["glows"] as Array).append(s)
				break

## Sparks ride the npc seat — moving the smith moves the sparks.
const SMITHY_SEAT := Vector2(43.0, 58.0)
const SMITHY_SPARK_SEAT := Vector2(30.0, -20.0)

func _smithy_overrides() -> Dictionary:
	## Offsets ADDED to the shipped seats; missing file = shipped seats exactly.
	var out := {"smithy": {}, "sparks": {}}
	var text := FileAccess.get_file_as_string("res://data/smithy_overrides.json")
	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if parsed is Dictionary:
		for k: String in ["smithy", "sparks"]:
			if (parsed as Dictionary).get(k) is Dictionary:
				out[k] = (parsed as Dictionary)[k]
	elif not text.is_empty():
		push_warning("[smithy] smithy_overrides.json unparsable — using the shipped seats")
	return out

func _spawn_blacksmith() -> void:
	## A background prop: never moves, never targeted.
	if smithy_post == Vector2.ZERO or \
			not DB.load_json("res://data/unit_anims.json").has("smithy"):
		return
	var npc := _make_unit("smithy", 1, Unit.Team.ALLY)
	npc.is_wall_archer = true  # skips the terrain-line stick like other props
	npc.ai_enabled = false
	npc.is_prop = true
	npc.anim_lock = "hammertime"
	# The mapdata point projects onto the roof in our flat port; SMITHY_SEAT lands him on the shop floor.
	var smithy_ov := _smithy_overrides()
	var smithy_off := Vector2(float((smithy_ov["smithy"] as Dictionary).get("dx", 0.0)),
		float((smithy_ov["smithy"] as Dictionary).get("dy", 0.0)))
	var npc_seat := smithy_post + SMITHY_SEAT
	npc.body_scale = 0.72
	npc.position = npc_seat + smithy_off
	npc.z_index = Z_BG + 2
	add_child(npc)
	# The sparks entry FOLLOWS smithy_npc; its own row is a residual on top.
	bg_pieces.append({"leaf": "smithy_npc", "spr": npc, "authored": npc_seat,
		"kind": "smithy", "follow": "", "size": Vector2(60.0, 110.0)})
	_start_anvil_sparks(npc, npc_seat, smithy_off, smithy_ov)

func _start_anvil_sparks(npc: Unit, npc_seat: Vector2, smithy_off: Vector2,
		smithy_ov: Dictionary) -> void:
	## Phase-locked to the animation clock (see _tick_anvil_sparks), not a wall Timer.
	var burst := CPUParticles2D.new()
	burst.texture = load("res://assets/fx/spark.webp")
	burst.amount = 10
	burst.one_shot = true
	burst.explosiveness = 1.0
	burst.lifetime = 1.0
	burst.position = npc_seat + smithy_off + SMITHY_SPARK_SEAT \
		+ Vector2(float((smithy_ov["sparks"] as Dictionary).get("dx", 0.0)),
			float((smithy_ov["sparks"] as Dictionary).get("dy", 0.0)))
	burst.emission_shape = CPUParticles2D.EMISSION_SHAPE_SPHERE
	burst.emission_sphere_radius = 20.0
	burst.direction = Vector2(0.2, -1.0)
	burst.spread = 60.0
	burst.initial_velocity_min = 50.0
	burst.initial_velocity_max = 150.0
	burst.gravity = Vector2(0, 400)
	burst.angular_velocity_min = 360.0
	burst.angular_velocity_max = 720.0
	burst.scale_amount_min = 0.24
	burst.scale_amount_max = 0.24
	var shrink := Curve.new()
	shrink.add_point(Vector2(0.0, 1.0))
	shrink.add_point(Vector2(1.0, 0.0))
	burst.scale_amount_curve = shrink
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.4, 0.0, 1.0))
	grad.set_color(1, Color(1.0, 1.0, 0.0, 0.0))
	burst.color_ramp = grad
	# At the npc's own z the shower rendered behind the shop front art.
	burst.z_index = 5
	add_child(burst)
	# authored = the DEFAULT burst seat (no gizmo rows applied).
	bg_pieces.append({"leaf": "smithy_sparks", "spr": burst,
		"authored": npc_seat + SMITHY_SPARK_SEAT, "kind": "smithy",
		"follow": "smithy_npc", "size": Vector2(56.0, 56.0)})
	# A wall-clock Timer drifted ~1 frame per loop (LOOP_NONE replay + cross-blend); the watcher reads the playhead instead.
	var strike_t := float(Unit.STRIKE_TIMES["smithy"]["hammertime"])
	if npc.actor3d != null:
		_anvil_watchers.append(
			{"npc": npc, "burst": burst, "prev": -1.0, "strike": strike_t})
	else:
		# Headless fallback: no AnimationPlayer playhead to read, so a phase timer stays.
		var t := Timer.new()
		t.wait_time = strike_t
		t.one_shot = true
		t.timeout.connect(func() -> void:
			burst.restart()
			t.one_shot = false  # a one_shot timer fired a second time would stop
			t.wait_time = 1.0
			t.start())
		add_child(t)
		t.start()

func _tick_anvil_sparks() -> void:
	## `c >= 0.0` guards the not-playing sentinel (-1.0) from masquerading as a LOOP_NONE wrap.
	for w: Dictionary in _anvil_watchers:
		var burst := w["burst"] as CPUParticles2D
		var npc := w["npc"] as Unit
		if not is_instance_valid(npc) or not is_instance_valid(burst):
			continue
		var c: float = npc.actor3d.anim_clock()
		var prev := float(w["prev"])
		w["prev"] = c
		if prev < float(w["strike"]) \
				and (c >= float(w["strike"]) or (c >= 0.0 and c < prev)):
			burst.restart()

func _fix_sprite(o: Dictionary, z: int, alpha: float, scale_f := 0.5) -> Sprite2D:
	## Archon textures are 2px/world, so fixtures draw at HALF pixel size.
	var uri := str(o.get("texture", ""))
	var info: Dictionary = map_data.get("textures", {}).get(uri, {})
	if info.is_empty():
		return null
	var loc: Array = o.get("location", [0, 0, 0])
	var s := _sprite(str(info["file"]), _g(float(loc[0]), float(loc[1])),
		Vector2(scale_f, scale_f), z)
	s.modulate.a = alpha
	return s

# ------------------------------------------------------------------- waves

func _shuffle_slots() -> void:
	# util.shuffleSpawnSlots: depth lanes so units overlap believably.
	_spawn_slots = [-18.0, -12.0, -6.0, 0.0, 6.0, 12.0, 18.0]
	_spawn_slots.shuffle()

func _next_slot() -> float:
	if _slot_i >= _spawn_slots.size():
		_slot_i = 0
	var v: float = _spawn_slots[_slot_i]
	_slot_i += 1
	return v

func start_wave(n: int) -> void:
	wave_over = false
	wave_won = false
	wave_push_count = 0
	enemies_spawned_alive = 0
	enemies_killed = 0
	iron = 0.0
	wave_gold_collected = 0
	gate_last_hit_at = 0  # fresh wave: the protect-the-book window is closed
	_gate_warn_t = 0.0
	# The iron-priced chip upgrade is per-wave; this re-boot from the Castle Smithy level resets it.
	iron_level = clampi(GameState.get_castle_level("smithy"), 1, 4)
	iron_cap = int(DB.table("globals").get("iron_level_cap", [50])[iron_level - 1])
	iron_rate = IRON_BASE_RATE * pow(1.5, float(iron_level - 1))
	button_cooldowns.clear()
	spell_cooldowns.clear()
	_unique_alive.clear()

	for c in units_layer.get_children():
		c.queue_free()
	for c in fx_layer.get_children():
		c.queue_free()
	_coins.clear()
	_projectiles.clear()

	_spawn_battlefield_actors()

	endless_mode = n >= ENDLESS_WAVE
	if endless_mode:
		# Pins the save to the endless sentinel so labels read "Wave INF", not "Wave 52".
		GameState.current_wave = ENDLESS_WAVE
		if endless != null:
			endless.queue_free()
		endless = EndlessDirector.new()
		endless.main = self
		add_child(endless)
		endless.start()
		# no timeline: empty events also keep the field-clear WIN check inert
		spawner.start({})
	else:
		spawner.start(DB.get_wave_data(n))
	hud.on_wave_started(n)
	if tutorial != null:
		tutorial.on_wave_started(n)  # TUT-01: wave_01/02/03 + default.lua actor
	_spawn_wall_archers()
	_spawn_catapults()
	_update_pit_visibility()  # the pit only stands on the field once the_pit is owned
	# the original restarts the in-game track each level, alternating the two songs
	play_music(n % 2 == 0)

func _spawn_battlefield_actors() -> void:
	## Gate + Ash, shared by start_wave and the sandbox stage.
	gate = _make_unit("necronomicon", GameState.get_type_level("necronomicon"), Unit.Team.ALLY)
	gate.is_gate = true
	# gate_dx seats the WHOLE assembly (art, hit point, HP bar); dx ONLY — the baked book paint cannot move, so a dy would break the cage-book delta.
	var gate_dx := 0.0
	if _anchor_overrides.has("gate_dx"):
		gate_dx = float((_anchor_overrides["gate_dx"] as Dictionary).get("dx", 0.0))
	gate.position = _g(131.0 + gate_dx, ground_y(131.0))
	if absf(gate_dx) > 0.0001:
		print("[gate] Necronomicon assembly moved %+.1f world (gate_dx; enemies target the moved cage)" % gate_dx)
	var spr := Sprite2D.new()
	spr.texture = load("res://assets/map/gate.webp")
	spr.scale = Vector2(0.5, 0.5)  # 2px/world texture — verified vs footage
	spr.position = Vector2(-27.0, -66.8)
	gate.add_child(spr)
	# The gate art's white twin, hidden until _on_gate_damaged drives its alpha pulse.
	if ResourceLoader.exists("res://assets/map/gate_white_flash.webp"):
		_gate_flash = Sprite2D.new()
		_gate_flash.texture = load("res://assets/map/gate_white_flash.webp")
		_gate_flash.scale = Vector2(0.5, 0.5)
		_gate_flash.position = spr.position
		_gate_flash.z_index = 1
		_gate_flash.visible = false
		gate.add_child(_gate_flash)
	gate.died.connect(_on_gate_died)
	gate.damaged.connect(_on_gate_damaged)
	units_layer.add_child(gate)
	# LIMITATION: the BOOK is baked bg paint — keep editor drags within the alcove.
	for i in range(bg_pieces.size()):
		if str(bg_pieces[i].get("leaf")) == "gate":
			bg_pieces.remove_at(i)
			break
	bg_pieces.append({"leaf": "gate", "spr": gate,
		"authored": _g(131.0, ground_y(131.0)), "kind": "gate", "follow": "",
		"size": Vector2(46.0, 97.0), "center": Vector2(-27.0, -66.8)})

	# Ash STAYS behind the gate until moved: no auto-advance at wave start.
	ash = _make_unit("ash", GameState.get_type_level("ash"), Unit.Team.ALLY)
	ash.is_hero = true
	ash.equip_weapon("boomstick")  # the stump has 0 damage; boomstick is the gun
	# The bought melee weapon replaces the stump in the primary slot at wave start.
	if not GameState.weapon_locked("chainsaw"):
		ash.equip_melee("chainsaw")
	elif not GameState.weapon_locked("iron_fist"):
		ash.equip_melee("iron_fist")
	ash.position = _g(ally_spawn_x + 30.0, ground_y(ally_spawn_x + 30.0))
	ash.walk_in_x = ash.position.x
	ash.damaged.connect(_on_ash_damaged)
	ash.died.connect(_on_unit_died)  # _on_unit_died -> _finish_wave(false) on Ash
	units_layer.add_child(ash)

# ------------------------------------------------------- castle upgrades

func _spawn_catapults() -> void:
	## Level N owns posts idx 1..N (level 1 = the courtyard post).
	# UNTYPED loop on purpose: assigning a freed instance to a typed loop var is fatal and would abort before clear() purges the stale refs.
	for u in catapults:
		if is_instance_valid(u):
			u.queue_free()
	catapults.clear()
	var lvl := GameState.get_castle_level("catapults")
	if lvl <= 0:
		return
	var count: Variant = DB.get_stat("units", "catapults", "count", lvl)
	# The spawn-count default is ONE, not zero.
	var spawn_count := int(count) if count != null else 1
	for cm: Dictionary in catapult_post_meta:
		if int(cm["idx"]) > spawn_count:
			continue  # the Lua spawn filter: unowned posts stay empty
		var post: Vector2 = cm["pos"]
		var u := _make_unit("catapults", mini(lvl, 5), Unit.Team.ALLY)
		u.is_catapult = true
		u.equip_weapon("catapults_weapon")
		# Render must NOT use the raw mapdata size — CATAPULT_RENDER re-derives it.
		var meta: Dictionary = CATAPULT_RENDER.get(int(cm["idx"]), {})
		u.body_scale = float(meta.get("scale", float(cm["scale"])))
		u.position = post + meta.get("seat", Vector2.ZERO)
		# Courtyard posts sort IN FRONT of the wall/curb masks; the tie resolves machine-first.
		u.z_index = int(cm["zi"])
		# Hold the SEATED spot, not the raw post — the x offset leaves a gap speed-0 machines can never close.
		u.walk_in_x = u.position.x
		u.died.connect(_on_unit_died)
		units_layer.add_child(u)
		catapults.append(u)

# ------------------------------------------------------------- the pit

func throw_into_pit(u: Unit) -> void:
	## Scoop radius 150 px; the lid opens while a body is in flight.
	if u == null or not is_instance_valid(u) or u.state == Unit.State.DEAD:
		return
	if absf(u.position.x - pit_x) > 150.0:
		return
	print("[pit] %s scooped at x=%.0f" % [u.unit_type, u.position.x])
	u.state = Unit.State.DEAD  # un-targetable for the flight (TEAM_NEUTRAL)
	enemies_killed += 1
	_drop_loot(u)
	award_enemy_death_gold(u, null)  # pit.lua: die() with no attacker -> 10% share
	pit_bodies += 1
	if pit_closed_sprite != null:
		pit_closed_sprite.visible = false
	if pit_open_sprite != null:
		pit_open_sprite.visible = true
	var t := PitThrow.new()
	t.main = self
	t.unit = u
	fx_layer.add_child(t)

func _pit_throw_done() -> void:
	pit_bodies -= 1
	if pit_bodies <= 0:
		if pit_closed_sprite != null:
			pit_closed_sprite.visible = true
		if pit_open_sprite != null:
			pit_open_sprite.visible = false

class PitThrow extends Node2D:
	## Drives the victim's own sprite; the Unit node is freed at the end.
	var main: Node2D
	var unit: Unit
	var _t := 0.0
	var _from := Vector2.ZERO
	var _dir := 1.0
	var _rot := 0.0
	const DUR := 0.9
	const UP_TIME := 0.55

	func _ready() -> void:
		if unit == null or not is_instance_valid(unit):
			_finish()
			return
		if unit.anim == null and unit.actor3d == null:
			_finish()
			return
		_from = unit.position
		_dir = signf(main.pit_x - _from.x)
		if _dir == 0.0:
			_dir = 1.0
		_rot = deg_to_rad(90.0 * (randi() % 3 + 1) * _dir)
		if unit.anim != null:
			unit.anim.rotation = 0.0
			unit.anim.play(unit._idle_clip_name())
		else:
			unit.actor3d._root.rotation = 0.0
			unit._play_clip(unit._idle_clip_name())
		set_process(true)

	func _process(dt: float) -> void:
		_t += dt
		var unit_node := unit
		if unit_node == null or not is_instance_valid(unit_node):
			_finish()
			return
		var k := clampf(_t / DUR, 0.0, 1.0)
		# horizontal: smooth glide to the pit
		var x := lerpf(_from.x, main.pit_x, k)
		# vertical: rise 75px (0..0.55) then fall into the hole (0.55..0.9)
		var y := _from.y
		if k < UP_TIME / DUR:
			var ku := k * DUR / UP_TIME
			y = _from.y - 75.0 * sin(ku * PI * 0.5)
		else:
			var kd := (k * DUR - UP_TIME) / (DUR - UP_TIME)
			y = _from.y - 75.0 + 75.0 * kd * kd
		unit_node.position = Vector2(x, y)
		if unit_node.anim != null:
			unit_node.anim.rotation = _rot * k
			var kd2 := clampf((k * DUR - UP_TIME) / (DUR - UP_TIME), 0.0, 1.0)
			var s := 1.0 - 0.7 * kd2
			var base: Vector2 = unit_node.get_meta("base_anim_scale", Vector2.ONE)
			unit_node.anim.scale = base * s
			unit_node.modulate = Color(1, 1, 1).lerp(Color(0, 0, 0), clampf((k - 0.8) / 0.2, 0.0, 1.0))
		elif unit_node.actor3d != null:
			unit_node.actor3d._root.rotation = _rot * k
			var kd3 := clampf((k * DUR - UP_TIME) / (DUR - UP_TIME), 0.0, 1.0)
			var s3 := 1.0 - 0.7 * kd3
			unit_node.actor3d.scale = Vector2.ONE * unit_node.body_scale * s3
			unit_node.modulate = Color(1, 1, 1).lerp(Color(0, 0, 0), clampf((k - 0.8) / 0.2, 0.0, 1.0))
		if _t >= DUR:
			unit_node.queue_free()
			_finish()

	func _finish() -> void:
		if unit != null and is_instance_valid(unit):
			unit.queue_free()
		main._pit_throw_done()
		queue_free()

func _spawn_wall_archers() -> void:
	# UNTYPED loop — same freed-instance trap as _spawn_catapults.
	for u in wall_archers:
		if is_instance_valid(u):
			u.queue_free()
	wall_archers.clear()
	var lvl := GameState.get_castle_level("inner_wall_archer")
	if lvl <= 0:
		return
	var count: Variant = DB.get_stat("units", "inner_wall_archer", "count", lvl)
	for i in mini(int(count) if count != null else 0, wall_archer_posts.size()):
		var post: Vector2 = wall_archer_posts[i]
		var u := _make_unit("archer", mini(lvl, 10), Unit.Team.ALLY)
		u.is_wall_archer = true
		u.equip_weapon("wall_bow")
		# Per-tower seats (right -24 so mask_03 occludes boots like the original); do NOT move BACKWALL_MASK_CENTERS — they are pixel-exact.
		u.body_scale = 1.0
		u.position = post + Vector2(-24.0 if post.x > 700.0 else -2.0, 78.0)
		u.z_index = wall_archer_post_z[i]
		# Hold the SEATED spot — a raw-post walk_in_x would let WALK_IN snap erase the offset.
		u.walk_in_x = u.position.x
		u.died.connect(_on_unit_died)
		units_layer.add_child(u)
		wall_archers.append(u)

func buy_castle_upgrade(type_name: String) -> bool:
	## Gold-buy the next level of a castle upgrade at its map fixture.
	var entry := DB.entry("units", type_name)
	if entry.is_empty():
		return false
	var unlock: Variant = entry.get("unlock_wave", 1)
	if GameState.current_wave < int(unlock):
		hud.flash_message("%s unlocks at wave %d" % [str(entry.get("title", type_name)), int(unlock)])
		return false
	var levels: Array = entry.get("level_stat", [])
	var next := GameState.get_castle_level(type_name) + 1
	if next > levels.size():
		hud.flash_message("Already maxed")
		return false
	var cost := int(levels[next - 1].get("cost", 0))
	if GameState.gold < cost:
		hud.flash_message("Need %d gold for %s" % [cost, str(entry.get("title", type_name))])
		return false
	GameState.add_gold(-cost)
	GameState.set_type_level(type_name, next)
	if type_name == "inner_wall_archer":
		_spawn_wall_archers()
	elif type_name == "catapults":
		_spawn_catapults()
	elif type_name == "the_pit":
		_update_pit_visibility()  # the pit art stands up the moment it is bought
	hud.flash_message("%s upgraded to level %d" % [str(entry.get("title", type_name)), next])
	return true

func _try_buy_fixture(screen: Vector2) -> bool:
	var world := _screen_to_world(screen)
	for t in ["inner_wall_archer", "catapults", "smithy"]:
		for pos: Vector2 in fixture_positions.get(t, []):
			if world.distance_to(pos) <= 45.0:
				return buy_castle_upgrade(t)
	return false

func _on_all_spawned() -> void:
	pass  # win check happens in _process once the field is clear

func on_wave_push() -> void:
	wave_push_count += 1
	hud.flash_push()
	play_sfx("wave_push_stinger")

func get_wave_unit_total(wave_num: int = 0) -> int:
	var w := DB.get_wave_data(wave_num if wave_num > 0 else GameState.current_wave)
	var n := 0
	for v: Dictionary in w.get("unit_stat", []):
		if not DB.entry("units", str(v.get("unit", ""))).is_empty():
			n += 1
	return n

func spawn_enemy(type_name: String, lvl: int) -> Unit:
	var u := _make_unit(type_name, lvl, Unit.Team.ENEMY)
	# util.createUnitOnPath: deadites enter from the right end of their path.
	var sx := enemy_spawn_x + 60.0
	u.position = _g(sx, ground_y(sx))
	u.lane_offset = _next_slot()
	u.position.y += u.lane_offset
	u.walk_in_x = enemy_spawn_x + randf_range(-30.0, 30.0)
	u.died.connect(_on_unit_died)
	units_layer.add_child(u)
	enemies_spawned_alive += 1
	if endless_mode:
		endless.on_enemy_spawned(type_name)
	return u

func unique_locked(type_name: String) -> bool:
	## True while a "unique" ally of this type is alive (the button lock).
	return int(_unique_alive.get(type_name, 0)) > 0

func _mark_unique_spawned(type_name: String) -> void:
	if bool(DB.entry("units", type_name).get("unique", false)):
		_unique_alive[type_name] = int(_unique_alive.get(type_name, 0)) + 1

func _mark_unique_died(type_name: String) -> void:
	## Clear the button lock; the ordinary cooldown runs its own course from the cast.
	if _unique_alive.has(type_name):
		var left := int(_unique_alive[type_name]) - 1
		if left > 0:
			_unique_alive[type_name] = left
		else:
			_unique_alive.erase(type_name)

func summon_ally(type_name: String) -> bool:
	if wave_over or not type_name in GameState.selected_units:
		return false
	if unique_locked(type_name):
		return false
	if button_cooldowns.get(type_name, 0.0) > 0.0:
		return false
	var cost := int(DB.get_stat("units", type_name, "iron_cost", 1))
	if iron < cost:
		return false
	iron -= cost
	var lvl := GameState.get_type_level(type_name)
	var u := _make_unit(type_name, lvl, Unit.Team.ALLY)
	var sx := ally_spawn_x + 20.0
	u.position = _g(sx, ground_y(sx))
	u.lane_offset = _next_slot()
	u.position.y += u.lane_offset
	u.walk_in_x = ally_spawn_x + randf_range(-20.0, 40.0)
	_mark_unique_spawned(type_name)
	u.died.connect(_on_unit_died)
	units_layer.add_child(u)
	# While alive the cooldown alone gates re-summoning (non-unique troops).
	var cd: Variant = DB.get_stat("units", type_name, "cooldown", lvl)
	button_cooldowns[type_name] = float(cd) if cd != null else 3.0
	play_unit_sound(type_name, "spawn")
	_maybe_spawn_subordinates(u)
	if endless_mode:
		endless.on_ally_spawned(type_name)
	return true

func _make_unit(type_name: String, lvl: int, team: Unit.Team) -> Unit:
	return Unit.create(self, type_name, lvl, team)

# ------------------------------------------------------------- unit queries

func get_closest_opposing(u: Unit) -> Unit:
	## Candidates closer than weapon_min_range must be SKIPPED or the wall defense softlocks (band check fails every frame).
	var best: Unit = null
	var best_d := INF
	var statics: bool = u.is_wall_archer or u.is_catapult  # hold their post — never advance
	var opposing: Unit.Team = Unit.Team.ENEMY if u.team == Unit.Team.ALLY else Unit.Team.ALLY
	for other: Unit in _team_objects(opposing):
		if other.state == Unit.State.DEAD or other.is_wall_archer \
				or other.is_catapult or other.is_prop:
			continue  # wall defenses/props: load.lua gives them no health part
		var d: float = absf(other.position.x - u.position.x)
		if u.weapon_min_range > 0.0 and d < u.weapon_min_range:
			continue  # inside the weapon's dead zone: cannot be fired at
		if statics and d > u.weapon_range:
			continue  # statics pick the closest enemy INSIDE the firing band
		if d < best_d:
			best_d = d
			best = other
	return best

func _team_objects(team: Unit.Team) -> Array:
	var out: Array = []
	for u: Unit in units_layer.get_children():
		if u is Unit and u.team == team:
			out.append(u)
	return out

func enemies_alive() -> int:
	var n := 0
	for u: Unit in units_layer.get_children():
		if u is Unit and u.team == Unit.Team.ENEMY and u.state != Unit.State.DEAD:
			n += 1
	return n

func get_front_line_ratio() -> float:
	## LuaMainGame.adjust_difficulty front-line math over ALLY path extents.
	var farthest := ally_spawn_x
	for u: Unit in _team_objects(Unit.Team.ALLY):
		if u.state == Unit.State.DEAD or u.is_gate or u.is_wall_archer or u.is_catapult:
			continue
		farthest = maxf(farthest, u.position.x)
	var closest := enemy_spawn_x
	for u: Unit in _team_objects(Unit.Team.ENEMY):
		if u.state == Unit.State.DEAD:
			continue
		closest = minf(closest, u.position.x)
	var front_line: float = maxf((farthest + closest) * 0.5, farthest)
	return clampf((front_line - ally_spawn_x) / (enemy_spawn_x - ally_spawn_x), 0.0, 1.0)

# --------------------------------------------------------------- projectiles

func spawn_projectile(shooter: Unit, target: Unit, target_pos := Vector2.ZERO) -> void:
	var ammo := shooter.ammo_name
	var p := Projectile.new()
	p.main = self
	p.from = shooter.position + Vector2(shooter.facing * 10.0, -shooter.height * shooter.body_scale * 0.62)
	p.target = target
	var speed: Variant = DB.get_stat("ammo", ammo, "speed", shooter.level)
	p.speed = float(speed) if speed != null else 400.0
	p.damage = shooter.attack_damage
	p.arching = str(DB.get_stat("ammo", ammo, "trajectory", shooter.level)) == "arching"
	var sr: Variant = DB.get_stat("ammo", ammo, "splash_range", shooter.level)
	p.splash_range = float(sr) if sr != null else 0.0
	p.hit_ground = DB.get_stat("ammo", ammo, "hit_ground", shooter.level) == true
	p.flaming = DB.get_stat("ammo", ammo, "flaming", shooter.level) == true
	var fdps: Variant = DB.get_stat("ammo", ammo, "flame_dps", shooter.level)
	p.flame_dps = float(fdps) if fdps != null else 0.0
	p.team = shooter.team
	p.source = shooter
	p.tex = _ammo_texture(ammo, shooter.level)
	p.spr_scale = _ammo_sprite_scale(ammo, shooter.level, p.tex)
	# The ammo-part hooks load.lua sets on PartAmmo (knockback, fired/impact sounds, script).
	var kb: Variant = DB.get_stat("ammo", ammo, "knockback_multiplier", shooter.level)
	p.knockback_mult = float(kb) if kb != null else 0.0
	p.ammo_name = ammo
	p.ammo_script = str(DB.get_stat("ammo", ammo, "script", shooter.level))
	var dds: Variant = DB.get_stat("ammo", ammo, "on_deal_damage_sound", shooter.level)
	p.on_deal_damage_sounds = str(dds) if dds != null else ""
	var fired: Variant = DB.get_stat("ammo", ammo, "on_fired_sound", shooter.level)
	if fired != null and str(fired) != "":
		play_uri_list(str(fired))
	# Cache the destination at spawn (the engine's aim cache is write-once) — a mid-flight death must not fling the shot off-screen.
	var t_valid := target != null and is_instance_valid(target)
	var t_pos := target_pos if target_pos != Vector2.ZERO \
		else (target.position if t_valid else Vector2.ZERO)
	if p.hit_ground or not t_valid:
		p._cached_dest = Vector2(t_pos.x, -ground_y(t_pos.x))
	else:
		p._cached_dest = t_pos + Vector2(0, -target.height * target.body_scale * 0.6)
	p._has_dest = true
	fx_layer.add_child(p)
	_projectiles.append(p)

func _ammo_texture(ammo: String, lvl: int) -> Texture2D:
	var leaf := str(DB.get_stat("ammo", ammo, "texture", lvl)).get_file()
	for folder in ["ammo", "fx"]:
		if leaf != "" and ResourceLoader.exists("res://assets/%s/%s.webp" % [folder, leaf]):
			return load("res://assets/%s/%s.webp" % [folder, leaf])
	return null

func _ammo_sprite_scale(ammo: String, lvl: int, tex: Texture2D) -> float:
	## World draw width / diffuse width (AMMO_WORLD_WIDTH); unknown leaves keep EFFECT_TEXEL.
	if tex == null:
		return EFFECT_TEXEL
	var leaf := str(DB.get_stat("ammo", ammo, "texture", lvl)).get_file()
	var world_w: Variant = AMMO_WORLD_WIDTH.get(leaf)
	return float(world_w) / float(tex.get_width()) if world_w != null else EFFECT_TEXEL

func play_uri(uri: String) -> void:
	## Assets URI -> manifest key: trim "sound/", "/" -> "_", lowercased.
	if uri == "":
		return
	play_sfx(uri.trim_prefix("sound/").replace("/", "_").to_lower())

func play_uri_list(uri_list: String) -> void:
	## Semicolon list (often with a trailing ";"): one random entry plays.
	var parts := uri_list.split(";", false)
	if parts.is_empty():
		return
	play_uri(parts[randi() % parts.size()])

func splash_damage(center_x: float, radius: float, damage: int, source: Unit,
		direct_target: Unit = null, flame_dps := 0.0) -> void:
	## Splash packet: damage*0.6 floored, knockback zeroed, flame_dps KEPT — splash victims of flaming ammo ignite too.
	var splash := int(floor(float(damage) * 0.6))
	if splash == 0:
		return
	for u: Unit in _team_objects(Unit.Team.ENEMY if source.team == Unit.Team.ALLY else Unit.Team.ALLY):
		if u == direct_target:
			continue
		# Wall defenses/props have no PartHealth — splash packets can't touch them.
		if u.is_wall_archer or u.is_catapult or u.is_prop:
			continue
		if u.state != Unit.State.DEAD and absf(u.position.x - center_x) <= radius:
			u.take_damage(splash, source, 0.0, true, flame_dps)

func try_pit_scoop(u: Unit) -> void:
	## The pit exists only once the_pit is owned; nothing can be scooped before that (--pitdemo forces it).
	if u.team == Unit.Team.ENEMY and absf(u.position.x - pit_x) <= 150.0 \
			and (GameState.get_castle_level("the_pit") > 0 or Dbg.args.has("pitdemo")):
		throw_into_pit(u)

func _update_pit_visibility() -> void:
	## The pit art stands only once the_pit is owned; open/closed follows the in-flight body.
	var shown := GameState.get_castle_level("the_pit") > 0 or Dbg.args.has("pitdemo")
	if pit_overlay_sprite != null:
		pit_overlay_sprite.visible = shown  # hide the whole pit contraption
	if pit_closed_sprite != null:
		pit_closed_sprite.visible = shown and pit_bodies <= 0
	if pit_open_sprite != null:
		pit_open_sprite.visible = shown and pit_bodies > 0

func _debris_log() -> bool:
	return Dbg.args.has("debrislog")

class PoppedItem extends Node2D:
	## Pops up 0.2 s, falls 0.4 s landing exactly on the ground line, fades 1.0 s.
	const HALF_ARC := 0.2
	const Y_LAUNCH := 25.0
	const X_LAUNCH := 15.0
	const FLIGHT := HALF_ARC + HALF_ARC * 2.0   # 0.6 s
	const FADE := 1.0
	var ground_y := 0.0
	var _start := Vector2.ZERO
	var _t := 0.0
	var _spr: Sprite2D

	func _ready() -> void:
		_start = position
		_spr = Sprite2D.new()
		_spr.texture = load("res://assets/items/%s" % str(get_meta("tex", "")))
		# Scale = OBJ aabb width / texture width to match the world footprint.
		var item_scale := EFFECT_TEXEL
		var mesh := GrannyActor3D.load_item_mesh(str(get_meta("obj", "")))
		if mesh != null and _spr.texture != null and mesh.get_aabb().size.x > 0.0:
			item_scale = mesh.get_aabb().size.x / float(_spr.texture.get_width())
		_spr.scale = Vector2.ONE * item_scale
		_spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_spr)

	func _process(dt: float) -> void:
		_t += dt
		if _t >= FLIGHT + FADE:
			queue_free()
			return
		if _t <= HALF_ARC:
			# fly up: Y by -y_launch_offset (Fall), X by +2*x_launch (Lerp)
			var k := _t / HALF_ARC
			var fall := 1.0 - (1.0 - k) * (1.0 - k)  # InterpAction.Fall
			position = _start + Vector2(2.0 * X_LAUNCH * k, -Y_LAUNCH * fall)
		elif _t <= FLIGHT:
			# fly down: to the ground line (Ramp), X by +x_launch more (Lerp)
			var k2 := (_t - HALF_ARC) / (HALF_ARC * 2.0)
			var ramp := k2 * k2  # InterpAction.Ramp
			var top := _start + Vector2(2.0 * X_LAUNCH, -Y_LAUNCH)
			position = top + Vector2(X_LAUNCH * k2, (ground_y - top.y) * ramp)
		else:
			position = Vector2(_start.x + 3.0 * X_LAUNCH, ground_y)
			modulate.a = 1.0 - (_t - FLIGHT) / FADE
		# RotateOffset(half_arc_time * 2, Lerp, -90 deg) runs through the flight
		_spr.rotation = deg_to_rad(-90.0) * clampf(_t / (HALF_ARC * 2.0), 0.0, 1.0)

func spawn_popped_item(pos: Vector2, ground_line_y: float, tex_path: String, obj_name := "") -> void:
	## obj_name sizes the sprite to the equipped mesh's world footprint.
	var p := PoppedItem.new()
	p.position = pos
	p.ground_y = ground_line_y
	p.set_meta("tex", tex_path.get_file())
	if obj_name != "":
		p.set_meta("obj", obj_name)
	fx_layer.add_child(p)

class Projectile extends Node2D:
	var main: Node2D
	var from: Vector2
	var target: Unit
	var speed := 400.0
	var damage := 0
	var arching := false
	var knockback_mult := 0.0  # DIRECT hit only (splash knockback is zeroed in splash_damage)
	var splash_range := 0.0
	var hit_ground := false   # lobbed (rocks): land at the target's ground spot
	var flaming := false
	var flame_dps := 0.0
	var team := 0
	var source: Unit
	var ammo_name := ""            # the firing weapon's ammo (data-driven fx hooks)
	var ammo_script := ""          # ammo.json script (catapult_ammo / explosive_arrow_ammo)
	var on_deal_damage_sounds := ""  # semicolon sound URI list, played at impact
	var lob_target_x := 0.0   # fixed ground impact point (catapult volley)
	var tex: Texture2D        # real extracted ammo art (assets/ammo)
	var spr_scale := EFFECT_TEXEL  # assets.lua draw size / diffuse width (FINAL-04b)
	var _spr: Sprite2D
	var _cached_dest := Vector2.ZERO  # PartAmmo cached aim point (+0x40)
	var _has_dest := false
	var _t := 0.0

	func _ready() -> void:
		position = from  # spawn at the shooter (the node defaults to Vector2.ZERO)
		if tex != null:
			_spr = Sprite2D.new()
			_spr.texture = tex
			_spr.scale = Vector2.ONE * spr_scale  # assets.lua ammo draw size
			_spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
			add_child(_spr)

	func _process(dt: float) -> void:
		if arching or hit_ground:
			_ballistic_tick(dt)
			return
		if not _has_dest:
			position.x += speed * dt * (1 if position.x < main.world_rect.end.x else -1)
			if not main.world_rect.has_point(position):
				_die()
			return
		var dest := _aim_point()
		var to := dest - position
		var step := speed * dt
		if to.length() <= step + 2.0:
			_impact(dest.x)
			return
		position += to.normalized() * step
		rotation = to.angle()  # straight shots pitch along the flight vector
		_t += dt
		queue_redraw()

	func _ballistic_tick(dt: float) -> void:
		## Y-down port of the engine's per-tick ballistic solve (500 px/s^2 gravity).
		var dest := _aim_point()
		if not _has_dest:
			# target gone before any aim was cached: fly on a bit then fizzle
			position.x += speed * dt * (1 if position.x < main.world_rect.end.x else -1)
			if not main.world_rect.has_point(position):
				_die()
			return
		var dx := dest.x - position.x
		var t_flight := absf(dx) / maxf(speed, 1.0)
		if t_flight <= dt:
			_impact(dest.x)
			return
		var dir := signf(dx)
		# Y-down port of the Y-up solve (v0y_up = dy_up/T + 250T).
		var v0y := (dest.y - position.y) / t_flight - 250.0 * t_flight
		var vy := v0y + 500.0 * dt
		if _spr != null:
			rotation = Vector2(dir * speed, vy).angle()
		position += Vector2(dir * speed * dt, vy * dt + 250.0 * dt * dt)
		_t += dt

	func _aim_point() -> Vector2:
		## Re-aims while the target lives; holds the cached destination once dead/freed.
		if hit_ground:
			if lob_target_x != 0.0:
				_cached_dest = Vector2(lob_target_x, -main.ground_y(lob_target_x))
				_has_dest = true
			elif target != null and is_instance_valid(target) and target.state != Unit.State.DEAD:
				_cached_dest = Vector2(target.position.x, -main.ground_y(target.position.x))
				_has_dest = true
		elif target != null and is_instance_valid(target) and target.state != Unit.State.DEAD:
			_cached_dest = target.position + Vector2(0, -target.height * target.body_scale * 0.6)
			_has_dest = true
		return _cached_dest

	func _impact(land_x: float) -> void:
		if hit_ground:
			main.play_sfx_like("rocks_impact", -2.0)
			main._shake = 0.35
		var impact_y := position.y
		if damage < 0:
			# Negative damage HEALS its own team and must NEVER mend an opposing unit.
			if target != null and is_instance_valid(target) and target.state != Unit.State.DEAD \
					and target.team == team:
				target.heal(-damage)
				main._spawn_heal_signs(target)
			_die()
			return
		# Catapult ammo handles its own knockback — the multiplier must not ALSO punt the direct target.
		var direct_kb := 0.0 if ammo_script == "catapult_ammo" else knockback_mult
		if target != null and is_instance_valid(target) and target.state != Unit.State.DEAD:
			target.take_damage(damage, source, direct_kb, true, flame_dps)
		if ammo_script == "catapult_ammo":
			_catapult_ammo_impact(land_x, impact_y)
		elif ammo_script == "explosive_arrow_ammo":
			_spawn_arrow_explode()
		# Catapult ammo bypasses the generic splash (its Lua loops its own victims).
		if splash_range > 0.0 and ammo_script != "catapult_ammo":
			main.splash_damage(land_x, splash_range, damage, source,
				target if target != null and is_instance_valid(target) else null,
				flame_dps)
		if on_deal_damage_sounds != "":
			main.play_uri_list(on_deal_damage_sounds)
		_die()

	func _catapult_ammo_impact(land_x: float, impact_y: float) -> void:
		## Fixed 50 px punt — the ammo's knockback_multiplier is never consulted.
		if splash_range > 0.0:
			var opposing: Unit.Team = Unit.Team.ENEMY if team == Unit.Team.ALLY \
				else Unit.Team.ALLY
			for u: Unit in main._team_objects(opposing):
				if u.state == Unit.State.DEAD or not u.can_be_knocked_back \
						or u.stumble_time > 0.0:  # orders:isBeingKnockedBack()
					continue
				if absf(u.position.x - land_x) > splash_range:
					continue
				u.apply_knockback(50.0, 0.0)
		# Static texture pop stays as the headless fallback.
		if main._spawn_granny_effect(
				"mesh/objects/ammo/effects/catapult_explosion_effect.gr2",
				"explode", Vector2(land_x, impact_y), main.Z_FG,
				"res://assets/fx/catapult_explosion.webp") != null:
			return
		var ex := Sprite2D.new()
		ex.texture = load("res://assets/fx/catapult_explosion.webp")
		ex.position = Vector2(land_x, impact_y)
		ex.scale = Vector2.ONE * EFFECT_TEXEL
		ex.z_index = main.Z_FG
		main.fx_layer.add_child(ex)
		var tw := ex.create_tween()
		tw.tween_property(ex, "modulate:a", 0.0, 0.4)
		tw.tween_callback(ex.queue_free)

	func _spawn_arrow_explode() -> void:
		## Staged sheet: 12 frames of 90x90, frame 0 = TOP-left cell.
		if not ResourceLoader.exists("res://assets/fx/arrow_explode.webp"):
			return
		var frames := SpriteFrames.new()
		frames.set_animation_speed("default", 20.0)  # 1 / 0.05 s
		frames.set_animation_loop("default", false)
		for i in 12:
			var at := AtlasTexture.new()
			at.atlas = load("res://assets/fx/arrow_explode.webp")
			at.region = Rect2(float(i % 3) * 90.0, float(i / 3) * 90.0, 90.0, 90.0)
			frames.add_frame("default", at)
		var boom := AnimatedSprite2D.new()
		boom.sprite_frames = frames
		boom.scale = Vector2.ONE * EFFECT_TEXEL
		boom.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		boom.position = position  # the Lua's +2 z is draw-order: z_index covers it
		boom.z_index = main.Z_FG
		main.fx_layer.add_child(boom)
		boom.play("default")
		var tw := boom.create_tween()
		tw.tween_interval(0.6)  # DestroyAction(0.6)
		tw.tween_callback(boom.queue_free)

	func _die() -> void:
		main._projectiles.erase(self)
		queue_free()

	func _draw() -> void:
		if tex != null:
			return  # real ammo sprite renders the projectile
		if hit_ground:
			draw_circle(Vector2.ZERO, 5.0, Color(0.55, 0.5, 0.45))
			return
		# flaming arrows/rocks glow orange (ammo texture swaps arrow->flaming_arrow)
		draw_line(Vector2(-5, 0), Vector2(5, 0),
			Color(1.0, 0.5, 0.15) if flaming else Color(0.85, 0.75, 0.5), 2.0)

# --------------------------------------------------------------- spell fx

class VortexSuck extends Node2D:
	## The suck clock starts only once the book strikes (0.667 s into idle).
	const STRIKE_AT := 0.667  # Unit.STRIKE_TIMES["vortex_book"]["idle"]
	var main: Node2D
	var book_x := 0.0
	var ground_y := 0.0
	var victims: Array = []
	var _t := 0.0
	var _book3d: GrannyActor3D  # the real book model (windowed runs)
	var _book: AnimatedSprite2D  # baked-strip fallback (headless/no model)
	var _ss := 2.0
	var _fade := 1.0

	func _ready() -> void:
		# The baked strip is the fallback for headless runs / a missing model.
		if GrannyActor3D.supports_model("mesh/objects/spells/vortex_book.gr2"):
			var b3d := GrannyActor3D.new()
			# The staged glb samples its atlas V-FLIPPED; the texture is pre-flipped once at the asset level.
			if b3d.setup("mesh/objects/spells/vortex_book.gr2",
					load("res://assets/units/vortex_book.webp")):
				_book3d = b3d
				# The idle clip anchors the quad at the model origin — NO static-bind correction (it pushed the book under the walk line).
				if b3d._root != null:
					b3d._root.position = Vector2.ZERO
				b3d.position = Vector2(book_x, ground_y)  # feet on the ground line
				add_child(b3d)
				b3d.play_clip("idle", false)
				# vortex_book.aabb.json carries the ANIMATED extent — a static AABB clipped the cloud mid-clip.
		if _book3d == null:
			var meta: Dictionary = DB.load_json("res://data/unit_anims.json").get("vortex_book", {})
			var info: Dictionary = meta.get("clips", {}).get("idle", {})
			if not info.is_empty() and ResourceLoader.exists(str(info.get("file", ""))):
				var tex: Texture2D = load(str(info["file"]))
				var n: int = int(info.get("frames", 1))
				var fw: int = maxi(int(meta.get("frame_w", 1)), 1)
				var fh: int = maxi(int(meta.get("frame_h", 1)), 1)
				var cols: int = maxi(int(info.get("cols", n)), 1)
				var frames := SpriteFrames.new()
				frames.add_animation("idle")
				frames.set_animation_speed("idle", float(info.get("fps", 18)))
				frames.set_animation_loop("idle", false)
				for i in n:
					var at := AtlasTexture.new()
					at.atlas = tex
					at.region = Rect2((i % cols) * fw, (i / cols) * fh, fw, fh)
					frames.add_frame("idle", at)
				_book = AnimatedSprite2D.new()
				_book.sprite_frames = frames
				# /0.62 matches the original's footage footprint, not the strip's full width.
				_ss = float(meta.get("ss", 2.0)) / 0.62
				_book.scale = Vector2.ONE / _ss
				_book.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
				# strip bottom sits on the ground line, centered on book_x
				_book.position = Vector2(book_x, ground_y - fh / (2.0 * _ss) + 2.0)
				add_child(_book)
				_book.play("idle")
		queue_redraw()

	func _draw() -> void:
		# soft ground shadow under the book (visible in the original footage)
		draw_set_transform(Vector2(book_x, ground_y + 2.0), 0.0, Vector2(1.0, 0.3))
		draw_circle(Vector2.ZERO, 30.0, Color(0.0, 0.0, 0.0, 0.30 * _fade))

	func _process(dt: float) -> void:
		_t += dt
		# the suck timeline runs from the book's "strike" event (0.667 s in)
		var ts: float = maxf(_t - STRIKE_AT, 0.0)
		if ts <= 0.0:
			return  # the book has not struck yet — victims hold
		for i in victims.size():
			var u: Unit = victims[i]
			if u == null or not is_instance_valid(u):
				continue
			var k: float = clampf(ts / 2.8, 0.0, 1.0)
			# each victim rises from ITS OWN position (lane offsets differ)
			var u_start_y: float = u.position.y
			if u.has_meta("vortex_start_y"):
				u_start_y = float(u.get_meta("vortex_start_y"))
			else:
				u.set_meta("vortex_start_y", u_start_y)
			var uy: float
			if k < 0.29:
				uy = lerpf(u_start_y, ground_y - 135.0, k / 0.29)
			elif k < 0.79:
				uy = ground_y - 135.0  # held aloft over the open book
				u.position.x = lerpf(u.position.x, book_x, 3.0 * dt)
				if u.anim != null:
					u.anim.rotation += 4.0 * dt
				elif u.actor3d != null:
					u.actor3d._root.rotation += 4.0 * dt  # the PitThrow 3D-path spin
			else:
				var kf: float = (k - 0.79) / 0.21
				uy = lerpf(ground_y - 135.0, ground_y, kf * kf)
				if u.anim != null:
					u.anim.scale = u.get_meta("base_anim_scale", Vector2.ONE) * (1.0 - 0.95 * kf)
				elif u.actor3d != null:
					u.actor3d._root.scale = Vector2.ONE * (1.0 - 0.95 * kf)  # the PitThrow 3D-path shrink
			u.position.y = uy  # direct set: 135 above the book's ground, never underground
		if ts >= 2.3:
			# vortex_spell.lua: after the suck, fade out + shrink to 0.2 (0.5 s)
			_fade = clampf(1.0 - (ts - 2.3) / 0.5, 0.0, 1.0)
			if _book3d != null:
				_book3d.modulate.a = _fade
				_book3d.scale = Vector2.ONE * lerpf(1.0, 0.2, 1.0 - _fade)
			elif _book != null:
				_book.modulate.a = _fade
				_book.scale = Vector2.ONE * (_ss * lerpf(1.0, 0.2, 1.0 - _fade))
			queue_redraw()
		if ts >= 2.8:
			for u: Unit in victims:
				if u != null and is_instance_valid(u):
					main.enemies_killed += 1
					main._drop_loot(u)
					main.award_enemy_death_gold(u, null)  # the book, not Ash
					if main.endless_mode:
						main.endless.on_enemy_killed(u)
					u.queue_free()
			queue_free()

class DeathcoasterRide extends Node2D:
	## Hits drain damage_remaining; the cart dies when the budget is spent or near the path end.
	const SPEED := 250.0
	const RANGE := 150.0
	const END_EPS := 60.0
	var main: Node2D
	var damage_remaining := 4000.0
	var start_x := 0.0
	var end_x := 0.0
	var _actor3d: GrannyActor3D
	var _anim: AnimatedSprite2D
	var _hit := {}
	var _dying := false

	func _ready() -> void:
		# The art natively faces RIGHT — the left->right drive needs NO mirror.
		if GrannyActor3D.supports_model("mesh/objects/units/deathcoaster.gr2"):
			var tex: Texture2D = load("res://assets/units/deathcoaster.webp")
			var a := GrannyActor3D.new()
			if tex != null and a.setup("mesh/objects/units/deathcoaster.gr2", tex):
				_actor3d = a
				a.scale = Vector2.ONE * 0.8
				a.set_facing_flip(false)  # FINAL-09: art faces right (see above)
				add_child(a)
				a.play_clip("walk", true)
		if _actor3d == null:
			var meta: Dictionary = DB.load_json("res://data/unit_anims.json").get("deathcoaster", {})
			var frames := SpriteFrames.new()
			var fw: int = maxi(int(meta.get("frame_w", 1)), 1)
			var fh: int = maxi(int(meta.get("frame_h", 1)), 1)
			for clip: String in ["walk", "die"]:
				var info: Dictionary = meta.get("clips", {}).get(clip, {})
				if not info.is_empty() and ResourceLoader.exists(str(info.get("file", ""))):
					var tex2: Texture2D = load(str(info["file"]))
					frames.add_animation(clip)
					frames.set_animation_speed(clip, float(info.get("fps", 10)))
					frames.set_animation_loop(clip, clip == "walk")
					for i in int(info.get("frames", 1)):
						var at := AtlasTexture.new()
						at.atlas = tex2
						at.region = Rect2(i * fw, 0, fw, fh)
						frames.add_frame(clip, at)
			if frames.has_animation("walk"):
				_anim = AnimatedSprite2D.new()
				_anim.sprite_frames = frames
				_anim.scale = Vector2(0.5, 0.5) * 0.8  # units.lua deathcoaster scale 0.8
				add_child(_anim)
				_anim.play("walk")
		# The cart hangs 18 px lower than its seat (y-up -18 -> y-down +18).
		position = Vector2(start_x, -main.ground_y(start_x)) + Vector2(0.0, 18.0)
		z_index = 5

	func _process(dt: float) -> void:
		if _dying:
			return
		var x := position.x + SPEED * dt
		position = Vector2(x, -main.ground_y(x))
		for u: Unit in main._team_objects(Unit.Team.ENEMY):
			if u.state == Unit.State.DEAD or _hit.has(u.get_instance_id()):
				continue
			if absf(u.position.x - x) > RANGE:
				continue
			_hit[u.get_instance_id()] = true
			# The false default matters: bool(null) throws — normals were marked hit but never damaged.
			var unique: bool = DB.entry("units", u.unit_type).get("unique", false)
			var dealt := (0.20 * u.max_health) if unique else u.health
			u.take_damage(int(floor(dealt)), null, 0.0)
			damage_remaining -= dealt
			if damage_remaining <= 0.0:
				_die()
				return
		if absf(end_x - x) < END_EPS:
			_die()

	func _die() -> void:
		_dying = true
		# Without this the drive loop lives until battle teardown stops the SFX pool.
		var loop_e: Variant = main._sfx_meta.get("fx_deathcoaster_special_attack_loop")
		if loop_e is Dictionary:
			var loop: AudioStream = main._sfx_stream(str(loop_e["path"]))
			for pl: AudioStreamPlayer in main._sfx_pool:
				if pl.playing and pl.stream == loop:
					pl.stop()
		if _actor3d != null:
			# object:die() -> the granny "die" clip, freed when it ends
			var dur := _actor3d.get_clip_length("die")
			_actor3d.play_clip("die", false)
			var tw := create_tween()
			tw.tween_interval(maxf(dur, 0.1))
			tw.tween_callback(queue_free)
			return
		if _anim != null and _anim.sprite_frames.has_animation("die"):
			_anim.play("die")
			var dur2: float = _anim.sprite_frames.get_frame_count("die") \
				/ maxf(_anim.sprite_frames.get_animation_speed("die"), 1.0)
			var tw2 := create_tween()
			tw2.tween_interval(dur2)
			tw2.tween_callback(queue_free)
		else:
			queue_free()

class VolleyArrow extends Node2D:
	## Hidden shots home on a victim; visible ones fly to a fixed ground point.
	const TEXEL := 480.0 / 1024.0  # assets.lua ratio (ammo blur art)
	var main: Node2D
	var victim: Unit              # set -> hidden damage shot
	var dest := Vector2.ZERO
	var speed := 1500.0
	var damage := 0
	var flaming := false
	var flame_dps := 0.0
	var explosive := false
	var splash_range := 0.0
	var tex: Texture2D
	var is_hidden := false
	var _spr: Sprite2D

	func _ready() -> void:
		if is_hidden:
			return  # the damage arrows spawn with hidden_recursive = true
		_spr = Sprite2D.new()
		_spr.texture = tex
		_spr.scale = Vector2.ONE * TEXEL
		_spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_spr)

	func _process(dt: float) -> void:
		var to := dest
		if victim != null and is_instance_valid(victim) and victim.state != Unit.State.DEAD:
			to = victim.position
		var d := to - position
		rotation = d.angle()  # setDirectionNow: nose tracks the flight vector
		if d.length() <= speed * dt:
			position = to
			_impact()
			return
		position += d.normalized() * speed * dt

	func _impact() -> void:
		if victim != null and is_instance_valid(victim) and victim.state != Unit.State.DEAD:
			# The packet's flame_dps rides into take_damage and the explosive splash keeps it.
			victim.take_damage(damage, main.ash, 0.0, true, flame_dps)
			if explosive and splash_range > 0.0:
				main.splash_damage(victim.position.x, splash_range, damage, main.ash,
					victim, flame_dps)
		elif not is_hidden:
			# arrow_volley_ammo.onAmmoHitTarget: only VISIBLE arrows stick
			var g := ArrowGround.new()
			g.position = dest
			g.rotation = rotation + deg_to_rad(float(randi() % 21 - 10))
			main.fx_layer.add_child(g)
		queue_free()

class ArrowGround extends Node2D:
	## Stuck arrow: sleeps 2.5 s, fades 0.25 s, dies.
	const TEXEL := 480.0 / 1024.0
	var _t := 0.0
	var _spr: Sprite2D

	func _ready() -> void:
		_spr = Sprite2D.new()
		_spr.texture = load("res://assets/fx/arrow_ground.webp")
		_spr.scale = Vector2.ONE * TEXEL
		_spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_spr)

	func _process(dt: float) -> void:
		_t += dt
		if _t >= 2.75:
			queue_free()
		elif _t > 2.5:
			modulate.a = 1.0 - (_t - 2.5) / 0.25

class VolleyRock extends Node2D:
	## Fixed ground-spot impact: zone damage + fixed 50 px knockback inside splash_range.
	const TEXEL := 480.0 / 1024.0
	var main: Node2D
	var dest := Vector2.ZERO
	var speed := 1500.0
	var damage := 0.0
	var zone_from := 0.0
	var zone_to := 0.0
	var flaming := false
	var flame_dps := 0.0
	var splash_range := 0.0
	var on_deal_damage_sounds := ""  # volley_rocks carries none today (seam)
	var tex: Texture2D
	var _spr: Sprite2D

	func _ready() -> void:
		_spr = Sprite2D.new()
		_spr.texture = tex
		_spr.scale = Vector2.ONE * TEXEL
		_spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_spr)

	func _process(dt: float) -> void:
		var d := dest - position
		rotation = d.angle()
		if d.length() <= speed * dt:
			position = dest
			_impact()
			return
		position += d.normalized() * speed * dt

	func _impact() -> void:
		# Zone damage only — no knockback here; flaming rocks ignite via flame_dps.
		for u: Unit in main._team_objects(Unit.Team.ENEMY):
			if u.state == Unit.State.DEAD:
				continue
			if u.position.x < zone_from or u.position.x > zone_to:
				continue
			u.take_damage(int(damage), main.ash, 0.0, true, flame_dps)
		for u2: Unit in main._team_objects(Unit.Team.ENEMY):
			if u2.state == Unit.State.DEAD or not u2.can_be_knocked_back \
					or u2.stumble_time > 0.0:
				continue
			if absf(u2.position.x - dest.x) <= splash_range:
				u2.apply_knockback(50.0, 0.0)
		main.play_uri_list(on_deal_damage_sounds)
		if main._spawn_granny_effect(
				"mesh/objects/ammo/effects/catapult_explosion_effect.gr2",
				"explode", dest, main.Z_FG,
				"res://assets/fx/catapult_explosion.webp") == null:
			var ex := Sprite2D.new()
			ex.texture = load("res://assets/fx/catapult_explosion.webp")
			ex.position = dest
			ex.scale = Vector2.ONE * TEXEL
			ex.z_index = main.Z_FG
			main.fx_layer.add_child(ex)
			var tw := ex.create_tween()
			tw.tween_property(ex, "modulate:a", 0.0, 0.4)
			tw.tween_callback(ex.queue_free)
		main._shake = 0.35  # doCameraShake(+/-2 X, -4 Y)
		queue_free()

# ------------------------------------------------------------------- coins

func _drop_loot(u: Unit) -> void:
	## ONE iron_chance roll, then a 50/50 iron/gold split.
	var chance: Variant = DB.get_stat("units", u.unit_type, "iron_chance", u.level)
	if chance == null or not (randf() < float(chance)):
		return
	var far_right: float = human_path[-1].x  # Map.getLastPoint(TEAM_ALLY).x
	if randf() < 0.50:
		var count_v: Variant = DB.get_stat("units", u.unit_type, "iron_drop", u.level)
		var count := int(count_v) if count_v != null else 0
		for i in count:
			_spawn_drop(u, true, 2, far_right, -60.0, 22.0, i)
	else:
		var count_v2: Variant = DB.get_stat("units", u.unit_type, "gold_drop", u.level)
		var count2 := int(count_v2) if count_v2 != null else 0
		# Endless reuses wave_51's economy — the clamp keeps current_wave<=51 here.
		var value_v: Variant = DB.get_wave_data(mini(GameState.current_wave, 51)).get("gold_value", 1)
		var value := int(value_v) if value_v != null else 1
		for i in count2:
			_spawn_drop(u, false, value, far_right, -40.0, 12.0, i)

func _spawn_drop(u: Unit, is_iron: bool, value: int, far_right: float,
		base_offset: float, spacing: float, idx: int) -> void:
	var land_x: float = u.position.x + minf(base_offset, far_right - u.position.x) \
		+ float(idx) * spacing
	var land_y: float = -ground_y(land_x)
	var c := Coin.new()
	c.main = self
	c.value = value
	c.is_iron = is_iron
	c._delay = float(idx) * 0.1
	c._start = Vector2(u.position.x, land_y - COIN_DROP_HEIGHT)
	c._land = Vector2(land_x, land_y)
	c.position = c._start
	fx_layer.add_child(c)
	_coins.append(c)

func spawn_coin_at(x: float, is_iron: bool, value: int) -> Coin:
	## A coin parked on the ground at x (the tutorial's fixed bars/coins).
	var land_y: float = -ground_y(x)
	var c := Coin.new()
	c.main = self
	c.value = value
	c.is_iron = is_iron
	c._start = Vector2(x, land_y)
	c._land = Vector2(x, land_y)
	c._delay = -1.0  # skip the drop-in: spawnCoin lands it directly (alpha 1)
	c.position = c._start
	fx_layer.add_child(c)
	_coins.append(c)
	return c

class Coin extends Node2D:
	## Ash vacuums coins within COIN_PICKUP_RANGE; iron flies to the smithy chip, gold banks on grab.
	const TEXEL := 480.0 / 1024.0  # assets.lua ratio (main.EFFECT_TEXEL): item art draws at ratio scale
	var main: Node2D
	var value := 1
	var is_iron := false
	var _delay := 0.0
	var _start := Vector2.ZERO
	var _land := Vector2.ZERO
	var _age := 0.0
	var _spr: Sprite2D
	var _collected := false
	var _collect_t := 0.0
	var _collect_from := Vector2.ZERO

	func _ready() -> void:
		_spr = Sprite2D.new()
		_spr.texture = load("res://assets/ui/hud/iron_bar.webp" if is_iron \
			else "res://assets/ui/hud/coin.webp")
		_spr.scale = Vector2.ONE * TEXEL
		_spr.modulate.a = 0.0  # spawnCoin: color starts (1,1,1,0)
		_spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_spr)

	func _process(dt: float) -> void:
		if _collected:
			_collect_tick(dt)
			return
		_age += dt
		var t := _age - _delay
		if t < 0.0:
			return  # SleepAction(i*0.1): parked invisible at the start point
		if t <= COIN_DROP_TIME:
			var k := t / COIN_DROP_TIME
			position = _start.lerp(_land, k * k)  # InterpAction.Ramp
			_spr.modulate.a = k * k
		elif t <= COIN_DROP_TIME + COIN_PULSE_TIME:
			position = _land
			_spr.modulate.a = 1.0
			var pt := fposmod(t - COIN_DROP_TIME, 0.5)
			var sp := smoothstep(0.0, 0.25, pt) if pt < 0.25 \
				else 1.0 - smoothstep(0.0, 0.25, pt - 0.25)
			_spr.scale = Vector2.ONE * TEXEL * lerpf(0.9, 1.1, sp)
		elif t <= COIN_DROP_TIME + COIN_PULSE_TIME + COIN_FADE_TIME:
			position = _land
			_spr.scale = Vector2.ONE * TEXEL
			_spr.modulate.a = 1.0 - (t - COIN_DROP_TIME - COIN_PULSE_TIME) / COIN_FADE_TIME
		else:
			queue_free()
			return
		# LuaAshUnit.checkForCoins: vacuum TEAM_COIN objects in x +/- 37.5
		var ash: Unit = main.ash
		if ash != null and is_instance_valid(ash) and ash.state != Unit.State.DEAD \
				and absf(ash.position.x - position.x) < main.COIN_PICKUP_RANGE:
			_collected = true
			main._coins.erase(self)
			_collect_from = position
			_collect_t = 0.0
			main.play_sfx("iron_pickup" if is_iron else "coin_pickup")
			if not is_iron:
				# the coin banks its value the moment Ash grabs it
				GameState.add_gold(value)
				main.wave_gold_collected += value

	func _collect_tick(dt: float) -> void:
		_collect_t += dt
		if is_iron:
			# The chip is HUD-space, so chase its world point.
			var k := clampf(_collect_t / 0.7, 0.0, 1.0)
			var kk := k * k * (3.0 - 2.0 * k)  # InterpAction.Smooth
			var chip: TextureButton = main.hud.smith_chip
			var target := _collect_from
			if chip != null and is_instance_valid(chip):
				target = main._screen_to_world(chip.get_global_rect().get_center() \
					+ Vector2(13.5, 13.5))
			position = _collect_from.lerp(target, kk)
			if k >= 1.0:
				main.increment_iron(main.IRON_PER_BAR)
				queue_free()
		else:
			# MoveOffset(0.5, Fall, 100 up) + alpha fade + scale 2.0x->1.0x
			var k2 := clampf(_collect_t / 0.5, 0.0, 1.0)
			position.y = _collect_from.y - 100.0 * (1.0 - (1.0 - k2) * (1.0 - k2))
			_spr.modulate.a = 1.0 - k2
			var sc := smoothstep(0.0, 1.0, clampf(_collect_t / 0.25, 0.0, 1.0)) \
				if _collect_t < 0.25 \
				else 1.0 - smoothstep(0.0, 1.0, clampf((_collect_t - 0.25) / 0.25, 0.0, 1.0))
			_spr.scale = Vector2.ONE * TEXEL * lerpf(1.0, 2.0, sc)
			if k2 >= 1.0:
				queue_free()

# ---------------------------------------------------------------- economy

func _process(dt: float) -> void:
	# Torch glow flicker — runs even between waves.
	for g: Dictionary in _glows:
		var t := Time.get_ticks_msec() / 1000.0
		(g["spr"] as Sprite2D).modulate.a = float(g["dim"]) * (0.86 \
			+ 0.08 * sin(t * float(g["speed"]) + float(g["phase"])) \
			+ 0.06 * sin(t * float(g["speed"]) * 2.7 + float(g["phase"]) * 2.0))
	# Anvil sparks phase-lock tick — runs even between waves.
	_tick_anvil_sparks()
	if wave_over:
		return
	increment_iron(iron_rate * dt)
	for k: String in button_cooldowns.keys():
		button_cooldowns[k] = maxf(button_cooldowns[k] - dt, 0.0)
	for k: String in spell_cooldowns.keys():
		spell_cooldowns[k] = maxf(spell_cooldowns[k] - dt, 0.0)

	# LuaMainGame.tick: last unit spawned and the field is clear -> wave won.
	if not spawner.active and enemies_alive() == 0 and spawner._events.size() > 0:
		_finish_wave(true)

	# Camera tracks Ash: X clamped to the camera path, Y from its elevation profile.
	if ash != null and is_instance_valid(ash):
		var cx := clampf(ash.position.x, cam_min_x, cam_max_x)
		camera.position = Vector2(cx, _g(0.0, _cam_y(cx)).y)
	_gate_warn_t = maxf(_gate_warn_t - dt, 0.0)
	# catapult impacts shake the camera (doCameraShake +/-2, -4)
	if _shake > 0.0:
		_shake -= dt
		camera.offset = Vector2(randf_range(-2.0, 2.0), randf_range(-4.0, 0.0)) * (_shake / 0.35)
	else:
		camera.offset = Vector2.ZERO

	_tick_keyboard_run()

func _keyboard_dir() -> float:
	## A/D (or arrows) run Ash left/right, like doNormalInput's drag zones.
	var dir := 0.0
	if Input.is_physical_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_LEFT):
		dir -= 1.0
	if Input.is_physical_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_RIGHT):
		dir += 1.0
	return dir

func _tick_keyboard_run() -> void:
	# bg_editor owns the keyboard while up — Ash must not walk out from under a drag.
	if bg_editor != null or wave_over or ash == null or not is_instance_valid(ash) or ash.state == Unit.State.DEAD:
		_kb_running = false
		return
	var dir := _keyboard_dir()
	if dir != 0.0:
		# Bound to the ally path's END POINTS — the original's walkable range.
		ash.walk_in_x = clampf(ash.position.x + dir * 500.0, human_path[0].x, human_path[-1].x)
		ash.state = Unit.State.WALK_IN
		_kb_running = true
	elif _kb_running:
		_kb_running = false
		ash.walk_in_x = ash.position.x
		ash.state = Unit.State.COMBAT

# -------------------------------------------------------------------- sfx

func _flash_hint(text: String) -> void:
	## ephemeral top-left notice (mute toggle etc.), fades and frees itself
	var layer := CanvasLayer.new()
	layer.layer = 50
	add_child(layer)
	var lb := Label.new()
	lb.text = text
	lb.add_theme_font_size_override("font_size", 18)
	lb.modulate = Color(1.0, 0.95, 0.8, 0.95)
	lb.position = Vector2(16, 10)
	layer.add_child(lb)
	var tw := lb.create_tween()
	tw.tween_interval(1.4)
	tw.tween_property(lb, "modulate:a", 0.0, 0.6)
	tw.tween_callback(layer.queue_free)

func _sfx_stream(path: String) -> AudioStream:
	if not _sfx_streams.has(path):
		_sfx_streams[path] = load(path)
	return _sfx_streams[path]

func play_sfx(key: String, volume_db := 0.0) -> void:
	## exact manifest key; silently no-ops when audio is unavailable
	if _sfx_meta == null or _sfx_meta.is_empty():
		return
	var e: Variant = _sfx_meta.get(key)
	if e == null or not (e is Dictionary):
		return
	var stream := _sfx_stream(str(e["path"]))
	for pl: AudioStreamPlayer in _sfx_pool:
		if not pl.playing:
			pl.stream = stream
			pl.volume_db = volume_db
			pl.play()
			return

func play_sfx_like(prefix: String, volume_db := 0.0) -> void:
	## random variant among manifest keys starting with the prefix
	if _sfx_meta == null or _sfx_meta.is_empty():
		return
	var matches: Array = []
	for k: String in _sfx_meta.keys():
		if k.begins_with(prefix):
			matches.append(k)
	if matches.is_empty():
		return
	play_sfx(matches[randi() % matches.size()], volume_db)

func play_unit_sound(unit_type: String, kind: String) -> void:
	play_sfx_like("%s_on_%s" % [unit_type, kind], -4.0)

func play_music(alternate: bool) -> void:
	if music_player == null:
		return
	var e: Variant = _sfx_meta.get("music_in_game_2" if alternate else "music_in_game_1")
	if e == null or not (e is Dictionary):
		return
	var stream := _sfx_stream(str(e["path"]))
	# Without .loop the song ends into silence.
	if stream is AudioStreamOggVorbis:
		stream.loop = true
	music_player.stream = stream
	music_player.play()

func play_menu_music() -> void:
	## The menu flow's looping track; teardown_battle hands the Music bus over.
	if music_player == null:
		return
	var e: Variant = _sfx_meta.get("music_loop")
	if e == null or not (e is Dictionary):
		return
	var stream := _sfx_stream(str(e["path"]))
	if stream is AudioStreamOggVorbis:
		stream.loop = true
	music_player.stream = stream
	music_player.play()

func increment_iron(amount: float) -> void:
	var prev := int(iron)
	iron = minf(iron + amount, float(iron_cap))
	if int(iron) != prev:
		hud.on_iron_changed()

func can_afford_iron(cost: int) -> bool:
	return iron >= cost

func can_upgrade_iron_cap() -> bool:
	## Below the cap tier and affordable right now — drives the chip's glow.
	var caps: Array = DB.table("globals").get("iron_level_cap", [50])
	if iron_level >= caps.size():
		return false
	var prices: Array = DB.table("globals").get("iron_level_cap_upgrade_price", [30, 50, 75])
	return iron >= float(prices[iron_level - 1])

func upgrade_iron_cap() -> bool:
	## Spends IRON (never gold); per-wave only — NOT persisted.
	var caps: Array = DB.table("globals").get("iron_level_cap", [50])
	if iron_level >= caps.size():
		hud.flash_message("Iron cap is MAXED")
		return false
	var prices: Array = DB.table("globals").get("iron_level_cap_upgrade_price", [30, 50, 75])
	var price := int(prices[iron_level - 1])
	if iron < price:
		hud.flash_message("Need %d iron to raise the cap" % price)
		return false
	iron -= price
	iron_level += 1
	iron_cap = int(caps[iron_level - 1])
	iron_rate *= float(DB.table("globals").get("iron_rate_upgrade_factor", 1.5))
	play_sfx("objects_units_spawn_blacksmith_ill_stand_by_ya")
	return true

# ------------------------------------------------------------------ spells

func equipped_spells() -> Array:
	## No player pick yet = auto-equip by unlock order.
	var unlocked: Array = []
	for id: String in SPELL_PRIORITY:
		var entry := DB.entry("spells", id)
		if entry.is_empty():
			continue
		if GameState.current_wave >= int(entry.get("unlock_wave", 1)):
			unlocked.append(id)
	if not GameState.selected_spells.is_empty():
		# the player's picks, filtered to what's unlocked this wave
		var picked: Array = []
		for id: String in GameState.selected_spells:
			if id in unlocked:
				picked.append(id)
		if not picked.is_empty():
			return picked
	var out: Array = []
	if unlocked.size() > 0:
		out.append(unlocked[0])
	for id: String in unlocked:
		if not id in out:
			out.append(id)
			break
	return out

func cast_spell(id: String, target_x := -1.0) -> bool:
	if spell_cooldowns.get(id, 0.0) > 0.0 or ash == null or ash.state == Unit.State.DEAD:
		return false
	var lvl := GameState.get_type_level(id)
	var cd: Variant = DB.get_stat("spells", id, "cooldown", lvl)
	spell_cooldowns[id] = float(cd) if cd != null else 20.0
	# The press sound fires immediately; non-user-targeted spells land at ash + offset + auto_target_offset.
	var press: Variant = DB.entry("spells", id).get("on_button_press_sound")
	if press != null and str(press) != "":
		play_sfx(str(press).replace("/", "_"))
	var off: Variant = DB.get_stat("spells", id, "auto_target_offset", lvl)
	var cast_x: float = target_x if target_x >= 0.0 \
		else ash.position.x + NON_USER_TARGETED_SPELL_OFFSET + (float(off) if off != null else 0.0)
	# super_boomstick_blast already swings attack_a in _cast_super_boomstick — don't double-play.
	if id != "super_boomstick_blast":
		ash.play_cast_anim()
	match id:
		"arrow_volley":
			_cast_arrow_volley(lvl, cast_x)
		"super_boomstick_blast":
			_cast_super_boomstick(lvl)
		"vortex":
			_cast_vortex(lvl, cast_x)
		"magic_words":
			_cast_magic_words(lvl)
		"catapults_spell":
			_cast_catapult_volley(lvl, cast_x)
		"deathcoaster_spell":
			_cast_deathcoaster(lvl)
	return true

func _cast_arrow_volley(lvl: int, start_x: float) -> void:
	## Hidden homing shots per living enemy, plus a visible rain of num_arrows.
	var range_v: Variant = DB.get_stat("spells", "arrow_volley", "range", lvl)
	var range_: float = float(range_v) if range_v != null else 80.0
	var ammo_v: Variant = DB.get_stat("spells", "arrow_volley", "ammo", lvl)
	var ammo := str(ammo_v) if ammo_v != null else "volley_arrows"
	var dmg_v: Variant = DB.get_stat("ammo", ammo, "damage", lvl)
	var damage := int(float(dmg_v) if dmg_v != null else 0.0)
	var speed_v: Variant = DB.get_stat("ammo", ammo, "speed", lvl)
	var speed := float(speed_v) if speed_v != null else 1500.0
	var flaming: bool = DB.get_stat("ammo", ammo, "flaming", lvl) == true
	var fdps_v: Variant = DB.get_stat("ammo", ammo, "flame_dps", lvl)
	var flame_dps := float(fdps_v) if fdps_v != null else 0.0
	var explosive: bool = DB.get_stat("ammo", ammo, "explosive", lvl) == true
	var sr_v: Variant = DB.get_stat("ammo", ammo, "splash_range", lvl)
	var splash_range := float(sr_v) if sr_v != null else 0.0
	play_sfx("arrow_volley")  # spells.arrow_volley on_cast_event_sound

	var num_arrows := int(floor(range_ * 2.0 / 7.5))
	var damage_y := 100.0 * float(num_arrows) * 0.25
	for u: Unit in _team_objects(Unit.Team.ENEMY):
		if u.state == Unit.State.DEAD:
			continue
		if u.position.x < start_x or u.position.x > start_x + range_ * 2.0:
			continue
		var a := VolleyArrow.new()
		a.main = self
		a.victim = u
		a.dest = u.position
		a.is_hidden = true
		a.speed = speed
		a.damage = damage
		a.flaming = flaming
		a.flame_dps = flame_dps
		a.explosive = explosive
		a.splash_range = splash_range
		a.position = u.position + Vector2(-300.0, -(400.0 + damage_y))
		fx_layer.add_child(a)

	var arrow_tex: Texture2D = load("res://assets/fx/blur_flaming_arrow.webp")
	var y_locs: Array = []
	for i in num_arrows:
		y_locs.append(100.0 * float(i + 1))
	for i in num_arrows:
		var tx := start_x + float(i) * 7.5
		var ty := -ground_y(tx) - (float(randi() % 41 - 20) + 20.0)
		var pick := randi() % y_locs.size()
		var rise: float = y_locs[pick]
		y_locs.remove_at(pick)
		var a2 := VolleyArrow.new()
		a2.main = self
		a2.dest = Vector2(tx, ty)
		a2.speed = speed
		a2.tex = arrow_tex
		a2.position = a2.dest + Vector2(-300.0, -(400.0 + rise))
		fx_layer.add_child(a2)

func _cast_super_boomstick(lvl: int) -> void:
	## Big hit in weapon range, knockback x20.
	if anim_has(ash, "attack_a"):
		ash.play_attack_anim()
	var dmg_v: Variant = DB.get_stat("weapons", "super_boomstick", "damage", clampi(lvl, 1, 10))
	var dmg := int(float(dmg_v) if dmg_v != null else 35.0)
	play_sfx("super_boomstick_hit")
	var muzzle := _muzzle_pos(ash)
	_spawn_muzzle_flash(muzzle)
	_spawn_boom_cloud(muzzle)
	for u: Unit in _team_objects(Unit.Team.ENEMY):
		if u.state == Unit.State.DEAD:
			continue
		var dx: float = u.position.x - ash.position.x
		if dx > -20.0 and dx <= 220.0:
			u.take_damage(dmg, ash, 20.0)

func _muzzle_pos(u: Unit) -> Vector2:
	## Boomstick muzzle world point.
	return Vector2(u.position.x + 35.0 * signf(u.facing if u.facing != 0.0 else 1.0),
		u.position.y - u.height * u.body_scale * 0.6)

func _spawn_muzzle_flash(pos: Vector2) -> void:
	## Pop 0 -> full sliding right, then collapse back and fade.
	var flash := Sprite2D.new()
	flash.texture = load("res://assets/fx/muzzle_flash.webp")
	flash.position = pos
	flash.scale = Vector2.ZERO
	flash.z_index = 50
	fx_layer.add_child(flash)
	var s := EFFECT_TEXEL
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(flash, "scale", Vector2.ONE * s, 0.15)
	tw.tween_property(flash, "position:x", pos.x + 198.0 * s * 0.5, 0.15)
	tw.chain().tween_property(flash, "modulate:a", 0.0, 0.15)
	tw.parallel().tween_property(flash, "scale", Vector2.ZERO, 0.15)
	tw.parallel().tween_property(flash, "position:x", pos.x, 0.15)
	tw.chain().tween_callback(flash.queue_free)

func _spawn_smoke_puff(pos: Vector2) -> void:
	## Pop in, then drift up while fading over 1.2 s.
	var puff := Sprite2D.new()
	puff.texture = load("res://assets/fx/smoke_puff.webp")
	puff.position = pos
	puff.scale = Vector2.ZERO
	puff.z_index = 50
	fx_layer.add_child(puff)
	var s := EFFECT_TEXEL
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(puff, "scale", Vector2.ONE * s, 0.15)
	tw.tween_property(puff, "position:x", pos.x + 147.0 * s * 0.5, 0.15)
	tw.tween_property(puff, "modulate:a", 1.0, 0.15)
	tw.chain().tween_property(puff, "position:y", pos.y - 129.0 * s * 0.5, 1.2) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.parallel().tween_property(puff, "modulate:a", 0.0, 1.2)
	tw.chain().tween_callback(puff.queue_free)

func _spawn_boom_cloud(pos: Vector2) -> void:
	## BOOM cloud pops in at the muzzle, then fades over 1.2 s.
	var cloud := Sprite2D.new()
	cloud.texture = load("res://assets/ui/hud/boom_blast.webp")
	cloud.position = pos
	cloud.scale = Vector2.ZERO
	cloud.z_index = 50
	fx_layer.add_child(cloud)
	var s := EFFECT_TEXEL
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(cloud, "scale", Vector2.ONE * s, 0.15)
	tw.tween_property(cloud, "position:x", pos.x + 403.0 * s * 0.5, 0.15)
	tw.tween_property(cloud, "modulate:a", 0.75, 0.15)
	tw.chain().tween_property(cloud, "modulate:a", 0.0, 1.2)
	tw.chain().tween_callback(cloud.queue_free)

func anim_has(u: Unit, clip: String) -> bool:
	## Clip presence on either render path (baked strips AND the live 3D actor).
	return u != null and u._has_clip(clip)

func _cast_vortex(lvl: int, target_x: float) -> void:
	## The fake book appears ahead and sucks non-unique enemies until the budget runs out.
	var dmg_v: Variant = DB.get_stat("spells", "vortex", "damage", lvl)
	var budget := float(dmg_v) if dmg_v != null else 55.0
	# Clamped onto the walkable field — past the path ends the book floats off-map.
	var book_x := clampf(target_x + 50.0, ally_spawn_x + 60.0, enemy_spawn_x - 60.0)
	var victims: Array = []
	for u: Unit in _team_objects(Unit.Team.ENEMY):
		if u.state == Unit.State.DEAD:
			continue
		var uniq: Variant = DB.entry("units", u.unit_type).get("unique", false)
		if bool(uniq):
			continue
		if absf(u.position.x - book_x) <= 200.0:
			victims.append(u)
	# nearest first so the book eats the closest horde
	victims.sort_custom(func(a, b): return absf(a.position.x - book_x) < absf(b.position.x - book_x))
	var eaten: Array = []
	for u: Unit in victims:
		eaten.append(u)
		budget -= maxf(u.health, 1.0)
		if budget <= 0.0:
			break
	# Do NOT gate the book spawn on targets in range; victims go neutral now so nothing can kill them mid-suck and double-count.
	for u: Unit in eaten:
		u.state = Unit.State.DEAD
	play_sfx("fx_the_wrong_book_special_attack")
	var t := VortexSuck.new()
	t.main = self
	t.book_x = book_x
	t.ground_y = -ground_y(book_x)
	t.victims = eaten
	fx_layer.add_child(t)

func _cast_magic_words(lvl: int) -> void:
	## A fizzle heals later; a success summons later — both resolve at the 1.65 s timer.
	var necktie: Variant = DB.get_stat("spells", "magic_words", "necktie_chance", lvl)
	var fizzle := randf() <= float(necktie if necktie != null else 0.0)
	if ash != null and is_instance_valid(ash):
		# Z_FG, not -1 — at -1 it drew behind every units_layer body.
		_spawn_granny_effect("mesh/objects/spells/magic_words.gr2",
			"necktie" if fizzle else "nicto", ash.position, Z_FG)
	if fizzle:
		play_sfx("objects_skills_ash_words_necktie_short")  # assets.words_fail
		get_tree().create_timer(1.65).timeout.connect(_magic_words_necktie.bind(lvl))
	else:
		play_sfx("objects_skills_ash_words_cough")  # assets.words_success
		get_tree().create_timer(1.65).timeout.connect(_magic_words_summon.bind(lvl))

func _spawn_granny_effect(model_uri: String, clip: String, at: Vector2, z: int,
		tex_path := "") -> Node:
	## Headless runs return null — callers keep their sprite fallbacks.
	if DisplayServer.get_name() == "headless":
		return null
	if tex_path == "":
		tex_path = "res://assets/units/%s.webp" % GrannyActor3D.glb_stem_for_model(model_uri)
	if not ResourceLoader.exists(tex_path):
		return null
	var a := GrannyActor3D.new()
	if not a.setup(model_uri, load(tex_path)):
		return null
	a.position = at
	a.z_index = z
	fx_layer.add_child(a)
	a.play_clip(clip, false)
	var tw := a.create_tween()
	tw.tween_interval(maxf(a.get_clip_length(clip), 0.1))
	tw.tween_callback(a.queue_free)
	return a

func _magic_words_necktie(lvl: int) -> void:
	## Heals heal_percent of MAX health per living ally.
	if ash != null and is_instance_valid(ash):
		ash.show_necktie()
	var heal_v: Variant = DB.get_stat("spells", "magic_words", "heal_percent", lvl)
	var heal := float(heal_v) if heal_v != null else 0.25
	for u: Unit in _team_objects(Unit.Team.ALLY):
		if u.state == Unit.State.DEAD or u.is_prop:
			continue
		var amount := int(floor(heal * u.max_health))
		if amount <= 0:
			continue
		u.health = minf(u.health + float(amount), u.max_health)
		_spawn_heal_signs(u)

func _spawn_heal_signs(u: Unit) -> void:
	## util.showHealSign defaults: heal_effect, clip length 1.1.
	spawn_sign(u)

func _magic_words_summon(lvl: int) -> void:
	## ONE random spawn_unit entry; units appear left of Ash, stunned and spell-blue.
	var units_v: Variant = DB.get_stat("spells", "magic_words", "spawn_unit", lvl)
	var nums_v: Variant = DB.get_stat("spells", "magic_words", "spawn_num", lvl)
	if units_v == null or ash == null or not is_instance_valid(ash):
		return
	var unit_list: PackedStringArray = str(units_v).split(";")
	var num_list: PackedStringArray = str(nums_v).split(";") if nums_v != null else PackedStringArray()
	if unit_list.is_empty():
		return
	var idx := randi() % unit_list.size()
	var type_name := str(unit_list[idx])
	var n := int(num_list[idx]) if idx < num_list.size() else 1
	var sum_lvl_v: Variant = DB.get_stat("spells", "magic_words", "summon_level", lvl)
	var sum_lvl := int(sum_lvl_v) if sum_lvl_v != null else 1
	for i in range(1, n + 1):
		var x := ash.position.x - 30.0 * float(i)
		var u := _make_unit(type_name, sum_lvl, Unit.Team.ALLY)
		u.position = _g(x, ground_y(x))
		u.lane_offset = _next_slot()
		u.position.y += u.lane_offset
		u.walk_in_x = x
		# A hold via knockback, not a direct stumble_time write.
		u.apply_knockback(0.0, float(i) * 0.065)
		# the spell's blue tint, hidden until the fade_in_sequence runs
		# (SleepAction 0.25, then 0.5 s alpha lerp back to the tinted alpha)
		u.modulate = Color(0.75, 0.75, 1.0, 0.0)
		_mark_unique_spawned(type_name)
		u.died.connect(_on_unit_died)
		units_layer.add_child(u)
		var tw := u.create_tween()
		tw.tween_interval(0.25)
		tw.tween_property(u, "modulate:a", 1.0, 0.5)
		_spawn_poof(u)
		_maybe_spawn_subordinates(u)

func _spawn_poof(u: Unit) -> void:
	## Poof at the unit; the art sprite is the headless fallback.
	if _spawn_granny_effect("mesh/objects/spells/poof.gr2", "poof", u.position, 5) != null:
		return
	var s := Sprite2D.new()
	s.texture = load("res://assets/ui/hud/poof.webp")
	s.position = u.position + Vector2(0.0, -u.height * u.body_scale * 0.5)
	s.scale = Vector2.ONE * EFFECT_TEXEL
	s.z_index = Z_FG
	fx_layer.add_child(s)
	var tw := s.create_tween()
	tw.tween_property(s, "modulate:a", 0.0, 0.5)
	tw.tween_callback(s.queue_free)

func summon_at(type_name: String, lvl: int, x: float) -> Unit:
	var u := _make_unit(type_name, lvl, Unit.Team.ALLY)
	u.position = _g(x, ground_y(x))
	u.lane_offset = _next_slot()
	u.position.y += u.lane_offset
	# Walk in to the normal ally post — the hero spawn point can sit off-screen and strand the unit in WALK_IN.
	u.walk_in_x = ally_spawn_x + randf_range(-20.0, 40.0)
	_mark_unique_spawned(type_name)
	u.died.connect(_on_unit_died)
	units_layer.add_child(u)
	_maybe_spawn_subordinates(u)
	return u

# ------------------------------------------------------- ally subordinates

func _maybe_spawn_subordinates(parent: Unit) -> void:
	## Subordinates spawn 1 s later, no spawn sound.
	if parent == null or not is_instance_valid(parent):
		return
	if str(DB.entry("units", parent.unit_type).get("script", "")) != "allyunit":
		return
	var sub: Variant = DB.get_stat("units", parent.unit_type, "subordinate", parent.level)
	var count: Variant = DB.get_stat("units", parent.unit_type, "subordinate_count", parent.level)
	if sub == null or count == null or int(count) <= 0 or str(sub) == "":
		return
	var sub_type := str(sub)
	if DB.entry("units", sub_type).is_empty():
		return
	var n := int(count)
	var lvl := parent.level
	var home_x := parent.position.x
	var parent_ref := parent
	print("[ally] %s summons %d x %s (L%d)" % [parent.unit_type, n, sub_type, lvl])
	get_tree().create_timer(1.0).timeout.connect(func() -> void:
		if not is_instance_valid(parent_ref) or wave_over:
			return
		for i in n:
			_spawn_ally_on_path(sub_type, lvl, home_x))

func _spawn_ally_on_path(type_name: String, lvl: int, near_x: float) -> Unit:
	var u := _make_unit(type_name, lvl, Unit.Team.ALLY)
	var sx := clampf(near_x, ally_spawn_x, enemy_spawn_x - 40.0)
	u.position = _g(sx, ground_y(sx))
	u.lane_offset = _next_slot()
	u.position.y += u.lane_offset
	u.walk_in_x = sx + randf_range(-20.0, 40.0)
	u.died.connect(_on_unit_died)
	units_layer.add_child(u)
	return u

func on_wave_hero_spawn(hero_type: String) -> void:
	## Banner + level-1 hero spawn; he walks in like any summoned ally.
	if wave_over or DB.entry("units", hero_type).is_empty():
		return
	print("[wave] hero spawn tag -> ", hero_type)
	if tutorial != null:
		tutorial.show_hero_banner("A hero has appeared!")
	var spawn_x: float = maxf(ash.position.x - 300.0, ally_spawn_x - 100.0)
	var u := summon_at(hero_type, 1, spawn_x)
	play_unit_sound(hero_type, "spawn")  # createUnitOnPath plays it by default

# ------------------------------------------------------- buff bubbles / signs

func spawn_bubble(u: Unit, tex_path: String, height := 100.0, tex_scale := 1.0) -> void:
	## Pops in at the unit's middle, rises while fading, pulses 2x -> 1x.
	var tex: Texture2D = load(tex_path)
	if tex == null or u == null or not is_instance_valid(u):
		return
	var s := Sprite2D.new()
	s.texture = tex
	s.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	s.scale = Vector2.ONE * 0.5 * tex_scale  # engine draws textures at half px size
	s.position = u.position + Vector2(0.0, -tex.get_height() * 0.25 * tex_scale)
	s.z_index = Z_FG
	fx_layer.add_child(s)
	var tw := s.create_tween()
	tw.set_parallel(true)
	tw.tween_property(s, "position:y", s.position.y - height, 0.65) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)  # InterpAction.Fall
	tw.tween_property(s, "modulate:a", 0.0, 0.65)
	tw.tween_property(s, "scale", Vector2.ONE * tex_scale, 0.325) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.chain().tween_property(s, "scale", Vector2.ONE * 0.5 * tex_scale, 0.325) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.chain().tween_callback(s.queue_free)

func spawn_sign(u: Unit, tex_path := "res://assets/fx/heal_effect.webp", length := 1.1) -> void:
	## Three rising copies {100,90,80} drift {0,10,-10}, staggered.
	var heights := [100.0, 90.0, 80.0]
	var drifts := [0.0, 10.0, -10.0]
	for i in 3:
		var s := RisingSign.new()
		s.delay = float(i + 1) * length * 0.1
		s.rise = heights[i]
		s.drift = drifts[i]
		s.phase = length * 0.5
		s.tex_path = tex_path
		s.position = u.position + Vector2(0.0, -u.height * u.body_scale * 0.5)
		fx_layer.add_child(s)

class RisingSign extends Node2D:
	## One rising sprite; tex + phase configurable.
	var delay := 0.11
	var rise := 100.0
	var drift := 0.0
	var phase := 0.55
	var tex_path := "res://assets/fx/heal_effect.webp"
	var _t := 0.0
	var _from := Vector2.ZERO
	var _spr: Sprite2D

	func _ready() -> void:
		_from = position
		_spr = Sprite2D.new()
		_spr.texture = load(tex_path)
		_spr.scale = Vector2.ONE * EFFECT_TEXEL
		_spr.modulate.a = 0.0
		_spr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		add_child(_spr)

	func _process(dt: float) -> void:
		_t += dt
		if _t < delay:
			return
		var t := _t - delay
		if t >= phase * 2.0:
			queue_free()
			return
		if t < phase:
			var k := t / phase
			var fall := 1.0 - (1.0 - k) * (1.0 - k)  # InterpAction.Fall
			position = _from + Vector2(drift * fall, -rise * fall)
			_spr.modulate.a = 1.0
			_spr.scale = Vector2.ONE * EFFECT_TEXEL
		else:
			var k2 := clampf((t - phase) / phase, 0.0, 1.0)
			position = _from + Vector2(drift, -rise)
			_spr.modulate.a = 1.0 - k2
			var sc := smoothstep(0.0, 1.0, clampf((t - phase) / (phase * 0.5), 0.0, 1.0)) \
				if t < phase * 1.5 \
				else 1.0 - smoothstep(0.0, 1.0, clampf((t - phase * 1.5) / (phase * 0.5), 0.0, 1.0))
			_spr.scale = Vector2.ONE * EFFECT_TEXEL * lerpf(1.0, 2.0, sc)

func _cast_catapult_volley(lvl: int, start_x: float) -> void:
	## num_rocks strafe the zone; each impact does zone damage, knockback, explosion, shake.
	var range_v: Variant = DB.get_stat("spells", "catapults_spell", "range", lvl)
	var range_: float = float(range_v) if range_v != null else 80.0
	var num_rocks := int(floor(range_ * 2.0 / 70.0))
	if num_rocks <= 0:
		return
	play_sfx("fx_catapult_volley")  # spells.catapults_spell on_cast_event_sound
	var dmg_v: Variant = DB.get_stat("ammo", "volley_rocks", "damage", lvl)
	var damage := float(dmg_v) if dmg_v != null else 180.0
	var flaming: bool = DB.get_stat("ammo", "volley_rocks", "flaming", lvl) == true
	var fdps_v: Variant = DB.get_stat("ammo", "volley_rocks", "flame_dps", lvl)
	var flame_dps := float(fdps_v) if fdps_v != null else 0.0
	var sr_v: Variant = DB.get_stat("ammo", "volley_rocks", "splash_range", lvl)
	var splash_range := float(sr_v) if sr_v != null else 0.0
	var kb_v: Variant = DB.get_stat("ammo", "volley_rocks", "knockback_multiplier", lvl)
	var knockback := float(kb_v) if kb_v != null else 0.0  # read for parity; the
	# ammo Lua punts a FIXED 50 px, it never consults this multiplier
	var dds_v: Variant = DB.get_stat("ammo", "volley_rocks", "on_deal_damage_sound", lvl)
	var rock_tex: Texture2D = load("res://assets/fx/blur_flaming_rock.webp" if flaming
		else "res://assets/fx/blur_rock.webp")
	var y_locs: Array = []
	for i in num_rocks:
		y_locs.append(75.0 * float(i + 1))
	for i in num_rocks:
		var tx := start_x + float(i) * 70.0
		var pick := randi() % y_locs.size()
		var rise: float = y_locs[pick]
		y_locs.remove_at(pick)
		var r := VolleyRock.new()
		r.main = self
		r.dest = Vector2(tx, -ground_y(tx))
		r.speed = 1500.0  # volley_rocks level speed
		r.damage = damage / float(num_rocks)
		r.zone_from = start_x
		r.zone_to = start_x + range_ * 2.0
		r.flaming = flaming
		r.flame_dps = flame_dps
		r.splash_range = splash_range
		r.on_deal_damage_sounds = str(dds_v) if dds_v != null else ""
		r.tex = rock_tex
		r.position = r.dest + Vector2(-300.0, -(400.0 + rise))
		fx_layer.add_child(r)

func _cast_deathcoaster(lvl: int) -> void:
	## Spawn left of the field and drive right, spending the damage budget.
	var dmg_v: Variant = DB.get_stat("spells", "deathcoaster_spell", "damage", lvl)
	var t := DeathcoasterRide.new()
	t.main = self
	t.damage_remaining = float(dmg_v) if dmg_v != null else 4000.0
	t.start_x = ally_spawn_x - 250.0
	t.end_x = human_path[-1].x
	fx_layer.add_child(t)
	play_sfx("fx_deathcoaster_special_attack_loop")

# -------------------------------------------------------------- end states

func _on_unit_died(u: Unit) -> void:
	# A dying flute/drummer divides its damage buffs back out of every victim.
	if u.helper_kind == "flute":
		for other: Unit in _team_objects(u.team):
			if other != u and is_instance_valid(other):
				other.clear_damage_buff_from(u)
	if u.team == Unit.Team.ALLY:
		_mark_unique_died(u.unit_type)  # destroy() -> cooldown button makeReady
	if u.team == Unit.Team.ENEMY:
		enemies_killed += 1
		_drop_loot(u)
		award_enemy_death_gold(u, u.last_hit_by)
		play_unit_sound(u.unit_type, "death")
		_maybe_ash_kill_line(u)
		if endless_mode:
			endless.on_enemy_killed(u)
			endless.notify_died(u)
	if u == ash:
		_finish_wave(false)

func _maybe_ash_kill_line(u: Unit) -> void:
	## Wave-scaled chance 1.0 -> 0.25 by wave 50, under the kill-line cooldown.
	var killer: Unit = u.last_hit_by
	if killer == null or not is_instance_valid(killer) or killer != ash \
			or ash.state == Unit.State.DEAD:
		return
	if enemies_alive() == 0:
		return
	var now := Time.get_ticks_msec()
	if now < _ash_next_kill_ms:
		return
	var chance := 1.0 + (0.25 - 1.0) / 49.0 * float(maxi(GameState.current_wave - 1, 0))
	if randf() > clampf(chance, 0.25, 1.0):
		return
	_ash_next_kill_ms = now + ASH_KILL_COOLDOWN_MS
	play_sfx(ASH_KILL_LINES[randi() % ASH_KILL_LINES.size()])

func award_enemy_death_gold(u: Unit, killer: Unit) -> void:
	## 10% of ash_kill_bonus on any death, the remaining 90% when Ash landed the kill.
	if u == null or not is_instance_valid(u):
		return
	var bonus_v: Variant = DB.get_stat("units", u.unit_type, "ash_kill_bonus", u.level)
	var bonus := float(bonus_v) if bonus_v != null else 0.0
	_add_kill_gold(int(floor(bonus * 0.1 + 0.5)))
	if killer != null and is_instance_valid(killer) and killer == ash:
		_add_kill_gold(int(floor(bonus * 0.9 + 0.5)))

func _add_kill_gold(amount: int) -> void:
	if amount <= 0:
		return
	GameState.add_gold(amount)
	wave_gold_collected += amount

var _gate_warn_t := 0.0
# msec timestamp of the gate's last damaging hit (0 = never); the HUD warning shows while under 2.0 s old.
var gate_last_hit_at := 0
var _gate_flash: Sprite2D        # gate_white_flash overlay on the gate art
var _gate_flash_tween: Tween

func _on_ash_damaged(_u: Unit, amount: int) -> void:
	## Every hit tries a pain grunt (cooldown); under half health also re-flash the blood overlay.
	if amount <= 0 or ash == null or not is_instance_valid(ash) \
			or ash.state == Unit.State.DEAD:
		return
	var now := Time.get_ticks_msec()
	if now >= _ash_next_grunt_ms:
		_ash_next_grunt_ms = now + ASH_GRUNT_COOLDOWN_MS
		play_sfx_like("objects_units_take_damage_ash_pain")
	if ash.max_health > 0.0 and ash.health / ash.max_health < 0.50:
		hud.flash_blood_overlay()

func _on_gate_damaged(_u: Unit, amount: int) -> void:
	# Only a POSITIVE damage packet records the hit and flashes the gate.
	if amount <= 0:
		return
	gate_last_hit_at = Time.get_ticks_msec()
	# Alpha 0 -> 1 -> 0 (0.1 s each), then hidden again.
	if _gate_flash != null and is_instance_valid(_gate_flash):
		if _gate_flash_tween != null and _gate_flash_tween.is_valid():
			_gate_flash_tween.kill()
		_gate_flash.visible = true
		_gate_flash.modulate = Color(1, 1, 1, 0.0)
		_gate_flash_tween = create_tween()
		_gate_flash_tween.tween_property(_gate_flash, "modulate:a", 1.0, 0.1) \
			.set_ease(Tween.EASE_IN)
		_gate_flash_tween.tween_property(_gate_flash, "modulate:a", 0.0, 0.1) \
			.set_ease(Tween.EASE_IN)
		_gate_flash_tween.tween_callback(func() -> void:
			_gate_flash.visible = false)
	# "Protect the book!" warning, throttled like the original's prompt
	if _gate_warn_t <= 0.0:
		_gate_warn_t = 6.0
		hud.flash_message("Protect the book!")

func _on_gate_died(_u: Unit) -> void:
	_finish_wave(false)

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		if not sandbox and not Dbg.args.has("smoke-test"):
			GameState.save()  # progress survives the window X
		get_tree().quit()

func teardown_battle() -> void:
	## Sets wave_over FIRST so no side effect can re-enter the end-of-wave flow during the sweep.
	wave_over = true
	wave_won = false
	gate_last_hit_at = 0  # no protect-the-book warning over the menu screens
	_gate_warn_t = 0.0
	# endless_mode must drop with the director or a straggler death calls into the freed node.
	spawner.stop()
	if endless != null:
		endless.queue_free()
		endless = null
	endless_mode = false
	if tutorial != null:
		tutorial.cancel_all()  # wave_*Actor:gameOver — clear every tutorial screen
	for c in units_layer.get_children():
		c.queue_free()
	for c in fx_layer.get_children():
		c.queue_free()
	_coins.clear()
	_projectiles.clear()
	# Drop the freed defense refs so no later iterator sees a freed instance.
	wall_archers.clear()
	catapults.clear()
	# Every SFX pool player stops with the battle.
	for pl: AudioStreamPlayer in _sfx_pool:
		pl.stop()
	# The menu flow's own track.
	play_menu_music()

func _finish_wave(won: bool) -> void:
	if wave_over:
		return
	# Endless never ends in victory; a loss falls through to the defeat flow.
	if endless_mode and won:
		return
	wave_over = true
	wave_won = won
	# Nothing may land after the banner rises; queue_free skips _die()'s erase, so clear the array too.
	for p in _projectiles:
		if is_instance_valid(p):
			p.queue_free()
	_projectiles.clear()
	if tutorial != null:
		tutorial.cancel_all()  # wave_*Actor:gameOver — clear every tutorial screen
	# The banner must show the wave just played — current_wave increments below on a win.
	hud.wave_num_override = GameState.current_wave
	var awarded := 0
	if won:
		# LuaMainGame.gameOver: award the completion bonus and advance.
		awarded = int(DB.get_wave_data(GameState.current_wave).get("completion_bonus", 0))
		GameState.add_gold(awarded)
		GameState.current_wave += 1
		play_sfx("victory_cheer")
		get_tree().create_timer(1.5).timeout.connect(func() -> void:
			play_sfx(ASH_WIN_LINES[randi() % ASH_WIN_LINES.size()]))
		_set_win_animations()
		menus.on_wave_won()  # UI-01: victory CONTINUE chains You Unlocked -> upgrades
	else:
		play_sfx_like("objects_level_loose")
		if endless_mode:
			# Set dead BEFORE the persist and on either death path — endless._process early-returns on it for the whole banner.
			endless.dead = true
			GameState.record_endless_score(int(endless.score))
	# Never save from smoke/sandbox runs — they don't touch the real save.
	if not sandbox and not Dbg.args.has("smoke-test"):
		GameState.save()
	if won:
		# Banner over the field first; the upgrades menu opens on continue.
		hud.show_wave_over(true, awarded, wave_gold_collected)
	else:
		# Gold rows show for win AND defeat — an endless death shows the harvested tally.
		hud.show_wave_over(false, 0, wave_gold_collected)

func request_next_wave() -> void:
	if wave_over and wave_won:
		start_wave(GameState.current_wave)

func _set_win_animations() -> void:
	## The win-anim lock holds until start_wave frees everyone.
	for u: Unit in _team_objects(Unit.Team.ALLY):
		if u == null or u == ash or u.is_gate or u.is_prop or u.state == Unit.State.DEAD:
			continue
		if not anim_has(u, "win"):
			continue
		var target := u
		get_tree().create_timer(randf()).timeout.connect(func() -> void:
			if is_instance_valid(target) and target.state != Unit.State.DEAD:
				target.anim_lock = "win")

func request_retry() -> void:
	if wave_over and not wave_won:
		start_wave(GameState.current_wave)

# ------------------------------------------------------------------ input

func _screen_to_world(screen: Vector2) -> Vector2:
	## Viewport px -> world coords, zoom-aware.
	var half := get_viewport_rect().size * 0.5
	return camera.position + camera.offset + (screen - half) / camera.zoom.x

func _toggle_mute() -> void:
	## Music/SFX buses muted explicitly alongside Master — muting only Master left menu audio audible in the Web export.
	var muted := not AudioServer.is_bus_mute(0)
	AudioServer.set_bus_mute(0, muted)
	var mus := AudioServer.get_bus_index("Music")
	var sfx := AudioServer.get_bus_index("SFX")
	if mus >= 0:
		AudioServer.set_bus_mute(mus, muted)
	if sfx >= 0:
		AudioServer.set_bus_mute(sfx, muted)
	if pause_menu != null:
		pause_menu.music_on = not muted
		pause_menu.sound_on = not muted
		pause_menu.save_audio_settings()
	_flash_hint("Muted — press M for sound" if muted else "Sound on")

func _unhandled_input(event: InputEvent) -> void:
	# Event-driven, before every other guard, so it works while dead and between waves.
	if event is InputEventKey and event.pressed and not event.echo \
			and (event.keycode == KEY_M or event.physical_keycode == KEY_M):
		_toggle_mute()
		get_viewport().set_input_as_handled()
		return
	if sandbox:
		_sandbox_input(event)
		return
	if wave_over or ash == null or ash.state == Unit.State.DEAD:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			# In-field click-buy is gone: it hijacked "run Ash left" taps into accidental purchases.
			_ash_run_to_screen_x(event.position.x)
			_field_hold = true
		else:
			ash.walk_in_x = ash.position.x
			ash.state = Unit.State.COMBAT
			_field_hold = false
	elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		_ash_run_to_screen_x(event.position.x)

func _input(event: InputEvent) -> void:
	## Runs before the GUI so HUD STOP filters can't eat the motion and strand the hold.
	if not _field_hold:
		return
	if ash == null or wave_over or ash.state == Unit.State.DEAD:
		_field_hold = false
		return
	if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		_ash_run_to_screen_x(event.position.x)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
			and not event.pressed:
		_field_hold = false
		ash.walk_in_x = ash.position.x
		ash.state = Unit.State.COMBAT
		get_viewport().set_input_as_handled()

func _ash_run_to_screen_x(screen_x: float) -> void:
	# Touch half -> the ally path's EXACT end points.
	var world_x := _screen_to_world(Vector2(screen_x, 0.0)).x
	if world_x < ash.position.x:
		ash.walk_in_x = human_path[0].x
	else:
		ash.walk_in_x = human_path[-1].x
	ash.state = Unit.State.WALK_IN

# ----------------------------------------------------------------- sandbox

func _start_sandbox() -> void:
	## No spawner and no win/lose path; units stand with ai_enabled=false.
	hud.visible = false
	menus.visible = false
	_spawn_battlefield_actors()
	ash.ai_enabled = false  # Ash must not gun down the specimens
	gate.ai_enabled = false
	for t: String in DB.table("units").keys():
		if t != "necronomicon":
			sandbox_types.append(t)
	sandbox_types.sort()
	if Dbg.args.has("sandbox-clip"):
		sandbox_clip = str(Dbg.args["sandbox-clip"])
		sandbox_clip_i = SANDBOX_CLIPS.find(sandbox_clip)
	if Dbg.args.has("sandbox-spawn"):
		# --sandbox-spawn=type,x,team(0=ally,1=enemy),level;... (screenshot aid)
		for spec: String in str(Dbg.args["sandbox-spawn"]).split(";", false):
			var p := spec.split(",")
			_sandbox_spawn_unit(p[0], float(p[1]),
				int(p[2]) if p.size() > 2 else 0,
				int(p[3]) if p.size() > 3 else 1)
	_build_sandbox_overlay()
	_sandbox_refresh()
	print("[sandbox] %d unit types; click spawns, shift-click enemy, [ ] cycle, -/= level, F flip, C clip, X clear" % sandbox_types.size())
	if Dbg.args.has("bgeditor"):
		# The editor script is local-only (gitignored) — missing in contributor clones, so the flag no-ops.
		var bge_scr: GDScript = load("res://scripts/bg_editor.gd")
		if bge_scr != null:
			bg_editor = bge_scr.new()
			bg_editor.main = self
			add_child(bg_editor)

func _build_sandbox_overlay() -> void:
	var layer := CanvasLayer.new()
	layer.layer = 30
	add_child(layer)
	_sandbox_label = Label.new()
	_sandbox_label.add_theme_font_size_override("font_size", 13)
	_sandbox_label.add_theme_color_override("font_color", Color(0.95, 0.9, 0.75))
	_sandbox_label.add_theme_color_override("font_outline_color", Color(0, 0, 0))
	_sandbox_label.add_theme_constant_override("outline_size", 6)
	_sandbox_label.position = Vector2(12, 596)
	layer.add_child(_sandbox_label)

func _sandbox_refresh() -> void:
	if _sandbox_label == null or sandbox_types.is_empty():
		return
	var t: String = sandbox_types[sandbox_i]
	var title: String = str(DB.entry("units", t).get("title", t))
	_sandbox_label.text = "SANDBOX  [%d/%d] %s  L%d  clip=%s\n click: spawn ALLY   shift-click: ENEMY   [ ]: unit   -/=: level   F: flip   C: clip   X: clear   A/D: move Ash" % [
		sandbox_i + 1, sandbox_types.size(), title, sandbox_level,
		sandbox_clip if sandbox_clip != "" else "auto"]

func _sandbox_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_sandbox_spawn(_screen_to_world(event.position).x,
			Unit.Team.ENEMY if event.shift_pressed else Unit.Team.ALLY)
	elif event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_BRACKETLEFT:
				sandbox_i = wrapi(sandbox_i - 1, 0, sandbox_types.size())
				sandbox_level = 1
				_sandbox_refresh()
			KEY_BRACKETRIGHT:
				sandbox_i = wrapi(sandbox_i + 1, 0, sandbox_types.size())
				sandbox_level = 1
				_sandbox_refresh()
			KEY_MINUS:
				sandbox_level = maxi(sandbox_level - 1, 1)
				_sandbox_refresh()
			KEY_EQUAL:
				sandbox_level = mini(sandbox_level + 1,
					maxi(DB.get_level_count("units", sandbox_types[sandbox_i]), 1))
				_sandbox_refresh()
			KEY_F:
				sandbox_flip = -sandbox_flip
				for u: Unit in sandbox_units:
					if is_instance_valid(u):
						u.facing = -u.facing
			KEY_C:
				sandbox_clip_i = wrapi(sandbox_clip_i + 1, 0, SANDBOX_CLIPS.size())
				sandbox_clip = SANDBOX_CLIPS[sandbox_clip_i]
				for u: Unit in sandbox_units:
					if is_instance_valid(u):
						u.anim_lock = sandbox_clip
						u._play_clip(StringName(sandbox_clip))
				_sandbox_refresh()
			KEY_X:
				for u: Unit in sandbox_units:
					if is_instance_valid(u):
						u.queue_free()
				sandbox_units.clear()

func _sandbox_spawn(x: float, team: int) -> void:
	_sandbox_spawn_unit(sandbox_types[sandbox_i], x, team, sandbox_level)

func _sandbox_spawn_unit(type_name: String, x: float, team: int, lvl: int) -> void:
	if DB.entry("units", type_name).is_empty():
		print("[sandbox] unknown unit type: ", type_name)
		return
	var u := _make_unit(type_name, lvl, team)
	u.position = _g(x, ground_y(x))
	u.lane_offset = _next_slot()
	u.position.y += u.lane_offset
	u.ai_enabled = false
	u.anim_lock = sandbox_clip
	u.state = Unit.State.COMBAT
	units_layer.add_child(u)
	if sandbox_flip < 0.0:
		u.facing = -u.facing
	sandbox_units.append(u)
	print("[sandbox] spawned %s L%d team=%d at x=%.0f" % [type_name, lvl, team, x])
