extends CanvasLayer
class_name Menus
## Between-wave menu flow reskinned to the original's screens, plus the boot screens (main menu, You Unlocked, select troops/skills, upgrade shop)

var main: Node2D
var state := ""  # "", "main_menu", "options", "upgrades", "unlocked", "troops", "spells", "credits"

const MENU_ART := "res://assets/ui/menu/"
const HUD_ART := "res://assets/ui/hud/"
# assets.lua ratio x2: native texture px -> our 960x640 screen px (the 480x320 world drawn 2x)
const ART_PX := 480.0 / 1024.0 * 2.0

var _root: Control
var _detail: Control = null  # T21 upgrade detail popup
var _detail_id := ""
var _detail_tab := ""

# set by main on a wave win: open_upgrades() chains You Unlocked before the shop
var _from_win := false
var _pending_unlocks: Array = []
var _unlock_idx := 0

var _horse: AnimatedSprite2D = null
var _horse_state := ""
var _horse_t := 0.0
var _horse_x := Vector2.ZERO  # x [start, mid] patrol endpoints
var _menu_t := 0.0

# the original's globals.ally_units troop pool, sorted by unlock_wave
const TROOP_POOL := ["peasant", "swordsman", "spearman", "archer", "swordboy",
	"armored_guard", "wiseman", "arthur", "horseman", "henry", "torchboy"]

func _ready() -> void:
	layer = 20
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)

func is_open() -> bool:
	return state != ""

func open_main_menu_on_boot() -> bool:
	## normal boot shows the title screen; harness/screenshot flags skip it and boot straight into the wave
	for flag in ["smoke-test", "wave", "sandbox", "menupreview", "banner", "menu"]:
		if Dbg.args.has(flag):
			return false
	open_main_menu()
	return true

func open_main_menu() -> void:
	state = "main_menu"
	_root.visible = true
	_build_main_menu()
	if main.music_player == null or not main.music_player.playing:
		main.play_menu_music()

func on_wave_won() -> void:
	_from_win = true

func open_upgrades() -> void:
	state = "upgrades"
	_root.visible = true
	if _from_win:
		_from_win = false
		_pending_unlocks = _get_unlocked_set()
		_unlock_idx = 0
		if not _pending_unlocks.is_empty():
			state = "unlocked"
			_rebuild()
			return
	_pending_unlocks = []
	_rebuild()

func _get_unlocked_set() -> Array:
	var out: Array = []
	for cat: String in ["units", "weapons", "spells"]:
		for id: String in DB.table(cat).keys():
			var uw: Variant = DB.entry(cat, id).get("unlock_wave", null)
			if uw != null and int(uw) == GameState.current_wave:
				out.append({"name": id, "cat": cat, "is_spell": cat == "spells"})
	return out

func open_troops() -> void:
	state = "troops"
	_root.visible = true
	GameState.try_auto_select_objects()
	_rebuild()

func open_spells() -> void:
	state = "spells"
	_root.visible = true
	_rebuild()
	_slide_in()

func open_credits(from := "") -> void:
	## `from` remembers the spawning screen -- credits quit lands back there (the engine pops its spawn stack)
	state = "credits"
	_credits_from = from
	_from_win = false
	_root.visible = true
	_rebuild()
	main.play_menu_music()

# where open_credits() was called from ("" = not from a menu screen)
var _credits_from := ""

func open_options() -> void:
	state = "options"
	_root.visible = true
	_rebuild()

func _slide_in() -> void:
	_root.position = Vector2(960, 0)
	var tw := create_tween()
	tw.tween_property(_root, "position:x", 0.0, 0.5) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

func close() -> void:
	state = ""
	_root.visible = false
	_root.position = Vector2.ZERO  # cancel any pending slide-in offset
	_kill_credits_roll()
	_close_detail()

func _launch_wave() -> void:
	close()
	main.start_wave(GameState.current_wave)

func _on_continue() -> void:
	match state:
		"upgrades":
			if GameState.hasAnyUnitsUnlocked():
				open_troops()
			else:
				_launch_wave()
		"troops":
			if GameState.selected_units.is_empty():
				main.play_sfx("ui_disabled_click_02")
				return
			# CONTINUE always slides into the spell window -- no wave gate: every troops screen is wave 2+, so a spell is always selectable
			if not GameState.get_valid_spells().is_empty():
				open_spells()
			else:
				_launch_wave()
		"spells":
			if GameState.selected_spells.is_empty():
				main.play_sfx("ui_disabled_click_02")
				return
			_launch_wave()

func _clear_root() -> void:
	for c in _root.get_children():
		c.queue_free()
	_detail = null
	_card = null
	_horse = null
	_horse_unit = null
	_reset_popup = null
	_shop_scroll = null
	_shop_thumb = null
	_shop_press_active = false
	_shop_press_scrolled = false
	_thumb_dragging = false

func _tex(path: String) -> Texture2D:
	return load(path) if ResourceLoader.exists(path) else null

func _menu_bg(title2: String) -> void:
	## the shop art has "UPGRADES" baked into its header band -- no title strip for the shop; other callers get a strip
	var bg := TextureRect.new()
	bg.texture = _tex(MENU_ART + "upgrade_background.webp")
	bg.size = Vector2(960, 640)
	_root.add_child(bg)
	if state != "upgrades":
		var strip := ColorRect.new()
		strip.color = Color(0.02, 0.02, 0.04, 0.92)
		strip.size = Vector2(960, 54)
		_root.add_child(strip)

	var wl := Label.new()
	wl.text = GameState.wave_label()
	wl.add_theme_font_size_override("font_size", 30)
	wl.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	wl.position = Vector2(310, 6)
	wl.size = Vector2(180, 42)
	_root.add_child(wl)
	if title2 != "":
		var tl := Label.new()
		tl.text = title2
		tl.add_theme_font_size_override("font_size", 30)
		tl.add_theme_color_override("font_color", Color.WHITE)
		tl.position = Vector2(520, 6)
		tl.size = Vector2(330, 42)
		_root.add_child(tl)

	var gb := TextureRect.new()
	gb.texture = _tex(MENU_ART + "gold_box.webp")
	gb.position = Vector2(12, 574)
	gb.size = Vector2(200, 60)
	gb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	gb.stretch_mode = TextureRect.STRETCH_SCALE
	_root.add_child(gb)
	var coin := TextureRect.new()
	coin.texture = _tex(MENU_ART + "coin.webp")
	coin.position = Vector2(24, 586)
	coin.size = Vector2(36, 36)
	coin.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_root.add_child(coin)
	var gold_l := Label.new()
	gold_l.name = "Gold"
	gold_l.text = "%d" % GameState.gold
	gold_l.add_theme_font_size_override("font_size", 28)
	gold_l.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
	gold_l.position = Vector2(68, 584)
	gold_l.size = Vector2(130, 40)
	_root.add_child(gold_l)

	var cont := _plate_btn("continue_button", HUD_ART, Vector2(150, 55))
	cont.position = Vector2(960 - 162, 640 - 66)
	cont.pressed.connect(_on_continue)
	_root.add_child(cont)

func _plate_btn(art: String, base: String, sz: Vector2) -> TextureButton:
	var b := TextureButton.new()
	b.texture_normal = _tex(base + art + ".webp")
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	b.custom_minimum_size = sz
	b.size = sz
	return b

func _mk_label(text: String, sz: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", sz)
	l.add_theme_color_override("font_color", col)
	return l

# DroidSans-Bold stands in for the engine's font://Helvetica-Bold numerals
const BOLD_FONT_PATH := "res://assets/fonts/DroidSans-Bold.ttf"
var _bold_font: FontFile

func _bold_label(text: String, sz: int, col: Color) -> Label:
	var l := _mk_label(text, sz, col)
	if _bold_font == null and ResourceLoader.exists(BOLD_FONT_PATH):
		_bold_font = load(BOLD_FONT_PATH)
	if _bold_font != null:
		l.add_theme_font_override("font", _bold_font)
	return l

func _entry_icon(uri: String, sz: Vector2) -> TextureRect:
	var tr := TextureRect.new()
	tr.custom_minimum_size = sz
	tr.size = sz
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var leaf := uri.rsplit("/", 1)[-1]
	for base in [MENU_ART, HUD_ART, "res://assets/ui/"]:
		var t := _tex(base + leaf + ".webp")
		if t != null:
			tr.texture = t
			break
	return tr

var _tab := ""  # active upgrades tab
var _shop_scroll: ScrollContainer = null
var _shop_thumb: TextureRect = null
# drag-scroll state: a press + >40 px drag pages the list (past buttons too) and the release is consumed so the dragged-over plate never clicks; sub-40 px presses stay vanilla
var _shop_press_active := false
var _shop_press_last := Vector2.ZERO
var _shop_press_scrolled := false
var _thumb_dragging := false
var _thumb_grab_dy := 0.0
# scroll offset carried across a purchase rebuild (the original refreshes cells in place; only a tab switch resets it)
var _shop_scroll_offset := 0

func _rebuild() -> void:
	_clear_root()
	match state:
		"main_menu":
			_build_main_menu()
		"unlocked":
			_build_unlocked()
		"troops":
			_build_troops()
		"spells":
			_build_spells()
		"credits":
			_build_credits()
		"options":
			_build_options()
		_:
			if _tab == "":
				_tab = "ash"
			_build_upgrades()

func _build_upgrades() -> void:
	_menu_bg("")  # the shop art has "UPGRADES" baked into its header
	var menu_btn := _plate_btn("menu_button", MENU_ART, Vector2(90, 48))
	menu_btn.position = Vector2(960 - 100, 8)
	menu_btn.pressed.connect(open_main_menu)
	_root.add_child(menu_btn)

	var tabs := [["ash", "Ash"], ["troops", "Troops"], ["castle", "Castle"]]
	for i in tabs.size():
		var active: bool = _tab == tabs[i][0]
		var b := TextureButton.new()
		b.texture_normal = _tex(MENU_ART + ("tab_active.webp" if active else "tab_inactive.webp"))
		b.ignore_texture_size = true
		b.stretch_mode = TextureButton.STRETCH_SCALE
		b.position = Vector2(8, 80 + i * 160)
		b.size = Vector2(210, 148)
		b.pressed.connect(_set_tab.bind(tabs[i][0]))
		_root.add_child(b)
		var lb := _mk_label(tabs[i][1], 26,
			Color(1.0, 0.85, 0.2) if active else Color(0.75, 0.75, 0.75))
		lb.add_theme_constant_override("outline_size", 4)
		lb.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.05))
		lb.set_anchors_preset(Control.PRESET_FULL_RECT)
		lb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lb.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		lb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		b.add_child(lb)

	var region := TextureRect.new()
	region.texture = _tex(MENU_ART + "scroll_region.webp")
	region.position = Vector2(228, 70)
	region.size = Vector2(712, 498)
	region.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	region.stretch_mode = TextureRect.STRETCH_SCALE
	region.modulate = Color(1, 1, 1, 0.55)
	region.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(region)
	var sbar := TextureRect.new()
	sbar.texture = _tex(MENU_ART + "scroll_bar.webp")
	sbar.position = Vector2(923, 72)
	sbar.size = Vector2(32, 494)
	sbar.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	sbar.stretch_mode = TextureRect.STRETCH_SCALE
	sbar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(sbar)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(232, 76)
	scroll.size = Vector2(690, 486)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# hide Godot's default grabber -- the original's scrollbar is a pure indicator; the bar stays functional for wheel + the thumb wiring
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	_root.add_child(scroll)
	var rows := Control.new()
	rows.custom_minimum_size = Vector2(666, _tab_entries().size() * 118.0)
	scroll.add_child(rows)
	var entries := _tab_entries()
	for i in entries.size():
		var row := _make_row(entries[i], _tab)
		row.position = Vector2(0, i * 118)
		rows.add_child(row)
	# added after the ScrollContainer so the thumb never draws under the rows
	var thumb := TextureRect.new()
	thumb.texture = _tex(MENU_ART + "scroll_controll.webp")
	thumb.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	thumb.stretch_mode = TextureRect.STRETCH_SCALE
	thumb.size = Vector2(22, 75)
	thumb.mouse_filter = Control.MOUSE_FILTER_STOP
	thumb.gui_input.connect(_on_shop_thumb_input)
	_root.add_child(thumb)
	_shop_scroll = scroll
	_shop_thumb = thumb
	scroll.get_v_scroll_bar().value_changed.connect(_update_shop_thumb)
	# deferred: the bar's limits exist only after the container's deferred sort -- an immediate call reads span 0
	call_deferred("_update_shop_thumb")

