class_name TutorialController
extends Node
## Waves 1-3 interactive tutorials + the default smithy-upgrade prompt; every screen no-ops when its target node is missing (skippable-safe).

const FADE := 0.25                 # every wave actor's fade_time
const IRON_TRIGGER := 30           # default.lua iron_trigger_count = globals.iron_level_cap_upgrade_price[1]
const TEXT := {
	"protect_the_book": "Protect the book!",
	"touch_screen": "Touch the screen",
	"to_move_ash": "to move Ash left or right",
	"ash_attacks_auto": "Ash attacks automatically",
	"tap_skill_button": "Tap the Skill button",
	"for_powerful_attack": "for a powerful attack",
	"ash_is_hurt": "Ash is hurt!",
	"run_left": "Run left to avoid attacks",
	"you_lose_if_fall": "You lose if he falls",
	"smithy_makes_iron": "Smithy makes iron",
	"to_summon_allies": "to summon allies",
	"tap_peasant": "Tap the peasant",
	"to_summon_him": "to summon him",
	"grab_iron": "Grab iron bars",
	"for_smithy": "for your smithy",
	"grab_coins": "Grab gold coins",
	"for_upgrades": "for upgrades",
	"upgrade_smithy": "Upgrade your smithy",
	"so_he_works_faster": "so he works faster",
}

var main: Node2D

# layer 20 sits above the HUD (10), below the pause menu (40); PROCESS_MODE_ALWAYS keeps the wave-1 hurt modal alive while the tree is paused.
var _layer: CanvasLayer
var _banners: Array = []           # live banner/pointer controls to fade on teardown
var _first_enemy: Unit = null      # wave_01.lua unitSpawned bookkeeping
var _wave := 0                     # 0 = inactive

# wave 1 stages: 1 gate banner, 2 move Ash, 3 auto-attack, 4 banner + first-enemy damage watch, 5 skill button.
var _w1_stage := 0
var _w1_p2_done := false  # the "attacks automatically" banner's 3.0 s timer fired
# wave 2 stages: 1 smithy-iron banner, 2 tap-the-peasant
var _w2_stage := 0
# wave 3: iron banner armed after 1.25 s, gold banner armed past x=750
var _w3_iron_shown := false
var _w3_gold_shown := false
var _w3_iron_banner: Control = null  # dismissed once ash.x > 400 (wave_03.lua:73)
# ash damage watchers (wave_01 0.75 / wave_02 0.5) fire once per wave
var _ash_warned := false
# default.lua smithy prompt: armed on script-less waves (4+) until seen
var _smithy_watch := false
var _smithy_prompt: Control = null

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_layer = CanvasLayer.new()
	_layer.layer = 20
	add_child(_layer)
	main.spawner.enemy_spawned.connect(_on_enemy_spawned)

func _on_enemy_spawned(_u: Unit) -> void:
	if _first_enemy == null:
		_first_enemy = _u

func on_wave_started(n: int) -> void:
	cancel_all()
	_wave = n
	_first_enemy = null
	_ash_warned = false
	_w1_p2_done = false
	_w3_iron_shown = false
	_w3_gold_shown = false
	_w3_iron_banner = null
	if n == 1:
		_wave1_start()
	elif n == 2:
		_wave2_start()
	elif n == 3:
		_wave3_start()
	elif n > 3:
		_smithy_watch = n < 7 and not main.endless_mode \
			and not GameState.seen_smithy_tutorial

func cancel_all() -> void:
	_wave = 0
	_w1_stage = 0
	_w1_p2_done = false
	_w2_stage = 0
	_smithy_watch = false
	_w3_iron_banner = null
	_hero_banner = null
	for c: Control in _banners:
		if is_instance_valid(c):
			c.queue_free()
	_banners.clear()
	_smithy_prompt = null
	hud().set_spells_visible(true)

func _process(_dt: float) -> void:
	if _wave <= 0 or main.wave_over:
		return
	match _wave:
		1:
			_wave1_tick()
		2:
			_wave2_tick()
		3:
			_wave3_tick()
	if _smithy_watch:
		_smithy_tick()

