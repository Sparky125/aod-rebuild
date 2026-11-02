extends Node
## Session state (wave/gold/upgrade levels) persisted to user://save.json; loads automatically on boot.

const SAVE_PATH := "user://save.json"

var current_wave := 1
var gold := 0
var total_gold := 0

# type name -> 1-based upgrade level, chosen in the between-wave upgrade menu; defaults to 1 like a fresh save (castle upgrades default 0 until bought).
var _type_levels := {}

# the original seeds NO roster — auto-select fills it; the HUD tray re-gates per wave, so a stale list never fields locked troops.
var selected_units: Array = []

# the two spell slots picked in the upgrades SPELLS tab (empty -> main auto-equips by unlock order like a fresh save).
var selected_spells: Array = []

var endless_best := 0

# set once the campaign is beaten; also true implicitly once current_wave passes FINAL_WAVE (see is_endless_unlocked).
var endless_unlocked := false

const FINAL_WAVE := 50  # globals.final_wave

# 1-based iron-cap upgrade bought at the HUD smithy chip with IRON; persisted so the purchase survives restarts.
var iron_cap_level := 1

# getLocked semantics: true = NOT bought, so a fresh save fights gun-only.
var weapon_locks := {"iron_fist": true, "chainsaw": true}

var seen_smithy_tutorial := false

# the original's intro movie plays once, on the FIRST press of PLAY; set true on every video completion (replays included — idempotent).
var has_seen_intro := false

# Castle upgrades whose level 1 must be bought with gold start at 0 (unbought).
const CASTLE_DEFAULT_ZERO := ["inner_wall_archer", "catapults", "the_pit"]

func _ready() -> void:
	load_save()

func save() -> void:
	# harness runs (any cmdline user arg) must never touch the real save — a --fresh screenshot run once overwrote it via the window-close save; real saves come from arg-less play only.
	if not OS.get_cmdline_user_args().is_empty():
		return
	var data := {
		"version": 1,
		"current_wave": current_wave,
		"gold": gold,
		"total_gold": total_gold,
		"type_levels": _type_levels,
		"selected_units": selected_units,
		"selected_spells": selected_spells,
		"endless_best": endless_best,
		"endless_unlocked": endless_unlocked,
		"iron_cap_level": iron_cap_level,
		"weapon_locks": weapon_locks,
		"seen_smithy_tutorial": seen_smithy_tutorial,
		# additive key, no version bump — old saves load fine and default false.
		"has_seen_intro": has_seen_intro,
	}
	var text := JSON.stringify(data)
	var f := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	# Web: user://'s IndexedDB flush is unreliable — localStorage is the durable mirror (see WebStore).
	WebStore.put("save", text)

func load_save() -> bool:
	# Web: prefer the localStorage mirror; fall back to the user:// file and adopt it into the mirror.
	var text := WebStore.get_item("save")
	if text.is_empty() and FileAccess.file_exists(SAVE_PATH):
		text = FileAccess.get_file_as_string(SAVE_PATH)
		if not text.is_empty():
			WebStore.put("save", text)
	if text.is_empty():
		return false
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary) or int(parsed.get("version", 0)) != 1:
		return false
	current_wave = int(parsed.get("current_wave", 1))
	gold = int(parsed.get("gold", 0))
	total_gold = int(parsed.get("total_gold", 0))
	var tl: Variant = parsed.get("type_levels", {})
	if tl is Dictionary:
		_type_levels = tl
	# a save claiming a castle upgrade before its unlock_wave is corrupt — force 0 (the un-unlocked wall-archers bug).
	for k: String in CASTLE_DEFAULT_ZERO:
		if current_wave < int(DB.entry("units", k).get("unlock_wave", 1)):
			_type_levels[k] = 0
	var su: Variant = parsed.get("selected_units", [])
	if su is Array and not (su as Array).is_empty():
		selected_units = su
	var ss: Variant = parsed.get("selected_spells", [])
	if ss is Array:
		selected_spells = ss
	endless_best = int(parsed.get("endless_best", 0))
	endless_unlocked = bool(parsed.get("endless_unlocked", false))
	iron_cap_level = clampi(int(parsed.get("iron_cap_level", 1)), 1, 4)
	var wl: Variant = parsed.get("weapon_locks", {})
	if wl is Dictionary:
		weapon_locks = wl
	seen_smithy_tutorial = bool(parsed.get("seen_smithy_tutorial", false))
	has_seen_intro = bool(parsed.get("has_seen_intro", false))
	return true