func _update_shop_thumb(_value: float = 0.0) -> void:
	## thumb y = 80 + frac * 403; hidden when the tab's content fits
	if _shop_thumb == null or _shop_scroll == null:
		return
	var vbar := _shop_scroll.get_v_scroll_bar()
	var span := vbar.max_value - vbar.page
	var frac := 0.0 if span <= 0.0 else clampf(vbar.value / span, 0.0, 1.0)
	_shop_thumb.position = Vector2(929, 80.0 + frac * 403.0)  # R13-02: 914 + 15 (track x 908->923), +6 off the track kept
	_shop_thumb.visible = span > 0.0

func _on_shop_thumb_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		_thumb_dragging = event.pressed
		if event.pressed:
			_thumb_grab_dy = event.position.y  # thumb-local grab point

func _input(event: InputEvent) -> void:
	## global jobs while the shop is open: steer the thumb drag past its own edge, and press-drag page the list (a scrolled release is consumed so plates never mis-fire)
	if _thumb_dragging:
		if event is InputEventMouseMotion:
			var le: InputEventMouseMotion = _shop_thumb.make_input_local(event)
			var root_y: float = _shop_thumb.position.y + le.position.y - _thumb_grab_dy
			var vbar := _shop_scroll.get_v_scroll_bar()
			var span := vbar.max_value - vbar.page
			if span > 0.0:
				vbar.value = clampf((root_y - 80.0) / 403.0, 0.0, 1.0) * span
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT \
				and not event.pressed:
			_thumb_dragging = false
		return
	if _shop_scroll == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var le: InputEventMouseButton = _shop_scroll.make_input_local(event)
		if event.pressed:
			_shop_press_active = le.position.x >= 0.0 and le.position.y >= 0.0 \
				and le.position.x <= _shop_scroll.size.x and le.position.y <= _shop_scroll.size.y
			_shop_press_last = le.position
			_shop_press_scrolled = false
		elif _shop_press_active:
			_shop_press_active = false
			if _shop_press_scrolled:
				# the drag scrolled: swallow the release so the plate under the finger doesn't also fire
				get_viewport().set_input_as_handled()
	elif _shop_press_active and event is InputEventMouseMotion \
			and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
		var lm: InputEventMouseMotion = _shop_scroll.make_input_local(event)
		if not _shop_press_scrolled and _shop_press_last.distance_to(lm.position) > 40.0:
			_shop_press_scrolled = true
		if _shop_press_scrolled:
			var vbar := _shop_scroll.get_v_scroll_bar()
			vbar.value -= (lm.position.y - _shop_press_last.y)
			_shop_press_last = lm.position
			get_viewport().set_input_as_handled()

func _set_tab(t: String) -> void:
	_tab = t
	_rebuild()

func _tab_entries() -> Array:
	match _tab:
		"ash":
			var entries: Array = ["ash"]
			if GameState.weapon_locked("iron_fist"):
				entries.append("iron_fist")
			elif GameState.weapon_locked("chainsaw"):
				entries.append("chainsaw")
			for s: Dictionary in GameState.get_valid_spells():
				entries.append(str(s["name"]))
			return entries
		"castle":
			var castle: Array = ["necronomicon", "smithy", "inner_wall_archer",
				"catapults", "the_pit"]
			castle.sort_custom(func(a, b): return _unlock_wave(a) < _unlock_wave(b))
			return castle
		_:
			var out: Array = []
			for u: Dictionary in GameState.get_valid_units():
				out.append(str(u["name"]))
			return out

func _row_stat(entry: Dictionary, lvl: int) -> Array:
	## info_text checks FIRST (magic_words carries "50%".."95%" and no damage/health of its own)
	var levels: Array = entry.get("level_stat", [])
	if levels.is_empty() or lvl < 1 or lvl > levels.size():
		return ["", 0]
	var st: Dictionary = levels[lvl - 1]
	if st.has("info_text"):
		return ["info", st["info_text"]]
	if st.has("health"):
		return ["heart", int(st["health"])]
	if st.has("damage"):
		return ["sword", int(st["damage"])]
	var ammo: String = str(st.get("ammo", ""))
	if ammo != "":
		var d: Variant = DB.get_stat("ammo", ammo, "damage", lvl)
		if d != null:
			return ["sword", int(d)]
	return ["", 0]

func _info_icon_tex(entry: Dictionary) -> String:
	var uri: String = str(entry.get("info_icon", ""))
	return (uri.rsplit("/", 1)[-1] + ".webp") if uri != "" else "attack_icon.webp"

func _unit_damage(id: String, lvl: int) -> int:
	## weapon dps, else ammo damage, else weapon damage -- negative-damage healers get the heal icon
	var wn: Variant = DB.get_stat("units", id, "weapon", lvl)
	var weapon := str(wn) if wn != null else ""
	if weapon == "" or weapon == "<null>":
		return 0
	var dps: Variant = DB.get_stat("weapons", weapon, "dps", lvl)
	if dps != null:
		return int(dps)
	var ammo: Variant = DB.get_stat("weapons", weapon, "ammo", lvl)
	if ammo != null and str(ammo) != "":
		var ad: Variant = DB.get_stat("ammo", str(ammo), "damage", lvl)
		if ad != null:
			return int(ad)
	var wd: Variant = DB.get_stat("weapons", weapon, "damage", lvl)
	return int(wd) if wd != null else 0

func _price_row(cost: int) -> HBoxContainer:
	## the HBox keeps coin and price centred TOGETHER so they never drift apart
	var box := HBoxContainer.new()
	box.position = Vector2(6, 40)
	box.size = Vector2(104, 32)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 5)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# SIZE_FILL stretched the square coin into an oval -- SHRINK_CENTER keeps the drawn rect 22x22
	var ci := TextureRect.new()
	ci.texture = _tex(MENU_ART + "coin.webp")
	ci.custom_minimum_size = Vector2(22, 22)
	ci.size = Vector2(22, 22)
	ci.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ci.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	ci.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	ci.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(ci)
	var cl := _mk_label(str(cost), 20, Color.WHITE)
	cl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(cl)
	return box

func _unlock_wave(id: String) -> int:
	var v: Variant = DB.entry("units", id).get("unlock_wave", 1)
	return int(v) if v != null else 1

func _category_for(id: String) -> String:
	if id == "boomstick" or id == "iron_fist" or id == "chainsaw":
		return "weapons"
	if DB.table("spells").has(id):
		return "spells"
	return "units"

func _cell_icon_uri(entry: Dictionary, id: String) -> String:
	var uri: String = str(entry.get("upgrade_icon_texture", ""))
	if uri == "":
		uri = str(entry.get("icon_texture", id))
	return uri

func _ash_boom_damage(lvl: int) -> int:
	var weapon: String = str(DB.entry("units", "ash").get("secondary_weapon", "boomstick"))
	var ammo: Variant = DB.get_stat("weapons", weapon, "ammo", lvl)
	if ammo != null and str(ammo) != "":
		var d: Variant = DB.get_stat("ammo", str(ammo), "damage", lvl)
		if d != null:
			return int(d)
	var wd: Variant = DB.get_stat("weapons", weapon, "damage", lvl)
	return int(wd) if wd != null else 0

func _make_row(id: String, tab: String) -> Control:
	var row := Control.new()
	row.custom_minimum_size = Vector2(690, 110)
	row.size = Vector2(690, 110)
	var box := TextureRect.new()
	box.texture = _tex(MENU_ART + "upgrade_box.webp")
	box.size = Vector2(690, 110)
	box.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	box.stretch_mode = TextureRect.STRETCH_SCALE
	row.add_child(box)

	var cat := _category_for(id)
	var is_spell := cat == "spells"
	var is_melee_weapon := cat == "weapons" and id != "boomstick"
	var is_ash := tab == "ash" and id == "ash"
	var is_castle := tab == "castle"
	var entry: Dictionary = DB.entry(cat, id)
	if entry.is_empty():
		return row

	var title: String = str(entry.get("title", id))
	var lvl := GameState.get_type_level(id)
	if is_castle:
		# unbought castle upgrades sit at level 0 (leveled separately from the lock)
		lvl = GameState.get_castle_level(id)
	var locked := false
	var unlock := 0
	if tab == "troops" or is_castle or is_spell:
		unlock = int(entry.get("unlock_wave", 1))
		locked = GameState.current_wave < unlock

	var icon := _entry_icon(_cell_icon_uri(entry, id), Vector2(84, 84))
	icon.position = Vector2(12, 13)
	row.add_child(icon)

	if locked:
		icon.texture = _tex(MENU_ART + "locked_icon.webp")
		var tl := _mk_label(title, 26, Color.WHITE)
		tl.position = Vector2(215, 14)
		row.add_child(tl)
		var ul := _mk_label("Unlocked At Wave %d" % unlock, 20, Color(0.9, 0.9, 0.9))
		ul.position = Vector2(215, 56)
		row.add_child(ul)
		return row

	var iron_cost: Variant = entry.get("iron_cost", null)
	if iron_cost != null:
		var badge := ColorRect.new()
		badge.color = Color(0.05, 0.05, 0.05, 0.92)
		badge.size = Vector2(34, 22)
		badge.position = Vector2(46, 58)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.add_child(badge)
		var bl2 := _mk_label(str(int(iron_cost)), 14, Color.WHITE)
		bl2.set_anchors_preset(Control.PRESET_FULL_RECT)
		bl2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		bl2.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		bl2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		badge.add_child(bl2)

	var levels: Array = entry.get("level_stat", [])
	var next := lvl + 1
	if is_ash:
		# boomstick upgrades level ASH — costs and the cap live in ash's table
		levels = DB.entry("units", "ash").get("level_stat", [])
		next = int(GameState.get_type_level("ash")) + 1

	# heart / sword stat next to the icon
	if is_ash:
		# Ash cell: one stat per line at Ash's level; value labels x=134 = deliberate +4 px off the original's 130 (R10-06)
		var ash_lvl := int(GameState.get_type_level("ash"))
		var ash_stats: Array = [["boomstick_icon.webp", str(_ash_boom_damage(ash_lvl))]]
		for wn in ["chainsaw", "iron_fist"]:
			if not GameState.weapon_locked(wn):
				var md: Variant = DB.get_stat("weapons", wn, "damage", ash_lvl)
				ash_stats.append([wn + "_icon.webp", str(int(md) if md != null else 0)])
			break
		var hp: Variant = DB.get_stat("units", "ash", "health", ash_lvl)
		ash_stats.append(["health_icon.webp", str(int(hp) if hp != null else 0)])
		for li in ash_stats.size():
			var si := TextureRect.new()
			si.texture = _tex(MENU_ART + str(ash_stats[li][0]))
			si.position = Vector2(104, 12 + li * 30)
			si.size = Vector2(18, 26)
			si.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			si.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			row.add_child(si)
			var sv := _mk_label(str(ash_stats[li][1]), 19, Color.WHITE)
			sv.position = Vector2(134, 12 + li * 30)  # R10-06 nudge (see above)
			sv.size = Vector2(56, 26)
			sv.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			row.add_child(sv)
	elif tab == "troops":
		# attack (heal icon for healers) over health beside the icon; labels x=134 = R10-06 nudge (see Ash note)
		var dmg := _unit_damage(id, maxi(lvl, 1))
		var has_weapon: bool = str(DB.entry("units", id).get("weapon", "")) != ""
		if has_weapon:
			var ai2 := TextureRect.new()
			ai2.texture = _tex(MENU_ART + ("heal_icon.webp" if dmg < 0 else "attack_icon.webp"))
			ai2.position = Vector2(104, 20)
			ai2.size = Vector2(22, 26)
			ai2.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			ai2.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			row.add_child(ai2)
			var av2 := _mk_label(str(absi(dmg)), 19, Color.WHITE)
			av2.position = Vector2(134, 20)  # R10-06 nudge (see Ash note)
			av2.size = Vector2(56, 26)
			av2.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			row.add_child(av2)
		var hp2: Variant = DB.get_stat("units", id, "health", maxi(lvl, 1))
		if hp2 != null:
			var hi2 := TextureRect.new()
			hi2.texture = _tex(MENU_ART + "health_icon.webp")
			hi2.position = Vector2(104, 58 if has_weapon else 38)
			hi2.size = Vector2(22, 26)
			hi2.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			hi2.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			row.add_child(hi2)
			var hv2 := _mk_label(str(int(hp2)), 19, Color.WHITE)
			hv2.position = Vector2(134, 58 if has_weapon else 38)  # R10-06 nudge
			hv2.size = Vector2(56, 26)
			hv2.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			row.add_child(hv2)
	else:
		# single-stat rows: info_text as info art; castle `weapon` rows show damage at max(level, 1); the_pit has no weapon -> no attack row
		var stat := _row_stat(entry, lvl)
		if is_castle and str(entry.get("weapon", "")) != "":
			stat = ["sword", _unit_damage(id, maxi(lvl, 1))]
		if stat[0] != "":
			var tex2 := "attack_icon.webp"
			if stat[0] == "heart":
				tex2 = "health_icon.webp"
			elif stat[0] == "info":
				tex2 = _info_icon_tex(entry)
			var si2 := TextureRect.new()
			si2.texture = _tex(MENU_ART + tex2)
			si2.position = Vector2(104, 38)
			si2.size = Vector2(22, 26)
			si2.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			si2.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			row.add_child(si2)
			var txt2: String = str(stat[1])
			if stat[0] == "sword":
				txt2 = str(absi(int(stat[1])))  # healers show |damage|
			var sv2 := _mk_label(txt2, 19, Color.WHITE)
			sv2.position = Vector2(134, 38)  # R10-06 nudge (see Ash note)
			sv2.size = Vector2(56, 26)
			sv2.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			row.add_child(sv2)

	var nl := _mk_label(title, 26, Color.WHITE)
	nl.position = Vector2(215, 14)
	row.add_child(nl)
	# an unbought castle upgrade (level 0) shows NO level label
	if not (is_castle and lvl < 1):
		var lv := _mk_label(("MELEE" if is_melee_weapon
			else ("MAX" if next > levels.size() else "LEVEL %d" % lvl)), 22,
			Color(0.9, 0.9, 0.9))
		lv.position = Vector2(215, 56)
		row.add_child(lv)

	# melee weapons buy with the weapon table's top-level `cost` (not a level) -- buying unlocks it for Ash's next wave
	if is_melee_weapon:
		var wcost := int(entry.get("cost", 0))
		var wb := _plate_btn("upgrade_button_blank", MENU_ART, Vector2(116, 84))
		wb.position = Vector2(556, 13)
		var wl := _mk_label("BUY", 15, Color.WHITE)
		wl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wl.position = Vector2(0, 12)
		wl.size = Vector2(116, 22)
		wl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wb.add_child(wl)
		wb.add_child(_price_row(wcost))
		wb.disabled = GameState.gold < wcost
		wb.pressed.connect(_buy_weapon.bind(id))
		row.add_child(wb)
		var info2 := Button.new()
		info2.flat = true
		info2.modulate = Color(1, 1, 1, 0.0)
		info2.position = Vector2(96, 0)
		info2.size = Vector2(450, 110)
		info2.pressed.connect(_open_detail.bind(id, tab))
		row.add_child(info2)
		return row

	# BUY while castle level 0, UPGRADE after, none at the cap; the row's invisible strip opens the detail popup
	if next <= levels.size():
		var cost := int(levels[next - 1].get("cost", 0))
		var buy := _plate_btn("upgrade_button_blank", MENU_ART, Vector2(116, 84))
		buy.position = Vector2(556, 13)
		var bl := _mk_label("BUY" if lvl < 1 else "UPGRADE", 15, Color.WHITE)
		bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		bl.position = Vector2(0, 12)
		bl.size = Vector2(116, 22)
		bl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		buy.add_child(bl)
		buy.add_child(_price_row(cost))
		buy.disabled = GameState.gold < cost
		buy.pressed.connect(_buy.bind(id, tab))
		row.add_child(buy)

	var info := Button.new()
	info.flat = true
	info.modulate = Color(1, 1, 1, 0.0)
	info.position = Vector2(96, 0)
	info.size = Vector2(450, 110)
	info.pressed.connect(_open_detail.bind(id, tab))
	row.add_child(info)
	return row