func _wave1_start() -> void:
	hud().set_spells_visible(false)
	main.spawner.factor = 0
	# the flash outline rides the LIVE cage sprite's rect — deriving center + size from it means they can never drift.
	var flash: Sprite2D = null
	if main.gate != null and is_instance_valid(main.gate):
		var cage := _cage_sprite()
		flash = Sprite2D.new()
		flash.texture = _tex_or("res://assets/map/gate_white_flash.webp", _gate_flash_tex)
		flash.z_index = 1
		if cage != null:
			flash.position = cage.position
			# same world rect even if the twin PNGs' pixel sizes ever diverge
			var ft: Texture2D = flash.texture
			if ft != null and cage.texture != null \
					and ft.get_size().x > 0.0 and ft.get_size().y > 0.0:
				flash.scale = cage.scale * (cage.texture.get_size() / ft.get_size())
			else:
				flash.scale = cage.scale
		else:
			flash.scale = Vector2(0.5, 0.5)  # 2px/world fallback (skippable-safe)
		main.gate.add_child(flash)
		_pulse_alpha(flash, 0.6)
	var banner := _mk_banner([TEXT["protect_the_book"]], "top")
	_track(banner)
	if main.gate != null and is_instance_valid(main.gate):
		var arrow := _mk_arrow("left", banner.size * 0.0 + Vector2(60.0, 6.0))
		var gp: Vector2 = main.gate.global_position + Vector2(0.0, -70.0)
		arrow.position = _world_to_screen(gp) + Vector2(60.0, 0.0)
		_bounce(arrow, Vector2(-1.0, 0.0))
	get_tree().create_timer(3.5).timeout.connect(func() -> void:
		if _wave != 1 or main.wave_over:
			return
		_fade_out_free(banner)
		_banners.erase(banner)
		if flash != null and is_instance_valid(flash):
			var tw := flash.create_tween()
			tw.tween_property(flash, "modulate:a", 0.0, FADE)
			tw.tween_callback(flash.queue_free)
		_wave1_part1())

func _cage_sprite() -> Sprite2D:
	## exact texture-path match so the damage flash never collides with this outline child; null keeps the step skippable-safe.
	for c in main.gate.get_children():
		if c is Sprite2D and (c as Sprite2D).texture != null \
				and (c as Sprite2D).texture.resource_path == "res://assets/map/gate.webp":
			return c
	return null

func _wave1_part1() -> void:
	if ash_x() > 350.0:
		main.spawner.factor = 1
		_w1_stage = 3
		return
	_w1_stage = 2
	var banner := _mk_banner([TEXT["touch_screen"], TEXT["to_move_ash"]], "top")
	_track(banner)
	var left := _mk_arrow("left", Vector2.ZERO)
	left.position = banner.position + Vector2(banner.size.x * 0.5 + 40.0, banner.size.y + 6.0)
	left.flip_h = true
	_bounce(left, Vector2(-1.0, 0.0))
	_track(left)
	var right := _mk_arrow("right", Vector2.ZERO)
	right.position = banner.position + Vector2(banner.size.x * 0.5 - 40.0, banner.size.y + 6.0)
	_bounce(right, Vector2(1.0, 0.0))
	_track(right)

func _wave1_tick() -> void:
	match _w1_stage:
		2:
			if ash_x() > 400.0:
				_w1_stage = 3
				_clear_tracked()
				main.spawner.factor = 1
		3:
			if _enemy_within(250.0):
				_w1_stage = 4
				_wave1_part2()
		4:
			# the banner dismisses itself after 3.0 s; the stage HOLDS until the first enemy is gone or below 65% health before Part 3.
			if _w1_p2_done and _first_enemy_hurt():
				_w1_stage = 5
				_wave1_part3()
		5:
			var equipped: Array = main.equipped_spells()
			if equipped.is_empty() or main.spell_cooldowns.get(equipped[0], 0.0) > 0.0:
				_w1_stage = 0
				_clear_tracked()
	if not _ash_warned and ash_ratio() < 0.75 and ash_x() >= 0.0:
		_ash_warned = true
		_wave1_ash_hit()

func _wave1_part2() -> void:
	var banner := _mk_banner([TEXT["ash_attacks_auto"]], "top")
	_track(banner)
	get_tree().create_timer(3.0).timeout.connect(func() -> void:
		if _wave != 1 or main.wave_over:
			return
		_fade_out_free(banner)
		_banners.erase(banner)
		_w1_p2_done = true)

