class_name EndlessDirector
extends Node
## Endless mode (the original's wave 51): challenge grows with the XP of everything that spawns, four group patterns stream forever; deliberate deviations: live-unit counts, FIFO spawn queue, float score, and death freezes the spawn queue too.

const SCORE_TIME_BASE := 10.0    # score per second per challenge level
const FILLER_GAP := 4.0          # lua: spawn_timer - total_spawn_time > 4
const BOSS_COOLDOWN := 5.0       # lua: LuaAction(5) clears m_boss

var main: Node2D
var data: Dictionary = {}
var xp := 0.0
var challenge := 1
var score := 0.0
var dead := false
var spawned_count := 0

var _t := 0.0
var _score_acc := 0.0
var _last_spawn_at := 0.0
var _queue: Array = []           # [{delay, unit, level, tag?, check_pushback?}]
var _queue_wait := 0.0
var _last_group := ""
var _tagged: Unit = null
var _boss: Unit = null
var _boss_cd := 0.0
var _should_spawn_boss := false
var _pushing_back := false
var _evaluate := false
var _log_at := 0.0

func start() -> void:
	data = DB.load_json("res://data/endless.json")
	_evaluate = true  # spawnWave -> evaluate -> smattering, 5s, tank-n-spank

func _process(dt: float) -> void:
	if dead or main == null:
		return
	_t += dt
	_score_acc += dt * SCORE_TIME_BASE * float(challenge)
	if _score_acc >= 1.0:
		var whole := floorf(_score_acc)
		score += whole
		_score_acc -= whole
	if _boss_cd > 0.0:
		_boss_cd -= dt
		if _boss_cd <= 0.0:
			_boss = null
	_process_queue(dt)
	if _evaluate:
		_evaluate = false
		if _last_group == "":
			_spawn_base_smattering()
			_queue.append({"delay": 5.0, "unit": "", "level": 1})  # SleepAction(5)
			_spawn_tank_and_spank(challenge)
		else:
			_spawn_base_smattering()
	var allies := _live_count(Unit.Team.ALLY)
	var enemies := _live_count(Unit.Team.ENEMY)
	if allies > enemies:
		var ratio := gate_camp_ratio()
		if ratio > 0.8:
			_spawn_tank_and_spank(challenge + 2)
		elif ratio > 0.4:
			_spawn_tank_and_spank(challenge)
		var start_push := 0.6 + 0.4 * (1.0 - float(challenge) / 10.0)
		if ratio > start_push and not _pushing_back:
			_pushing_back = true
			_spawn_push_back()
	if _should_spawn_boss:
		_should_spawn_boss = false
		if _boss == null:
			var r := randi_range(1, 15)
			var boss_type := "evil_sheila" if (10 - r) > challenge else "evil_ash"
			_boss = _spawn(boss_type, 1)
	if _t - _last_spawn_at > FILLER_GAP:
		_spawn_filler_wave()
	if _t - _log_at >= 10.0:
		_log_at = _t
		print("[endless] t=%.0fs score=%d challenge=%d spawned=%d allies=%d enemies=%d" % [
			_t, int(score), challenge, spawned_count, allies, enemies])

func _process_queue(dt: float) -> void:
	if _queue.is_empty():
		return
	_queue_wait -= dt
	while _queue_wait <= 0.0 and not _queue.is_empty():
		var e: Dictionary = _queue.pop_front()
		if e.has("check_pushback"):
			var ratio := gate_camp_ratio()
			var let_off := 0.5 - 0.3 * (1.0 - float(challenge) / 10.0)
			if ratio < let_off:
				_pushing_back = false
			else:
				_spawn_push_back()
		elif str(e["unit"]) != "":
			var u := _spawn(str(e["unit"]), int(e["level"]))
			if e.get("tag", false):
				_tagged = u
			_last_spawn_at = _t
		if _queue.is_empty():
			break
		_queue_wait += maxf(float(_queue[0].get("delay", 0.0)), 0.0)

