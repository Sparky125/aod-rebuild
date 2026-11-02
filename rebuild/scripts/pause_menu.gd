extends CanvasLayer
class_name PauseMenu
## ESC pause overlay, runs while the tree is paused; RESTART re-enters the CURRENT wave (save intact), QUIT returns to the menu flow — never app exit.

const SETTINGS_PATH := "user://settings.json"
const MENU_ART := "res://assets/ui/menu/"
const HUD_ART := "res://assets/ui/hud/"
# native texture px -> screen px at the 960x640 design size (ratio 480/1024, world drawn 2x)
const ART_PX := (480.0 / 1024.0) * 2.0

var main: Node2D

var _root: Control
var _wave_label: Label
var _sound_btn: TextureButton
var _music_btn: TextureButton
var _sound_check: TextureRect
var _music_check: TextureRect
var sound_on := true
var music_on := true

func _ready() -> void:
	layer = 40
	process_mode = Node.PROCESS_MODE_ALWAYS
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.visible = false
	add_child(_root)

	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.5)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)

	var wave := Label.new()
	wave.text = GameState.wave_label()
	wave.add_theme_font_size_override("font_size", 64)  # 32 world * 2
	wave.add_theme_color_override("font_color", Color(0.93, 0.72, 0.26))
	wave.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 1))
	wave.add_theme_constant_override("shadow_offset_x", 4)
	wave.add_theme_constant_override("shadow_offset_y", 4)
	wave.add_theme_constant_override("shadow_outline_size", 8)
	wave.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	wave.position = Vector2(0, 50)
	wave.size = Vector2(960, 80)
	_root.add_child(wave)
	_wave_label = wave  # toggle() re-bakes the text on every pause-open
	if ResourceLoader.exists("res://assets/fonts/DroidSerif-Bold.ttf"):
		wave.add_theme_font_override("font", load("res://assets/fonts/DroidSerif-Bold.ttf"))

	_root.add_child(_plate(HUD_ART + "paused", Vector2(480.0 - 170.0 * ART_PX, 130.0),
		Vector2(340.0, 146.0) * ART_PX))

	var resume := _button(HUD_ART + "resume_button", Vector2(269.0, 138.0) * ART_PX,
		Vector2(480.0 - 134.5 * ART_PX, 330.0 - 69.0 * ART_PX))
	resume.pressed.connect(_on_resume)
	_root.add_child(resume)

	var restart := _button(HUD_ART + "restart", Vector2(174.0, 138.0) * ART_PX,
		Vector2(440.0 - 87.0 * ART_PX, 470.0 - 69.0 * ART_PX))
	restart.pressed.connect(_on_restart)
	_root.add_child(restart)

	var quit := _button(HUD_ART + "quit_button", Vector2(191.0, 98.0) * ART_PX,
		Vector2(500.0, 470.0 - 49.0 * ART_PX))
	quit.pressed.connect(_on_quit)
	_root.add_child(quit)

	_music_btn = _button(MENU_ART + "music_button", Vector2(260.0, 112.0) * ART_PX,
		Vector2(480.0 - 250.0 * ART_PX, 588.0 - 56.0 * ART_PX))
	_music_btn.pressed.connect(_on_music)
	_root.add_child(_music_btn)
	_sound_btn = _button(MENU_ART + "sound_button", Vector2(260.0, 112.0) * ART_PX,
		Vector2(480.0 + 10.0 * ART_PX, 588.0 - 56.0 * ART_PX))
	_sound_btn.pressed.connect(_on_sound)
	_root.add_child(_sound_btn)
	_music_check = _check_mark(_music_btn)
	_sound_check = _check_mark(_sound_btn)

func _plate(art_path: String, pos: Vector2, sz: Vector2) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = load(art_path + ".webp")
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.position = pos
	tr.size = sz
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return tr

func _button(art_path: String, sz: Vector2, pos: Vector2) -> TextureButton:
	var b := TextureButton.new()
	b.texture_normal = load(art_path + ".webp")
	b.ignore_texture_size = true
	b.stretch_mode = TextureButton.STRETCH_SCALE
	b.position = pos
	b.size = sz
	b.mouse_entered.connect(func() -> void:
		b.modulate = Color(0.7, 0.7, 0.7, 1.0))
	b.mouse_exited.connect(func() -> void: b.modulate = Color.WHITE)
	return b

func _check_mark(btn: TextureButton) -> TextureRect:
	var c := TextureRect.new()
	c.texture = load(MENU_ART + "check.webp")
	c.stretch_mode = TextureRect.STRETCH_SCALE
	c.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	c.size = Vector2(84.0, 82.0) * ART_PX
	c.position = Vector2(btn.size.x - c.size.x, btn.size.y - c.size.y)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	btn.add_child(c)
	return c