func _first_enemy_hurt() -> bool:
	if _first_enemy == null or not is_instance_valid(_first_enemy) \
			or _first_enemy.state == Unit.State.DEAD:
		return true
	return _first_enemy.max_health > 0.0 \
		and _first_enemy.health / _first_enemy.max_health < 0.65

func _wave1_part3() -> void:
	hud().set_spell_button_visible(0, true)
	var banner := _mk_banner([TEXT["tap_skill_button"], TEXT["for_powerful_attack"]], "top")
	_track(banner)
	var btn: Control = _spell_button(0)
	if btn != null:
		var circle := _mk_circle_over(btn)
		_track(circle)
		circle.pressed.connect(func() -> void:
			var equipped: Array = main.equipped_spells()
			if not equipped.is_empty() and _w1_stage == 5:
				main.cast_spell(equipped[0]))
		var arrow := _mk_arrow("right", Vector2(16.0, 0.0))
		# the arrow art points LEFT: seat it on the button's RIGHT side, its
		# left edge overlapping the plate edge by 16 px
		arrow.position = btn.get_global_rect().end + Vector2(-16.0 - arrow.size.x, \
			(btn.size.y - arrow.size.y) * 0.5)
		_bounce(arrow, Vector2(1.0, 0.0))
		_track(arrow)

func _wave1_ash_hit() -> void:
	get_tree().paused = true
	if _w1_stage in [2, 3, 4]:
		for c: Control in _banners:
			if is_instance_valid(c):
				c.modulate.a = 0.0  # the Lua fades any open banner out
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.0)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_layer.add_child(dim)
	var tw := dim.create_tween()
	tw.tween_property(dim, "color:a", 0.5, FADE)
	var banner := _mk_banner([TEXT["ash_is_hurt"], TEXT["run_left"]], "top")
	var arrow := _mk_arrow("right", Vector2.ZERO)
	arrow.position = banner.position - Vector2(arrow.size.x + 8.0, 0.0)
	arrow.mouse_entered.connect(_dismiss_wave1_hurt.bind(dim, banner, arrow))
	# TextureRect has no "pressed" signal -- tap/click dismissal goes through
	# gui_input instead (covers mouse and touch)
	arrow.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed:
			_dismiss_wave1_hurt(dim, banner, arrow))
	# failsafe: the modal can never hold the game paused for long
	get_tree().create_timer(6.0).timeout.connect(func() -> void:
		if is_instance_valid(arrow):
			_dismiss_wave1_hurt(dim, banner, arrow))
	var pulse := arrow.create_tween()
	pulse.set_loops()
	pulse.tween_property(arrow, "modulate:a", 0.3, 0.7)
	pulse.tween_property(arrow, "modulate:a", 1.0, 0.7)

func _dismiss_wave1_hurt(dim: ColorRect, banner: Control, arrow: Control) -> void:
	## Unpauses and fades the wave-1 hurt modal (hover, tap, or failsafe
	## timer all converge here; guarded so extra calls are harmless).
	if not get_tree().paused:
		return
	get_tree().paused = false
	var twd := dim.create_tween()
	twd.tween_property(dim, "color:a", 0.0, FADE)
	twd.tween_callback(dim.queue_free)
	if is_instance_valid(banner):
		_fade_out_free(banner)
		_banners.erase(banner)
	if is_instance_valid(arrow):
		_fade_out_free(arrow)
	if _w1_stage in [2, 3, 4]:
		for c: Control in _banners:
			if is_instance_valid(c):
				c.modulate.a = 1.0

func _wave2_start() -> void:
	_w2_stage = 1
	_wave2_part1()

func _wave2_part1() -> void:
	var banner := _mk_banner([TEXT["smithy_makes_iron"], TEXT["to_summon_allies"]], "bottom-right")
	_track(banner)
	var chip: Control = hud().smith_chip
	if chip != null:
		var arrow := _mk_arrow("left", Vector2(-16.0, 0.0))
		arrow.position = chip.get_global_rect().position - arrow.size + Vector2(-16.0, \
			(chip.size.y - arrow.size.y) * 0.5)
		_bounce(arrow, Vector2(-1.0, 0.0))
		_track(arrow)