func _detail_subtitle(entry: Dictionary, id: String, tab: String, cat: String) -> String:
	## the locale renders the subtitle dash-wrapped ("- Skill -"); the original never says "Unit"
	if cat == "spells":
		return "- Skill -"
	if cat == "weapons":
		return "- Weapon -"
	var fallback := "Castle Upgrade" if tab == "castle" else "Troop"
	return "- %s -" % str(entry.get("unit_type", fallback))

func _detail_rows(entry: Dictionary, id: String, lvl: int) -> Array:
	## stat rows top->bottom: info_text alone, else damage (heal icon + |value| for healers) -> ash-only melee weapon -> health
	var rows: Array = []
	var cat := _category_for(id)
	var levels: Array = entry.get("level_stat", [])
	var st: Dictionary = {}
	if lvl >= 1 and lvl <= levels.size():
		st = levels[lvl - 1]
	if st.has("info_text"):
		rows.append([_info_icon_tex(entry), str(st["info_text"])])
		return rows
	var is_ash := id == "ash"
	var dmg: Variant = null
	if is_ash:
		dmg = _ash_boom_damage(lvl)
		rows.append(["boomstick_icon.webp", absi(int(dmg))])
	else:
		var wv: Variant = DB.get_stat(cat, id, "weapon", lvl)
		var weapon := str(wv) if wv != null else ""
		dmg = st.get("damage", null)
		if dmg == null and weapon != "" and weapon != "<null>":
			dmg = DB.get_stat("weapons", weapon, "dps", lvl)
			if dmg == null:
				var am: Variant = DB.get_stat("weapons", weapon, "ammo", lvl)
				if am != null and str(am) != "":
					dmg = DB.get_stat("ammo", str(am), "damage", lvl)
			if dmg == null:
				dmg = DB.get_stat("weapons", weapon, "damage", lvl)
		if dmg == null:
			var am2: Variant = DB.get_stat(cat, id, "ammo", lvl)
			if am2 != null and str(am2) != "":
				dmg = DB.get_stat("ammo", str(am2), "damage", lvl)
		if dmg != null:
			rows.append(["heal_icon.webp" if int(dmg) < 0 else "attack_icon.webp",
				absi(int(dmg))])
	# the OWNED melee weapon -- chainsaw only once BOTH are owned, else iron_fist; damage stat, not dps
	if is_ash and not GameState.weapon_locked("iron_fist"):
		var mw := "chainsaw" if not GameState.weapon_locked("chainsaw") else "iron_fist"
		var md: Variant = DB.get_stat("weapons", mw, "damage", lvl)
		if md != null:
			rows.append([mw + "_icon.webp", int(md)])
	var hp: Variant = DB.get_stat(cat, id, "health", lvl)
	if hp != null:
		rows.append(["health_icon.webp", int(hp)])
	return rows

func _open_detail(id: String, tab: String) -> void:
	_detail_id = id
	_detail_tab = tab
	_close_detail()
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	_detail = dim

	var card := TextureRect.new()
	card.texture = _tex("res://assets/ui/menu/selection_box.webp")
	if _tex("res://assets/ui/hud/selection_box.webp") != null:
		card.texture = _tex("res://assets/ui/hud/selection_box.webp")
	# expand/stretch BEFORE size or the 648x569 texture minimum clamps the assignment
	card.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	card.stretch_mode = TextureRect.STRETCH_SCALE
	card.position = Vector2(200, 74)
	card.size = Vector2(560, 492)
	dim.add_child(card)

	var cat := _category_for(id)
	var entry: Dictionary = DB.entry(cat, id)
	if entry.is_empty():
		return
	var title: String = str(entry.get("title", id))

	var icon := _entry_icon(_cell_icon_uri(entry, id), Vector2(88, 88))
	icon.position = Vector2(38, 42)
	card.add_child(icon)

	var iron_cost: Variant = entry.get("iron_cost", null)
	if iron_cost != null:
		var badge := ColorRect.new()
		badge.color = Color(0.05, 0.05, 0.05, 0.92)
		badge.size = Vector2(36, 24)
		badge.position = Vector2(50, 62)
		badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
		icon.add_child(badge)
		var bl2 := _mk_label(str(int(iron_cost)), 15, Color.WHITE)
		bl2.set_anchors_preset(Control.PRESET_FULL_RECT)
		bl2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		bl2.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		bl2.mouse_filter = Control.MOUSE_FILTER_IGNORE
		badge.add_child(bl2)

	var nl := _mk_label(title, 30, Color.WHITE)
	nl.position = Vector2(30, 26)
	nl.size = Vector2(500, 40)
	nl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(nl)
	var sl := _mk_label(_detail_subtitle(entry, id, tab, cat), 20, Color(0.75, 0.75, 0.75))
	sl.position = Vector2(30, 66)
	sl.size = Vector2(500, 26)
	sl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	card.add_child(sl)

	var lvl := GameState.get_type_level(id) if id != "boomstick" else 1
	if tab == "castle":
		lvl = GameState.get_castle_level(id)  # unbought upgrades sit at 0
	var levels: Array = entry.get("level_stat", [])
	var has_stats := false
	if cat != "weapons" and id != "smithy" and lvl >= 1 \
			and lvl + 1 <= levels.size():
		has_stats = true
		var cur_rows := _detail_rows(entry, id, lvl)
		var nxt_rows := _detail_rows(entry, id, lvl + 1)
		var col_colors := [Color.WHITE, Color(0, 1, 0)]  # next level pure green (:279)
		var col_rows := [cur_rows, nxt_rows]
		for ci in 2:
			var lv2 := _mk_label("Lvl %d" % (lvl + ci), 28, col_colors[ci])
			lv2.position = Vector2(170 + ci * 100, 130)
			lv2.size = Vector2(120, 40)
			lv2.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			card.add_child(lv2)
			for ri in col_rows[ci].size():
				var row: Array = col_rows[ci][ri]
				var vv := _mk_label(str(row[1]), 24, col_colors[ci])
				vv.position = Vector2(230 + ci * 100, 164 + 34 * ri)
				vv.size = Vector2(110, 34)
				vv.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
				card.add_child(vv)
		# stat icons on the CURRENT column only (the Lua parents every icon to the current lvl label), right edge pinned to the header's left edge, centred on the value row
		# expand/stretch BEFORE size: size-then-expand clamps the box and skews the row centring
		for ri in cur_rows.size():
			var ii := TextureRect.new()
			ii.texture = _tex(MENU_ART + str(cur_rows[ri][0]))
			ii.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			ii.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			ii.position = Vector2(168, 165 + 34 * ri)
			ii.size = Vector2(32, 32)
			card.add_child(ii)

	var desc: String = str(entry.get("description", ""))
	if desc != "":
		var dl := _mk_label(desc, 22, Color(1.0, 0.85, 0.3))
		dl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		# on no-stat cards the description moves UP under the icon block
		if has_stats:
			dl.position = Vector2(40, 300)
			dl.size = Vector2(480, 110)
		else:
			dl.position = Vector2(40, 140)
			dl.size = Vector2(480, 130)
		dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		card.add_child(dl)
	var flavor: String = str(entry.get("flavor_text", ""))
	if flavor != "" and not has_stats:
		var fl := _mk_label('"%s"' % flavor, 17, Color.WHITE)
		fl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		fl.position = Vector2(48, 290)
		fl.size = Vector2(464, 120)
		fl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(fl)

	# weapons get their own BUY plate (the weapon table's top-level `cost`); other tabs upgrade with level_stat[next].cost
	var next := lvl + 1
	if cat == "weapons":
		var wcost := int(entry.get("cost", 0))
		var wbuy := _plate_btn("upgrade_button_blank", MENU_ART, Vector2(140, 90))
		wbuy.position = Vector2(210, 435)
		var wul := _mk_label("BUY", 17, Color.WHITE)
		wul.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		wul.position = Vector2(0, 8)
		wul.size = Vector2(140, 22)
		wul.mouse_filter = Control.MOUSE_FILTER_IGNORE
		wbuy.add_child(wul)
		var wprow := _price_row(wcost)
		wprow.position = Vector2(6, 40)
		wprow.size = Vector2(128, 32)
		wbuy.add_child(wprow)
		wbuy.disabled = GameState.gold < wcost
		wbuy.pressed.connect(_buy_weapon.bind(id))
		card.add_child(wbuy)
	elif tab != "spells" and next <= levels.size():
		var cost := int(levels[next - 1].get("cost", 0))
		var up := _plate_btn("upgrade_button_blank", MENU_ART, Vector2(140, 90))
		up.position = Vector2(210, 435)
		var ul := _mk_label("BUY" if lvl < 1 else "UPGRADE", 17, Color.WHITE)
		ul.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		ul.position = Vector2(0, 8)
		ul.size = Vector2(140, 22)
		ul.mouse_filter = Control.MOUSE_FILTER_IGNORE
		up.add_child(ul)
		var prow := _price_row(cost)
		prow.position = Vector2(6, 40)
		prow.size = Vector2(128, 32)
		up.add_child(prow)
		up.disabled = GameState.gold < cost
		up.pressed.connect(_buy.bind(id, tab))
		card.add_child(up)

	var back := _plate_btn("back_button", MENU_ART, Vector2(110, 59))
	back.position = Vector2(450, -10)
	back.pressed.connect(_close_detail)
	card.add_child(back)

