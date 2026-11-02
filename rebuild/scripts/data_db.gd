extends Node
## getStat semantics: level = force_level or the saved type level, clamped into level_stat; stat falls back to unit-level data.

const DATA := {
	"units": "res://data/units.json",
	"weapons": "res://data/weapons.json",
	"items": "res://data/items.json",
	"waves": "res://data/waves.json",
	"spells": "res://data/spells.json",
	"ammo": "res://data/ammo.json",
	"globals": "res://data/globals.json",
}

var _tables := {}

func _ready() -> void:
	for cat: String in DATA:
		var text := FileAccess.get_file_as_string(DATA[cat])
		_tables[cat] = JSON.parse_string(text)
		assert(_tables[cat] != null, "failed to parse %s" % DATA[cat])

func table(cat: String) -> Dictionary:
	return _tables.get(cat, {})

func entry(cat: String, type_name: String) -> Dictionary:
	return _tables.get(cat, {}).get(type_name, {})

func get_stat(cat: String, type_name: String, stat: String, force_level: int = 0) -> Variant:
	var type_data: Dictionary = entry(cat, type_name)
	if type_data.is_empty():
		return null
	var level := force_level
	if level <= 0:
		level = GameState.get_type_level(type_name)
	var level_data := get_level_data(type_data, level)
	if level_data.is_empty():
		return type_data.get(stat)
	return level_data.get(stat, type_data.get(stat))

func get_level_data(type_data: Dictionary, level: int) -> Dictionary:
	var levels: Array = type_data.get("level_stat", [])
	if levels.is_empty():
		return {}
	level = clampi(level, 1, levels.size())
	return levels[level - 1]

func get_level_count(cat: String, type_name: String) -> int:
	return entry(cat, type_name).get("level_stat", []).size()

func get_wave_data(wave_num: int) -> Dictionary:
	return _tables.get("waves", {}).get("wave_%02d" % wave_num, {})

func load_json(path: String) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	var parsed: Variant = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}