func _wave2_tick() -> void:
	match _w2_stage:
		1:
			if main.iron > 4.5:
				_w2_stage = 2
				_clear_tracked()
				get_tree().create_timer(FADE + 0.5).timeout.connect(func() -> void:
					if _wave == 2 and not main.wave_over and _w2_stage == 2:
						_wave2_part2())
		2:
			if _ally_alive("peasant"):
				_w2_stage = 0
				_clear_tracked()
	# wave-2 hurt warning: banner + 3 small arrows for 5 s — NO pause (unlike wave 1's modal).
	if not _ash_warned and ash_ratio() < 0.5 and ash_x() >= 0.0:
		_ash_warned = true
		_wave2_ash_hit()

func _wave2_part2() -> void:
	var banner := _mk_banner([TEXT["tap_peasant"], TEXT["to_summon_him"]], "bottom-right")
	_track(banner)
	var btn: Control = hud().unit_buttons.get("peasant", {}).get("btn", null)
	if btn == null:
		return  # loadout without a peasant: nothing to point at
	var circle := _mk_circle_over(btn)
	_track(circle)
	circle.pressed.connect(func() -> void:
		if _w2_stage == 2:
			main.summon_ally("peasant"))
	var arrow := _mk_arrow("down", Vector2.ZERO)
	arrow.position = btn.get_global_rect().get_center() \
		+ Vector2(-arrow.size.x * 0.5, btn.size.y * 0.5 + 4.0)
	_bounce(arrow, Vector2(0.0, 1.0))
	_track(arrow)

func _wave2_ash_hit() -> void:
	var banner := _mk_banner([TEXT["ash_is_hurt"], TEXT["you_lose_if_fall"]], "top")
	_track(banner)
	var lb: Control = _ash_lifebar_anchor()
	if lb != null:
		for i in 3:
			var arrow := _mk_arrow("up", Vector2.ZERO)
			arrow.scale = Vector2(0.3, 0.3)
			arrow.position = lb.global_position + Vector2(48.0 + float(i) * 22.0, -arrow.size.y * 0.3 - 2.0)
			_bounce(arrow, Vector2(0.0, -1.0), 0.5, 0.2)
			_track(arrow)
	get_tree().create_timer(5.0).timeout.connect(func() -> void:
		if _wave != 2 or main.wave_over:
			return
		_clear_tracked())

func _wave3_start() -> void:
	for i in 3:
		var x := 415.0 + 15.0 * float(i)
		var coin: Variant = main.spawn_coin_at(x, true, 1)
		if i == 1:
			set_meta("w3_iron_bar", coin)
	for i in 3:
		var gx := 965.0 + 15.0 * float(i)
		var coin2: Variant = main.spawn_coin_at(gx, false, 5)
		if i == 1:
			set_meta("w3_gold_coin", coin2)
	get_tree().create_timer(1.25).timeout.connect(func() -> void:
		if _wave != 3 or main.wave_over or _w3_iron_shown:
			return
		_w3_iron_shown = true
		_w3_iron_banner = _mk_banner([TEXT["grab_iron"], TEXT["for_smithy"]], "top")
		_track(_w3_iron_banner)
		_mk_circle_on_coin(get_meta("w3_iron_bar", null)))

func _wave3_tick() -> void:
	if not _w3_gold_shown and ash_x() > 750.0:
		_w3_gold_shown = true
		var banner := _mk_banner([TEXT["grab_coins"], TEXT["for_upgrades"]], "top")
		_track(banner)
		_mk_circle_on_coin(get_meta("w3_gold_coin", null))
	if _w3_iron_shown and ash_x() > 400.0:
		# the circle rides the coin — deliberately left parented to it.
		if _w3_iron_banner != null and is_instance_valid(_w3_iron_banner):
			_fade_out_free(_w3_iron_banner)
			_banners.erase(_w3_iron_banner)
		_w3_iron_banner = null
	if _w3_gold_shown and ash_x() > 950.0:
		_clear_tracked()