func _close_detail() -> void:
	if _detail != null:
		_detail.queue_free()
		_detail = null

# ------------------------------------------------------------------ buy/sell

func _buy(id: String, tab: String) -> void:
	var cat := _category_for(id)
	var entry: Dictionary = DB.entry(cat, id)
	var levels: Array = entry.get("level_stat", [])
	var lvl := GameState.get_type_level(id)
	if tab == "castle":
		# unbought castle upgrades sit at level 0: BUY charges cost(level 1) and lifts it to 1
		lvl = GameState.get_castle_level(id)
	var next := lvl + 1
	if id == "boomstick":
		# boomstick upgrades level ASH — cost and cap come from ash's table
		entry = DB.entry("units", "ash")
		levels = entry.get("level_stat", [])
		lvl = int(GameState.get_type_level("ash"))
		next = lvl + 1
	if next > levels.size():
		return
	var cost := int(levels[next - 1].get("cost", 0))
	if GameState.gold < cost:
		return
	GameState.add_gold(-cost)
	GameState.set_type_level(id, next)
	main.play_sfx("ui_upgrade_01")
	_close_detail()
	# carry the scroll offset across the rebuild; deferred restore because the new rows' minimum sizes propagate late
	_shop_scroll_offset = _shop_scroll.scroll_vertical if _shop_scroll != null else 0
	_rebuild()
	if _shop_scroll != null:
		_shop_scroll.set_deferred("scroll_vertical", _shop_scroll_offset)

func _downgrade(id: String, tab: String, refund: int) -> void:
	var lvl := GameState.get_type_level(id)
	if tab == "castle":
		lvl = GameState.get_castle_level(id)
	if lvl <= 1:
		return
	GameState.add_gold(refund)
	GameState.set_type_level(id, lvl - 1)
	# keep the scroll offset across the rebuild, like _buy
	_shop_scroll_offset = _shop_scroll.scroll_vertical if _shop_scroll != null else 0
	_rebuild()
	if _shop_scroll != null:
		_shop_scroll.set_deferred("scroll_vertical", _shop_scroll_offset)

func _buy_weapon(id: String) -> void:
	var cost := int(DB.entry("weapons", id).get("cost", 0))
	if GameState.gold < cost:
		return
	GameState.add_gold(-cost)
	GameState.purchase_weapon(id)
	main.play_sfx("ui_upgrade_01")
	_close_detail()
	# keep the scroll offset across the rebuild, like _buy
	_shop_scroll_offset = _shop_scroll.scroll_vertical if _shop_scroll != null else 0
	_rebuild()
	if _shop_scroll != null:
		_shop_scroll.set_deferred("scroll_vertical", _shop_scroll_offset)

func _build_troops() -> void:
	_select_bg("Select Troops", func() -> void: open_upgrades())

	# side fix: expand/stretch BEFORE size (texture minimum clamp)
	var panel := TextureRect.new()
	panel.texture = _tex("res://assets/ui/hud/selection_box.webp")
	panel.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	panel.stretch_mode = TextureRect.STRETCH_SCALE
	panel.position = Vector2(4, 4)
	panel.size = Vector2(644, 516)
	_root.add_child(panel)
	var header := _mk_label("Select Troops", 26, Color.WHITE)
	header.add_theme_constant_override("outline_size", 4)
	header.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.05))
	header.position = Vector2(24, 8)
	panel.add_child(header)

	var cw := 196.0
	var ch := 92.0
	for i in TROOP_POOL.size():
		var t: String = TROOP_POOL[i]
		var r := i / 3
		var c := i % 3
		var cell := Control.new()
		cell.position = Vector2(38 + c * (cw + 6), 96 + r * (ch + 6))
		cell.size = Vector2(cw, ch)
		panel.add_child(cell)

		var entry := DB.entry("units", t)
		if entry.is_empty():
			continue
		var unlock := _unlock_wave(t)
		var lvl := GameState.get_type_level(t)
		if GameState.current_wave < unlock:
			var pad := TextureRect.new()
			pad.texture = _tex(MENU_ART + "locked_icon.webp")
			# expand/stretch BEFORE size: size-first gets clamped to the texture minimum and never re-shrinks
			pad.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			pad.stretch_mode = TextureRect.STRETCH_SCALE
			pad.position = Vector2(6, 12)
			pad.size = Vector2(72, 72)
			pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cell.add_child(pad)
			continue

		var icon := _entry_icon(str(entry.get("icon_texture", t)), Vector2(72, 72))
		icon.position = Vector2(6, 12)
		cell.add_child(icon)
		if unlock == GameState.current_wave:
			var np := TextureRect.new()
			np.texture = _tex(MENU_ART + "new_plaque.webp")
			np.position = Vector2(2, 6)
			np.size = Vector2(44, 22)
			np.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			np.stretch_mode = TextureRect.STRETCH_SCALE
			cell.add_child(np)
		# the attack row ALWAYS renders for an available troop (heal icon + |damage| for healers, 0 weaponless); labels x=114 = R10-06 nudge (see Ash note)
		var dmg := _unit_damage(t, maxi(lvl, 1))
		var ai := TextureRect.new()
		ai.texture = _tex(MENU_ART + ("heal_icon.webp" if dmg < 0 else "attack_icon.webp"))
		ai.position = Vector2(84, 12)
		ai.size = Vector2(22, 26) if dmg >= 0 else Vector2(24, 24)
		ai.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		ai.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		cell.add_child(ai)
		var av := _bold_label(str(absi(dmg)), 20, Color.WHITE)
		av.position = Vector2(114, 12)  # R10-06 nudge (see above); was 110
		av.size = Vector2(64, 26)
		av.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cell.add_child(av)
		var hp: Variant = DB.get_stat("units", t, "health", maxi(lvl, 1))
		if hp != null:
			var hi := TextureRect.new()
			hi.texture = _tex(MENU_ART + "health_icon.webp")
			hi.position = Vector2(84, 52)
			hi.size = Vector2(24, 22)
			hi.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			hi.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			cell.add_child(hi)
			var hv := _bold_label(str(int(hp)), 20, Color.WHITE)
			hv.position = Vector2(114, 52)  # R10-06 nudge (see above); was 110
			hv.size = Vector2(64, 22)
			hv.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			cell.add_child(hv)
		# iron cost lands in the icon art's OWN painted black box
		var cost := int(DB.get_stat("units", t, "iron_cost", 1))
		var tv := _mk_label(str(cost), 15, Color.WHITE)
		tv.position = Vector2(38, 60)
		tv.size = Vector2(36, 20)
		tv.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		tv.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tv.mouse_filter = Control.MOUSE_FILTER_IGNORE
		cell.add_child(tv)

		# picked: gold edge + dimmed icon (no red X inside the panel); click toggles
		var selected: bool = t in GameState.selected_units
		if selected:
			var edge := ColorRect.new()
			edge.color = Color(1.0, 0.85, 0.2)
			edge.position = Vector2(-2, -2)
			edge.size = Vector2(cw + 4, ch + 4)
			edge.z_index = -1
			cell.add_child(edge)
			icon.modulate = Color(0.5, 0.5, 0.5)
		var pick := Button.new()
		pick.flat = true
		pick.modulate = Color(1, 1, 1, 0.0)
		pick.size = Vector2(cw, ch)
		pick.pressed.connect(_toggle_troop.bind(t))
		cell.add_child(pick)

	# blank AND picked icons share the EXACT same rect so they sit flush; the x_button badge removes a picked troop
	var tray_n := _max_selected()
	for i in tray_n:
		var blank := TextureRect.new()
		blank.texture = _tex(HUD_ART + "icon_blank.webp")
		# expand before size or the 121px texture minimum clamps the slot
		blank.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		blank.stretch_mode = TextureRect.STRETCH_SCALE
		blank.position = Vector2(12 + i * 92, 544)
		blank.size = Vector2(84, 84)
		blank.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(blank)
	for i in GameState.selected_units.size():
		var t: String = GameState.selected_units[i]
		var icon := _entry_icon(str(DB.entry("units", t).get("icon_texture", t)), Vector2(84, 84))
		icon.position = Vector2(12 + i * 92, 544)
		_root.add_child(icon)
		# bold digits centred in the icon art's own painted cost box (icon centre + (13, -15) y-up, scaled to the 84 draw)
		var cost_l := _bold_label(str(int(DB.get_stat("units", t, "iron_cost", 1))), 28, Color.WHITE)
		cost_l.position = Vector2(12 + i * 92, 544) + Vector2(32.0, 48.0) * (84.0 / 72.0)
		cost_l.size = Vector2(36.0, 20.0) * (84.0 / 72.0)
		cost_l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cost_l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		cost_l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(cost_l)
		var xb := _mk_x_button_tex()
		xb.position = Vector2(12 + i * 92, 544) + Vector2((84.0 - 36.0) / 2.0, -18.0)
		_root.add_child(xb)
		xb.pressed.connect(_toggle_troop.bind(t))

func _select_bg(header: String, on_back: Callable) -> void:
	## castle-front chrome for the select screens; preview units spawn FIRST so the panel and tray stay on top
	var bg := TextureRect.new()
	bg.texture = _tex(MENU_ART + "castle_front_background.webp")
	bg.position = Vector2(-88, 0)
	bg.size = Vector2(1136, 640)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(bg)

	_spawn_wave_preview_units()

	var wl := _mk_label(GameState.wave_label(), 32, Color(1.0, 0.85, 0.2))
	wl.position = Vector2(690, 8)
	wl.size = Vector2(160, 42)
	_root.add_child(wl)
	var back := _plate_btn("back_button", MENU_ART, Vector2(94, 48))
	back.position = Vector2(856, 6)
	back.pressed.connect(on_back)
	_root.add_child(back)
	var cont := _plate_btn("continue_button", HUD_ART, Vector2(210, 80))
	cont.position = Vector2(736, 548)
	cont.pressed.connect(_on_continue)
	_root.add_child(cont)

func _mk_x_button_tex() -> TextureButton:
	var b := TextureButton.new()
	b.texture_normal = _tex(MENU_ART + "x_button.webp")
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	b.custom_minimum_size = Vector2(36, 36)
	b.size = Vector2(36, 36)
	return b