func _spawn(type_name: String, lvl: int) -> Unit:
	spawned_count += 1
	return main.spawn_enemy(type_name, lvl)

func _spawn_base_smattering() -> void:
	_last_group = "smattering"
	var unit_count := randi_range(2, 5) + challenge
	var tag_number := int(floor(float(unit_count) / 2.0)) - 1
	var avg_unit_time := 2.0 - (float(challenge) / 10.0) * 1.5
	var unit := "sword_skeleton"
	var is_melee := true
	var spawned := 0
	var i := 0
	while i < unit_count:
		var switch_rand := randi_range(1, unit_count)
		if switch_rand < spawned:
			if is_melee:
				is_melee = false
				unit = "spear_skeleton" if randi_range(1, 10) < 6 else "crossbow_skeleton"
			else:
				is_melee = true
				unit = "sword_skeleton"
		_queue.append({
			"delay": avg_unit_time + randf() - 0.5,
			"unit": unit,
			"level": _generate_level(unit, challenge),
			"tag": i == tag_number,
		})
		spawned += 1
		i += 1

func _find_tank(challenge_arg: int) -> String:
	var ch := clampi(challenge_arg, 1, 10)
	var r := randi_range(1, 10)
	if ch < 8:
		return "shield_skeleton" if r > 5 else "pit_monster"
	elif ch < 10:
		return "shield_skeleton" if r > 8 else "pit_monster"
	return "shield_skeleton"  # challenge 10: only shield skeletons

func _spawn_tank_and_spank(challenge_arg: int) -> void:
	_last_group = "tank-n-spank"
	var ch := clampi(challenge_arg, 1, 10)
	var unit_count := 1 + int(ceil(float(ch) / 2.0))
	var tank := _find_tank(ch)
	_queue.append({"delay": 0.0, "unit": tank, "level": _generate_level(tank, ch)})
	var unit := "spear_skeleton"
	var avg_time := 1.5 - float(ch) / 10.0
	var has_changed := false
	var half := int(floor(float(unit_count) / 2.0))
	var i := 0
	while i < unit_count:
		if unit_count > half and not has_changed:
			var r := randi_range(1, 10)
			if r > 4:
				unit = "sword_skeleton" if r > 7 else "crossbow_skeleton"
				has_changed = true
		_queue.append({
			"delay": avg_time + randf() - 0.5,
			"unit": unit,
			"level": _generate_level(unit, ch),
		})
		i += 1

func _spawn_filler_wave() -> void:
	_last_group = "filler"
	var unit_count := randi_range(3, 5)
	var avg_unit_time := 2.2 - (float(challenge) / 10.0) * 1.5
	var ch := maxi(challenge - 3, 1)
	var unit := "sword_skeleton"
	var is_melee := true
	var spawned := 0
	var i := 0
	while i < unit_count:
		var switch_rand := randi_range(1, unit_count)
		if switch_rand < spawned:
			if is_melee:
				is_melee = false
				unit = "spear_skeleton" if randi_range(1, 10) < 6 else "crossbow_skeleton"
			else:
				is_melee = true
				unit = "sword_skeleton"
		_queue.append({
			"delay": avg_unit_time + randf() - 0.5,
			"unit": unit,
			"level": _generate_level(unit, ch),
		})
		spawned += 1
		i += 1
	_last_spawn_at = _t
	# keep the original's branch order: r>7 witch first, so the r>8 flute branch stays dead — do not "fix" it.
	var r := randi_range(1, 10)
	if r > 7:
		_queue.append({"delay": 1.0, "unit": "witch", "level": 1})