func _smithy_tick() -> void:
	if _smithy_prompt == null:
		if main.iron >= IRON_TRIGGER:
			_smithy_prompt = _mk_banner(
				[TEXT["upgrade_smithy"], TEXT["so_he_works_faster"]], "top")
			_track(_smithy_prompt)
			var chip: Control = hud().smith_chip
			if chip != null:
				var circle := _mk_circle_over(chip)
				_track(circle)
				circle.pressed.connect(func() -> void:
					_smithy_pressed())
				var arrow := _mk_arrow("down", Vector2.ZERO)
				arrow.position = chip.get_global_rect().get_center() \
					+ Vector2(-arrow.size.x * 0.5, chip.size.y * 0.5 + 4.0)
				_bounce(arrow, Vector2(0.0, 1.0))
				_track(arrow)
	else:
		if main.iron < IRON_TRIGGER:
			_fade_out_free(_smithy_prompt)
			_banners.erase(_smithy_prompt)
			_smithy_prompt = null
			_clear_tracked()

func _smithy_pressed() -> void:
	GameState.seen_smithy_tutorial = true
	_smithy_watch = false
	main.upgrade_iron_cap()
	if _smithy_prompt != null:
		_fade_out_free(_smithy_prompt)
		_banners.erase(_smithy_prompt)
		_smithy_prompt = null
	_clear_tracked()

func ash_x() -> float:
	if main.ash == null or not is_instance_valid(main.ash):
		return -1.0  # "no ash" also gates the damage watchers
	return main.ash.position.x

func ash_ratio() -> float:
	if main.ash == null or not is_instance_valid(main.ash) or main.ash.max_health <= 0.0:
		return 1.0
	return main.ash.health / main.ash.max_health

func _enemy_within(dist: float) -> bool:
	var ax := ash_x()
	if ax < 0.0:
		return false
	for u: Unit in main._team_objects(Unit.Team.ENEMY):
		if u.state != Unit.State.DEAD and absf(u.position.x - ax) < dist:
			return true
	return false

func _ally_alive(type_name: String) -> bool:
	for u: Unit in main._team_objects(Unit.Team.ALLY):
		if u.state != Unit.State.DEAD and u.unit_type == type_name:
			return true
	return false

func _on_wave_check() -> void:
	pass  # reserved

var _hero_banner: Control = null

func show_hero_banner(text: String) -> void:
	## hero "spawn_" tag banner: tutorial_box art top-centre, alpha in over FADE, holds 3 s, alpha out, freed; re-triggerable — a live banner is replaced.
	if _hero_banner != null and is_instance_valid(_hero_banner):
		_hero_banner.queue_free()
		_banners.erase(_hero_banner)
	var panel := PanelContainer.new()
	var art := _tex_or("res://assets/ui/hud/tutorial_box.webp")
	if art != null:
		var tr := TextureRect.new()
		tr.texture = art
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		tr.custom_minimum_size = Vector2(720.0, 192.0) * (480.0 / 1024.0) * 2.0
		panel.add_child(tr)
		var vb := VBoxContainer.new()
		vb.set_anchors_preset(Control.PRESET_FULL_RECT)
		vb.alignment = BoxContainer.ALIGNMENT_CENTER
		tr.add_child(vb)
		vb.add_child(_mk_label(text, 44, Color.WHITE, true))  # 22 world * 2
	else:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.09, 0.08, 0.07, 0.92)
		sb.border_color = Color(0.45, 0.4, 0.32)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		sb.set_content_margin_all(10.0)
		panel.add_theme_stylebox_override("panel", sb)
		panel.add_child(_mk_label(text, 44, Color.WHITE, true))
	_layer.add_child(panel)
	# MOUSE_FILTER_IGNORE is load-bearing: the STOP default turned these banners into invisible dead zones on touch.
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.reset_size()
	panel.position = Vector2((960.0 - panel.size.x) * 0.5, 48.0)
	panel.modulate.a = 0.0
	var tw := panel.create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, FADE)
	_hero_banner = panel
	_track(panel)
	get_tree().create_timer(FADE + 3.0).timeout.connect(func() -> void:
		if not is_instance_valid(panel):
			return
		_fade_out_free(panel)
		_banners.erase(panel)
		if _hero_banner == panel:
			_hero_banner = null)

func hud() -> CanvasLayer:
	return main.hud

func _track(c: Control) -> void:
	_banners.append(c)