func _spawn_wave_preview_units() -> void:
	## the coming wave's enemies posed on the right-hand road as non-AI props looping their "win" emote
	if main == null:
		return
	# wave_51's waves.json row (the endless seed) carries unit_stat as a Dictionary, not an Array -- a save parked on wave 51 crashed here
	var stats_v: Variant = DB.get_wave_data(GameState.current_wave).get("unit_stat", [])
	var stats: Array = stats_v if stats_v is Array else []
	var unique_units := {}
	for v: Dictionary in stats:
		var lvv: Variant = v.get("level", null)
		if lvv == null:
			continue  # the Lua's `if v.level` gate (tally markers etc.)
		var un := str(v.get("unit", ""))
		if un == "" or DB.entry("units", un).is_empty():
			continue
		unique_units[un] = maxi(int(unique_units.get(un, 1)), int(lvv))
	var to_spawn: Array = []
	for un: String in unique_units.keys():
		var lv: int = int(unique_units[un])
		var uv: Variant = DB.get_stat("units", un, "unique", lv)
		var uwv: Variant = DB.get_stat("units", un, "unlock_wave", lv)
		to_spawn.append({"name": un, "level": lv,
			"unique": uv != null and bool(uv),
			"unlock_wave": int(uwv) if uwv != null else 1})
	to_spawn.sort_custom(func(a, b):
		if bool(a["unique"]) != bool(b["unique"]):
			return bool(a["unique"])
		return int(a["unlock_wave"]) < int(b["unlock_wave"]))
	# pad by repeating non-unique entries -- the Lua re-reads the array while appending, so copies breed copies until min is reached
	var min_n: int = int(DB.table("globals").get("min_units_in_wave_preview", 5))
	var max_n: int = int(DB.table("globals").get("max_units_in_wave_preview", 12))
	var num_insert := mini(min_n - to_spawn.size(), max_n - to_spawn.size())
	for i in range(maxi(num_insert, 0)):
		if i >= to_spawn.size():
			break
		var ud: Dictionary = to_spawn[i]
		if not bool(ud["unique"]):
			to_spawn.append(ud)
	# spawn in REVERSE index order: tree order keeps every preview unit behind the controls added after _select_bg while i=0 (nearest camera) draws last = on top
	var x_locs := [740.0, 825.0, 910.0]
	for ri in to_spawn.size():
		var i := to_spawn.size() - 1 - ri
		if i >= max_n:
			continue
		var ud2: Dictionary = to_spawn[i]
		var u := Unit.create(main, str(ud2["name"]), int(ud2["level"]), Unit.Team.ENEMY)
		u.ai_enabled = false
		u.is_prop = true  # menu prop: no health bar, no AI, no field queries
		u.facing = -1.0   # face the castle like the original's menu camera
		u.anim_lock = "win"
		u.position = Vector2(float(x_locs[i % 3]), 490.0 - i * 34.0)
		# no camera on this CanvasLayer: apply the menu camera's 2 screen-px-per-world scale manually
		u.scale = Vector2.ONE * 2.0
		_root.add_child(u)
		# match the facing flip BEFORE set_process(false) freezes the per-tick flip (_ready ran at add_child, so _authored_facing is populated)
		if u.anim != null:
			u.anim.flip_h = u.facing * u._authored_facing < 0.0
		elif u.actor3d != null:
			u.actor3d.set_facing_flip(u.facing * u._authored_facing < 0.0)
		u.set_process(false)  # no _process ticks: no terrain snap, no movement
		if u.actor3d != null:
			if u.actor3d.has_clip("win"):
				u.actor3d.play_clip("win", true)
		elif u.anim != null and u.anim.sprite_frames.has_animation("win"):
			u.anim.play("win")

func _max_selected() -> int:
	var v: Variant = DB.table("globals").get("max_selected_units", 5)
	return int(v) if v != null else 5

func _toggle_troop(t: String) -> void:
	var sel: Array = GameState.selected_units.duplicate()
	if t in sel:
		sel.erase(t)
	elif sel.size() < _max_selected():
		sel.append(t)
	else:
		main.play_sfx("ui_disabled_click_02")
		return
	GameState.selected_units = sel
	_rebuild()

# ------------------------------------------------------------ select spells

var _card: Control = null  # unlocked-screen card

func _toggle_spell_pick(id: String) -> void:
	var sel: Array = GameState.selected_spells.duplicate()
	if id in sel:
		sel.erase(id)
	elif sel.size() < GameState.getNumSpellSlotsUnlocked():
		sel.append(id)
	else:
		main.play_sfx("ui_disabled_click_02")
		return
	GameState.selected_spells = sel
	_rebuild()

func _build_spells() -> void:
	_select_bg("Select Skills", func() -> void: open_troops())

	var panel := TextureRect.new()
	panel.texture = _tex("res://assets/ui/hud/selection_box.webp")
	# side fix: expand/stretch BEFORE size (texture minimum clamp)
	panel.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	panel.stretch_mode = TextureRect.STRETCH_SCALE
	panel.position = Vector2(4, 4)
	panel.size = Vector2(644, 516)
	_root.add_child(panel)
	var header := _mk_label("Select Skills", 26, Color.WHITE)
	header.add_theme_constant_override("outline_size", 4)
	header.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.05))
	header.position = Vector2(24, 8)
	panel.add_child(header)

	var cw := 196.0
	var ch := 150.0
	var pool := GameState.get_valid_spells()
	for i in pool.size():
		var id: String = str(pool[i]["name"])
		var entry := DB.entry("spells", id)
		if entry.is_empty():
			continue
		var unlock := int(entry.get("unlock_wave", 1))
		var c := i % 3
		var r := i / 3
		var cell := Control.new()
		cell.position = Vector2(38 + c * (cw + 6), 100 + r * (ch + 8))
		cell.size = Vector2(cw, ch)
		panel.add_child(cell)

		var available: bool = GameState.current_wave >= unlock
		if not available:
			var pad := TextureRect.new()
			pad.texture = _tex(MENU_ART + "locked_icon.webp")
			# expand/stretch BEFORE size (see the troops grid note)
			pad.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			pad.stretch_mode = TextureRect.STRETCH_SCALE
			pad.position = Vector2(cw / 2 - 60, 8)
			pad.size = Vector2(120, 120)
			pad.mouse_filter = Control.MOUSE_FILTER_IGNORE
			cell.add_child(pad)
			continue
		var icon := _entry_icon(_cell_icon_uri(entry, id), Vector2(120, 120))
		icon.position = Vector2(cw / 2 - 60, 8)
		cell.add_child(icon)
		if unlock == GameState.current_wave:
			var np := TextureRect.new()
			np.texture = _tex(MENU_ART + "new_plaque.webp")
			np.position = Vector2(cw / 2 - 62, 4)
			np.size = Vector2(40, 38)
			np.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			np.stretch_mode = TextureRect.STRETCH_SCALE
			cell.add_child(np)

		# picked: gold edge + dimmed icon; click toggles
		var selected: bool = id in GameState.selected_spells
		if selected:
			var edge := ColorRect.new()
			edge.color = Color(1.0, 0.85, 0.2)
			edge.position = Vector2(-2, -2)
			edge.size = Vector2(cw + 4, ch + 4)
			edge.z_index = -1
			cell.add_child(edge)
			icon.modulate = Color(0.5, 0.5, 0.5)
		var pick := Button.new()
		pick.flat = true
		pick.modulate = Color(1, 1, 1, 0.0)
		pick.size = Vector2(cw, ch)
		pick.pressed.connect(_toggle_spell_pick.bind(id))
		cell.add_child(pick)

	# blank AND picked icons share the EXACT same rect; the x_button badge removes a picked spell
	var slots := GameState.getNumSpellSlotsUnlocked()
	for i in slots:
		var blank := TextureRect.new()
		blank.texture = _tex(HUD_ART + "icon_blank.webp")
		# expand before size or the 121px texture minimum clamps the slot
		blank.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		blank.stretch_mode = TextureRect.STRETCH_SCALE
		blank.position = Vector2(12 + i * 92, 544)
		blank.size = Vector2(84, 84)
		blank.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(blank)
	for i in GameState.selected_spells.size():
		var id2: String = GameState.selected_spells[i]
		var icon2 := _entry_icon(_cell_icon_uri(DB.entry("spells", id2), id2),
			Vector2(84, 84))
		icon2.position = Vector2(12 + i * 92, 544)
		_root.add_child(icon2)
		var xb2 := _mk_x_button_tex()
		xb2.position = Vector2(12 + i * 92, 544) + Vector2((84.0 - 36.0) / 2.0, -18.0)
		_root.add_child(xb2)
		xb2.pressed.connect(_toggle_spell_pick.bind(id2))

# ---------------------------------------------------------------- unlocked

func _build_unlocked() -> void:
	var dim := ColorRect.new()
	dim.color = Color.BLACK
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)

	var header := _mk_label("You Unlocked", 32, Color.WHITE)
	header.add_theme_constant_override("outline_size", 6)
	header.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.05))
	# NO anchor preset here -- PRESET_CENTER_TOP against the empty parent rect landed the label off-screen; (360,8) is already dead-centre
	header.position = Vector2(360, 8)
	header.size = Vector2(240, 44)
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	header.modulate.a = 0.0
	_root.add_child(header)
	var tw := create_tween()
	tw.tween_property(header, "modulate:a", 1.0, 0.25)  # AlphaAction(0.25)
	_show_unlock_card()

func _show_unlock_card() -> void:
	if _unlock_idx >= _pending_unlocks.size():
		return
	var item: Dictionary = _pending_unlocks[_unlock_idx]
	var id: String = str(item["name"])
	var cat: String = str(item["cat"])
	var entry: Dictionary = DB.entry(cat, id)
	# assets.sounds.unlock is not in the audio manifest -- the purchase stinger stands in
	main.play_sfx("ui_upgrade_01")

	var card := TextureRect.new()
	card.texture = _tex("res://assets/ui/hud/selection_box.webp")
	# expand/stretch MUST precede size -- the texture minimum clamps a size-first assignment and never shrinks back
	card.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	card.stretch_mode = TextureRect.STRETCH_SCALE
	card.size = Vector2(608, 533)  # 648x569 * ratio 0.46875 * 2 px/world — assets-*.lua:182
	card.position = Vector2(176, 50)  # x centred; 11px above the Lua's C,C+(0,4) (y=61) so the continue plate clears the 640 canvas
	card.pivot_offset = card.size / 2.0
	card.scale = Vector2.ZERO
	_root.add_child(card)
	_card = card
	var tw := create_tween()
	tw.tween_property(card, "scale", Vector2.ONE, 0.25)  # ScaleAction(0.25, Smooth)

	var icon := _entry_icon(_cell_icon_uri(entry, id), Vector2(120, 120))
	icon.position = Vector2(28, 56)
	card.add_child(icon)
	# digits are a child OF THE ICON (as in the Lua), centred on the art's baked cost tab -- any icon move carries them
	if cat == "units":
		var cost: Variant = entry.get("iron_cost", null)
		if cost != null:
			var cl := _mk_label(str(int(cost)), 20, Color.WHITE)
			cl.add_theme_constant_override("outline_size", 4)
			cl.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.05))
			cl.size = Vector2(80, 26)
			cl.position = icon.size / 2.0 + Vector2(26.0, 30.0) - cl.size / 2.0
			cl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			cl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			cl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			icon.add_child(cl)

	var tl := _mk_label(str(entry.get("title", id)), 30, Color.WHITE)
	tl.position = Vector2(162, 56)
	tl.size = Vector2(370, 40)
	tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(tl)
	var sub: String = "Skill" if bool(item.get("is_spell", false)) \
		else str(entry.get("unit_type", ""))
	var sl := _mk_label(sub, 20, Color(0.75, 0.75, 0.75))
	sl.position = Vector2(162, 96)
	sl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(sl)

	var desc: String = str(entry.get("description", ""))
	if desc != "":
		var dl := _mk_label(desc, 21, Color(1.0, 0.92, 0.55))
		dl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		dl.position = Vector2(29, 190)
		dl.size = Vector2(550, 120)
		dl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		dl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(dl)
		if str(entry.get("unit_type", "")) == "Castle Upgrade":
			var mb := _mk_label("*Must buy to use", 19, Color(1.0, 0.25, 0.25))
			mb.position = Vector2(29, 316)
			mb.size = Vector2(550, 26)
			mb.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			mb.mouse_filter = Control.MOUSE_FILTER_IGNORE
			card.add_child(mb)

	var flavor: String = str(entry.get("flavor_text", ""))
	if flavor != "":
		var fl := _mk_label('"%s"' % flavor, 17, Color.WHITE)
		fl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		fl.position = Vector2(29, 375)
		fl.size = Vector2(550, 88)
		fl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		fl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		card.add_child(fl)

	# the continue plate straddles the frame's bottom lip; a card child so the scale tween carries it
	var cont := _plate_btn("continue_button", HUD_ART, Vector2(236, 86))
	cont.position = Vector2(186, 501)  # x: (608-236)/2; y: 533 - 32
	cont.pressed.connect(_on_unlock_continue)
	card.add_child(cont)

func _on_unlock_continue() -> void:
	main.play_sfx("ui_button_02")
	if _card == null:
		_advance_unlock()
		return
	var card := _card
	_card = null
	var tw := create_tween()
	tw.tween_property(card, "scale", Vector2.ZERO, 0.25)
	tw.tween_callback(_advance_unlock)