func clear_save() -> void:
	## --fresh ignores the persisted save for this run only — it once deleted the file here and wiped a live save.
	reset_run()

func fresh_start() -> void:
	## NEW GAME: wipe the save file and reset every progress var; the deletion is guarded like save() (harness runs never touch the real save).
	if OS.get_cmdline_user_args().is_empty() and FileAccess.file_exists(SAVE_PATH):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(SAVE_PATH))
	WebStore.put("save", "")  # web mirror: an empty value reads as no save
	reset_run()

func get_type_level(type_name: String) -> int:
	return int(_type_levels.get(type_name, 1))

func get_castle_level(type_name: String) -> int:
	return int(_type_levels.get(type_name, 0 if type_name in CASTLE_DEFAULT_ZERO else 1))

func set_type_level(type_name: String, level: int) -> void:
	_type_levels[type_name] = level

func add_gold(amount: int) -> void:
	gold += amount
	total_gold += amount

func weapon_locked(name: String) -> bool:
	return bool(weapon_locks.get(name, true))

func purchase_weapon(name: String) -> void:
	weapon_locks[name] = false

func record_endless_score(score: int) -> void:
	if score > endless_best:
		endless_best = score

func wave_label() -> String:
	## the single wave-text source; past FINAL_WAVE renders "Wave ∞" — a > gate so stale past-50 saves show the sentinel too.
	if current_wave > FINAL_WAVE:
		return "Wave ∞"
	return "Wave %d" % maxi(current_wave, 1)

func is_endless_unlocked() -> bool:
	return endless_unlocked or current_wave > FINAL_WAVE

func unlock_endless() -> void:
	endless_unlocked = true

func hasAnyUnitsUnlocked() -> bool:
	## false at wave 1 (peasant unlocks at 2) — the upgrade menu's CONTINUE then skips straight into the wave.
	for ally: Dictionary in DB.table("globals").get("ally_units", []):
		var unlock_v: Variant = DB.entry("units", str(ally.get("name", ""))).get("unlock_wave", 1)
		if current_wave >= int(unlock_v):
			return true
	return false

func getNumSpellSlotsUnlocked() -> int:
	var wave := current_wave
	var levels: Array = DB.table("globals").get("spell_slot_unlock_levels", [1, 2])
	for i in levels.size():
		if wave < int(levels[i]):
			return i
	return levels.size()

func get_valid_units() -> Array:
	var out: Array = []
	for ally: Dictionary in DB.table("globals").get("ally_units", []):
		var name_: String = str(ally.get("name", ""))
		out.append({
			"name": name_,
			"unlock_wave": int(DB.entry("units", name_).get("unlock_wave", 1)),
		})
	out.sort_custom(func(a, b): return int(a["unlock_wave"]) < int(b["unlock_wave"]))
	return out

func get_valid_spells() -> Array:
	var out: Array = []
	for name_: String in DB.table("spells").keys():
		var e: Dictionary = DB.entry("spells", name_)
		if not e.has("script"):
			continue
		out.append({"name": name_, "unlock_wave": int(e.get("unlock_wave", 1))})
	out.sort_custom(func(a, b): return int(a["unlock_wave"]) < int(b["unlock_wave"]))
	return out

func try_auto_select_objects() -> void:
	if current_wave > int(DB.table("globals").get("auto_select_max_wave", 9)):
		return
	var max_units: Variant = DB.table("globals").get("max_selected_units", 5)
	_auto_select_list(selected_units, get_valid_units(), int(max_units))
	_auto_select_list(selected_spells, get_valid_spells(), getNumSpellSlotsUnlocked())

func _auto_select_list(list: Array, possible: Array, num_slots: int) -> void:
	if list.size() >= num_slots:
		return
	for v: Dictionary in possible:
		if list.size() >= num_slots:
			break
		if current_wave < int(v.get("unlock_wave", 1)):
			continue
		var name_: String = str(v.get("name", ""))
		if name_ == "" or name_ in list:
			continue
		list.append(name_)

func reset_run() -> void:
	## fresh-boot state; selected_units deliberately EMPTY — auto-select refills it once unlocked units exist.
	current_wave = 1
	gold = 0
	total_gold = 0
	_type_levels = {}
	selected_units = []
	selected_spells = []
	endless_best = 0
	endless_unlocked = false
	weapon_locks = {"iron_fist": true, "chainsaw": true}
	seen_smithy_tutorial = false
	has_seen_intro = false
	iron_cap_level = 1