func _clear_tracked() -> void:
	for c: Control in _banners:
		if is_instance_valid(c):
			_fade_out_free(c)
	_banners.clear()

func _fade_out_free(c: Control, dur := FADE) -> void:
	if c == null or not is_instance_valid(c):
		return
	var tw := c.create_tween()
	tw.tween_property(c, "modulate:a", 0.0, dur)
	tw.tween_callback(c.queue_free)

func _mk_banner(lines: Array, where: String) -> Control:
	## synchronous: the panel sizes to its combined in-tree minimum, so callers read size/position right away.
	var panel := PanelContainer.new()
	var art := _tex_or("res://assets/ui/hud/tutorial_box.webp")
	if art != null:
		var tr := TextureRect.new()
		tr.texture = art
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		tr.custom_minimum_size = art.get_size() * 0.5  # 2px/world art at half px
		panel.add_child(tr)
		var vb := VBoxContainer.new()
		vb.set_anchors_preset(Control.PRESET_FULL_RECT)
		vb.alignment = BoxContainer.ALIGNMENT_CENTER
		tr.add_child(vb)
		for line: String in lines:
			vb.add_child(_mk_label(line, 18, Color.WHITE))
	else:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0.09, 0.08, 0.07, 0.92)
		sb.border_color = Color(0.45, 0.4, 0.32)
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(6)
		sb.set_content_margin_all(10.0)
		panel.add_theme_stylebox_override("panel", sb)
		var vb2 := VBoxContainer.new()
		vb2.add_theme_constant_override("separation", 2)
		panel.add_child(vb2)
		for line: String in lines:
			var bold: bool = line == lines[0]
			vb2.add_child(_mk_label(line, 18 if bold else 14,
				Color.WHITE if bold else Color(0.92, 0.9, 0.82), bold))
	_layer.add_child(panel)
	# MOUSE_FILTER_IGNORE is load-bearing: the STOP default turned these banners into invisible dead zones on touch.
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.reset_size()  # combined minimum (in-tree) — no frame wait needed
	match where:
		"top":
			panel.position = Vector2((960.0 - panel.size.x) * 0.5, 14.0)
		"bottom-right":
			panel.position = Vector2(960.0 - panel.size.x - 16.0, 640.0 - panel.size.y - 190.0)
	panel.modulate.a = 0.0
	var tw := panel.create_tween()
	tw.tween_property(panel, "modulate:a", 1.0, FADE)
	return panel

func _mk_label(text: String, size: int, color: Color, bold := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if bold:
		l.add_theme_constant_override("outline_size", 4)
		l.add_theme_color_override("font_outline_color", Color(0.05, 0.05, 0.05))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l

func _mk_arrow(direction: String, _offset: Vector2) -> TextureRect:
	var a := TextureRect.new()
	a.texture = _tex_or("res://assets/ui/hud/tutorial_arrow.webp", _arrow_tex)
	a.ignore_texture_size = true
	a.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	a.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	a.size = Vector2(64.0, 40.0)
	a.pivot_offset = a.size * 0.5
	a.mouse_filter = Control.MOUSE_FILTER_STOP  # the hurt-modal arrow is a button
	a.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	match direction:
		"left":
			a.flip_h = true
		"down":
			a.rotation = PI * 0.5
		"up":
			a.rotation = -PI * 0.5
	_layer.add_child(a)
	return a

func _bounce(node: Control, dir: Vector2, magnitude := 32.0, speed := 0.4) -> void:
	var home: Vector2 = node.position
	var tw := node.create_tween()
	tw.set_loops()
	tw.tween_property(node, "position", home + dir * magnitude, speed) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)  # Fall
	tw.tween_property(node, "position", home, speed) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)  # Ramp

func _pulse(node: Control) -> void:
	var tw := node.create_tween()
	tw.set_loops()
	tw.tween_property(node, "scale", Vector2(1.25, 1.25), 0.4) \
		.set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(node, "scale", Vector2.ONE, 0.4) \
		.set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)

func _pulse_alpha(node: Sprite2D, duration: float) -> void:
	var half := duration * 0.5
	var tw := node.create_tween()
	tw.set_loops()
	tw.tween_property(node, "modulate:a", 1.0, half).set_trans(Tween.TRANS_SINE)
	tw.tween_property(node, "modulate:a", 0.0, half).set_trans(Tween.TRANS_SINE)