func _click() -> void:
	if main != null:
		main.play_sfx("ui_button_02")

func _on_resume() -> void:
	_click()
	toggle()

func _on_restart() -> void:
	# re-enter the CURRENT wave with the save intact — NOT new-game, nothing is wiped.
	_click()
	GameState.save()
	_root.visible = false
	get_tree().paused = false
	if main != null:
		main.start_wave(GameState.current_wave)

func _on_quit() -> void:
	# leave for the menu flow — teardown_battle() strips the abandoned wave; never get_tree().quit().
	_click()
	GameState.save()
	_root.visible = false
	get_tree().paused = false
	if main != null:
		main.teardown_battle()
	if main != null and main.menus != null:
		if main.menus.is_open():
			main.menus.close()
		main.menus.open_upgrades()

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo \
			and event.keycode == KEY_ESCAPE:
		toggle()
		get_viewport().set_input_as_handled()

func is_open() -> bool:
	return _root.visible

func toggle() -> void:
	var opening := not _root.visible
	_root.visible = opening
	get_tree().paused = opening
	if opening:
		# re-bake from the LIVE wave or the label stays frozen at boot (this node persists; the original rebuilt its window per pause-open).
		_wave_label.text = GameState.wave_label()
		sound_on = not AudioServer.is_bus_mute(AudioServer.get_bus_index("SFX")) \
			if AudioServer.get_bus_index("SFX") >= 0 else sound_on
		music_on = not AudioServer.is_bus_mute(AudioServer.get_bus_index("Music")) \
			if AudioServer.get_bus_index("Music") >= 0 else music_on
		_sound_check.visible = sound_on
		_music_check.visible = music_on

func _on_sound() -> void:
	set_sound(not sound_on)

func _on_music() -> void:
	set_music(not music_on)

## shared with the main-menu options screen — one settings writer for both entry points.
func set_sound(on: bool) -> void:
	sound_on = on
	var idx := AudioServer.get_bus_index("SFX")
	if idx >= 0:
		AudioServer.set_bus_mute(idx, not sound_on)
	_sound_check.visible = sound_on
	_click()
	_save_settings()

func set_music(on: bool) -> void:
	music_on = on
	var idx := AudioServer.get_bus_index("Music")
	if idx >= 0:
		AudioServer.set_bus_mute(idx, not music_on)
	_music_check.visible = music_on
	_click()
	_save_settings()

func _save_settings() -> void:
	var text := JSON.stringify({
		"version": 2,
		"volume": db_to_linear(AudioServer.get_bus_volume_db(0)),
		"muted": AudioServer.is_bus_mute(0),
		"sound_on": sound_on,
		"music_on": music_on,
	})
	var f := FileAccess.open(SETTINGS_PATH, FileAccess.WRITE)
	if f != null:
		f.store_string(text)
		f.close()
	# Web: user:// flush is unreliable there — localStorage is the durable copy (see WebStore).
	WebStore.put("settings", text)

## external persistence hook — the M-key global mute writes through this so it survives a restart.
func save_audio_settings() -> void:
	_save_settings()

## boot-time audio restore: fresh installs default sound/music ON; player-set mutes persist and are honored.
static func apply_saved_audio() -> void:
	var vol := 0.8
	var muted := false
	var sound_on := true
	var music_on := true
	# Web: localStorage is the durable copy; fall back to the user:// file and adopt it into the mirror.
	var text := WebStore.get_item("settings")
	if text.is_empty() and FileAccess.file_exists(SETTINGS_PATH):
		text = FileAccess.get_file_as_string(SETTINGS_PATH)
		if not text.is_empty():
			WebStore.put("settings", text)
	var parsed: Variant = JSON.parse_string(text) if not text.is_empty() else null
	if parsed is Dictionary and int(parsed.get("version", 0)) >= 1:
		vol = clampf(float(parsed.get("volume", 0.8)), 0.0, 1.0)
		muted = bool(parsed.get("muted", false))
		sound_on = bool(parsed.get("sound_on", true))
		music_on = bool(parsed.get("music_on", true))
	AudioServer.set_bus_volume_db(0, linear_to_db(maxf(vol, 0.0001)))
	AudioServer.set_bus_mute(0, muted)
	var sfx := AudioServer.get_bus_index("SFX")
	if sfx >= 0:
		AudioServer.set_bus_mute(sfx, not sound_on)
	var mus := AudioServer.get_bus_index("Music")
	if mus >= 0:
		AudioServer.set_bus_mute(mus, not music_on)