func _advance_unlock() -> void:
	_unlock_idx += 1
	if _unlock_idx >= _pending_unlocks.size():
		_pending_unlocks = []
		state = "upgrades"
		_rebuild()
	else:
		_show_unlock_card()

const CREDITS_SCROLL_SPEED := 30.0  # credits.lua:14 scroll_speed (px/s)

# credits.lua data transcribed verbatim; format tiers map to h1 45 / h2 27 / n 18 / small 12
const CREDITS_DATA := [
	{"tex": "logo.webp", "sz": Vector2(597, 288)},  # assets.textures.logo
	{"h1": "Backflip Studios"},
	{"sp": true},
	{"h2": "Executive Producer"}, {"n": "Julian Farrior"}, {"sp": true},
	{"h2": "Technical Director"}, {"n": "Dale Thoms"}, {"sp": true},
	{"h2": "Lead Game Designer"}, {"n": "Tom Blind"}, {"sp": true},
	{"h2": "Art Director"}, {"n": "Ryan Drag"}, {"sp": true},
	{"h2": "Project Manager"}, {"n": "Bryan Mashinter"}, {"sp": true},
	{"h2": "Game Programming"},
	{"n": "Mike Lewandowski"}, {"n": "Zack Smith"}, {"sp": true},
	{"h2": "Engine Programming"},
	{"n": "Justin Larrabee"}, {"n": "Kevin Depue"}, {"n": "Ambrose Krapacs"},
	{"n": "Nic Foster"}, {"n": "Curtis Bennett"}, {"sp": true},
	{"h2": "Additional Programming"},
	{"n": "Tye Hooley"}, {"n": "Addison LeMessurier"}, {"n": "Ethan Pendergraft"},
	{"n": "Kyle Roucis"}, {"sp": true},
	{"h2": "live_producer"}, {"n": "Jess Harpley"}, {"sp": true},
	{"h2": "Game Design"}, {"n": "Ben Scott Harper"}, {"sp": true},
	{"h2": "Art"}, {"n": "Adam Roark"}, {"n": "Tommy Zhou"}, {"sp": true},
	{"h2": "Additional Art"},
	{"n": "Annie Fodge"}, {"n": "James Larson"}, {"n": "Thomas Olson"},
	{"n": "Brian Vinton"}, {"sp": true},
	{"h2": "Sound & Music"}, {"n": "Aubrey Hodges"}, {"sp": true},
	{"h2": "Director of QA & CS"}, {"n": "Ron Clement"}, {"sp": true},
	{"h2": "QA Manager"}, {"n": "Blaine Loder"}, {"sp": true},
	{"h2": "Lead Product QA"}, {"n": "Jordan Sindelar"}, {"sp": true},
	{"h2": "QA"},
	{"n": "Colby Chavez"}, {"n": "Austin Childers"}, {"n": "Cameron Conrad"},
	{"n": "Lauren Cordani"}, {"n": "Martine Della Ruffa"}, {"n": "Adam Dyer"},
	{"n": "Max Esayev"}, {"n": "Omar Guzman"}, {"n": "Cyndi Jolley"},
	{"n": "Donny Long"}, {"n": "Igor Lobodyuk"}, {"n": "Bob McCabe"},
	{"n": "Aileen McCollum"}, {"n": "Aaron McCormick"}, {"n": "Greg McQueen"},
	{"n": "Nick Medlock"}, {"n": "Justin Mercier"}, {"n": "Tim Michaud"},
	{"n": "Jerry Moncrief"}, {"n": "Geoff Moyer"}, {"n": "Evan Newton"},
	{"n": "Kyle Oswald"}, {"n": "Sean Prahinski"}, {"n": "Jennifer Reed"},
	{"n": "Justin Seabourn"}, {"n": "Russ Slough"}, {"n": "Doug Summers"},
	{"n": "Patrick Tompkins"}, {"n": "William Voss"}, {"n": "Michael Walters"},
	{"n": "Erin Whitehorse"}, {"n": "Nick Wilcox"}, {"sp": true},
	{"h2": "CS Lead"}, {"n": "Mike McGovern"}, {"sp": true},
	{"h2": "Customer Service"},
	{"n": "Brandy Long"}, {"n": "Rachel Medrano"}, {"n": "Craig Neff"},
	{"sp": true},
	{"h2": "Special Thanks"},
	{"n": "Jim Packer"}, {"n": "Aaron Berndtson"}, {"n": "Juli Logemann"},
	{"n": "Lucy Lathan"}, {"n": "Linda Kim"}, {"sp": true},
	{"tex": "granny_logo.webp", "sz": Vector2(298, 179)},
	{"small": "Uses Granny Animation."},
	{"small": "Copyright (C) 1999-2010 by RAD Game Tools, Inc."},
	{"sp": true},
	{"tex": "mgm_logo_bw.webp", "sz": Vector2(480, 312)},
	{"small": "ARMY OF DARKNESS TM & (C) 1993 Orion Pictures Corporation."},
	{"small": "(C) 2012 Metro-Goldwyn-Mayer Studios Inc. All Rights Reserved."},
	{"sp": true},
]

var _credits_tween: Tween = null  # the scroll + end-sequence chain

func _build_credits() -> void:
	## full-screen black window (tap anywhere quits); the column scrolls up, stinger + 4 s hold at the end, then quit
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	bg.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.button_index == MOUSE_BUTTON_LEFT \
				and ev.pressed:
			_quit_credits())
	_root.add_child(bg)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 0)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.custom_minimum_size = Vector2(960, 0)
	for e: Dictionary in CREDITS_DATA:
		var child: Control
		if e.has("tex"):
			var tr := TextureRect.new()
			tr.texture = _tex(MENU_ART + str(e["tex"]))
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.custom_minimum_size = e["sz"]
			tr.size = e["sz"]
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			child = tr
		else:
			var sz := 18
			var text := ""
			if e.has("h1"):
				sz = 45
				text = str(e["h1"])
			elif e.has("h2"):
				sz = 27
				text = str(e["h2"])
			elif e.has("n"):
				sz = 18
				text = str(e["n"])
			else:  # "sp" / "small": heading3, 18 x 0.66 = 11.88 -> 12
				sz = 12
				text = " " if e.has("sp") else str(e["small"])
			var lbl := _bold_label(text, sz, Color.WHITE)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			child = lbl
		child.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		col.add_child(child)
	_root.add_child(col)

	# starts below the screen, stops with the last line on the top edge; the duration is DERIVED, not hand-tuned
	var scroll_height := col.get_combined_minimum_size().y + 640.0
	var speed := CREDITS_SCROLL_SPEED
	if Dbg.args.has("creditsspeed"):
		speed = maxf(float(Dbg.args["creditsspeed"]), 1.0)  # screenshot aid
		print("[credits] content=%.0fpx scroll=%.0fs at %.0f px/s (dbg override)" % [
			scroll_height - 640.0, scroll_height / speed, speed])
	col.position = Vector2(0, 640.0)
	_credits_tween = create_tween()
	_credits_tween.tween_property(col, "position:y", 640.0 - scroll_height,
		scroll_height / speed).set_trans(Tween.TRANS_LINEAR)
	_credits_tween.tween_callback(func() -> void:
		main.play_sfx("objects_level_outros_ash_boomstick"))
	_credits_tween.tween_interval(4.0)  # creditsmenu.lua:191-194 hold
	_credits_tween.tween_callback(_quit_credits)

func _kill_credits_roll() -> void:
	## a tap-exit must stop the chain, or the dead roll would yank the flow back to the main menu mid-game
	if _credits_tween != null and _credits_tween.is_valid():
		_credits_tween.kill()
	_credits_tween = null

func _quit_credits() -> void:
	## wave-50 path routes to the title; the options re-watch routes BACK to options (the spawn-stack behavior)
	_kill_credits_roll()
	_clear_root()
	if _credits_from == "options":
		_credits_from = ""
		open_options()
	else:
		_credits_from = ""
		open_main_menu()

# reset-confirm popup state; non-null only while it is up
var _reset_popup: Control = null

func reset_popup_open() -> bool:
	return _reset_popup != null

func _build_options() -> void:
	## the EN background art ships the "OPTIONS" header baked in
	var bg := TextureRect.new()
	bg.texture = _tex(MENU_ART + "options_screen_bg.webp")  # :33-36, 480x320 world
	bg.size = Vector2(960, 640)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(bg)

	# TOP-RIGHT corner flush with the window -- a bottom-right subtraction put the plate at y=-70, fully off-screen
	var back := _plate_btn("back_button", MENU_ART, Vector2(139, 75) * ART_PX)
	back.position = Vector2(960.0 - back.size.x, 0.0)
	back.pressed.connect(_on_options_back)
	_root.add_child(back)

	var pm: PauseMenu = main.pause_menu
	_add_options_toggle(MENU_ART + "music_button", Vector2(0, 58),
		pm.music_on, func() -> void: pm.set_music(not pm.music_on))
	_add_options_toggle(MENU_ART + "sound_button", Vector2(120, 58),
		pm.sound_on, func() -> void: pm.set_sound(not pm.sound_on))

	# the original opens a platform web view -- inert here, dimmed
	var legal := TextureButton.new()
	legal.texture_normal = _tex(MENU_ART + "legal_button.webp")
	legal.ignore_texture_size = true
	legal.stretch_mode = TextureButton.STRETCH_SCALE
	legal.size = Vector2(210, 63) * ART_PX  # {L,L,(0,0,1)} -> left-centre (0,160)
	legal.position = Vector2(0, 320 - legal.size.y / 2.0)
	legal.disabled = true
	legal.modulate = Color(1, 1, 1, 0.45)  # web view: inert in the rebuild
	_root.add_child(legal)
	var ll := _mk_label("Legal", 36, Color.WHITE)  # Gothic_Large 18 world *2
	ll.set_anchors_preset(Control.PRESET_FULL_RECT)
	ll.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ll.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	ll.mouse_filter = Control.MOUSE_FILTER_IGNORE
	legal.add_child(ll)

	# right column plates, labels baked into the art; INTRO is live, RESTORE PURCHASES stays inert
	var intro := TextureButton.new()
	intro.texture_normal = _tex(MENU_ART + "intro_button.webp")
	intro.ignore_texture_size = true
	intro.stretch_mode = TextureButton.STRETCH_SCALE
	intro.size = Vector2(168, 89) * ART_PX
	intro.position = Vector2(940 - intro.size.x, 356 - intro.size.y)
	# the plate ALWAYS replays (no has_seen_intro gate); the options screen never closes
	intro.pressed.connect(_play_intro.bind("options"))
	_root.add_child(intro)

	var credits := _plate_btn("credits_button", MENU_ART, Vector2(220, 93) * ART_PX)
	credits.position = Vector2(940 - credits.size.x, 448 - credits.size.y)
	credits.pressed.connect(_on_options_credits)
	_root.add_child(credits)

	var reset := _plate_btn("reset_game_button", MENU_ART,
		Vector2(308, 96) * ART_PX)  # :200-216 reset_data_button
	reset.position = Vector2(940 - reset.size.x, 544 - reset.size.y)
	reset.pressed.connect(_open_reset_popup)
	_root.add_child(reset)

	var restore := TextureButton.new()
	restore.texture_normal = _tex(MENU_ART + "restore_purchases_button.webp")
	restore.ignore_texture_size = true
	restore.stretch_mode = TextureButton.STRETCH_SCALE
	restore.size = Vector2(512, 114) * ART_PX
	restore.position = Vector2(940 - restore.size.x, 640 - restore.size.y)
	restore.disabled = true
	restore.modulate = Color(1, 1, 1, 0.45)  # IAP: inert in the rebuild
	_root.add_child(restore)

	# only while endless is unlocked; the Lua's own geometry clips the box at the screen edge
	if GameState.is_endless_unlocked():
		var sw := TextureRect.new()
		sw.texture = _tex(HUD_ART + "coin_box.webp")
		sw.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		sw.stretch_mode = TextureRect.STRETCH_SCALE
		sw.size = (Vector2(586, 88) * ART_PX / 2.0 - Vector2(96, 6)) * 2.0
		sw.position = Vector2(16, 656 - sw.size.y)  # world (8,-8) self BL
		sw.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_root.add_child(sw)
		var digits := "%09d" % GameState.endless_best
		var grouped := ""
		for i in range(0, 9, 3):
			grouped += digits.substr(i, 3) + " "
		var sc := _bold_label("Score: %s" % grouped.strip_edges(), 40, Color.WHITE)
		sc.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
		sc.add_theme_constant_override("shadow_offset_x", 4)
		sc.add_theme_constant_override("shadow_offset_y", -4)
		sc.position = Vector2((sw.size.x - 320.0) / 2.0,
			(sw.size.y - 40.0) / 2.0 - 6.0)  # {C,C,(0,3,1)}: 3 world up
		sc.size = Vector2(320, 40)
		sc.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		sc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		sw.add_child(sc)