func _mk_circle_over(ctrl: Control) -> TextureButton:
	## sized over a HUD control; sits ON TOP and forwards its press to the real handler.
	var b := TextureButton.new()
	b.texture_normal = _tex_or("res://assets/ui/hud/tutorial_circle.webp", _circle_tex)
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	var d: float = maxf(ctrl.size.x, ctrl.size.y) * 1.25
	b.size = Vector2(d, d)
	b.position = ctrl.get_global_rect().get_center() - b.size * 0.5
	b.pivot_offset = b.size * 0.5
	_layer.add_child(b)
	_pulse(b)
	return b

func _mk_circle_on_coin(coin: Variant) -> void:
	if coin == null or not is_instance_valid(coin):
		return
	var spr := Sprite2D.new()
	spr.texture = _tex_or("res://assets/ui/hud/tutorial_circle.webp", _circle_tex)
	spr.scale = Vector2.ONE * 0.8
	spr.z_index = 50
	(coin as Node2D).add_child(spr)
	var tw := spr.create_tween()
	tw.set_loops()
	tw.tween_property(spr, "scale", Vector2.ONE, 0.4).set_trans(Tween.TRANS_SINE)
	tw.tween_property(spr, "scale", Vector2.ONE * 1.25, 0.4).set_trans(Tween.TRANS_SINE)

func _spell_button(slot: int) -> Control:
	var arr: Array = hud().spell_buttons
	if slot < 0 or slot >= arr.size():
		return null
	return arr[slot]["btn"]

func _ash_lifebar_anchor() -> Control:
	var hud_layer: CanvasLayer = hud()
	for c in hud_layer.get_children():
		if c is TextureRect and (c as TextureRect).texture != null \
				and (c as TextureRect).texture.resource_path.ends_with("ash_lifebar_back.webp"):
			return c
	return null  # caller skips the arrows (skippable-safe)

func _world_to_screen(world: Vector2) -> Vector2:
	var cam: Camera2D = main.camera
	var half := main.get_viewport_rect().size * 0.5
	return (world - cam.get_screen_center_position()) * cam.zoom.x + half

static var _arrow_tex_cache: ImageTexture
static var _circle_tex_cache: ImageTexture
static var _gate_flash_cache: GradientTexture2D

func _tex_or(path: String, fallback := Callable()) -> Texture2D:
	## the staged art when present, else the generated stand-in (Callable).
	if ResourceLoader.exists(path):
		return load(path)
	if fallback.is_valid():
		return fallback.call()
	return null

static func _arrow_tex() -> ImageTexture:
	if _arrow_tex_cache != null:
		return _arrow_tex_cache
	var img := Image.create(64, 40, false, Image.FORMAT_RGBA8)
	for y in 40:
		var t := 1.0 - absf(float(y) - 19.5) / 20.0
		var length := int(52.0 * clampf(t, 0.0, 1.0))
		for x in range(8, 8 + maxi(length, 1)):
			img.set_pixel(x, y, Color(1, 1, 1, 1))
	_arrow_tex_cache = ImageTexture.create_from_image(img)
	return _arrow_tex_cache

static func _circle_tex() -> ImageTexture:
	if _circle_tex_cache != null:
		return _circle_tex_cache
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	var c := Vector2(31.5, 31.5)
	for y in 64:
		for x in 64:
			var d := Vector2(float(x), float(y)).distance_to(c)
			if d >= 26.0 and d <= 31.0:
				img.set_pixel(x, y, Color(1, 1, 1, 1))
	_circle_tex_cache = ImageTexture.create_from_image(img)
	return _circle_tex_cache

static func _gate_flash_tex() -> GradientTexture2D:
	if _gate_flash_cache != null:
		return _gate_flash_cache
	var g := Gradient.new()
	g.set_color(0, Color(1, 1, 1, 1))
	g.set_color(1, Color(1, 1, 1, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill = GradientTexture2D.FILL_RADIAL
	gt.fill_from = Vector2(0.5, 0.5)
	gt.fill_to = Vector2(0.5, 0.0)
	gt.width = 128
	gt.height = 256
	_gate_flash_cache = gt
	return gt
