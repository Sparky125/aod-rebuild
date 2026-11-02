class_name WaveSpawner
extends Node
## Sequential spawn timeline from the wave's unit_stat; the adaptive-difficulty factor speeds it up as the front line advances.

signal all_spawned
signal enemy_spawned(unit: Unit)

var main: Node2D
var _events: Array = []
var _fired := 0
var _wave_time := 0.0
var _factor_lo := 1.0
var _factor_hi := 5.0
var _dt_curve := 10.0
var factor := 1.0
var active := false

func total_planned() -> int:
	## enemy spawns planned for the current wave (wave-progress denominator)
	return _events.size()

func start(wave_data: Dictionary) -> void:
	_events = []
	_fired = 0
	_wave_time = 0.0
	factor = _factor_lo
	active = false

	var cumulative := 0.0
	for v: Dictionary in wave_data.get("unit_stat", []):
		cumulative += float(v.get("delay", 0.0))
		_events.append({"t": cumulative, "unit": str(v.get("unit", "")), "level": int(v.get("level", 1)), "tag": v.get("tag", "")})
	if _events.is_empty():
		all_spawned.emit.call_deferred()
		return
	active = true

func stop() -> void:
	## empties _events so main's win check (_events.size() > 0) goes inert; idempotent.
	_events = []
	_fired = 0
	_wave_time = 0.0
	active = false

func _process(dt: float) -> void:
	if not active:
		return
	_wave_time += dt * factor
	while _fired < _events.size() and _events[_fired]["t"] <= _wave_time:
		var e: Dictionary = _events[_fired]
		_fired += 1
		var tag := str(e["tag"])
		if tag == "push":
			main.on_wave_push()
		if DB.entry("units", e["unit"]).is_empty():
			continue  # "tally" and other pseudo-entries are pure timeline delays
		var u: Unit = main.spawn_enemy(e["unit"], e["level"])
		if tag.begins_with("spawn_"):
			main.on_wave_hero_spawn(tag.trim_prefix("spawn_"))
		enemy_spawned.emit(u)
		_adjust_difficulty()
	if _fired >= _events.size():
		active = false
		all_spawned.emit.call_deferred()

func _adjust_difficulty() -> void:
	var ratio: float = main.get_front_line_ratio()
	var difficulty := pow(ratio, _dt_curve)
	factor = _factor_lo + (_factor_hi - _factor_lo) * difficulty