func _add_options_toggle(art: String, off_world: Vector2, on_now: bool,
		press: Callable) -> void:
	var btn := TextureButton.new()
	btn.texture_normal = _tex(art + ".webp")
	btn.ignore_texture_size = true
	btn.stretch_mode = TextureButton.STRETCH_SCALE
	btn.size = Vector2(260, 112) * ART_PX
	btn.position = Vector2(off_world.x * 2.0,
		(160.0 - off_world.y) * 2.0 - btn.size.y / 2.0)
	btn.pressed.connect(press)
	_root.add_child(btn)
	var ck := TextureRect.new()
	ck.texture = _tex(MENU_ART + "check.webp")  # textures.check_mark 84x82
	ck.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ck.stretch_mode = TextureRect.STRETCH_SCALE
	ck.size = Vector2(84, 82) * ART_PX
	ck.position = Vector2(btn.size.x - ck.size.x, (btn.size.y - ck.size.y) / 2.0)
	ck.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ck.visible = on_now
	btn.add_child(ck)
	# re-sync THIS check mark after a flip -- the PauseMenu one is separate
	btn.pressed.connect(func() -> void:
		var pm: PauseMenu = main.pause_menu
		ck.visible = pm.music_on if art.contains("music") else pm.sound_on)

func _on_options_back() -> void:
	main.play_sfx("ui_button_02")
	open_main_menu()

func _on_options_credits() -> void:
	main.play_sfx("ui_button_02")
	open_credits("options")

func _open_reset_popup() -> void:
	## NOTHING is wiped here: the reset fires only from the popup's RESET plate, after its scale-out completes
	if _reset_popup != null:
		return
	main.play_sfx("ui_button_02")
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	_reset_popup = dim

	var card := TextureRect.new()
	card.texture = _tex("res://assets/ui/hud/selection_box.webp")  # :31
	# expand/stretch BEFORE size -- size-first left the card clamped at the texture minimum
	card.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	card.stretch_mode = TextureRect.STRETCH_SCALE
	card.size = Vector2(202, 177) * 2.0  # :32 popup.size 202x177 world
	card.position = ((Vector2(960, 640) - card.size) / 2.0).round()
	card.pivot_offset = card.size / 2.0
	card.scale = Vector2.ZERO  # :127 popup.scale = (0,0,1)
	dim.add_child(card)
	var tw := create_tween()
	tw.tween_property(card, "scale", Vector2.ONE, 0.2) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

	var tl := _bold_label("Reset Current Game", 40, Color.WHITE)
	tl.position = Vector2(22, 28)
	tl.size = Vector2(360, 44)
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	tl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(tl)

	# font 24, not the faithful 32: the DroidSans stand-in wraps to ~8 lines that run under the bottom plates; 24 keeps the 6-line budget
	var ml := _bold_label("All awarded gold, item upgrades, and the current "
		+ "wave will be reset.\n\nAre you sure you want to continue?", 24,
		Color.WHITE)
	ml.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	ml.position = Vector2(32, 86)
	ml.size = Vector2(340, 200)
	ml.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	ml.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(ml)

	_popup_plate(card, Vector2(0.25 * 202.0 * 2.0, 0), "RESET", _on_reset_confirm)
	_popup_plate(card, Vector2(-0.25 * 202.0 * 2.0, 0), "Cancel", _on_reset_cancel)

func _popup_plate(card: Control, centre_off: Vector2, text: String,
		pressed: Callable) -> void:
	var plate := TextureButton.new()
	plate.texture_normal = _tex(MENU_ART + "upgrade_button_blank.webp")
	plate.ignore_texture_size = true
	plate.stretch_mode = TextureButton.STRETCH_SCALE
	plate.size = Vector2(152, 120) * ART_PX
	plate.position = Vector2(card.size.x / 2.0 - plate.size.x / 2.0 + centre_off.x,
		card.size.y - plate.size.y / 2.0 + centre_off.y)
	plate.pressed.connect(pressed)
	card.add_child(plate)
	var lbl := _bold_label(text, 32, Color.WHITE)
	lbl.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	lbl.add_theme_constant_override("shadow_offset_x", 4)
	lbl.add_theme_constant_override("shadow_offset_y", -4)
	lbl.position = Vector2(0, -9)
	lbl.size = plate.size
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	plate.add_child(lbl)

func _on_reset_cancel() -> void:
	main.play_sfx("ui_button_02")
	_close_reset_popup(func() -> void: pass)

func _on_reset_confirm() -> void:
	main.play_sfx("ui_button_02")
	_close_reset_popup(_do_reset_game)

func _close_reset_popup(done: Callable) -> void:
	if _reset_popup == null:
		done.call()
		return
	var popup := _reset_popup
	_reset_popup = null
	var card := popup.get_child(0) as TextureRect
	var tw := create_tween()
	tw.tween_property(card, "scale", Vector2.ZERO, 0.2) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_callback(func() -> void:
		popup.queue_free()
		done.call())

func _do_reset_game() -> void:
	## no IAP: the reset is a FULL wipe (intentional deviation), re-landing on a fresh main menu
	GameState.fresh_start()
	open_main_menu()

# --------------------------------------------------------------- main menu

# title menu editor (--menueditor, local-only tool: see menu_editor.gd); the
# overrides json it writes ships with the game and shifts these seats
const MENU_LAYOUT_PATH := "res://data/menu_layout_overrides.json"
var _menu_elements: Array = []      # [{leaf, node, size, feet, base}]
var _menu_overrides: Dictionary = {}
var _menu_editor: Node = null

func _build_main_menu() -> void:
	# background + gate mask; draw order reproduces the engine's absolute z (bg < far torch < horseman < mask < near torch): later children draw on top
	_menu_elements = []
	var otext := FileAccess.get_file_as_string(MENU_LAYOUT_PATH)
	var oparsed: Variant = JSON.parse_string(otext) if not otext.is_empty() else null
	if oparsed is Dictionary:
		_menu_overrides = oparsed
	var bg := TextureRect.new()
	bg.texture = _tex(MENU_ART + "castle_front_background.webp")
	bg.position = Vector2(-88, 0)
	bg.size = Vector2(1136, 640)
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(bg)
	_menu_reg("bg", bg, Vector2(1136, 640))
	var torch_far: AnimatedSprite2D = _spawn_fire(bg.position + Vector2(1136.0 * 0.275, 320.0 - 640.0 * 0.175),
		2.0 * ART_PX)
	_menu_reg("torch_far", torch_far, Vector2(80, 160))
	_spawn_menu_horse()
	var mask := TextureRect.new()
	mask.texture = _tex(MENU_ART + "castle_front_mask.webp")
	mask.position = Vector2(-88, 224)
	mask.size = Vector2(537, 348)
	mask.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mask.stretch_mode = TextureRect.STRETCH_SCALE
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(mask)
	_menu_reg("gate_mask", mask, Vector2(537.3, 345.6))

	var torch_near: AnimatedSprite2D = _spawn_fire(bg.position + Vector2(1136.0 * 0.15, 320.0 + 640.0 * 0.01),
		2.5 * ART_PX)
	_menu_reg("torch_near", torch_near, Vector2(100, 160))

	var logo := TextureRect.new()
	logo.texture = _tex(MENU_ART + "logo.webp")
	logo.position = Vector2(4, 10)
	logo.size = Vector2(498, 240)
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	logo.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(logo)
	_menu_reg("logo", logo, Vector2(498, 240))

	var opts := _plate_btn("options_button", MENU_ART, Vector2(328, 138))
	opts.position = Vector2(960 - 336, 640 - 128)
	opts.pressed.connect(_on_menu_options)
	_root.add_child(opts)
	_menu_reg("options_plate", opts, Vector2(328, 138))
	if GameState.is_endless_unlocked():
		var eb := _plate_btn("endless_button", MENU_ART, Vector2(328, 138))
		eb.position = Vector2(960 - 336, 640 - 262)
		eb.pivot_offset = eb.size / 2.0
		eb.pressed.connect(_on_menu_endless)
		_root.add_child(eb)
		_menu_reg("endless_plate", eb, Vector2(328, 138))
		# tween bound to the BUTTON, not menus -- a menus-bound looper outlives the freed plate and Godot aborts teardown with "Infinite loop detected"
		var pt := eb.create_tween().set_loops()
		pt.tween_property(eb, "scale", Vector2.ONE * 1.05, 0.6) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		pt.tween_property(eb, "scale", Vector2.ONE, 0.6) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	else:
		var pb := _plate_btn("play_button", MENU_ART, Vector2(328, 138))
		pb.position = Vector2(960 - 336, 640 - 262)
		pb.pressed.connect(_on_menu_play)
		_root.add_child(pb)
		_menu_reg("play_plate", pb, Vector2(328, 138))

	if OS.has_feature("web"):
		var nav: JavaScriptObject = JavaScriptBridge.get_interface("navigator")
		var ua := str(nav.userAgent)
		var standalone: bool = bool(nav.standalone)
		if (ua.contains("iPhone") or ua.contains("iPod")) and not standalone:
			var tip := Label.new()
			tip.text = "Tip: Share > Add to Home Screen plays fullscreen"
			tip.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			tip.position = Vector2(0, 4)
			tip.size = Vector2(960, 22)
			tip.add_theme_font_size_override("font_size", 13)
			tip.add_theme_color_override("font_color", Color(0.92, 0.9, 0.82, 0.95))
			tip.add_theme_color_override("font_outline_color", Color.BLACK)
			tip.add_theme_constant_override("outline_size", 6)
			tip.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_root.add_child(tip)
			var tip_tw := tip.create_tween()
			tip_tw.tween_interval(9.0)
			tip_tw.tween_property(tip, "modulate:a", 0.0, 1.2)
			tip_tw.tween_callback(tip.queue_free)

	# --menueditor: attach the title-menu editor overlay last (topmost);
	# E writes MENU_LAYOUT_PATH, applied on every boot above
	if Dbg.args.has("menueditor"):
		var ed_scr: GDScript = load("res://scripts/menu_editor.gd")
		if ed_scr != null:
			_menu_editor = ed_scr.new()
			_menu_editor.setup(_menu_elements)
			_root.add_child(_menu_editor)

func _menu_reg(leaf: String, node: Node, size: Vector2, feet := false) -> void:
	## Register a title-menu element for --menueditor and apply its saved
	## layout delta (menu_layout_overrides.json). Feet-anchored nodes (the
	## horseman) keep their y when the delta shifts the patrol track.
	var e := {"leaf": leaf, "node": node, "size": size, "feet": feet,
		"base": node.position, "delta": Vector2.ZERO,
		"base_dim": (node as Control).size if node is Control else (node as Node2D).scale}
	var d: Variant = _menu_overrides.get(leaf)
	if d is Array and d.size() >= 2:
		var dv := Vector2(float(d[0]), float(d[1]))
		node.position += dv
		e.delta = dv
		if d.size() >= 4:
			var f := Vector2(float(d[2]), float(d[3]))
			if node is Control:
				(node as Control).size *= f
			elif node is Node2D:
				(node as Node2D).scale *= f
		if leaf == "horseman":
			_horse_x += Vector2(dv.x, 0.0)
	_menu_elements.append(e)