func _spawn_push_back() -> void:
	_last_group = "pushback"
	var unit_count := randi_range(2, 5)
	var avg_unit_time := 1.5 - float(challenge) / 10.0
	var unit := "sword_skeleton"
	var is_melee := true
	var spawned := 0
	var i := 0
	while i < unit_count:
		var switch_rand := randi_range(1, unit_count)
		if switch_rand < spawned:
			if is_melee:
				is_melee = false
				unit = "spear_skeleton" if randi_range(1, 10) < 6 else "crossbow_skeleton"
			else:
				is_melee = true
				unit = "sword_skeleton"
		_queue.append({
			"delay": avg_unit_time + randf() - 0.5,
			"unit": unit,
			"level": _generate_level(unit, challenge),
		})
		spawned += 1
		i += 1
	_last_spawn_at = _t
	var r := randi_range(1, 5)
	if r > 4:
		_queue.append({"delay": 1.0, "unit": "witch", "level": 1})
	elif r > 3:
		_queue.append({"delay": 1.0, "unit": "drummer_skeleton", "level": 1})
	elif r > 2:
		_queue.append({"delay": 1.0, "unit": "dryad", "level": 1})
	_queue.append({"delay": 1.0, "unit": "", "level": 1, "check_pushback": true})

func _generate_level(unit: String, challenge_arg: int) -> int:
	var ch := clampi(challenge_arg, 1, 10)
	var sets: Array = data.get("units", {}).get(unit, {}).get("levels", [[1]])
	var set: Array = sets[ch - 1] if ch - 1 < sets.size() else [1]
	return int(set[randi_range(0, set.size() - 1)]) if not set.is_empty() else 1

func gate_camp_ratio() -> float:
	## midpoint(leftmost enemy, front-most ally) / ally-path end.
	var leftmost_enemy := INF
	var foremost_ally := -INF
	for u: Unit in main.units_layer.get_children():
		if u.state == Unit.State.DEAD:
			continue
		if u.team == Unit.Team.ENEMY:
			leftmost_enemy = minf(leftmost_enemy, u.position.x)
		elif u.team == Unit.Team.ALLY and not u.is_gate and not u.is_prop \
				and not u.is_wall_archer and not u.is_catapult:
			foremost_ally = maxf(foremost_ally, u.position.x)
	if leftmost_enemy == INF or foremost_ally == -INF:
		return 0.0
	var ratio: float = ((leftmost_enemy + foremost_ally) * 0.5) / float(main.enemy_spawn_x)
	if ratio > 0.95:
		_should_spawn_boss = true
	return clampf(ratio, 0.0, 1.0)

func _live_count(team: Unit.Team) -> int:
	var n := 0
	for u: Unit in main.units_layer.get_children():
		if u.team == team and u.state != Unit.State.DEAD and not u.is_gate \
				and not u.is_prop and not u.is_wall_archer and not u.is_catapult:
			n += 1
	return n

func on_ally_spawned(type_name: String) -> void:
	var xp_val: Variant = data.get("allies", {}).get(type_name, {}).get("xp")
	if xp_val != null:
		xp += float(xp_val)
		_check_level_up()

func on_enemy_spawned(type_name: String) -> void:
	var xp_val: Variant = data.get("units", {}).get(type_name, {}).get("xp")
	if xp_val != null:
		xp += float(xp_val)
		_check_level_up()

func on_enemy_killed(u: Unit) -> void:
	# kills during the defeat banner must not score — the HUD repaints the live score every frame, so an unguarded hook pumps a visibly moving value.
	if dead:
		return
	var pts: Variant = data.get("units", {}).get(u.unit_type, {}).get("points")
	var base := float(pts) if pts != null else 200.0
	score += base * float(u.level) * float(challenge)

func notify_died(u: Unit) -> void:
	if u == _tagged:
		_tagged = null
		_evaluate = true
	if u == _boss:
		_boss_cd = BOSS_COOLDOWN

func _check_level_up() -> void:
	if challenge > 9:
		return
	var thresholds: Array = data.get("challenge_xp", [])
	if xp > float(thresholds[challenge - 1]):
		challenge += 1
		print("[endless] challenge level -> ", challenge)