func _spawn_fire(center: Vector2, scale_factor: float) -> AnimatedSprite2D:
	var tex: Texture2D = _tex("res://assets/map/fire_sprite.webp")
	if tex == null:
		return
	var frames := SpriteFrames.new()
	frames.set_animation_speed("default", 15.0)
	frames.set_animation_loop("default", true)
	for i in range(8):
		var at := AtlasTexture.new()
		at.atlas = tex
		at.region = Rect2(float(i % 4) * 32.0, (1.0 if i < 4 else 0.0) * 64.0, 32.0, 64.0)
		frames.add_frame("default", at)
	var f := AnimatedSprite2D.new()
	f.sprite_frames = frames
	f.position = center  # AnimatedSprite2D draws centred on position
	f.scale = Vector2.ONE * scale_factor
	f.modulate = Color(1, 1, 1, 0.75)
	f.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_root.add_child(f)
	f.play("default")
	return f

func _on_menu_options() -> void:
	main.play_sfx("ui_button_02")
	open_options()

func _on_menu_play() -> void:
	## past wave 1 the upgrade menu opens; a fresh save plays the intro first (post-video target stays the wave -- kept deviation)
	main.play_sfx("ui_button_02")
	# PLAY clamps a save past FINAL_WAVE back down -- only the ENDLESS plate enters the sentinel wave (51)
	if GameState.current_wave > GameState.FINAL_WAVE:
		GameState.current_wave = GameState.FINAL_WAVE
	if GameState.current_wave > 1:
		open_upgrades()
	elif GameState.has_seen_intro:
		_launch_wave()
	else:
		_play_intro("play")

# ------------------------------------------------------------ intro video

var _intro_playing := false
var _intro_from := ""
var _intro_overlay: Control = null

func _play_intro(from: String) -> void:
	## pause music, fullscreen movie, resume music + set the flag -- tap, BACK, and natural end all converge here
	# harness runs must NEVER play the 66-second movie; GameState.save() no-ops under cmdline args, so the flag set here is memory-only
	# the original never stacked intro videos -- ignore re-entry
	if _intro_playing:
		return
	for flag in ["smoke-test", "wave", "sandbox", "menupreview", "banner", "menu"]:
		if Dbg.args.has(flag):
			GameState.has_seen_intro = true
			if from == "play":
				_launch_wave()
			return
	if main.music_player != null:
		main.music_player.stop()
	var overlay := Control.new()
	overlay.name = "IntroVideoOverlay"
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(black)
	var vp := VideoStreamPlayer.new()
	vp.stream = load("res://assets/video/aod_intro.ogv")
	# a streamless player (Theora asset absent) no-ops play() and never fires `finished`, stranding the overlay -- route to the post-video path instead
	if vp.stream == null:
		GameState.has_seen_intro = true
		if from == "play":
			_launch_wave()
		return
	vp.expand = true
	vp.set_anchors_preset(Control.PRESET_FULL_RECT)
	vp.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.add_child(vp)
	var catcher := Control.new()
	catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
	catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	catcher.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed:
			_intro_finish()
	)
	overlay.add_child(catcher)
	vp.finished.connect(_intro_finish)
	_intro_playing = true
	_intro_from = from
	_intro_overlay = overlay
	_root.add_child(overlay)
	vp.play()

func _unhandled_input(event: InputEvent) -> void:
	if _intro_playing and event.is_action_pressed("ui_cancel"):
		_intro_finish()

func _intro_finish() -> void:
	## the single completion path; `finished`/tap/Esc double-fires are swallowed by the _intro_playing guard
	if not _intro_playing:
		return
	_intro_playing = false
	if _intro_overlay != null and is_instance_valid(_intro_overlay):
		_intro_overlay.queue_free()
	_intro_overlay = null
	var from := _intro_from
	_intro_from = ""
	main.play_menu_music()  # chunks.music.playSong() (guards null internally)
	GameState.has_seen_intro = true
	GameState.save()
	if from == "play":
		_launch_wave()
	# "options" replay: the options screen never closed -- stay put

func _on_menu_endless() -> void:
	main.play_sfx("ui_button_02")
	var ew: Variant = main.get("ENDLESS_WAVE")
	GameState.current_wave = int(ew) if ew != null else 51
	open_upgrades()

func _spawn_menu_horse() -> void:
	## the patrolling horseman -- live 3D actor when supported, baked strips as the headless/no-model fallback
	var meta: Dictionary = DB.load_json("res://data/unit_anims.json").get("horseman", {})
	var model_uri := str(DB.entry("units", "horseman").get("model", ""))
	if not meta.is_empty() and GrannyActor3D.supports_model(model_uri):
		var u := Unit.create(main, "horseman", 1, Unit.Team.ALLY)
		u.ai_enabled = false
		u.is_prop = true
		u.scale = Vector2.ONE * 2.0 * 0.9
		u.position = Vector2(-800.0, 530.0)
		_root.add_child(u)
		# AFTER add_child -- set_process(false) before tree entry is reset on NOTIFICATION_ENTER_TREE and the Unit's own _process would terrain-snap the prop
		u.set_process(false)  # menus.gd drives position + clips (no terrain snap)
		_horse_unit = u
		_horse_dist = 1600.0  # MoveOffsetAction(800 world) = 1600 screen px
		_horse_x = Vector2(-800.0, -800.0 + 1600.0)
		_horse_state = "wait_out"
		# randf() * 2.0 IS the authentic initial delay (SleepAction(math.random() * 2)) -- not a bug
		_horse_t = randf() * 2.0
		_menu_reg("horseman", u, Vector2(190, 260), true)
		return
	if meta.is_empty():
		return
	var fw: int = maxi(int(meta.get("frame_w", 1)), 1)
	var fh: int = maxi(int(meta.get("frame_h", 1)), 1)
	var frames := SpriteFrames.new()
	for clip: String in ["walk", "idle", "attack_b"]:
		var info: Dictionary = meta.get("clips", {}).get(clip, {})
		if info.is_empty() or not ResourceLoader.exists(str(info.get("file", ""))):
			continue
		var tex: Texture2D = load(str(info["file"]))
		frames.add_animation(clip)
		frames.set_animation_speed(clip, float(info.get("fps", 18)))
		frames.set_animation_loop(clip, clip == "walk")
		var cols: int = maxi(int(info.get("cols", int(info.get("frames", 1)))), 1)
		for i in int(info.get("frames", 1)):
			var at := AtlasTexture.new()
			at.atlas = tex
			at.region = Rect2((i % cols) * fw, (i / cols) * fh, fw, fh)
			frames.add_frame(clip, at)
	if not frames.has_animation("walk"):
		return
	_horse = AnimatedSprite2D.new()
	_horse.sprite_frames = frames
	_horse.scale = Vector2(0.42, 0.42)  # lua horse.scale 0.9 at the menu camera
	_horse.position = Vector2(-250, 640 - 100 - fh * 0.21)
	_horse.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_root.add_child(_horse)
	_horse_dist = 900.0
	_horse_x = Vector2(-250, 650)
	_horse_state = "wait_out"
	_horse_t = randf() * 2.0
	_menu_reg("horseman", _horse, Vector2(180, 120), true)

const HORSE_WALK_TIME := 5.0     # move_time_one_way (line 370)
const HORSE_HALF_TIME := 2.5     # move_time_one_way * 0.5

var _gallop_cd := 0.0
var _horse_dist := 900.0         # one-way patrol distance in screen px
var _horse_unit: Unit = null     # FINAL-07: the live 3D horseman (windowed)

func _horse_alive() -> bool:
	if _horse_unit != null:
		return is_instance_valid(_horse_unit)
	return _horse != null and is_instance_valid(_horse)

func _horse_pos() -> Vector2:
	return _horse_unit.position if _horse_unit != null else _horse.position

func _horse_move_x(dx: float) -> void:
	if _horse_unit != null:
		_horse_unit.position.x += dx
	else:
		_horse.position.x += dx

func _set_horse_facing(dir: float) -> void:
	if _horse_unit != null and is_instance_valid(_horse_unit):
		if _horse_unit.actor3d != null:
			_horse_unit.actor3d.set_facing_flip(
				dir * _horse_unit._authored_facing < 0.0)
		elif _horse_unit.anim != null:
			_horse_unit.anim.flip_h = dir * _horse_unit._authored_facing < 0.0
	elif _horse != null:
		_horse.flip_h = dir < 0.0  # authored facing is right (model_facing)

func _horse_play(clip: String, loop := false) -> void:
	if _horse_unit != null and is_instance_valid(_horse_unit):
		if _horse_unit.actor3d != null and _horse_unit.actor3d.has_clip(clip):
			_horse_unit.actor3d.play_clip(clip, loop)
	elif _horse != null and _horse.sprite_frames.has_animation(clip):
		_horse.play(clip)

func _horse_clip_len(clip: String) -> float:
	if _horse_unit != null and is_instance_valid(_horse_unit) \
			and _horse_unit.actor3d != null:
		return _horse_unit.actor3d.get_clip_length(clip)
	if _horse != null and _horse.sprite_frames.has_animation(clip):
		return _horse.sprite_frames.get_frame_count(clip) \
			/ maxf(_horse.sprite_frames.get_animation_speed(clip), 1.0)
	return 0.0

func _play_gallop() -> void:
	_play_sfx_safe("fx_gallop_1", -10.0)

func _play_sfx_safe(key: String, vol := 0.0) -> void:
	if main != null:
		main.play_sfx(key, vol)

func _tick_horse(dt: float) -> void:
	if not _horse_alive():
		return
	_gallop_cd = maxf(_gallop_cd - dt, 0.0)
	_horse_t -= dt
	match _horse_state:
		"wait_out":
			if _horse_t <= 0.0:
				_set_horse_facing(1.0)
				_horse_play("walk", true)
				_play_gallop()
				_horse_state = "walk_right"
				_horse_t = HORSE_WALK_TIME
		"walk_right":
			_horse_move_x(_horse_dist / HORSE_WALK_TIME * dt)
			if _gallop_cd <= 0.0:
				_play_gallop()
				_gallop_cd = 1.4
			if _horse_t <= 0.0:
				_horse_state = "wait_back"
				_horse_t = randf() * 10.0
				if randf() <= 0.4:
					_play_sfx_safe("objects_effects_soldier_a_scout_approaches", -6.0)
					_horse_t = maxf(_horse_t, 1.0)
		"wait_back":
			if _horse_t <= 0.0:
				_set_horse_facing(-1.0)
				var roll := randf()
				if roll <= 0.3:
					_horse_play("idle", true)
					_horse_state = "look_a"
					_horse_t = 0.5
				elif roll <= 0.6:
					_horse_play("idle", true)
					_horse_state = "rear_a"
					_horse_t = randf() * 2.0
				else:
					_horse_play("walk", true)
					_play_gallop()
					_horse_state = "walk_left"
					_horse_t = HORSE_HALF_TIME
		"walk_left":
			_horse_move_x(_horse_dist / 2.0 / HORSE_HALF_TIME * -dt)
			if _gallop_cd <= 0.0:
				_play_gallop()
				_gallop_cd = 1.4
			if _horse_t <= 0.0:
				if _horse_pos().x > _horse_x.x + 10.0:
					_horse_state = "walk_left"
					_horse_t = HORSE_HALF_TIME
				else:
					_horse_state = "cooldown"
					_horse_t = randf() * 10.0
		"look_a":
			# no snort in the audio manifest -- a quiet whinny stands in
			if _horse_t <= 0.0:
				_play_sfx_safe("fx_whinny_3", -14.0)
				_horse_state = "look_b"
				_horse_t = randf() * 3.0
		"look_b":
			if _horse_t <= 0.0:
				_set_horse_facing(-1.0)
				_horse_play("walk", true)
				_play_gallop()
				_horse_state = "walk_left"
				_horse_t = HORSE_HALF_TIME
		"rear_a":
			if _horse_t <= 0.0:
				_play_sfx_safe("fx_whinny_5", -6.0)
				_horse_play("attack_b", false)
				_horse_state = "rear_b"
				_horse_t = _horse_clip_len("attack_b") + 0.4
		"rear_b":
			if _horse_t <= 0.0:
				_set_horse_facing(-1.0)
				_horse_play("walk", true)
				_play_gallop()
				_horse_state = "walk_left"
				_horse_t = HORSE_HALF_TIME
		"cooldown":
			if _horse_t <= 0.0:
				_horse_state = "wait_out"
				_horse_t = randf() * 2.0

func _process(dt: float) -> void:
	if _menu_editor != null:
		return  # the editor owns the menu: patrol and timers stand down
	if _intro_playing:
		return  # the intro movie owns the screen: no horse patrol or gallop
	if state != "main_menu":
		return
	_menu_t += dt
	_tick_horse(dt)
